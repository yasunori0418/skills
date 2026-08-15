# レーン起動 — COMMANDS の解説

`plan_orchestration.py` の `COMMANDS` 各ブロックがやっていることの解説。**このレシピを手で組み立てず、スクリプトの出力を使う。**

## レーン先頭の起動（workspace 作成）

レーン（直列チェーン）ごとに workspace を 1 つ立てる。レーン先頭の task は `herdr workspace create` の root pane で起動する。

```bash
HSESSION="${HERDR_SESSION:-default}"   # COMMANDS 先頭で 1 度だけ定義される
resp=$(herdr --session "$HSESSION" workspace create --cwd "$PWD" --label refactor-logger --no-focus)
WS_LANE_0=$(printf '%s' "$resp" | jq -r '.result.workspace.workspace_id')
PANE_A=$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id')
herdr --session "$HSESSION" pane run "$PANE_A" 'wt switch --create refactor-logger --base main -x claude -- "$(cat <prompt-dir>/A.md)"'
```

- **`--session` は全 herdr 呼び出しに明示**される。CLI は `HERDR_SESSION` / `HERDR_SOCKET_PATH` が生きていれば現在の session へ解決するが、COMMANDS を env の無い別 shell へコピペすると既定 session へ落ちる。親と同じ session にレーンが並ぶ保証を env に預けない（`herdr --session ""` は拒否されるため未設定時は `default` へ畳む）
- workspace のラベルはレーン先頭のブランチ名。並列レーンは workspace が並ぶ
- `--no-focus` でユーザーの現在フォーカスを奪わない。ID は JSON 応答から jq で掴む（予測しない）
- `wt switch --create` が worktree を作り、`-x claude` で wt プロセスが claude に置き換わる。herdr は pane 内の claude をエージェントとして自動認識する
- **`--base` は常に明示**される。省略すると wt はリポジトリの default branch から切るため、spec の意図と食い違う事故が起きる
- プロンプトは複数行のためファイル渡し。`"$(cat <path>)"` は pane の shell が展開し、wt が EXECUTE_ARGS として shell-escape して claude に 1 引数で渡す

## 直列の次段（同 workspace への tab 追加）

stacked の後続段は、そのレーンの workspace へ `herdr tab create` で tab を足して起動する。workspace ID はレーン先頭のラベルから `herdr workspace list` で再解決する（wave 間で shell が変わっても動くように。変数の持ち越しに依存しない）。

```bash
WS_LANE_0=$(herdr --session "$HSESSION" workspace list | jq -r '.result.workspaces[] | select(.label == "refactor-logger") | .workspace_id' | head -n1)
resp=$(herdr --session "$HSESSION" tab create --workspace "$WS_LANE_0" --cwd "$PWD" --label refactor-logger-2 --no-focus)
PANE_B=$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id')
```

起動コマンドの形はレーン先頭と同じ（`--base` が前段ブランチになるだけ）。起動は**前段の PR 作成を確認してから**（`gh pr list --head <前段ブランチ>` が非空）。コミット数到達をゲートにしない（前段の amend で base がずれ restack を誘発する）。

## 起動オプション

`--model` / `--permission-mode` / `--effort` / `--remote-control` は `-x claude --` の後・プロンプトより前に置かれる。解決順は spec の task 個別指定 > CLI フラグ（グローバル既定）> 未指定（claude 自身のデフォルト）。`--remote-control <名前>` を付けると起動した claude へ claude.ai 等からリモート接続できる。

## 起動確認

`herdr --session "$HSESSION" agent list` に pane が現れれば認識済み。現れないまま `herdr --session "$HSESSION" pane read <pane>` で shell エラーが見えるなら wt の失敗（ブランチ名衝突など）なので preflight に戻る。
