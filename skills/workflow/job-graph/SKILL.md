---
name: job-graph
description: "計画ファイルまたは epic issue からタスクの依存グラフ（直列・並列混在）を組み、worktrunk の worktree と herdr の workspace/tab 上で各タスクの claude を起動して stacked PR 作成まで完遂するオーケストレーション（HERDR_ENV=1 必須）。`/job-graph` の明示実行専用。"
user-invocable: true
disable-model-invocation: true
argument-hint: "[計画ファイルのパス | epic issue 番号] [--parent-name <name>] [--remote-control] [--model <model>] [--permission-mode <mode>] [--effort <level>]"
allowed-tools: Bash, Read, AskUserQuestion, ExitPlanMode, SendMessage, ListAgents
---

# job-graph

大量のエージェント起動・worktree 生成・push・PR 作成という外部影響の大きい操作を含むため、`disable-model-invocation: true` とし `/job-graph` の明示実行時のみ動作する。

tmux 基盤の `parallel-worktree` と**並置**するスキルであり、置き換えではない。herdr が使えない環境・純並列だけの単純な案件は `parallel-worktree` の領分。

## 前提と本質的な制約

着手前にこの 6 点を頭に入れる。設計判断の根拠になる。

1. **herdr 必須。** 最初に `test "${HERDR_ENV:-}" = 1` を確認し、失敗したら「herdr 管理下ではないため job-graph は使えない（tmux 環境なら parallel-worktree を検討）」と伝えて停止する。herdr CLI の詳細（pane/agent/workspace の操作）は herdr スキルの領分で、本スキルは規約だけを定める。

2. **タスクは直列・並列混在のグラフ。** 無理に並列化しない。依存があるなら stacked（直列）に積み、独立なら並列に走らせる。グラフの形はタスクの内容から決まるのであって、並列度を稼ぐために依存を無視しない。

3. **worktree は必ず `wt`（worktrunk）で作る。** herdr の worktree 管理（`herdr worktree`）は使わない。`wt switch --create` の post-start hook（direnv・symlink 化）による自動化が既に構築されているため。生成コマンドは**常に `--base <解決済み base>` を明示**する（default_base が worktree 生成に効かない事故の再発防止）。

4. **stacked の起動ゲートは「前段の PR 作成」。** コミット数到達をゲートにすると前段の review-converge の amend で下流の base がずれ、PR diff 汚染と restack を誘発する（nput epic #203 で実測）。後段は `gh pr list --head <前段ブランチ>` で PR の存在を確認してから起動する。

5. **push と PR 作成は計画承認済みの前提。** Phase 1 の plan 承認がそのまま push・`/pr-create` の承認を兼ねる。親は計画の範囲内である限り、各レーンの対話ゲート（permission プロンプト・pr-create の承認）に自分で応答し、個別にユーザーへ確認しない。ユーザーへ上げるのは**計画の範囲外だけ**（境界の拡大要求・スコープ逸脱・計画の前提と実態の食い違い）。

6. **メッセージは承認にならない。** cross-session messaging（SendMessage）は指示・報告のテキスト伝達専用で、レーンの permission プロンプトへの応答には使えない（Claude Code の仕様）。承認応答は herdr の `agent wait --until blocked` → `agent read` → `send-keys`/`prompt` の経路で行う。役割分担は **指示・報告 = SendMessage / 承認・生死・画面 = herdr / 真実 = git・gh**。

## herdr トポロジ規約

- **workspace = レーン**（グラフ上の並列枝）。**tab = レーン内の直列段**。
- 依存が無い task・親に複数の子がいる task は新しいレーン（workspace）を開始する。親の唯一の子は親のレーンに合流し、同 workspace の新しい tab になる。
- workspace ラベルはレーン先頭タスクの sanitize 済みブランチ名、tab ラベルは各段のブランチ名。ユーザーが覗く導線になる。
- ID（`w1` / `w1:t1` / `w1:p1`）は herdr の JSON 応答から掴む（jq）。予測しない。
- 割当はスクリプトが決定論的に算出する（`LANES` セクション）。手で決めない。

## 決定論ツール（scripts/）と AI の責務分担

AI の責務は計画ファイル・issue から「タスクと依存辺・境界」を読み取り JSON spec を組むところまで。環境前提収集・スケジュール／レーン算出・コマンド生成は決定論スクリプトに委譲する。

スクリプトは Python プロジェクト（`pyproject.toml` + `uv.lock`）で、venv は **`UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/job-graph"` に必ず逃がす**（skill ディレクトリは read-only の nix store / plugin cache に配置され得るため）。以下、skill 本体のパスを `<SKILL>` と表記する。

