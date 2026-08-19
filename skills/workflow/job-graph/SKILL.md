---
name: job-graph
description: "計画ファイルまたは epic issue からタスクの依存グラフ（直列・並列混在）を組み、worktrunk の worktree と herdr のレーン別 workspace（stacked は tab）上で各タスクの claude を起動して stacked PR 作成まで完遂するオーケストレーション（HERDR_ENV=1 必須）。`/job-graph` の明示実行専用。"
user-invocable: true
disable-model-invocation: true
argument-hint: "[計画ファイルのパス | epic issue 番号] [--parent-name <name>] [--remote-control] [--model <model>] [--permission-mode <mode>] [--effort <level>]"
allowed-tools: Bash, Read, AskUserQuestion, ExitPlanMode
---

# job-graph

大量のエージェント起動・worktree 生成・push・PR 作成という外部影響の大きい操作を含むため、`disable-model-invocation: true` とし `/job-graph` の明示実行時のみ動作する。

## 前提と本質的な制約

1. **herdr 必須。** `<SKILL>/scripts/preflight.sh` を実行し、前提条件（HERDR_ENV・ツール）が揃っているかを確認する。揃っていなければ WARNING を伝えて停止する。
2. **タスクは直列・並列混在のグラフ。** 無理に並列化しない。依存があるなら stacked（直列）に積み、独立なら並列に走らせる。グラフの形はタスクの内容から決まるのであって、並列度を稼ぐために依存を無視しない。
3. **worktree・起動コマンドはスクリプトが生成する。** worktree は `wt`（worktrunk）で作られ、常に `--base <解決済み base>` が明示される。手で組み立てない。
4. **stacked の起動ゲートは「前段の PR 作成」。** コミット数到達をゲートにすると前段の収束修正（amend）で下流の base がずれ、PR diff 汚染と restack を誘発する。後段は `gh pr list --head <前段ブランチ>` で PR の存在を確認してから起動する。
5. **push と PR 作成は計画承認済みの前提。** Phase 1 の plan 承認がそのまま push・`/pr-create` の承認を兼ねる。親は計画の範囲内である限り、各レーンの対話ゲートに自分で応答し、個別にユーザーへ確認しない。ユーザーへ上げるのは**計画の範囲外だけ**（境界の拡大要求・スコープ逸脱・計画の前提と実態の食い違い）。
6. **レーンの操縦・監視・承認代行は lane-ops スキルに従う。** 指示送信・blocked 検知・報告受信・機械検証・境界拡張はすべて lane-ops の運用ループとスクリプトで行う。job-graph が定めるのはグラフと起動までであり、運用規約を重複して定義しない。

herdr 上では**レーン（直列チェーン）ごとに workspace を立てる**。レーン先頭の task は `herdr workspace create` の root pane で起動し、stacked の後続段は同じレーンの workspace へ `herdr tab create` で tab を足して起動する（並列レーン = workspace の並び。レーンを別 session へ分けることはしない。session はランタイム名前空間が分かれて親の socket からレーンへ到達できなくなるため）。レーン割当と各 ID の取り回しはスクリプトが `LANES` / `COMMANDS` として決定論的に算出する。手で決めない。

`COMMANDS` に含まれる `--session "$HSESSION"` と起動コマンド先頭の `env -u ...` は、**どちらも外さない**（理由は `references/launch.md`）。

## 決定論ツール（scripts/）と AI の責務分担

AI の責務は計画ファイル・issue から「タスクと依存辺・境界」を読み取り JSON spec を組むところまで。スケジュール／レーン算出・コマンド生成・ワーカー規約の連結は決定論スクリプトに委譲する。

スクリプトは Python プロジェクト（`pyproject.toml` + `uv.lock`）。venv はスキルディレクトリ外へ逃がすため、実行時は必ず `UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/job-graph"` を付ける。以下、スキル本体のパスを `<SKILL>` と表記する。

- **`scripts/preflight.sh`**（read-only）: HERDR_ENV・ツール有無・既定ブランチ・未コミット変更・名前衝突を収集。`WARNING` を解消してから進む。
- **`scripts/plan_orchestration.py`**: JSON spec を入力に、循環検出・base 解決・ウェーブ算出・レーン割当・ワーカープロンプトのファイル書き出し・wt/herdr コマンド列生成を行う:

  ```bash
  UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/job-graph" uv run --project "<SKILL>" \
    python "<SKILL>/scripts/plan_orchestration.py" \
    --prompt-dir "<scratchpad>/job-graph-prompts" --parent-name <親のエージェント名> <spec.json>
  # 起動引数のオプションはそのまま前に付ける（--remote-control / --model / --permission-mode / --effort）
  ```

  spec の形は `scripts/example-spec.json` を参照。task には任意で `issue`（GitHub issue 番号）・`boundary`（触ってよい glob 配列）・`model`/`permission_mode`/`effort`（起動上書き）を書ける。`--prompt-dir` は実質必須（未指定だと COMMANDS を出力しない）。プロンプトは `<prompt-dir>/<task-id>.md` へ書き出され、起動コマンドが `"$(cat <path>)"` で読む。

  出力の `SCHEDULE`・`LANES`・`BOUNDARY`・`PROMPTS`・`COMMANDS`・`MONITOR` をそのまま plan と実行に使う。スクリプトのロジックを本文で再現しない。

- **ワーカー規約の正本は lane-ops の `worker_contract.py`**。`plan_orchestration.py` が同一プラグイン内の兄弟パスから子プロセスで呼び、spec の `prompt`（タスク固有の内容と完了条件だけを書く）へ連結する。job-graph と lane-ops は必ずセットで配置する。

