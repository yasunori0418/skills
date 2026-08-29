# restack の定石 — 下段変更時の上段載せ替え

stacked 構成で下段（前段）の tip が動いたら、上段（後段）を載せ替える。

## 発動条件: 下段の tip が動いたら（fast-forward の積み増しを含む）

amend / rebase による履歴書き換えだけでなく、**下段へのコミット積み増し（fast-forward）でも上段は古い base のまま**になる。実運用で、下段が review-converge の修正を 2 コミット積んだ後に上段が旧 tip の上に残り、上段の PR diff に「下段で消したはずの識別子」が残存したまま次段へ進んだ。「履歴が書き換わったときだけ restack」と覚えると取りこぼす。

下段の PR 更新（push）を検知したら、上段について次を確認する:

- 上段残存検査（どちらかが偽なら restack が必要）:
  - `git merge-base --is-ancestor <下段の新 tip> <上段ブランチ>` が真（下段の全コミットが上段に含まれる）
  - `git show <上段ブランチ>:<file> | grep <下段で消したはずの識別子>` が空（下段の削除が上段に反映されている）
- 上段のワーカーは古い base の内容を読んでいる可能性がある。載せ替え後に「base を変えたので該当ファイルを読み直せ」と指示する

## 載せ替えの手順

- 上段の履歴に残る旧 base コミットは `git rebase --onto <新base> <旧baseの先端sha>` で**明示的に drop** する（そのまま `git rebase <新base>` だと amend 版と衝突する）。fast-forward の積み増しだけなら `git rebase <新base>` で足りる
- 載せ替え検証の最強の証拠は **tree 同一性**（`git rev-parse HEAD^{tree}` が backup と一致。積み増しを取り込んだ場合は一致しないので、代わりに range-diff で自段のコミットが不変であることを見る）
- 起動後に base のずれを見つけたら、コミット前なら `git switch -C <branch> <正しい親>` で付け替えられる（reset 不要・guard に掛からない）
- PR の完了判定・base 確認は `gh pr list --head <branch>` で行う（`gh pr view` に `--head` は無い）

## 役割分担: rebase はワーカー、reset は親

| 操作 | 実行者 | 理由 |
| --- | --- | --- |
| `git rebase` | 対象レーンのワーカー自身（rebase-flow スキル経由。lane-ops の `send_instruction.sh` で指示） | backup 作成 + 解錠が要り、git-guard hook が素の rebase を deny する。ワーカーの cwd が worktree なので marker がそのまま効く |
| `git reset`（`permissions.ask` 対象） | **親が `git -C <worktree> reset ...` で代行**（reset-flow スキル経由で arm してから） | レーン（非対話 pane）では ask の承認プロンプトが誰にも届かず自動 deny される（preflight の PERMISSIONS 節で事前に検出） |

- 親が別 worktree を操作するときは **`git -C <worktree>`** を使う。`cd <worktree> && git reset ...` の複合コマンドは git-guard が arm marker を見つけられず deny する（実測）。EnterWorktree でセッションの cwd を移す方法は、親の cwd（spec・handoff・prompt-dir の相対参照）を壊すので使わない
- 親の代行後はワーカーへ「base を載せ替えたので `git log --oneline -5` で確認し、該当ファイルを読み直してから再開」と `send_instruction.sh` で伝える
