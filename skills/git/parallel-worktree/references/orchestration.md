# orchestration リファレンス

`parallel-worktree` スキルの具体手順。依存解析の判断基準、`wt`/tmux/`gh` のコマンドレシピ、タスクプロンプト雛形をまとめる。

> **正本は `scripts/plan_orchestration.py`。** 起動ウェーブ順・base 解決・コマンド列の生成は決定論スクリプトが出力する（`uv run --project <SKILL> python <SKILL>/scripts/plan_orchestration.py <spec.json>`）。本ドキュメントは「そのコマンドが何をしているか」の解説と、スクリプトを使わない場合のフォールバックとして読む。順序・base・クォートをここから手作業で再構成しない。

## 目次

- [依存解析](#依存解析) — 並列にしてよいか stacked にすべきかの見分け
- [worktree 作成](#worktree-作成) — 独立 / stacked それぞれの `wt` コマンド
- [tmux でエージェント起動](#tmux-でエージェント起動) — agent handoff の起動コマンド
- [タスク境界の宣言](#タスク境界の宣言) — 境界ファイル生成とスコープドリフト防止
- [タスクプロンプト雛形](#タスクプロンプト雛形) — 各エージェントに渡す指示（標準セクションは自動付与）
- [PR 作成](#pr-作成) — `/pr-create` 連携と base 指定
- [監視・後始末](#監視後始末) — `wt list` / `wt merge` / `wt remove`

## 依存解析

2 つのタスクを **並列にしてよい（独立）** か **stacked にすべき（依存）** かは、次で判断する。

**依存あり（stacked / 逐次にする）と判断する材料:**

- 後段が前段で追加・変更する**型・関数・クラス・API・DB スキーマ・設定**を参照する
- 同一ファイル、または密結合した同一モジュールを両方が編集する（コンフリクト確実）
- 後段の動作確認に前段の実装が前提になる
- 「まず基盤を入れてから、その上に機能を載せる」構造

**独立（並列にしてよい）と判断する材料:**

- 触るファイル/ディレクトリ/モジュールが重ならない
- 共有するのは安定済みの既存 API のみで、互いの新規変更に依存しない
- 別々の機能・別々のレイヤーで、マージ順がどちらでも成立する

判断に迷う組み合わせは独立扱いにせず、**ユーザーに確認する**（grill-me 方式）。並列で走らせてから依存が発覚すると手戻りが大きい。

stacked が 3 段以上になるときは、本当に全段が連鎖依存か見直す。途中に独立な段が混ざるなら、そこは別の並列グループに切り出せる。

## worktree 作成

worktree は必ず `wt` で作る（post-start hook で direnv/symlink が整う）。

**独立タスク**（base はデフォルトブランチ）:

```bash
wt switch --create feat-foo      # main から feat-foo の worktree を作成
wt switch --create feat-bar      # main から feat-bar の worktree を作成
```

**stacked**（前段ブランチを base にする。前段がコミット済みになってから後段を切る）:

```bash
# 1段目を作って実装・コミットを済ませる
wt switch --create stack-base
# （stack-base で実装・コミット完了後）
# 2段目を 1段目から分岐
wt switch --create stack-2 --base stack-base
# 3段目を 2段目から分岐
wt switch --create stack-3 --base stack-2
```

`--base` のショートカット: `--base=@`（現 HEAD から）、`--base=pr:123`（PR #123 の head から）。

worktree のパスは user config の `worktree-path` テンプレートで決まる（このリポジトリでは `{{ repo_path }}/../{{ repo }}.{{ branch | sanitize }}`）。パスを知るには `wt list` で確認する。

## tmux でエージェント起動

worktrunk の agent handoff パターン。`wt switch -x claude` で worktree 切替後にその worktree 内で本物の claude を起動する（`-x` は wt プロセスを claude に置き換え、端末制御を渡す）。detached tmux セッションに入れることでバックグラウンド並列になる。

**独立タスク群（同時に起動してよい）:**

```bash
tmux new-session -d -s feat-foo "wt switch --create feat-foo -x claude -- '<タスクプロンプト>'"
tmux new-session -d -s feat-bar "wt switch --create feat-bar -x claude -- '<タスクプロンプト>'"
```

- `-d` で detached 起動。`-s <name>` はブランチ名（sanitize 済み）に揃えると `wt list` と対応が取れて追いやすい
- `--` 以降がプロンプトとして claude に渡る（`wt switch feature -- 'Fix #322'` → `claude 'Fix #322'`）

**Remote Control 付き起動（`--remote-control` 指定時）:**

detached tmux に入ったままでも claude.ai 等からリモート接続したいときは、claude を `--remote-control <名前>` で起動する。`-x claude` の `--` 以降は順にコマンドへ追記されるので、**名前 → プロンプトの順**で渡す。

```bash
tmux new-session -d -s feat-foo "wt switch --create feat-foo -x claude -- --remote-control feat-foo '<タスクプロンプト>'"
```

- `claude --remote-control <名前> '<プロンプト>'` になる。`--remote-control` の名前は省略可能だが、省略すると後続のプロンプトを名前として誤食いするため、**常に名前を明示する**。
- 名前は tmux セッション名（sanitize 済みブランチ名）に揃え、`tmux ls` / `wt list` / リモート一覧で同じ識別子で対応を取る。
- このコマンド列は `plan_orchestration.py --remote-control` が生成する（手作業で組み立てない）。

**モデル・パーミッションモード・effort の切り替え:**

各 worktree の claude の起動設定は、claude 本体のフラグ `--model` / `--permission-mode` / `--effort` を `-x claude` の `--` 以降・プロンプトより前に置くことで切り替える。

```bash
tmux new-session -d -s feat-foo "wt switch --create feat-foo -x claude -- --model opus --permission-mode acceptEdits --effort high '<タスクプロンプト>'"
```

- 値の選択肢: `--permission-mode` は `acceptEdits`/`auto`/`bypassPermissions`/`manual`/`dontAsk`/`plan`、`--effort` は `low`/`medium`/`high`/`xhigh`/`max`。`--model` は alias（`opus` 等）かフルネーム
- 解決順は **spec の task 個別指定（`model`/`permission_mode`/`effort`）> `plan_orchestration.py` の CLI フラグ（全 worktree 共通の既定）> 未指定**。未指定のフラグは出力せず、claude 自身のデフォルト（settings.json 等の呼び出し元設定）に委ねる
- 用途例: 機械的な独立タスクだけ `"model": "sonnet", "effort": "low"` に落とす、レビュー必須の段だけ `"permission_mode": "plan"` にする
- このコマンド列も `plan_orchestration.py` が生成する（手作業で組み立てない）

**境界宣言つきの起動（spec に `boundary` があるとき）:**

`-x claude` の代わりに `-x bash` で bootstrap を挟み、境界ファイルを置いてから claude を exec する。詳細は[タスク境界の宣言](#タスク境界の宣言)を参照。このコマンド列も `plan_orchestration.py` が生成する（クォートが深いので手作業で組み立てない）。

**stacked（逐次。前段の実装・コミットを待ってから次段を起動）:**

1段目を起動 → 完了（実装・コミット）を `wt list` 等で確認 → 2段目を `--base <前段ブランチ>` 付きで起動、を繰り返す。前段がコミットされる前に後段を切ると、後段が前段のコードを見られない。

セッションへの接続は `tmux attach -t <name>`、一覧は `tmux ls`。

## タスク境界の宣言

### 何のためか: スコープドリフト防止

並列レーンで観測される退行メカニズムの一つが **スコープドリフト**（ワーカーがレビュー指摘対応などに没頭し、当初タスクの境界から逸脱して他レーンの領域まで編集してしまう）。プロンプトに「他タスクのファイルに触れない」と書くだけでは、勢いに乗ったエージェントは平気で越境する。

対策は**指示と機械ブロックの二重化**:

| 層 | 担い手 | 効果 |
| --- | --- | --- |
| 指示 | `plan_orchestration.py` が生成するワーカー指示の標準セクション | ワーカーが境界を自覚する |
| 機械ブロック | `task-boundary` hook（`hooks/task-boundary-plugin`。**併用推奨**） | 境界外への `Edit`/`Write`/`NotebookEdit` を PreToolUse で deny する |

両者は**境界ファイルという契約だけで結合**している（スキルと hook は互いを呼ばない）。hook が未 install でも指示層は機能し、逆に hook だけでも他の生成者が置いた境界ファイルを尊重する。

### 宣言のしかた

spec の各 task に `boundary`（触ってよいパスの glob 配列）を書く。

```json
{
  "id": "B2",
  "branch": "feat-client-retry",
  "depends_on": ["B1"],
  "prompt": "...",
  "boundary": ["src/client/**", "tests/client/**", "docs/dev/<対象>/**"]
}
```

`boundary` を書いた task は、worktree ルートに境界ファイル `.claude/task-boundary.json` が生成される（hook の公開契約書式）:

```json
{
  "task_id": "B2",
  "branch": "feat-client-retry",
  "allow": ["src/client/**", "tests/client/**", "docs/dev/<対象>/**"]
}
```

**`boundary` を書かない task は境界ファイルを生成しない**（従来動作）。境界ファイルが無ければ hook は即 `exit 0` で沈黙するので、境界宣言はオプトインのまま。

境界の決め方は[依存解析](#依存解析)と同じ材料を使う。並列にできると判断した根拠＝「触るファイルが重ならない」なので、その重ならない範囲がそのまま境界になる。テスト実装も含むので、実装ディレクトリとテストディレクトリの両方を宣言に入れる（TDD 順序を指示しておきながらテストが境界外だと詰む）。

### 生成方式（`wt switch -x` の bootstrap 経由）

worktree のパスは user config の `worktree-path` テンプレートで決まるため、オーケストレータ側では確定できない。そこで `plan_orchestration.py` は、`boundary` ありの task の起動コマンドだけ `-x claude` を `-x bash` に差し替え、**worktree 生成後・claude 起動前**に境界ファイルを置いてから `exec claude "$@"` へ繋ぐ。

- `wt switch --execute` は worktree ルートを cwd にして走るので、その瞬間が境界ファイルを置ける唯一の窓になる
- 境界 JSON と claude 引数はすべて **positional 引数**で渡す（`bash -c '<script>' <argv0> <json> <claude 引数...>`）。入れ子クォートを積み上げずに済み、glob の `**` や空白を含むパスも展開・分割されずに宣言のまま届く
- `--model` / `--permission-mode` / `--effort` / `--remote-control` は bootstrap の後段でそのまま claude へ渡るので、既存の起動オプションと直交する
- bootstrap は `set -e` で **fail-closed**。cwd は `wt switch --create` が作った worktree なので git リポジトリであることが前提であり、`git rev-parse` がコケるのは環境が壊れているとき。そのとき境界の無い状態で claude を起動する（ガードレール無しで走らせる）より、起動せず tmux セッションに失敗を残す方が安全。**hook 側の fail-open（境界ファイルが無ければ沈黙）とは役割が逆**であることに注意

### gitignore 方式: `git rev-parse --git-path info/exclude` への追記

境界ファイルは worktree ローカルの一時物なのでコミットさせてはいけない。かつ、リポジトリの `.gitignore` を汚す（＝ワーカーの diff にノイズが乗る・レビュー対象になる）のも避けたい。採用したのは **`git rev-parse --git-path info/exclude` で解決したパスへ 1 行追記**する方式。

選定理由:

- **worktree の `.git` がファイル（gitdir ポインタ）である差異を呼び出し側で場合分けせずに済む。** linked worktree から実行しても `--git-path info/exclude` は common dir（メインリポジトリの `.git/info/exclude`）へ正しく解決される。`.git/info/exclude` をパス直書きすると linked worktree では存在しないパスを掴む
- **追跡ファイルを一切変更しない。** `.gitignore` への追記だと worktree の diff に無関係な変更が残り、diff-review のノイズになる
- **冪等。** パターンは `/.claude/task-boundary.json` 固定・行頭 `/` 付きで、`grep -qxF` で既存行を確認してから追記するため、同じレーンを作り直しても重複しない
- **`wt remove` で worktree ごと消える。** 境界ファイル自体は worktree 内にあるので後始末が要らない（exclude の 1 行だけが残るが、対象ファイルが無ければ無害）

**採らなかった選択肢**: 真に worktree ローカルな `extensions.worktreeConfig` + per-worktree `core.excludesFile`。境界の局所性は上回るが、(1) リポジトリ全体の config 解決を変える `extensions.worktreeConfig` を副作用として立ててしまう、(2) `core.excludesFile` を上書きするのでユーザーが設定済みのグローバル除外をそのレーンで壊す — という代償が、1 ファイルを無視するという目的に対して過大。

なお、`info/exclude` は全 worktree とメインリポジトリで共有されるため、この 1 行は他のレーンにも効く。だが無視されるのは `.claude/task-boundary.json` という 1 パスだけで、そのファイル自体が各 worktree ローカルの生成物なので実害はない（むしろ全レーンで一貫して無視されるのが望ましい）。

## タスクプロンプト雛形

**手書きは不要**。`plan_orchestration.py` が spec の `prompt`（タスク本文）の後ろへ下記の標準セクションを自動で連結する。境界・TDD 順序・PR 前ゲート・コミット粒度が全 task に必ず載るので、spec の `prompt` には**タスク固有の内容と完了条件だけ**を書く。

```
<spec の prompt（タスクの具体的な内容と完了条件）>

## 制約（parallel-worktree 標準セクション）
- 編集してよい範囲（境界）: <boundary の glob 一覧>
  この glob 外のファイルは編集しない。宣言は .claude/task-boundary.json と同一で、
  task-boundary hook が境界外の Edit/Write を機械ブロックする。
  境界を広げる必要が出たら自分で境界ファイルを書き換えず、ユーザーに相談する。
- TDD 順序: テストを先に実装し（失敗を確認）、その後アプリケーション実装で通す
- コミット粒度: 論理的に独立した修正は都度コミットする（commit-flow スキル準拠、Conventional Commits）
- push: 自分の feature ブランチ <branch> に限り push してよい。main 等の保護ブランチへは push しない
- PR 作成前ゲート: `/review-converge` を実行して指摘を収束させてから `/pr-create [base]` を実行する（収束前に PR を作らない）
```

- **境界の記述は境界ファイルと同じ glob を使う**（`worker_sections` と `boundary_json` が同じ `boundary` を読む）。指示文と hook の deny 条件が食い違わないことがコードで保証される
- `boundary` 未宣言の task では境界行が「このタスクの担当範囲に限る。他タスクのファイルに触れない」という従来の文言に落ちる
- PR 前ゲートの `[base]` は stacked なら前段ブランチ名が入る（独立タスクは省略）
- **自己解錠の封じ**: 境界を広げたくなったワーカーが自分で境界ファイルを書き換えるのを防ぐため、指示側でも「ユーザーに相談する」と明示する（hook 側も境界ファイル自身への書き込みを deny する）

## PR 作成

各エージェントが実装・コミット完了後、**まず `/review-converge` で指摘を収束させ**、そのうえで自分で `/pr-create [base]` を実行する（この 2 段は標準セクションで全 task に指示される）。

- **PR 作成前ゲート**: `/review-converge` は diff-review の収束ループを回し、閾値以上の指摘がゼロになるか周回上限・振動検出で停止する。収束前に PR を作らない（レビュー指摘での往復を PR 上に持ち出さない）
- `/pr-create` は draft 既定・タイトル/本文をユーザー承認後に作成・自動 push 禁止。各 tmux pane で承認/push のゲートに到達して停止するので、ユーザーが pane を巡回して進める
- push: エージェントは自分の feature ブランチを push してよい（PR 作成に必要なため）。保護ブランチは不可
- stacked: `/pr-create <parent-branch>` で base を前段に向ける。GitHub 上で stacked PR の依存が表現される

## 監視・後始末

- **進捗確認**: `wt list`（worktree 一覧・状態）。詳細は `wt list --full`（CI・diffstat・LLM 要約）
- **マージ**: `wt merge [target]`（current ブランチを target に squash & rebase してマージ、worktree 削除まで）。ただしローカル merge は PR レビューを飛ばすので、PR 運用中は GitHub 側マージを基本にする
- **後始末**: `wt remove`（worktree 削除、マージ済みならブランチも削除）
- **stacked の再 rebase**: 下段が変わったら上段を rebase する必要がある。`wt merge --rebase` か手動 `git rebase`。この環境に `wt sync`（worktrunk-sync）は無いので自動 restack は使えない