## タスク境界の宣言（スコープドリフト防止）

spec の task に `boundary`（glob 配列）を書くと、起動コマンドが worktree ルートへ境界ファイル `.claude/task-boundary.json` を生成し、`task-boundary` hook（併用推奨・別プラグイン）が境界外の Edit/Write を機械ブロックする。

- 境界に何を含めるかの判定基準は `references/dependency-analysis.md`（宣言漏れは正当作業のブロックになる）
- 実行中の境界拡張は lane-ops の `widen_boundary.sh`（親専用）が正規経路。ワーカーから境界不足の報告を受けたら、計画と突き合わせて範囲内なら widen して再開を指示し、範囲外ならユーザーへ上げる

詳細（生成方式・deny 後のフロー）は `references/boundary.md`。

## 全体フロー

### Phase 0: 入口を読み、spec を組む

入口は次のどちらか:

- **計画ファイル**（引数のパス）: 事前に対話で固めた計画を読む
- **epic issue 番号**: `gh issue view <番号>` で本文とサブ issue を読み、タスクの叩き台を組む

各タスクの依存辺・境界を意味的に判定し JSON spec に落とす（判定基準は `references/dependency-analysis.md`）。**依存関係や境界が欠けている・曖昧なときは、憶測で埋めずユーザーへ問いを立てて締める**。依存の読み違えはグラフを破綻させ、境界の読み違えは誤 deny かドリフト取り逃がしになる。タスク数が多く spec 起草が重い場合に限り、起草をサブエージェントへ委任してよい（任意の最適化）。

### Phase 1: 事前確認・スケジュール算出 → plan 承認

1. `bash <SKILL>/scripts/preflight.sh` を実行し、`WARNING` を解消する。
2. 親（自分）に herdr のエージェント名を付ける: `herdr --session "${HERDR_SESSION:-default}" agent rename "$HERDR_PANE_ID" <一意な短い名前>`（ワーカー報告の宛先。lane-ops 参照）。この名前は起動済みワーカーの規約（worker_contract）に焼き付くため、**セッション再開・herdr セッション復旧のたびに同じ名前で rename し直す**。一字でも違うと report.sh の報告が届かなくなる。
3. `plan_orchestration.py` を `--prompt-dir`（scratchpad 配下）と `--parent-name`（上記の名前）付きで実行し、`ERROR` が出たら spec を直して再実行。
4. 出力を土台に plan を組み、**`ExitPlanMode` で承認を取る**。plan には必ず含める:
   - **起動ウェーブとレーン割当**（`SCHEDULE` / `LANES`）
   - **コミット計画**: `commit-plan` スキル準拠（タスク＝ブランチ単位）
   - **PR 戦略**: 各ブランチの base（`PR` セクション）
   - **承認代行の宣言**: 「計画内の push・PR 作成・対話ゲートへの応答は親が判断する」ことを明記（この承認が Phase 3 の代行根拠になる）

承認なしで worktree 生成・エージェント起動に進まない。

### Phase 2: worktree 作成・レーン起動

承認後、`COMMANDS` をウェーブ順に実行する。

- **wave 0**: 独立レーン。まとめて起動してよい
- **後続 wave**: 制約 4 のゲート（`gh pr list --head <前段ブランチ>` が非空）を確認してから起動
- pane ID（`PANE_<task-id>` 変数）は監視・承認で使うので控えておく

起動コマンドの中身の解説は `references/launch.md`。

### Phase 3: 監視・承認代行

制約 6 のとおり lane-ops の運用ループに従う（監視の常駐・報告の裏取り・blocked への応答）。

長時間ジョブは 1 セッションで完走しない前提で、**Phase 2 完了時点で
`tmp_claude/<job>/handoff.md` を生成し、状態が変わるたび（wave 完了・PR 作成・
事前裁定の追加）に更新する**。様式と必須要素は `references/handoff.md`。
セッション跨ぎの再開はこのファイルを唯一の入口にする。

### Phase 4: PR 作成と凍結

各ワーカーは `/review-converge` 収束後に自分で `/pr-create [base]` を実行する（規約で指示済み）。PR 作成の報告を受けたら機械検証し、レーンの凍結（以降の実装変更・push 停止）を確認する。逸脱を見つけたら lane-ops の `send_instruction.sh` で明示的に止める。

### Phase 5: 後始末

- 進捗確認: `wt list`
- 全レーンのマージ後: `/post-merge-cleanup` を案内する。herdr の workspace / tab は**自分が作ったものだけ**閉じる（`herdr --session "$HSESSION" workspace close` / `herdr --session "$HSESSION" tab close`）
- stacked の restack が必要になったら `references/restack.md` に従う

## 連携スキル・参照

このスキルは下記を**呼び出す側**で、内容を重複させない。

- `lane-ops`（Phase 3〜4 の実体）/ `commit-plan`（Phase 1）/ `review-converge`・`pr-create`（各ワーカーが実行）/ `post-merge-cleanup`（Phase 5）
- `herdr` / `worktrunk`: herdr CLI・`wt` の一般規約が要るとき
- `references/`: `dependency-analysis.md`（依存辺・境界の判定基準）/ `launch.md`（COMMANDS の解説）/ `boundary.md`（境界ファイルと deny 後のフロー）/ `restack.md`（下段変更時の載せ替え）/ `handoff.md`（セッション跨ぎ引き継ぎ書の様式と生成規約）
