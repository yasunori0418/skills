#!/usr/bin/env bash
# Verifies review-check.sh (test-review の機械検査):
#   - plan: 完備な成果物         -> exit 0
#   - plan: 成果物なし           -> exit 1
#   - plan: テーブル空欄         -> exit 1
#   - analyze: R# 参照先なし     -> exit 1 / 参照先あり -> exit 0 / plan なし -> SKIP + exit 0
#   - design: TC 未カバー        -> exit 1 / 全カバー -> exit 0
#   - implement: 手動ありで手順書なし -> exit 1 / 自動のみ -> exit 0
#   - execute: D# 定義あり       -> exit 0 / D# 定義なし -> exit 1
#   - spec: 完備 -> exit 0 / セクション欠落・REQ 重複定義・REQ 参照先なし -> exit 1
#           test-analysis.md の孤児参照 -> exit 1 / test-analysis.md なし -> SKIP + exit 0
#   - design-doc: 完備 -> exit 0 / 機能一覧に REQ 参照なし行 -> exit 1
#                 spec.md なし -> SKIP + exit 0 / CASE-# 突合 NG -> exit 1
#   - 不明な工程・ディレクトリ   -> exit 2
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CHECK="$SCRIPT_DIR/../review-check.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
run() { # stage dir -> exit code
    "$CHECK" "$1" "$2" >/dev/null 2>&1
    echo $?
}

write_plan() { # dir
    cat >"$1/test-plan.md" <<'EOF'
# テスト計画: sample
## 1. 目的とスコープ
- スコープ内: 集計モジュール
## 2. プロダクトリスク評価
| # | リスク項目 | 発生可能性 | 影響度 | リスクレベル | 根拠 |
|---|---|---|---|---|---|
| R1 | 集計が壊れる | 高 | 高 | 高 | 新規実装のため |
## 3. テストアプローチ
- 重点領域: R1
## 4. 開始基準・完了基準
- 完了基準: カバレッジ 80% 以上
EOF
}
write_analysis() { # dir risk-id
    cat >"$1/test-analysis.md" <<EOF
# テスト分析: sample
## 2. テスト観点一覧（テスト条件）
| ID | テスト条件 | 切り口 | 対応テストベース | 対応リスク # | 優先度 |
|---|---|---|---|---|---|
| TC-01 | 集計が正しい | 機能 | 仕様 1 章 | $2 | 高 |
| TC-02 | 空データで壊れない | 境界 | 仕様 2 章 | - | 中 |
## 3. 優先度の根拠
- $2 対応のため高
## 4. カバレッジの見立て
- 全機能を網羅
EOF
}
write_design() { # dir
    cat >"$1/test-design.md" <<'EOF'
# テスト設計書: sample
## 1. 採用テスト技法と選定根拠
| 対応テスト条件 | 採用技法 | 選定根拠 | カバレッジ基準 |
|---|---|---|---|
| TC-01 | 境界値分析 | 値域を持つため | 各境界の内外 |
## 2. カバレッジの確認
- 全境界を網羅
## 3. 自動/手動の区分基準
| 実行手段 | 実行方法 | 区分 |
|---|---|---|
| Unit テスト | make test | 自動 |
EOF
}
write_case() { # dir covered-conditions(space separated) kubun
    {
        echo "# テストケース一覧: sample"
        echo "| ID | 対応テスト条件 | 前提条件 | 入力 | 期待結果 | 区分 | 優先度 |"
        echo "|---|---|---|---|---|---|---|"
        local i=1
        for tc in $2; do
            echo "| CASE-0$i | $tc | なし | 0 | エラーなし | $3 | 高 |"
            i=$((i + 1))
        done
    } >"$1/test-case.md"
}

# --- plan ---
D="$WORK/plan-pass" && mkdir -p "$D" && write_plan "$D"
check "plan-pass" 0 "$(run plan "$D")"

D="$WORK/plan-missing" && mkdir -p "$D"
check "plan-missing-file" 1 "$(run plan "$D")"

