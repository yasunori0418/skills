# レーン起動 — COMMANDS の解説

`plan_orchestration.py` の `COMMANDS` 各ブロックがやっていることの解説。**このレシピを手で組み立てず、スクリプトの出力を使う。**

## レーン開始（workspace 作成 + 1 段目起動）

```bash
resp=$(herdr workspace create --cwd "$PWD" --label refactor-logger --no-focus)
WS_0=$(printf '%s' "$resp" | jq -r '.result.workspace.workspace_id')
PANE_A=$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id')
herdr pane run "$PANE_A" 'wt switch --create refactor-logger --base main -x claude -- "$(cat <prompt-dir>/A.md)"'
```

- `--no-focus` でユーザーの現在フォーカスを奪わない。ID は JSON 応答から jq で掴む（予測しない）
- `wt switch --create` が worktree を作り、`-x claude` で wt プロセスが claude に置き換わる。herdr は pane 内の claude をエージェントとして自動認識する
- **`--base` は常に明示**される。省略すると wt はリポジトリの default branch から切るため、spec の意図と食い違う事故が起きる
- プロンプトは複数行のためファイル渡し。`"$(cat <path>)"` は pane の shell が展開し、wt が EXECUTE_ARGS として shell-escape して claude に 1 引数で渡す

## 直列の次段（同 workspace に tab 追加）

```bash
resp=$(herdr tab create --workspace "$WS_0" --cwd "$PWD" --label feat-next --no-focus)
PANE_B=$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id')
herdr pane run "$PANE_B" 'wt switch --create feat-next --base refactor-logger -x claude -- "$(cat <prompt-dir>/B.md)"'
```

起動は**前段の PR 作成を確認してから**（`gh pr list --head <前段ブランチ>` が非空）。コミット数到達をゲートにしない（前段の amend で base がずれ restack を誘発する）。

## 起動オプション

`--model` / `--permission-mode` / `--effort` / `--remote-control` は `-x claude --` の後・プロンプトより前に置かれる。解決順は spec の task 個別指定 > CLI フラグ（グローバル既定）> 未指定（claude 自身のデフォルト）。`--remote-control <名前>` を付けると起動した claude へ claude.ai 等からリモート接続できる。

## 起動確認

`herdr agent list` に pane が現れれば認識済み。現れないまま `herdr pane read <pane>` で shell エラーが見えるなら wt の失敗（ブランチ名衝突など）なので preflight に戻る。
