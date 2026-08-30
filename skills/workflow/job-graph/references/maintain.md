# レビュー対応フェーズ（Phase 4.5）— maintain モードでレーンを起動する

PR 作成後、レビュー指摘への対応をレーンに担わせる手順。実装フェーズ（Phase 0〜4）で
使った worktree・ブランチ・PR がそのまま残っている状態を入口にする。

implement との違いは spec の top-level に `"mode": "maintain"` を足すことだけで、
以降の起動コマンド・レーン割当・ワーカー規約の切り替えは `plan_orchestration.py` と
lane-ops の `worker_contract.py` が決定論的に行う。

| | implement | maintain |
| --- | --- | --- |
| worktree | `wt switch --create <branch> --base <base>`（新規生成） | `wt switch <branch>`（既存へ入る） |
| レーン割当 | `depends_on` に従い stacked は同 workspace の tab | `depends_on` を無視し全 task が独立レーン（wave 0） |
| 起動ゲート | 前段の PR 作成（`gh pr list --head`） | なし（全レーン同時起動） |
| PR | 各ワーカーが `/review-converge` 収束後に `/pr-create` | 既に存在する。`/review-converge`・`/pr-create` は禁止 |
| push | 計画承認済みの前提で個別確認なし | 都度、親の承認が要る |
| 計画突合 | PR 前（ワーカー）・PR 後（親）の両方 | 行わない（レビュー対応の差分は元計画に無い） |

## 1. 入口 — 指摘を読み、spec を起草する

1. 対象 PR のレビューコメントを読む: `gh pr view <PR#> --comments`
   （行コメントまで拾うなら `gh api repos/{owner}/{repo}/pulls/<PR#>/comments`）
2. **どの指摘に対応するかはユーザーが決める。** 親は指摘の一覧と、それぞれが
   どの PR・どのファイルに掛かるかを整理して提示するに留め、対応要否の判断基準を
   自分で作らない（`scope-gate.md` が「分離・削除の指示を親が自分で出さない」と
   しているのと同じ理由。取捨選択は仕様の解釈変更に届きうる）
3. 確定した対応対象を task ごとの `prompt` に落として spec を起草する

## 2. 起動 — 元 spec を再利用する

**元の spec.json をコピーして書き換える**（新規に組み直さない。ブランチ名・境界・
issue 番号は実装フェーズと同じものを使い続ける）。

- top-level に `"mode": "maintain"` を足す
- 各 task の `prompt` をレビュー指摘の内容へ差し替える
- 対応不要な task は spec から削る（起動しないレーンを spec に残さない）
- `depends_on` は残っていても無視される（全 task が wave 0 の独立レーンになる）。
  maintain では `depends_on` の検証も掛からないので、task を削って参照が宙に浮いても
  エラーにならない（消しても残しても動く）
- `expected_files` / `expected_scale` は残っていても maintain では使われない（突合を行わないため）
- **`plan` は消すか、実在するパスにする。** 存在確認だけは mode に依らず走るため、
  実在しないパスが残っていると ERROR で COMMANDS が出力されない

`plan_orchestration.py` の呼び出しは implement と同じ（`--prompt-dir` は
`tmp_claude/<job>/job-graph/prompts` を再利用してよい。上書きされる）。

出力の `COMMANDS` を実行する前に、**起動コマンドに `--create` が付いていないこと**を
確認する:

```sh
grep -n 'wt switch' tmp_claude/<job>/job-graph/prompts/launch_*.sh
# => exec env -u ... wt switch <branch> -x claude -- "$(cat .../<id>.md)"
#    境界宣言のある task は -x claude ではなく -x bash -- の bootstrap 形になる
#    どちらの形でも `wt switch` の直後に --create / --base が現れないこと
```

`--create` が残っていると既存 worktree に対して `Path occupied` で失敗し、レーンが
起動しない（起動失敗は pane に残るので、実行後に `herdr agent read <pane>` で確認する）。

### 注意: 既存 worktree への switch では hook が走らない

`pre-start` / `post-start` フックは **worktree 作成時にしか走らない**（`direnv allow`・
`.env` のコピー・symlink 化など）。maintain の起動は既存 worktree へ入るだけなので、
環境は実装フェーズで整った状態のまま引き継がれる前提で起動する。環境変数や
`.envrc` の再設定が要るなら、起動後に `send_instruction.sh` でワーカーへ指示する。

### 注意: worktree が消えている場合

worktree だけ削除されていてブランチが残っている場合、`wt switch <branch>` は
worktree を**新規作成する**（ブランチが既存なので成功する）。このとき:

- `pre-start` / `post-start` は走る（新規作成のため）
- **未コミットの変更は復元されない**。実装フェーズで push していなかった作業は
  失われている。起動前に `wt list` で worktree の有無を確認する

## 3. 監視 — Phase 3 と同じ運用ループ

lane-ops の運用ループをそのまま使う（`MONITOR` 節の `watch_events.py --once` を
再起動しながら張る・`agent read` での画面確認・`verify_lane.sh` での裏取り）。
maintain では次段の起動ゲートが無いので、ゲート待ちの管理は不要になる。

handoff.md は実装フェーズのものを更新して使い続ける（レビュー対応も同じジョブの
続きであり、PR 番号・worktree・境界の所在は変わらない）。

## 4. push 承認の捌き方

maintain のワーカー規約は「push・force-push は親の承認を得てから実行する。push 前に
`push 承認待ち` を報告し、親の応答を待つ」と定める。親はこの報告を受けたら:

1. `bash <lane-ops>/scripts/verify_lane.sh <branch> <worktree>` で裏取りする
   （コミットの有無・未コミット変更の残り・push 同期状態。報告は自己申告）
2. 差分が対応対象の指摘の範囲に収まっているかを見る:
   `git -C <worktree> diff <PR の base>...HEAD --stat`
3. 範囲内なら `send_instruction.sh` で「push してよい」と伝える。
   **範囲外（指摘に無いファイル・計画外のリファクタ）ならユーザーへ上げる**
   （何を削る・分離するかを親が自分で決めない。`scope-gate.md` の FAIL 時と同じ扱い）

push 承認を計画承認で代替しないのは、レビュー対応の差分が元計画に無く、機械的な
突合ゲート（`check_scope.py`）が効かないため。突合の代わりに親の目視が最後の関門になる。

## 5. restack — 下段 PR に追加コミットが入ったら

stacked 構成では、下段の PR にレビュー対応のコミットが積まれた時点で上段は古い base の
ままになる（fast-forward の積み増しでも起きる）。下段の push 承認・push 完了を確認したら
`restack.md` の手順で上段を載せ替える。

maintain は全レーンを同時に起動するので、**下段と上段のレーンが並行して修正している**
状態になりうる。載せ替えは上段のワーカーが作業していない時点（push 完了報告の直後など）を
選び、載せ替え後は「base を変えたので該当ファイルを読み直せ」と `send_instruction.sh` で
伝える（`restack.md` の役割分担どおり、`rebase` はワーカー・`reset` は親）。

## 6. 完了条件

- 対応対象とした全指摘への修正がコミットされ、親の承認を経て push されている
- 各 PR にその push が反映されている（`gh pr view <PR#> --json commits` で確認）
- stacked なら上段が新しい下段 tip の上に載っている（`restack.md` の上段残存検査）
- レーンを閉じてよい状態になったら、実装フェーズと同じく Phase 5 の後始末へ進む
  （マージ後に `/post-merge-cleanup`。workspace / tab は自分が作ったものだけ閉じる）