D="$WORK/plan-empty-cell" && mkdir -p "$D" && write_plan "$D"
printf '| R2 |  | 高 | 高 | 高 | 根拠 |\n' >>"$D/test-plan.md"
check "plan-empty-cell" 1 "$(run plan "$D")"
OUT=$("$CHECK" plan "$D" 2>&1 || true)
echo "$OUT" | grep -q '空欄セルあり' && check "plan-empty-cell-msg" ok ok || check "plan-empty-cell-msg" ok ng

# --- analyze ---
D="$WORK/analyze-pass" && mkdir -p "$D" && write_plan "$D" && write_analysis "$D" R1
check "analyze-pass" 0 "$(run analyze "$D")"

D="$WORK/analyze-dangling" && mkdir -p "$D" && write_plan "$D" && write_analysis "$D" R9
check "analyze-dangling-risk" 1 "$(run analyze "$D")"
OUT=$("$CHECK" analyze "$D" 2>&1 || true)
echo "$OUT" | grep -q 'R9' && check "analyze-dangling-id-named" ok ok || check "analyze-dangling-id-named" ok ng

D="$WORK/analyze-no-plan" && mkdir -p "$D" && write_analysis "$D" R1
check "analyze-no-plan-skip" 0 "$(run analyze "$D")"
OUT=$("$CHECK" analyze "$D" 2>&1 || true)
echo "$OUT" | grep -q '^SKIP' && check "analyze-no-plan-skip-msg" ok ok || check "analyze-no-plan-skip-msg" ok ng

# --- design ---
D="$WORK/design-uncovered" && mkdir -p "$D" && write_analysis "$D" R1 && write_design "$D" && write_case "$D" "TC-01" 自動
check "design-uncovered" 1 "$(run design "$D")"
OUT=$("$CHECK" design "$D" 2>&1 || true)
echo "$OUT" | grep -q 'TC-02' && check "design-uncovered-id-named" ok ok || check "design-uncovered-id-named" ok ng

D="$WORK/design-pass" && mkdir -p "$D" && write_analysis "$D" R1 && write_design "$D" && write_case "$D" "TC-01 TC-02" 自動
check "design-pass" 0 "$(run design "$D")"

# --- implement ---
D="$WORK/impl-manual-missing" && mkdir -p "$D" && write_case "$D" "TC-01" 手動
check "implement-manual-no-procedures" 1 "$(run implement "$D")"

D="$WORK/impl-auto-only" && mkdir -p "$D" && write_case "$D" "TC-01" 自動
check "implement-auto-only" 0 "$(run implement "$D")"

# --- execute ---
D="$WORK/exec-pass" && mkdir -p "$D"
cat >"$D/test-execution-log.md" <<'EOF'
# テスト実行ログ: sample
## 1. 実行サマリ
| 種別 | 実行数 | 成功 | 失敗 | スキップ | 備考 |
|---|---|---|---|---|---|
| 自動 | 2 | 1 | 1 | 0 | make test |
## 2. 実行結果詳細
| ケース # | 内容 | 結果 | 実際結果（失敗時） | 対応欠陥候補 # |
|---|---|---|---|---|
| CASE-01 | 集計 | 失敗 | 値ずれ | D1 |
## 3. 欠陥候補
### D1: 値ずれ
- 再現手順: 空データで実行する
EOF
check "execute-pass" 0 "$(run execute "$D")"

D="$WORK/exec-dangling" && mkdir -p "$D"
sed 's/### D1: 値ずれ/### D9: 別件/' "$WORK/exec-pass/test-execution-log.md" >"$D/test-execution-log.md"
check "execute-dangling-defect" 1 "$(run execute "$D")"

