# レーン起動 — COMMANDS の解説

`plan_orchestration.py` の `COMMANDS` 各ブロックがやっていることの解説。**このレシピを手で組み立てず、スクリプトの出力を使う。**

## 全 COMMANDS に共通する 2 つの前置（外さない）

`COMMANDS` の各ブロックには次の 2 つが必ず入る。どちらも env に依存せず動くための措置で、**外すと壊れる**。

- **`--session "$HSESSION"`**（先頭で `HSESSION="${HERDR_SESSION:-default}"` を 1 度定義）— herdr CLI は `HERDR_SESSION` / `HERDR_SOCKET_PATH` が生きていれば現在の session へ解決するが、`COMMANDS` を env の無い別 shell へコピペすると既定 session へ落ち、レーンが親と別の場所に作られる。親と同じ session に並ぶ保証を env に預けない（`herdr --session ""` は拒否されるため未設定時は `default` へ畳む）
- **起動コマンド先頭の `env -u ...`** — claude は Bash ツールの子シェルへ自分の身元（`CLAUDE_CODE_CHILD_SESSION` / `*_SESSION_ID` / `MESSAGING_*` 等）を注入する。そのまま流すと起動したレーンが**親の子プロセスと誤認**され、**transcript 保存が切られる**・**親宛のメッセージ経路を掴む**。レーンは独立したセッションなので断ち切る。`wt` より前に置くので wt 自身にも波及しない（対象は `plan_orchestration.py` の `INHERITED_SESSION_VARS` が正）
  - なお `env -u` は **pane の shell へ渡すコマンド文字列の先頭**に置く。pane の環境を決めるのは herdr **server** の environ だけで、`herdr ... pane run` を打つ側の環境は伝播しないため、CLI 呼び出し側に `env -u` を付けても無意味（実測で確認済み）
  - **前提**: herdr server 自体がクリーンな環境で起動していること。汚染された claude の子シェルから `herdr --session <name> server` を起こすと、その session の**全 pane の shell**がマーカーを持つ。この状態ではレーン起動時の `env -u` で claude 自身は救えるが、ユーザーが手で開いた tab では警告が出る（`project-session` の `herdr_start_session` はこれを踏まえて server 起動を `env -u` 越しにしている）

## 起動スクリプト方式（pane run には `bash <path>` だけを流す）

起動コマンド本体（`env -u … wt switch --create … -x claude|bash …`）は `plan_orchestration.py` が `<prompt-dir>/launch_<task-id>.sh` へ書き出し、pane には `bash <path>` の短い 1 行だけを流す。

起動コマンドは 1 行で数百文字（境界 bootstrap を含むと 1000 文字超）になり、`pane run` への長文注入で **pane に入力されたまま実行されない**・**途中で切れて壊れたコマンドが走る** 事故が実運用で起きた。スクリプト化すれば pane へ渡す文字列は短く一定になり、起動コマンドの完全形がファイルとして残る（handoff からの再投入も `bash <path>` で済む）。スクリプトの中身は下記の解説どおりで、**手で書き換えない**（spec を直して再生成する）。

## レーン先頭の起動（workspace 作成）

レーン（直列チェーン）ごとに workspace を 1 つ立てる。レーン先頭の task は `herdr workspace create` の root pane で起動する。

```bash
HSESSION="${HERDR_SESSION:-default}"   # COMMANDS 先頭で 1 度だけ定義される
resp=$(herdr --session "$HSESSION" workspace create --cwd "$PWD" --label refactor-logger --no-focus)
WS_LANE_0=$(printf '%s' "$resp" | jq -r '.result.workspace.workspace_id')
PANE_A=$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id')
herdr --session "$HSESSION" pane run "$PANE_A" 'bash <prompt-dir>/launch_A.sh'
```

`launch_A.sh` の中身（`exec env -u CLAUDE_CODE_CHILD_SESSION -u … wt switch --create refactor-logger --base main -x claude -- "$(cat <prompt-dir>/A.md)"`）について:

- workspace のラベルはレーン先頭のブランチ名。並列レーンは workspace が並ぶ
- `--no-focus` でユーザーの現在フォーカスを奪わない。ID は JSON 応答から jq で掴む（予測しない）
- `wt switch --create` が worktree を作り、`-x claude` で wt プロセスが claude に置き換わる。herdr は pane 内の claude をエージェントとして自動認識する（スクリプトは `exec` で wt に置き換わるので bash は残らない）
- **`--base` は常に明示**される。省略すると wt はリポジトリの default branch から切るため、spec の意図と食い違う事故が起きる
- プロンプトは複数行のためファイル渡し。`"$(cat <path>)"` はスクリプトを実行する bash が展開し、wt が EXECUTE_ARGS として shell-escape して claude に 1 引数で渡す

## 直列の次段（同 workspace への tab 追加）

stacked の後続段は、そのレーンの workspace へ `herdr tab create` で tab を足して起動する。workspace ID はレーン先頭のラベルから `herdr workspace list` で再解決する（wave 間で shell が変わっても動くように。変数の持ち越しに依存しない）。

```bash
WS_LANE_0=$(herdr --session "$HSESSION" workspace list | jq -r '.result.workspaces[] | select(.label == "refactor-logger") | .workspace_id' | head -n1)
resp=$(herdr --session "$HSESSION" tab create --workspace "$WS_LANE_0" --cwd "$PWD" --label refactor-logger-2 --no-focus)
PANE_B=$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id')
```

起動コマンドの形はレーン先頭と同じ（`--base` が前段ブランチになるだけ）。起動ゲートは SKILL.md の制約 4 に従う。

## 起動オプション

`--model` / `--permission-mode` / `--effort` / `--remote-control` は `-x claude --` の後・プロンプトより前に置かれる。解決順は spec の task 個別指定 > CLI フラグ（グローバル既定）> 未指定（claude 自身のデフォルト）。`--remote-control <名前>` を付けると起動した claude へ claude.ai 等からリモート接続できる。

## 起動確認

`herdr --session "$HSESSION" agent list` に pane が現れれば認識済み。現れないまま `herdr --session "$HSESSION" pane read <pane>` で shell エラーが見えるなら wt の失敗（ブランチ名衝突など）なので preflight に戻る。

pane に `bash …/launch_<id>.sh` が**入力されたまま実行されていない**（プロンプト行にコマンドが残り、`agent list` にも現れない）ときは、その入力を `herdr … pane send-keys <pane> ctrl-u` 等で破棄してから同じ `pane run` を再投入する。Enter だけを送ると、切れた入力が部分的に実行される可能性がある。
