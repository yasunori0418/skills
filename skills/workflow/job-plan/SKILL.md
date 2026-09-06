---
name: job-plan
description: "grilling の対話で job-graph 向けの計画（tmp_claude/<job>/plan.md と job-graph/spec.json）を確定し、任意で GitHub の epic / sub-issue へ出す上流スキル。`/job-plan` の明示実行専用。"
user-invocable: true
disable-model-invocation: true
argument-hint: "[対象名 | 資料パス | issue 番号] [--issue]"
allowed-tools: Skill, Bash, Read, Write, Edit, Glob, Grep, Agent, AskUserQuestion
---

# job-plan

job-graph は「計画ファイル → spec.json → レーン起動 → 手放し監視」を担うが、手放し運用の成否は
計画の完成度で決まる。依存辺・境界・期待ファイルが曖昧だと job-graph は Phase 0 で問いを立てて
止まり、完了条件が曖昧だとワーカーが勝手に終了判断する。job-plan はその上流で、
**grilling による対話**で計画を閉じ、job-graph がそのまま消費できる 2 ファイルを確定させる:

- `tmp_claude/<job>/plan.md`（6 章固定。ワーカーの `/review-converge` が ground truth として読む）
- `tmp_claude/<job>/job-graph/spec.json`（`plan` が plan.md を指す。job-graph の計画突合の材料）

外部書き込み（GitHub issue）を含み得るため `disable-model-invocation: true`。`/job-plan` の明示実行
時のみ動く。以下、スキル本体のパスを `<SKILL>` と表記する。

## 前提と制約

1. **grilling は必須依存。** 対話の進め方（フロンティア・推奨案付きの問い・事実は自分で調べる）は
   `Skill("grilling")` に委ね、本スキルは brief と「閉じるまで終われない項目」を固定するだけ
   （`references/grilling-brief.md`）。フロンティアが空になるまで成果物を書かない。
2. **事実はユーザーに訊かない。** 変更対象・境界・規模は既存コードを調べて叩き台を出し、承認を取る。
   タスク分割が固まった直後に **1 回まとめて調査するラウンド**を必ず置く（brief 参照）。
3. **ローカル成果物は常に書く。issue は明示時のみ。** `--issue` が無ければ AskUserQuestion で問い、
   既定はローカルのみ。起票前に本文を提示して承認を取る（external-writes 準拠）。
4. **末尾ゲートを通してから引き渡す。** `check_plan_spec.py`（plan ↔ spec 整合）と job-graph の
   `plan_orchestration.py`（循環・base・plan 実在）が両方通るまで終わらない。FAIL は該当項目だけ
   grilling へ戻す（全体をやり直さない）。
5. **job-graph を自動で起動しない。** 最後に `/job-graph tmp_claude/<job>/plan.md` を提示して終わる。
   HERDR_ENV は本スキルには不要。

## 決定論ツール（scripts/）

Python プロジェクト（`pyproject.toml` + `uv.lock`、依存なし）。実行は
`UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/job-plan" uv run --project "<SKILL>" python "<SKILL>/scripts/<script>.py"`。

- **`check_plan_spec.py <plan.md> <spec.json>`**（stdlib のみ）: 第 3 章の固定小見出しと spec の task を
  突合し `VERDICT: PASS|FAIL` を出す。job-graph の Phase 0 も同じスクリプトを兄弟パスで呼ぶ
- **`create_issues.py --plan … --spec … [--epic N] [--sync]`**: epic / sub-issue の起票・spec への
  `issue` 書き戻し・plan.md 第 6 章への URL 追記・改訂同期。`gh auth status` を先に検査する

## 全体フロー

### Phase A: 入口を読む

引数を解釈する（`--issue` は末尾フラグとして分離）:

| 引数 | 入力 | 読み方 |
| --- | --- | --- |
| 対象名・自由記述 | ユーザーの依頼 | `<job>` 名をこの語彙から提案する |
| `docs/dev/<対象>/spec.md` 等のパス | feature-spec の成果物 | `REQ-#` を全て拾い、task へ引き継ぐ |
| 数字 | GitHub issue | `gh issue view <N> --json title,body` と `gh api repos/{owner}/{repo}/issues/<N>/sub_issues` で本文と既存 sub-issue を読む。sub-issue はタスク候補 |