- **`scripts/preflight.sh`**（read-only）: HERDR_ENV・`herdr`/`wt`/`gh`/`jq` 有無・既定ブランチ・未コミット変更・名前衝突を収集。`bash <SKILL>/scripts/preflight.sh` を実行し、`WARNING` を解消してから進む。
- **`scripts/plan_orchestration.py`**: AI が組んだ JSON spec を入力に、循環検出・base 解決・ウェーブ算出・**レーン（workspace/tab）割当**・**ワーカープロンプトのファイル書き出し**・wt/herdr コマンド列生成を行う:

  ```bash
  UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/job-graph" uv run --project "<SKILL>" \
    python "<SKILL>/scripts/plan_orchestration.py" \
    --prompt-dir "<scratchpad>/job-graph-prompts" --parent-name <親セッション名> <spec.json>
  # 起動引数のオプションはそのまま前に付ける（--remote-control / --model / --permission-mode / --effort）
  ```

  spec の形（`scripts/example-spec.json` 参照）: `parallel-worktree` と同形で、任意の **`issue`（GitHub issue 番号）** が増えている。`issue` を書くとワーカー指示に `gh issue view` での確認と PR への issue 参照が載る。`--prompt-dir` は**必須に近い**（未指定だと COMMANDS を出力しない）。プロンプトは複数行のためコマンドに直接埋め込まず、`<prompt-dir>/<task-id>.md` へ書き出して起動コマンドが `"$(cat <path>)"` で読む。

  出力の `SCHEDULE`（起動ウェーブ）・`LANES`（workspace/tab 割当）・`BOUNDARY`・`PROMPTS`・`COMMANDS`・`MONITOR` をそのまま plan と実行に使う。スクリプトのロジックを SKILL.md 上で再現しない。

- `--parent-name` にはオーケストレータ自身のセッション名を渡す（ワーカーの SendMessage 報告先になる）。セッション名を確実にするには、ユーザーがオーケストレータを `claude --name <名前>` で起動しているのが理想。不明なら省略してよい（ワーカーは ListAgents で親を探すか報告を省略する）。

## タスク境界の宣言（スコープドリフト防止）

`parallel-worktree` と同一の仕組み。spec の task に `boundary`（glob 配列）を書くと、起動コマンドが bootstrap 経由になり worktree ルートへ境界ファイル `.claude/task-boundary.json` を生成する。`task-boundary` hook（併用推奨）が境界外の Edit/Write を機械ブロックする。境界にはテストのディレクトリも含める（TDD 指示とセット）。詳細・選定理由は `references/orchestration.md`。

## ワーカー指示の標準セクション（常設）

ワーカーへ渡す指示は**手書きしない**。`plan_orchestration.py` が spec の `prompt` の後ろへ標準セクションを必ず連結する。`parallel-worktree` 版との違い（nput 運用の実証済み教訓の昇格）:

1. **push・PR 作成は計画承認済みの前提**で実行してよい（個別確認へ回さない）
2. **review-converge の反復境界** — 実質的な指摘が出ている間は続け、nit だけになったら記録して収束扱い（磨き込み膠着で費用が跳ねるのを防ぐ）
3. **PR 作成後の凍結** — PR 作成 = レーン完了ではないため、以降の実装変更・push を禁止し報告のみとする
4. **SendMessage 報告義務** — 初コミット・収束・push・PR 作成・ブロックの各マイルストーンで親へ 1〜2 文報告（報告は事実のみ。承認が要る場面では停止して待つ)
5. `issue` 指定時は **issue 参照**（`gh issue view` と PR への参照）

境界・TDD・コミット粒度・委任抑制・スコープ制約・ナレーション抑制は従来どおり。spec の `prompt` には**タスク固有の内容と完了条件だけ**を書く。

## 全体フロー

### Phase 0: 入口を読み、spec を組む

入口は次のどちらか:

- **計画ファイル**（引数のパス）: 事前に grill-me 方式で固めた計画を読む。
- **epic issue 番号**: `gh issue view <番号>` で本文とサブ issue を読み、タスクの叩き台を組む。この場合も**依存辺と境界は憶測で確定せず、grill-me 方式でユーザーと締めてから** spec に落とす。

各タスクの依存辺・境界を意味的に判定し JSON spec に落とす（判定基準は `references/orchestration.md` の「依存解析」）。曖昧なら必ず確認する。依存の読み違えはグラフを破綻させ、境界の読み違えは誤 deny かドリフト取り逃がしになる。