# --- spec / design-doc (docs/dev/<対象> を見る軽量ゲート) ---
# docs/dev/<対象> と docs/test/<対象> の既定レイアウトを作る。
mkdev() { # target -> echoes dev dir
    mkdir -p "$WORK/$1/docs/dev/sample" "$WORK/$1/docs/test/sample"
    echo "$WORK/$1/docs/dev/sample"
}
write_spec() { # dir acceptance-req-id
    cat >"$1/spec.md" <<EOF
# 仕様: sample

## 目的

- 集計モジュールを追加する

## スコープ

- 集計モジュールのみ

## 機能要求

### REQ-01: 集計する

- 入力を合計する

### REQ-02: 空データを扱う

- 空でも落ちない

## 非機能要求

- **NFR-01**: 応答 1 秒以内

## 受け入れ条件

| ID | 対象 | 条件 |
| --- | --- | --- |
| AC-01 | $2 | 合計が正しい |

## スコープ外

- 永続化
EOF
}
write_basic_design() { # dir feature-row-req case-ref
    cat >"$1/basic-design.md" <<EOF
# 基本設計: sample

## 機能一覧

| # | 機能 | 対応要求 | 概要 |
| --- | --- | --- | --- |
| 1 | 合計 | $2 | 入力を合計する |

## モジュール構成

- aggregator

## インターフェース

- \`sum(values) -> int\`

## データフロー

- 入力 → 合計 → 出力$3
EOF
}

# spec: 完備 (下流 test-analysis.md ありで孤児参照なし)
DEV=$(mkdev spec-pass) && write_spec "$DEV" REQ-01
write_analysis "$(dirname "$(dirname "$DEV")")/test/sample" REQ-01
check "spec-pass" 0 "$(run spec "$DEV")"

# spec: 必須セクション欠落
DEV=$(mkdev spec-no-section) && write_spec "$DEV" REQ-01
grep -v '^## スコープ外$' "$DEV/spec.md" >"$DEV/spec.tmp" && mv "$DEV/spec.tmp" "$DEV/spec.md"
check "spec-missing-section" 1 "$(run spec "$DEV")"

# spec: REQ-# 定義見出しの重複
DEV=$(mkdev spec-dup) && write_spec "$DEV" REQ-01
printf '\n### REQ-01: 重複した定義\n\n- 二重定義\n' >>"$DEV/spec.md"
check "spec-duplicate-req" 1 "$(run spec "$DEV")"
OUT=$("$CHECK" spec "$DEV" 2>&1 || true)
echo "$OUT" | grep -q '重複' && check "spec-duplicate-req-msg" ok ok || check "spec-duplicate-req-msg" ok ng

# spec: 受け入れ条件が未定義の REQ-# を参照
DEV=$(mkdev spec-dangling) && write_spec "$DEV" REQ-09
check "spec-dangling-req" 1 "$(run spec "$DEV")"
OUT=$("$CHECK" spec "$DEV" 2>&1 || true)
echo "$OUT" | grep -q 'REQ-09' && check "spec-dangling-req-named" ok ok || check "spec-dangling-req-named" ok ng

# spec: 受け入れ条件の行が REQ-# を参照していない
DEV=$(mkdev spec-noref) && write_spec "$DEV" -
check "spec-acceptance-noref" 1 "$(run spec "$DEV")"

# spec: 下流 test-analysis.md の孤児参照(仕様改訂で参照先 REQ-# を消した)
DEV=$(mkdev spec-orphan) && write_spec "$DEV" REQ-01
write_analysis "$(dirname "$(dirname "$DEV")")/test/sample" REQ-09
check "spec-downstream-orphan" 1 "$(run spec "$DEV")"
OUT=$("$CHECK" spec "$DEV" 2>&1 || true)
echo "$OUT" | grep -q 'REQ-09' && check "spec-downstream-orphan-named" ok ok || check "spec-downstream-orphan-named" ok ng

# spec: 下流 test-analysis.md が無ければ SKIP して通過
DEV=$(mkdev spec-no-analysis) && write_spec "$DEV" REQ-01
check "spec-no-analysis-skip" 0 "$(run spec "$DEV")"
OUT=$("$CHECK" spec "$DEV" 2>&1 || true)
echo "$OUT" | grep -q '^SKIP.*test-analysis.md' && check "spec-no-analysis-skip-msg" ok ok || check "spec-no-analysis-skip-msg" ok ng

# design-doc: 完備(spec.md あり・CASE-# 参照なし)
DEV=$(mkdev dd-pass) && write_spec "$DEV" REQ-01 && write_basic_design "$DEV" REQ-01 ""
check "design-doc-pass" 0 "$(run design-doc "$DEV")"

# design-doc: 機能一覧の行が REQ-# を参照していない(「-」も NG)
DEV=$(mkdev dd-noref) && write_spec "$DEV" REQ-01 && write_basic_design "$DEV" - ""
check "design-doc-feature-noref" 1 "$(run design-doc "$DEV")"

# design-doc: 参照先 REQ-# が spec.md に無い
DEV=$(mkdev dd-dangling) && write_spec "$DEV" REQ-01 && write_basic_design "$DEV" REQ-09 ""
check "design-doc-dangling-req" 1 "$(run design-doc "$DEV")"

# design-doc: spec.md が無ければ実在突合を SKIP して通過
DEV=$(mkdev dd-no-spec) && write_basic_design "$DEV" REQ-01 ""
check "design-doc-no-spec-skip" 0 "$(run design-doc "$DEV")"
OUT=$("$CHECK" design-doc "$DEV" 2>&1 || true)
echo "$OUT" | grep -q '^SKIP.*spec.md' && check "design-doc-no-spec-skip-msg" ok ok || check "design-doc-no-spec-skip-msg" ok ng

# design-doc: 参照する CASE-# が test-case.md に無い
DEV=$(mkdev dd-case-ng) && write_spec "$DEV" REQ-01 && write_basic_design "$DEV" REQ-01 '（CASE-09 で検証）'
write_case "$(dirname "$(dirname "$DEV")")/test/sample" "TC-01" 自動
check "design-doc-dangling-case" 1 "$(run design-doc "$DEV")"
OUT=$("$CHECK" design-doc "$DEV" 2>&1 || true)
echo "$OUT" | grep -q 'CASE-09' && check "design-doc-dangling-case-named" ok ok || check "design-doc-dangling-case-named" ok ng

# design-doc: basic-design スキルの references/template.md の実形に追従する回帰テスト。
#   「# 列なし 3 列テーブル」「REQ-01/03 の併記」「データフロー配下の異常系テーブル」を含む。
#   異常系テーブルを機能一覧の行と誤認すると REQ 参照なしで誤 NG になるため、形を固定して守る。
write_template_shaped_design() { # dir first-row-req
    cat >"$1/basic-design.md" <<EOF
# sample 基本設計

## 機能一覧

| 機能 | 対応要求 | 概要 |
| --- | --- | --- |
| 集計 | $2 | 合計する |
| 空処理 | REQ-01/02 | 複数要求にまたがる機能の併記形式 |

## モジュール構成

| モジュール | 区分 | 責務 | 依存先 |
| --- | --- | --- | --- |
| agg | 新設 | 合計する | io |

## インターフェース

### sum

- 提供元: agg
- 入力: values

## データフロー

### 正常系

1. 入力を受け取る

### 異常系

| 発生条件 | 検出箇所 | 振る舞い |
| --- | --- | --- |
| 空入力 | agg | 中断する |
EOF
}

DEV=$(mkdev dd-template) && write_spec "$DEV" REQ-01 && write_template_shaped_design "$DEV" REQ-01
check "design-doc-template-shape" 0 "$(run design-doc "$DEV")"

# 同じ形で「対応要求 -」= スコープ外混入なら NG(異常系テーブルは誤検出しない)
DEV=$(mkdev dd-template-drift) && write_spec "$DEV" REQ-01 && write_template_shaped_design "$DEV" -
check "design-doc-template-scope-drift" 1 "$(run design-doc "$DEV")"
OUT=$("$CHECK" design-doc "$DEV" 2>&1 || true)
NGCOUNT=$(echo "$OUT" | grep -c '^NG')
check "design-doc-template-drift-single-ng" 1 "$NGCOUNT"

# design-doc: 突合ディレクトリを第 3 引数で明示指定できる
DEV=$(mkdev dd-explicit) && write_spec "$DEV" REQ-01 && write_basic_design "$DEV" REQ-01 ""
EXPLICIT="$WORK/dd-explicit-testdir" && mkdir -p "$EXPLICIT" && write_case "$EXPLICIT" "TC-01" 自動
"$CHECK" design-doc "$DEV" "$EXPLICIT" >/dev/null 2>&1
check "design-doc-explicit-testdir" 0 "$?"

# --- 引数エラー ---
check "unknown-stage" 2 "$(run nosuch "$WORK/plan-pass")"
check "missing-dir" 2 "$(run plan "$WORK/no-such-dir")"

exit $fail