`tmp_claude/<job>/` が既にあれば **改訂か別名か**を AskUserQuestion で問う（推奨 = 改訂）。改訂なら
既存 plan.md / spec.json を読み、差分だけを grilling する（既存 task の `issue` 番号は保つ）。

### Phase B: grilling で閉じる

`Skill("grilling")` を、`references/grilling-brief.md` の雛形で組んだ brief 付きで呼ぶ。brief には
「閉じるまで終われない項目」10 個（`<job>` 名 / 分割・branch・依存 / boundary / expected_files・scale /
完了条件 / コミット計画 / 事前裁定 / スコープ外 / REQ-# 対応 / 既存 sub-issue の振り分け）を必ず載せる。

- タスク分割が固まったら、コード調査ラウンド（brief の「コード調査ラウンドの置き方」）を挟み、
  task ごとの変更対象・境界・規模の叩き台を提示して確認を取る
- 事前裁定は lane-ops の判定基準表（「常にユーザー裁定」行）に当たる論点を候補として出し、裁定を
  取るか「該当なし」を明言させる。様式は job-graph `references/handoff.md` と同じ
- コミット計画は `commit-plan` スキル準拠（task = ブランチ単位）
- フロンティアが空になったら brief のチェックリストで 10 項目を確認する。未了があればその項目だけ
  grilling へ戻す

### Phase C: 書き出しと末尾ゲート

1. `tmp_claude/<job>/plan.md` を `references/plan-template.md` の 6 章で書く。第 3 章の小見出し
   （branch / 依存 / 完了条件 / 変更対象 / 規模目安 / 境界 / コミット計画）は固定文法。崩すと
   `check_plan_spec.py` が偽 FAIL を出す
2. `tmp_claude/<job>/job-graph/spec.json` を `references/plan-spec-mapping.md` の対応表で書く
   （`plan` は `tmp_claude/<job>/plan.md`、`prompt` は組み立て規則どおり）
3. ゲート（コマンドは mapping 参照）:
   - `check_plan_spec.py` → `VERDICT: PASS`。FAIL の ERROR 行は task 単位で直す。WARNING（第 5 章が空・
     REQ-# の孤児）は該当項目だけ grilling へ戻す
   - `plan_orchestration.py`（`--prompt-dir` なし）→ `ERROR` なし。`SCHEDULE` の wave が第 2 章の見込みと
     合うことを目視する

改訂のときも同じ手順。既存 task の spec を書き換えない限り `issue` は保たれる。

### Phase D: issue 出力（任意）

- `--issue` があれば問わずに進む。無ければ AskUserQuestion で「ローカルのみ（推奨）/ GitHub issue にも
  出す」を問う。**本文にも選択肢を書く**（remote-control で選択 UI 前の文脈が見えない対策）。
  AskUserQuestion が deny されていれば番号付きで列挙して回答を求める
- 出す場合は external-writes 準拠で、epic タイトル + sub-issue タイトル一覧 +「本文は plan.md 第 3 章の
  各節」を提示 → 承認 → `create_issues.py`（入力が issue 番号なら `--epic <番号>`）。手順・失敗時の
  再実行・改訂時の `--sync` は `references/plan-spec-mapping.md`
- `gh auth status` が通らなければスクリプトは何も作らず exit 2。その旨を伝えてローカル成果物だけで
  終える（issue は後から同じコマンドで出せる）

### Phase E: 引き渡し

次を提示して終わる（自動連鎖しない）:

```
/job-graph tmp_claude/<job>/plan.md
```

併せて伝える: 親は `acceptEdits` 等の明示 permission mode で動かすこと（job-graph Phase 1 の注意）、
issue を出したなら epic の URL、改訂なら変更した task の一覧。

## 連携スキル・参照

このスキルは下記を**呼び出す側**で、内容を重複させない。

- `grilling`（Phase B の対話そのもの）/ `commit-plan`（コミット計画の様式）/ `external-writes`
  （Phase D の承認）/ `job-graph`（引き渡し先。spec の意味は job-graph `references/spec.md`、依存・境界の
  判定基準は `references/dependency-analysis.md`）/ `lane-ops`（事前裁定の判定基準表）
- `references/`: `grilling-brief.md`（brief 雛形・閉じる項目・調査ラウンド）/ `plan-template.md`
  （plan.md の 6 章と第 3 章の固定文法）/ `plan-spec-mapping.md`（plan → spec の対応表、末尾ゲートと
  issue 起票・改訂同期のコマンド）
