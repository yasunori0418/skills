# レビュー対応フェーズ（Phase 4.5）— maintain モードでレーンを起動する

PR 作成後、レビュー指摘への対応をレーンに担わせる手順。実装フェーズ（Phase 0〜4）で
使った worktree・ブランチ・PR がそのまま残っている状態を入口にする。

spec の top-level に `"mode": "maintain"` を足せば、起動コマンド・レーン割当・ワーカー規約の
切り替えは `plan_orchestration.py` と lane-ops の `worker_contract.py` が決定論的に行う
（spec 側で他に要る調整は §2。特に `plan` は消すか実在パスにしないと起動できない）。

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
4. **plan 承認を取る**（`ExitPlanMode`）。実装フェーズの Phase 1 と同じくレーン起動の前に承認を取る。
   Phase 1 の必須要素のうち **PR 戦略と計画突合の基準だけ**を次に差し替える
   （起動ウェーブとレーン割当・コミット計画・承認代行の宣言はそのまま含める）:
   - 起動するレーン（どの PR のどの指摘へ、どの task が対応するか）
   - **push は都度親が承認する**こと（Phase 1 の plan 承認は push の承認を兼ねない）。
     承認代行の宣言は maintain では対話ゲートへの応答だけに掛かる — push はこの例外に従い、
     PR 作成はワーカー規約が禁じているので対象自体が無い
   - stacked なら下段・上段の関係と、下段 push 後に restack が要ること（下記 §5）

### 注意: stack 関係は spec の外に控える

maintain の出力は `depends_on` を無視するため、`SCHEDULE` / `LANES` / 起動スクリプトのどこにも
**下段・上段の関係が現れない**（`PR` 節も出ない）。§5 の restack はこの関係を前提にするので、
**どの PR がどの PR の上に載っているかを handoff.md に控えてから起動する**（`gh pr view <PR#> --json baseRefName`
で確認できる）。spec の `depends_on` を残しておくと spec 自体が控えになるので、消さずに残す方が安全
（maintain では無視されるだけで害は無い）。

## 2. 起動 — 元 spec を再利用する

**元の spec.json をコピーして書き換える**（新規に組み直さない。ブランチ名・境界・
issue 番号は実装フェーズと同じものを使い続ける）。

- top-level に `"mode": "maintain"` を足す
- 各 task の `prompt` をレビュー指摘の内容へ差し替える
- 対応不要な task は spec から削る（起動しないレーンを spec に残さない）
- `depends_on` は**残す**。maintain では無視される（全 task が wave 0 の独立レーンになる）が、
  出力に stack 関係が出ない以上、spec が唯一の控えになる（§1 の注意参照）。maintain では
  `depends_on` の検証も掛からないので、task を削って参照が宙に浮いてもエラーにならない
- `expected_files` / `expected_scale` は残っていても maintain では使われない（突合を行わないため）。
  ただし `expected_files` 欠落の WARNING は maintain でも出る（処理は止まらない。同じ spec を
  implement へ戻して再利用したときに欠落へ気づけるようにするため）
- **`plan` は消すか、実在するパスにする。** 存在確認だけは mode に依らず走るため、
  実在しないパスが残っていると ERROR で COMMANDS が出力されない
- `boundary` は実装フェーズと同じ宣言のままでよい。widen した分は起動時のマージで保たれる（下記の注意）
- **`plan_orchestration.py` の `--parent-name` は maintain では必須**（無いと ERROR で
  COMMANDS が出ない。push 承認待ちの報告先が要るため）

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

### 起動前に閉じる: 実装フェーズのレーン

**実装フェーズの pane / workspace が生きたまま maintain を起動しない。** maintain は既存
worktree へ入るので、implement 期のレーンが残っていると**同じ worktree・同じブランチで
claude が 2 つ動く**。未コミット変更の巻き込みコミット・git の index lock 競合・
`verify_lane.sh` の裏取り汚染が起きる。`wt switch`（`--create` なし）はこの状況でも
エラーにならず素通りするので、機械的な歯止めが無い。

さらに workspace のラベルは implement 期と同じブランチ名になるため、旧 workspace が
残っていると**同じラベルが 2 つ並ぶ**。lane-ops はラベル引き（`workspace list | select(.label == ...) | head -n1`）で
workspace を解決するので、親の指示送信・push 承認が旧 pane へ届く経路が残る。

```sh
wt list                                                   # worktree の所在を確認
herdr --session "$HSESSION" agent list                    # 生きている claude を確認
herdr --session "$HSESSION" workspace close <旧 workspace>  # 実装フェーズのレーンを閉じる
```

### 注意: 境界ファイルは既存とマージされる（spec の `boundary` は実態より狭くなりうる）

境界宣言のある task の起動は、implement と同じ bootstrap（`-x bash --`）を通る。既存 worktree に
`.claude/task-boundary.json` があれば上書きせず、**`allow` を既存 ∪ 宣言の和集合**にして書く
（`task_id` / `branch` は宣言が正）。実装フェーズ中に `widen_boundary.sh`（親専用）で広げた glob は
このマージで保たれるので、起動前の突き合わせや spec への写しは要らない。

