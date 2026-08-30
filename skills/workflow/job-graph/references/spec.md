# spec — フィールド表と起草基準

`plan_orchestration.py` に渡す JSON spec の全フィールド。形の例は `scripts/example-spec.json`。
AI の責務はここまで（依存辺・境界・期待ファイルの意味的判定）で、以降の順序・base・コマンド生成はスクリプトが保証する。

## top-level

| フィールド | 型 | 既定 | 意味 |
| --- | --- | --- | --- |
| `default_base` | string | `"main"` | 依存の無い task の base ブランチ |
| `plan` | string | なし | 計画ファイルのパス（相対なら cwd 基準で絶対化。指定されていて存在しなければ ERROR）。ワーカー規約の「計画の参照」条項に載り、`/review-converge` の `DIFF_REVIEW_GROUND_TRUTH` になる。計画ファイル入口なら必ず書く（epic issue 入口で計画ファイルが無いときだけ省略） |
| `mode` | string | `"implement"` | ジョブ全体の性質。`implement` = 実装 → PR 作成（Phase 0〜4）、`maintain` = PR 作成後のレビュー対応（Phase 4.5）。他の値は ERROR。`maintain` にすると起動が既存 worktree への `wt switch`（`--create` なし）になり、`depends_on` を無視して全 task が独立レーン（wave 0）になり、出力から `PR` / `VERIFY` 節が消え、ワーカー規約が `/review-converge`・`/pr-create` 禁止 + push 親承認へ切り替わる。手順は `maintain.md` |
| `tasks` | array | 必須（非空） | 下表の task |

`mode: "maintain"` のときは計画突合を行わないため、`plan` / `expected_files` /
`expected_scale` はワーカー規約にも突合にも使われない（`depends_on` も同様に無視され、検証されない）。
ただし次の 2 つは mode に依らず走る:

- **`expected_files` 欠落の WARNING**。同じ spec を implement へ戻して再利用したときに、
  maintain 時に無警告で通った欠落へ気づけるようにするため（処理は止まらない）
- **`plan` の存在確認**。maintain では **消すか、実在するパスにする**（実在しないパスが
  残っていると ERROR で COMMANDS が出ない）。元 spec を再利用する運用では計画ファイルの
  パスが残ったまま maintain に入るのが既定経路なので、起動前に確認する

## task

| フィールド | 型 | 既定 | 意味 |
| --- | --- | --- | --- |
| `id` | string | 必須 | 一意な短い id（pane 変数 `PANE_<id>`・プロンプトファイル名になる） |
| `branch` | string | 必須 | feature ブランチ名（一意。`wt switch --create` に渡る。maintain では `--create` なしの `wt switch` に渡り、既存ブランチへ入る） |
| `depends_on` | string[] | `[]` | 前段 task の id。空 = 独立（並列）、1 つ = その branch を base にした stacked 段、複数 = WARNING（先頭親を仮採用）。判定基準は `dependency-analysis.md` |
| `prompt` | string | 必須相当 | タスク固有の内容と完了条件だけを書く（運用規約は worker_contract が連結するので書かない） |
| `issue` | int | `0` | 対応する GitHub issue 番号。規約に issue 参照と PR へのリンク指示が載る |
| `boundary` | string[] | `[]` | 編集を許す glob。宣言すると境界ファイルを生成し task-boundary hook が境界外 Edit/Write を deny する。`tmp_claude/**` は自動追加。決め方は `dependency-analysis.md`、仕組みは `boundary.md`。maintain では既存 worktree の境界ファイルと**マージ**される（allow は和集合。実装フェーズ中に widen した分は保たれる。詳細は `maintain.md`） |
| `model` / `permission_mode` / `effort` | string | 未指定 | claude 起動の task 個別上書き（CLI フラグのグローバル既定より優先）。`permission_mode` は `acceptEdits` / `auto` / `bypassPermissions` / `manual` / `dontAsk` / `plan`、`effort` は `low` / `medium` / `high` / `xhigh` / `max` |
| `expected_files` | string[] | `[]` | 計画に書かれた変更ファイル一覧（下記の起草基準）。`check_scope.py` の照合対象。無い task は WARNING（ファイル照合なしに縮退） |
| `expected_scale` | int | `0` | 計画の規模目安（追加 + 削除の行数）。実測が `expected_scale × 2` を超えると FAIL。`0` = 規模照合なし |

## `expected_files` / `expected_scale` の起草基準

計画突合（`scope-gate.md`）の判定精度はここで決まる。緩いと計画外変更を通し、厳しいと正当作業を FAIL にする。

- **計画の「変更対象」に書かれたファイルをそのまま**列挙する。リポジトリルート相対のパスで、**glob は不可**（`check_scope.py` は完全一致で照合する。`boundary` とは役割が違う: boundary は「触ってよい範囲」、expected_files は「触るはずのファイル」）
- 実装に伴って**必ず巻き添えになるファイルも列挙**する: lockfile（`uv.lock` / `package-lock.json` / `flake.lock`）、スナップショット、生成物、`plugin.json` の登録配列、CHANGELOG 等。列挙漏れは FAIL になり親の裁定を要する（安全側だが手間）
- 新規ファイルも書く（計画に新設と書かれているなら、そのパス）
- `expected_scale` は計画の記述量・変更点数から見積もる**追加 + 削除の合計行数**。テストを含める。ファイル判定が主で規模は補助（AI の見積りなので、閾値は 2 倍まで許容される）
- **計画に変更ファイル一覧や規模が無いときは、憶測で埋めずユーザーへ問う**（計画側に書き足してもらうか、対話で確定してから spec に落とす）。空のまま進めると突合が縮退し、Phase 4 のゲートが機能しない
- stacked の後段は、その段で触るファイルだけを書く（前段の変更は base 側に入るので diff に現れない）

## 置き場: spec と prompt-dir は `tmp_claude/<job>/job-graph/` に置く

```
tmp_claude/<job>/
  plan.md                 # 計画（spec の plan）
  handoff.md              # 引き継ぎ書（handoff.md 参照）
  job-graph/
    spec.json             # plan_orchestration.py の入力
    prompts/              # --prompt-dir: <task-id>.md と launch_<task-id>.sh
```

scratchpad（セッション固有の一時ディレクトリ）に置くと、**親交代（セッション再開・別セッションの親へ引き継ぎ）でパスが失効し、起動済みワーカーへ渡した prompt ファイルや後続 wave の launch スクリプトが読めなくなった実績**がある。`tmp_claude/` はリポジトリ直下で gitignored、worktree からも絶対パスで辿れ、handoff.md と同じ場所に揃う。spec と prompt-dir の絶対パスは handoff.md の「所在」に記録する。
