# restack の定石 — 下段変更時の上段載せ替え

stacked 構成で下段（前段）の履歴が変わったら、上段（後段）を載せ替える。

- 上段の履歴に残る旧 base コミットは `git rebase --onto <新base> <旧baseの先端sha>` で**明示的に drop** する（そのまま `git rebase <新base>` だと amend 版と衝突する）
- 載せ替えの実行は **rebase-flow スキル経由**（backup 作成 + 解錠が必須。git-guard hook が素の rebase を deny する）
- 別 worktree での rebase は、複合コマンド（`cd <worktree> && git rebase`）が guard に弾かれるため、対象レーンのワーカー自身にやらせる（lane-ops の `send_instruction.sh` で指示する）か、EnterWorktree でセッション cwd を移してから実行する
- 起動後に base のずれを見つけたら、コミット前なら `git switch -C <branch> <正しい親>` で付け替えられる（reset 不要・guard に掛からない）。ただしワーカーは古い base の内容を読んでいる可能性があるので、付け替え後に「base を変えたので該当ファイルを読み直せ」と指示する
- 載せ替え検証の最強の証拠は **tree 同一性**（`git rev-parse HEAD^{tree}` が backup と一致）
- PR の完了判定・base 確認は `gh pr list --head <branch>` で行う（`gh pr view` に `--head` は無い）
