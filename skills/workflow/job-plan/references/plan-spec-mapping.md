# plan-spec-mapping — plan.md → spec.json の対応と issue 起票・改訂同期の手順

spec.json は job-graph `plan_orchestration.py` の入力（フィールドの意味は job-graph
`references/spec.md`、形は job-graph `scripts/example-spec.json`）。plan.md から機械的に写せる項目は
写し、`prompt` だけは job-plan が組み立てる。

## 対応表

| plan.md | spec.json | 備考 |
| --- | --- | --- |
| `# 計画: <job>` / 置き場 | top-level `plan` | `tmp_claude/<job>/plan.md`（cwd 相対。job-graph は cwd 基準で絶対化する） |
| （固定） | top-level `default_base` | 通常 `"main"`。リポジトリの既定ブランチが違えばそれ |
| （書かない） | top-level `mode` | 省略（= implement）。maintain は job-graph Phase 4.5 の領分 |
| 第 3 章 `### <id>: <概要>` | `tasks[].id` | 1:1。plan に無い task・spec に無い task はどちらも FAIL |
| `- branch:` | `tasks[].branch` | 完全一致 |
| `- 依存:` | `tasks[].depends_on` | 集合一致。`なし` = `[]`。複数親は job-graph が WARNING（先頭親を仮採用）なので、複数書くなら依存の意味を grilling で確認する |
| `- 変更対象:` | `tasks[].expected_files` | 集合一致。実パス・glob 不可 |
| `- 規模目安:` | `tasks[].expected_scale` | 整数一致 |
| `- 境界:` | `tasks[].boundary` | 集合一致（`tmp_claude/**` は両側で無視） |
| `- 完了条件:` + `- コミット計画:` + `- 対応要求:` | `tasks[].prompt` | 下記の組み立て規則 |
| 第 6 章 `- sub-issue: <id> → <URL>` | `tasks[].issue` | `create_issues.py` が書き戻す。手で書くのは issue 入力の既存 sub-issue を振り分けたときだけ |
| （書かない） | `tasks[].model` / `permission_mode` / `effort` | 起動時の上書き。plan では扱わず、job-graph の起動引数に委ねる。task 個別に必要ならユーザーが spec を直接編集する |

`prompt` の組み立て規則（ワーカー規約は lane-ops `worker_contract.py` が連結するので書かない）:

```
<概要>。<第 1 章の要点を 1〜2 文>
対応要求: REQ-01, REQ-02        ← 第 1 章に REQ-# があるときだけ
完了条件: <- 完了条件: の内容>
コミット計画:
1. <- コミット計画: の 1 行目>
2. …
```

計画の参照（`tmp_claude/<job>/plan.md` を読め）はワーカー規約の「計画の参照」条項が載せるので、
prompt に重ねて書かない。

## 書き出しの順序と末尾ゲート

1. `tmp_claude/<job>/plan.md` を書く（plan-template.md）
2. `tmp_claude/<job>/job-graph/spec.json` を書く（上表）
3. 整合検査:

   ```bash
   UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/job-plan" uv run --project "<SKILL>" \
     python "<SKILL>/scripts/check_plan_spec.py" tmp_claude/<job>/plan.md tmp_claude/<job>/job-graph/spec.json
   ```

   `VERDICT: FAIL` なら ERROR 行の task / 項目だけ直す（plan.md と spec.json のどちらが正かは
   grilling の合意内容で決まる。両方直すことはない）。WARNING は内容を読んで、必要なら該当項目だけ
   grilling へ戻す（第 5 章が空 / REQ-# の孤児）
4. job-graph 側の検証（`--prompt-dir` なし。COMMANDS は出ないが循環・base・plan 実在を検査する）:

   ```bash
   UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/job-graph" uv run --project "<SKILL>/../job-graph" \
     python "<SKILL>/../job-graph/scripts/plan_orchestration.py" tmp_claude/<job>/job-graph/spec.json
   ```

   `ERROR`（循環・重複 id・plan 不在）は spec の該当 task を直す。`WARNING`（複数親・expected_files
   欠落）は grilling へ戻すか、ユーザーが承知の上なら残す。`SCHEDULE` の wave 構成が第 2 章の見込みと
   合うことを目視する

## issue 起票（`--issue` または AskUserQuestion で「出す」を選んだとき）

external-writes 準拠: **本文を提示 → 承認 → 実行**。承認前に `gh issue create` を叩かない。

1. 提示する本文: epic のタイトル（plan.md の H1）と冒頭（「ローカル計画: `tmp_claude/<job>/plan.md`」+
   plan.md 全文）、sub-issue のタイトル（`<job>: <id> <概要>`）と本文（第 3 章の該当節）。全文を貼ると
   長いので、タイトル一覧 + 「本文は plan.md の第 3 章各節そのまま」で足りる
2. 承認後:

   ```bash
   UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/job-plan" uv run --project "<SKILL>" \
     python "<SKILL>/scripts/create_issues.py" --plan tmp_claude/<job>/plan.md --spec tmp_claude/<job>/job-graph/spec.json
   # 入力が issue 番号だったとき（その issue を epic にする）:
   #   … --epic <番号>
   ```

   スクリプトは `gh auth status` / `gh repo view` を先に検査し、失敗なら何も作らず exit 2。
   epic を確定した直後にその URL を plan.md 第 6 章へ書き、task ごとに作成 → spec の `issue`
   書き戻し → 紐付け、の順で進む。紐付け失敗は WARNING + タスクリストで代替する。途中で落ちたら
   （exit 1）**第 6 章の epic 番号を `--epic <番号>` に付けて**同じコマンドを再実行する（`issue` が
   埋まった task は飛ぶ。`--epic` 無しで再実行すると epic が二重に作られる）
3. 完了後、第 6 章に epic / sub-issue の URL が追記されているのを確認し、`check_plan_spec.py` を
   もう一度通す（`issue` の書き戻しは検査対象外なので PASS のまま。念のため）

## 改訂時の同期（既存 `tmp_claude/<job>/` を改訂したとき）

1. 差分 grilling → plan.md / spec.json を更新 → 末尾ゲート（上記）
2. 既存 task の `issue` は保つ。落とした task は spec から消す（`issue` ごと）。新 task は `issue` 無し
3. 第 6 章に epic があり、ユーザーが同期を望むなら:

   ```bash
   … create_issues.py --plan tmp_claude/<job>/plan.md --spec tmp_claude/<job>/job-graph/spec.json --epic <第 6 章の epic 番号> --sync
   ```

   - epic に新版の全文をコメント
   - 既存 task: `gh pr list --head <branch>` で PR があれば通知コメントのみ、無ければタイトル・本文を更新
   - API の sub-issue にあって spec に無いもの: 理由コメント付きで close
   - 新 task: 新規経路（作成 → 書き戻し → 紐付け）
4. これも external-writes 準拠で、実行前に「何を更新・close・作成するか」を提示して承認を取る