その代わり、**spec の `boundary`（出力の `BOUNDARY` 節）は実際に許可されている範囲より狭いことがある**。
ワーカーが今どこまで触れるかは worktree 側のファイルを見る:

```sh
cat <worktree>/.claude/task-boundary.json
```

既存ファイルが空・不正 JSON・境界の書式でない（object でない / `allow` が配列でない）とき
（`widen_boundary.sh` の空 stdin 事故跡など）は bootstrap が**起動を中止する**（上書きせず exit≠0。
pane に `ERROR: 既存の境界ファイルが空・不正 JSON・境界の書式でない` が残る）。
**消す前に `cat` で中身を見る**: widen 分の glob が入っていれば控えてから直す（消して起動し直すと
widen 分は宣言側にしか残らない）。pane のエラーが `ERROR: jq が無いため既存の境界ファイルと
マージできない` なら境界ファイルは壊れていない — jq を入れて起動し直す。起動失敗は「worktree が
消えている・使えない場合」と同じく全 pane を直接見て拾う。境界を宣言していない task はこの問題を持たない（境界ファイルを
生成せず、hook も沈黙する）。

### 注意: 既存 worktree への switch では hook が走らない

`pre-start` / `post-start` フックは **worktree 作成時にしか走らない**（`direnv allow`・
`.env` のコピー・symlink 化など）。maintain の起動は既存 worktree へ入るだけなので、
環境は実装フェーズで整った状態のまま引き継がれる前提で起動する。環境変数や
`.envrc` の再設定が要るなら、起動後に `send_instruction.sh` でワーカーへ指示する。

### 注意: worktree が消えている・使えない場合

worktree だけ削除されていてブランチが残っている場合、`wt switch <branch>` は
worktree を**新規作成する**（ブランチが既存なので成功する）。このとき:

- `pre-start` / `post-start` は走る（新規作成のため）
- **未コミットの変更は復元されない**。実装フェーズで push していなかった作業は
  失われている。起動前に `wt list` で worktree の有無を確認する

対象ブランチが別の worktree で checkout 済みのときは `wt switch` 自体が失敗する。
maintain は全レーンを同時に起動するため、**複数の起動失敗が同時に埋もれる**。
起動直後は watch を張る前に、全 pane を直接見て生存を確かめる:

```sh
herdr --session "$HSESSION" agent list                    # 起動した全 pane が並ぶか
herdr --session "$HSESSION" pane read <pane> --lines 40   # 並ばない pane は shell エラーを読む
```

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
   （`<PR の base>` は maintain の出力には出ない。§1 の注意で控えた stack 関係、または
   `gh pr view <PR#> --json baseRefName` から取る）
3. 範囲内なら `send_instruction.sh` で「push してよい」と伝える。
   **範囲外（指摘に無いファイル・計画外のリファクタ）ならユーザーへ上げる**
   （何を削る・分離するかを親が自分で決めない。`scope-gate.md` の FAIL 時と同じ扱い）

push 承認を計画承認で代替しないのは、レビュー対応の差分が元計画に無く、機械的な
突合ゲート（`check_scope.py`）が効かないため。突合の代わりに親の目視が最後の関門になる。

## 5. restack — 下段 PR に追加コミットが入ったら

stacked 構成では、下段の PR にレビュー対応のコミットが積まれた時点で上段は古い base の
ままになる（fast-forward の積み増しでも起きる）。下段の push 承認・push 完了を確認したら
`restack.md` の手順で上段を載せ替える。

**どれが下段でどれが上段かは maintain の出力に出ない**（§1 の注意）。spec の `depends_on`・
handoff.md の控え・`gh pr view <PR#> --json baseRefName` のいずれかで確認する。

maintain は全レーンを同時に起動するので、**下段と上段のレーンが並行して修正している**
状態になりうる。次段ゲートが無い以上「上段が今は止まっている」という観測は次の瞬間に
崩れるため、載せ替えの前に**上段へ明示的に停止を指示する**:

1. `send_instruction.sh` で上段へ「restack するので手を止めて待て」と伝える
2. `verify_lane.sh` で上段が停止し未コミット変更が無いことを確かめる
3. `restack.md` の手順で載せ替える（`rebase` はワーカー・`reset` は親）
4. 載せ替え後に「base を変えたので `git log --oneline -5` で確認し、該当ファイルを
   読み直してから再開」と伝える

複数レーンの push 承認待ちが同時に届いたときは、**stacked の下段から先に捌く**
（上段を先に通すと下段 push のたびに restack が二度手間になる）。

## 6. 完了条件

- 対応対象とした全指摘への修正がコミットされ、親の承認を経て push されている
- 各 PR にその push が反映されている（`gh pr view <PR#> --json commits` で確認）
- stacked なら上段が新しい下段 tip の上に載っている（`restack.md` の上段残存検査）
- レーンを閉じてよい状態になったら、実装フェーズと同じく Phase 5 の後始末へ進む
  （マージ後に `/post-merge-cleanup`。workspace / tab は自分が作ったものだけ閉じる）