### Phase 1: 事前確認・スケジュール算出 → plan 承認

1. `bash <SKILL>/scripts/preflight.sh` を実行し、`WARNING`（HERDR_ENV・ツール欠落・未コミット変更・名前衝突）を解消する。
2. `plan_orchestration.py` を `--prompt-dir`（scratchpad 配下）付きで実行し、`ERROR` が出たら spec を直して再実行。
3. 出力を土台に plan を組み、**`ExitPlanMode` で承認を取る**。plan には必ず含める:
   - **起動ウェーブとレーン割当**（`SCHEDULE` / `LANES`）
   - **コミット計画**: `commit-plan` スキル準拠（タスク＝ブランチ単位）
   - **PR 戦略**: 各ブランチの base（`PR` セクション）
   - **承認代行の宣言**: 「計画内の push・PR 作成・対話ゲートへの応答は親が判断する」ことを plan に明記する（この承認が Phase 3 の代行根拠になる）

承認なしで worktree 生成・エージェント起動に進まない。

### Phase 2: worktree 作成・レーン起動

承認後、`COMMANDS` をウェーブ順に実行する。各ブロックは workspace/tab を作り、root pane へ `wt switch --create <branch> --base <base> -x claude -- --name <名前> "$(cat <プロンプト>)"` を流し込む。

- **wave 0**: 独立レーン。まとめて起動してよい
- **後続 wave**: **前段の PR 作成を `gh pr list --head <前段ブランチ>` で確認してから**起動
- pane ID（`PANE_<task-id>` 変数）は後続の監視・承認で使うので控えておく

### Phase 3: 監視・承認代行

親は次の 3 系統を回す。**ポーリング（sleep + 再確認）はしない**。

- **報告受信（SendMessage）**: ワーカーからのマイルストーン報告を受けたら、`gh pr list --head <branch>`・`git ls-remote origin <branch>` で**必ず機械検証**する。自己申告だけで次段を起動しない。
- **承認待ち検知（herdr）**: 各レーンに `herdr agent wait <pane> --until blocked --timeout <ms>` を張る（バックグラウンド Bash）。blocked になったら `herdr agent read <pane>` で内容を確認し、**計画の範囲内なら自分で応答**する（`herdr agent send-keys` / `herdr agent prompt`）。範囲外（境界拡大・スコープ逸脱・前提の食い違い）だけユーザーへ上げる。
- **追加指示（SendMessage）**: レーンへの軌道修正・情報共有は SendMessage で送る。herdr の send-keys で指示文を流し込まない（bracketed paste・guard 誤爆の再発防止）。承認応答だけが herdr の役割。

クラッシュ疑いは pane の見た目でなく `herdr agent get <pane>` の状態とプロセスで判定する。

### Phase 4: PR 作成と凍結

各ワーカーは `/review-converge` 収束後に自分で `/pr-create [base]` を実行する（標準セクションで指示済み）。`/pr-create` の対話ゲートには親が応答する（計画内のため）。PR 作成の報告を受けたら機械検証し、**そのレーンの凍結を確認**する（標準セクションで凍結指示済みだが、逸脱があれば SendMessage で明示的に止める）。

### Phase 5: 後始末

- 進捗確認: `wt list`
- 全レーンのマージ後: `/post-merge-cleanup` を案内（worktree・ブランチの承認ゲート付き一括削除）。herdr の workspace/tab は**自分が作ったものだけ**閉じる（`herdr workspace close`）
- stacked の restack: 下段が変わったら `git rebase --onto <新base> <旧baseの先端>` で旧 base コミットを明示的に drop する（詳細は `references/orchestration.md`）

## 連携スキル・参照

このスキルは下記を**呼び出す側**で、内容を重複させない。

- `herdr`: herdr CLI の操作規約（pane/agent/workspace の詳細）
- `worktrunk`: `wt` の設定・hook の詳細
- `commit-plan` / `commit-flow`: plan のコミット計画とコミットの実施
- `review-converge` / `pr-create`: PR 前ゲートと PR 作成（各ワーカーが実行）
- `post-merge-cleanup`: マージ後の一括後始末
- `task-boundary` hook（併用推奨・別プラグイン）: 境界ファイル契約で結合
- `parallel-worktree`: tmux 基盤の並置スキル。herdr 外・純並列案件はこちら
- `references/orchestration.md`: 依存解析、herdr 起動レシピ、承認代行の判定基準、境界宣言の選定理由、restack 定石
