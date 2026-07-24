#!/usr/bin/env bash
# Verifies review-check.sh (test-review の機械検査):
#   - plan: 完備な成果物         -> exit 0
#   - plan: 成果物なし           -> exit 1
#   - plan: テーブル空欄         -> exit 1
#   - analyze: R# 参照先なし     -> exit 1 / 参照先あり -> exit 0 / plan なし -> SKIP + exit 0
#   - design: TC 未カバー        -> exit 1 / 全カバー -> exit 0
#   - implement: 手動ありで手順書なし -> exit 1 / 自動のみ -> exit 0
#   - execute: D# 定義あり       -> exit 0 / D# 定義なし -> exit 1
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

# --- 引数エラー ---
check "unknown-stage" 2 "$(run nosuch "$WORK/plan-pass")"
check "missing-dir" 2 "$(run plan "$WORK/no-such-dir")"

exit $fail
