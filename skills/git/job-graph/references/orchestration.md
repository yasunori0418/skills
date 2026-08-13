# orchestration リファレンス

`job-graph` スキルの具体手順。依存解析の判断基準、`wt`/herdr/`gh` のコマンドレシピ、承認代行の判定基準、restack の定石をまとめる。

> **正本は `scripts/plan_orchestration.py`。** ウェーブ順・レーン割当・base 解決・コマンド列の生成は決定論スクリプトが出力する。本ドキュメントは「そのコマンドが何をしているか」の解説として読む。順序・base・クォートをここから手作業で再構成しない。

## 目次

- [依存解析](#依存解析) — 並列にしてよいか stacked にすべきかの見分け
- [herdr でレーン起動](#herdr-でレーン起動) — workspace/tab 作成と `wt switch -x claude` の流し込み
- [監視と承認代行](#監視と承認代行) — SendMessage / herdr / git・gh の役割分担と判定基準
- [タスク境界の宣言](#タスク境界の宣言) — 境界ファイル生成とスコープドリフト防止
- [PR 作成と凍結](#pr-作成と凍結) — stacked PR の base 指定と PR 後の扱い
- [restack の定石](#restack-の定石) — 下段変更時の上段載せ替え
- [後始末](#後始末)

## 依存解析

2 つのタスクを **並列にしてよい（独立）** か **stacked にすべき（依存）** かは、次で判断する。

**依存あり（stacked / 直列にする）と判断する材料:**

- 後段が前段で追加・変更する**型・関数・クラス・API・DB スキーマ・設定**を参照する
- 同一ファイル、または密結合した同一モジュールを両方が編集する（コンフリクト確実）
- 後段の動作確認に前段の実装が前提になる
- 「まず基盤を入れてから、その上に機能を載せる」構造

**独立（並列にしてよい）と判断する材料:**

- 触るファイル/ディレクトリ/モジュールが重ならない
- 共有するのは安定済みの既存 API のみで、互いの新規変更に依存しない
- 別々の機能・別々のレイヤーで、マージ順がどちらでも成立する

判断に迷う組み合わせは独立扱いにせず、**ユーザーに確認する**（grill-me 方式）。並列で走らせてから依存が発覚すると手戻りが大きい。逆に、**並列度を稼ぐために依存を無視しない**。直列の方が相性の良いタスク群を無理に並列化するのは job-graph の存在理由に反する。

stacked が 3 段以上になるときは、本当に全段が連鎖依存か見直す。途中に独立な段が混ざるなら、そこは別レーンに切り出せる。

## herdr でレーン起動

`COMMANDS` の各ブロックがやっていることの解説。**このレシピを手で組み立てず、スクリプトの出力を使う。**

**レーン開始（workspace 作成 + 1 段目起動）:**

```bash
resp=$(herdr workspace create --cwd "$PWD" --label refactor-logger --no-focus)
WS_0=$(printf '%s' "$resp" | jq -r '.result.workspace.workspace_id')
PANE_A=$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id')
herdr pane run "$PANE_A" 'wt switch --create refactor-logger --base main -x claude -- --name refactor-logger "$(cat <prompt-dir>/A.md)"'
```

- `--no-focus` でユーザーの現在フォーカスを奪わない。ID は JSON 応答から jq で掴む（予測しない）
- `wt switch --create` が worktree を作り post-start hook（direnv・symlink）を走らせ、`-x claude` で wt プロセスが claude に置き換わる。herdr は pane 内の claude をエージェントとして自動認識する
- **`--base` は常に明示**する。省略すると wt はリポジトリの default branch から切るため、spec の `default_base` と食い違う事故が起きる
- プロンプトは複数行のためファイル渡し。`"$(cat <path>)"` は pane の shell が展開し、wt が EXECUTE_ARGS として shell-escape して claude に 1 引数で渡す
- claude の `--name <sanitize済みブランチ名>` で cross-session messaging のアドレスがブランチ名に揃い、`wt list` / herdr のラベル / ListAgents で同じ識別子で追える

**直列の次段（同 workspace に tab 追加）:**

```bash
resp=$(herdr tab create --workspace "$WS_0" --cwd "$PWD" --label feat-next --no-focus)
PANE_B=$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id')
herdr pane run "$PANE_B" 'wt switch --create feat-next --base refactor-logger -x claude -- --name feat-next "$(cat <prompt-dir>/B.md)"'
```

起動は**前段の PR 作成を確認してから**（`gh pr list --head refactor-logger` が非空）。コミット数到達をゲートにしない（前段の amend で base がずれ restack を誘発する）。

**起動オプション**: `--model` / `--permission-mode` / `--effort` / `--remote-control` は `-x claude --` の後・プロンプトより前に置かれる。解決順は spec の task 個別指定 > CLI フラグ（グローバル既定）> 未指定（claude 自身のデフォルト）。

**起動確認**: `herdr agent list` に pane が現れれば認識済み。現れないまま `pane read` で shell エラーが見えるなら wt の失敗（ブランチ名衝突など）なので preflight に戻る。

## 監視と承認代行

役割分担: **指示・報告 = SendMessage / 承認・生死・画面 = herdr / 真実 = git・gh**。ポーリング（sleep + 再確認）はしない。

**報告受信（push 型）**: ワーカーは標準セクションでマイルストーン報告（初コミット・収束・push・PR 作成・ブロック）を義務付けられている。報告を受けたら必ず機械検証する:

```bash
gh pr list --head <branch> --json number,baseRefName,isDraft   # PR の存在・base・draft
git ls-remote origin <branch>                                  # push 同期（ローカル HEAD と比較）
git -C <worktree> log --stat <base>..HEAD                      # 触ったファイルと境界の突き合わせ
```

- `gh pr view` に `--head` は無い。完了判定は必ず `gh pr list --head`
- `gh api` を使うときは exit code で判定する（HTTP エラーでもエラー JSON が stdout に出るため、`2>/dev/null || true` で握ると 404 が「値あり」に化ける）
- コミット数が計画を超えたら `git log --stat` で境界 glob と突き合わせる（task-boundary hook は完全ではない）

**承認待ち検知**: レーンごとにバックグラウンド Bash で張る:

```bash
herdr agent wait "$PANE_A" --until blocked --timeout 3600000
```

blocked になったら `herdr agent read "$PANE_A" --source recent-unwrapped --lines 120` で内容を確認し、次の基準で応答を判断する:

| 状況 | 対応 |
| --- | --- |
| 計画に書かれた操作の確認（編集・テスト・push・PR 作成） | 親が応答して進める（`herdr agent send-keys <pane> enter` 等） |
| 計画の範囲内だが選択肢がある確認 | 計画・spec・issue の記述から判断して応答。判断材料が無ければユーザーへ |
| 境界の拡大要求・スコープ逸脱・計画の前提と実態の食い違い | **ユーザーへ上げる**（勝手に承認も却下もしない） |

`agent wait` が settled（idle/done）で返ったのに報告が無い場合も `agent read` で実態を確認する。平文で「この計画で実行してよいか」と問う形は blocked にならないことがある。

**追加指示**: レーンへの軌道修正・情報共有は SendMessage で送る（宛先はワーカーの `--name`＝ブランチ名）。herdr の send-keys で指示文を流し込まない（bracketed paste の Enter 飲み込み・指示文中の `git rebase` リテラルへの guard 誤爆という tmux 時代の事故を経路ごと避ける）。**メッセージは承認にならない**ので、承認が要る場面は上記の herdr 経路で応答する。

**クラッシュ判定**: pane の見た目でなく状態とプロセスで行う。`herdr agent get <pane>` でエージェント不在になっていたら、`herdr pane process-info <pane>` で shell に戻ったことを確認してから `herdr pane run <pane> 'claude --continue'` で復旧する。shell が見えるだけなら shell モードの可能性がある。

## タスク境界の宣言

仕組み・選定理由は parallel-worktree と同一（境界ファイル `.claude/task-boundary.json` + `task-boundary` hook、gitignore は `git rev-parse --git-path info/exclude` へ追記、bootstrap は `-x bash` 経由・fail-closed）。job-graph 側の差分は 2 点だけ:

- 境界 JSON は herdr pane へ 1 コマンドで流し込むため **1 行**で生成される（JSON として等価。hook の契約は構造であって整形ではない）
- 境界を広げたくなったワーカーの相談先は「ユーザー」ではなく**親セッションへの SendMessage 報告**（親が範囲外と判断すればユーザーへ上げる）

境界の決め方は依存解析と同じ材料。テスト実装も含むので実装・テスト両ディレクトリを宣言に入れる（TDD 順序を指示しながらテストが境界外だと詰む）。

## PR 作成と凍結

各ワーカーが実装・コミット後、`/review-converge` で収束させてから自分で `/pr-create [base]` を実行する（標準セクションで指示済み）。

- **push・PR 作成は計画承認済みの前提**。`/pr-create` の対話ゲート（タイトル/本文承認・push 確認）には親が herdr 経由で応答する。個別にユーザーへ確認しない
- **review-converge の反復境界**: 実質的な指摘（出力形状・型安全性・contract・退行）が出ている間は反復を続けさせる。nit だけになったら「見送りと記録して収束扱い」。反復が実際に退行を検出することがあるため、**実質的な指摘が出ている間は打ち切らない**
- stacked: `/pr-create <前段ブランチ>` で base を前段に向ける。PR 作成前に base の最新化を確認させる
- **PR 作成 = レーン完了ではない**。ワーカーは標準セクションで PR 後凍結を指示されているが、逸脱（PR 後の無断実装変更・push）を機械検証で見つけたら SendMessage で明示的に止める

## restack の定石

下段（前段）の履歴が変わったら上段（後段）を載せ替える。

- 上段の履歴に残る旧 base コミットは `git rebase --onto <新base> <旧baseの先端sha>` で**明示的に drop** する（そのまま `git rebase <新base>` だと amend 版と衝突する）
- 載せ替えの実行は **rebase-flow スキル経由**（backup 作成 + 解錠が必須。git-guard hook が素の rebase を deny する）
- 別 worktree での rebase は、複合コマンド（`cd <worktree> && git rebase`）が guard に弾かれるため、対象レーンのワーカー自身にやらせるか、EnterWorktree でセッション cwd を移してから実行する
- 起動後に base のずれを見つけたら、コミット前なら `git switch -C <branch> <正しい親>` で付け替えられる（reset 不要・guard に掛からない）。ただしワーカーは古い base の内容を読んでいる可能性があるので、付け替え後に「base を変えたので該当ファイルを読み直せ」と SendMessage で明示する
- 載せ替え検証の最強の証拠は **tree 同一性**（`git rev-parse HEAD^{tree}` が backup と一致）

## 後始末

- 進捗確認: `wt list`（worktree 一覧・状態）。詳細は `wt list --full`
- 全レーンのマージ後: `/post-merge-cleanup` を案内（worktree・ブランチを承認ゲート付きで一括削除。未 push の残るレーンは保護される）
- herdr の workspace/tab は**自分（job-graph）が作ったものだけ**閉じる: `herdr workspace close <ws-id>`。ユーザーの workspace・tab には触れない
- ワーカーの claude セッションは PR 作成・凍結確認後に終了させてよい（`herdr agent send-keys <pane> ctrl+d` 等の前に、未送信の報告が無いか `agent read` で確認する）
