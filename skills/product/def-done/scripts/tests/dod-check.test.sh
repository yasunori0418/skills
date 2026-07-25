#!/usr/bin/env bash
# Verifies dod-check.sh (def-done の機械検査):
#   - 完備な完成の定義           -> exit 0
#   - 機械判定セクション欠落     -> exit 1
#   - 人判定セクション欠落       -> exit 1
#   - 不正な種別                 -> exit 1
#   - 不正な条件(ci-check/artifact それぞれ) -> exit 1
#   - DOD-# 重複                 -> exit 1
#   - DOD-# 形式不正             -> exit 1
#   - 空欄セル                   -> exit 1
#   - 機械判定テーブルのデータ行なし -> exit 1
#   - 人判定が空                 -> exit 1 / 「(なし)」明記 -> exit 0
#   - contains:<文字列> 条件      -> exit 0
#   - 項目総数 5 件              -> exit 0 / 6 件 -> exit 1
#   - 引数なし・ファイルなし     -> exit 2
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CHECK="$SCRIPT_DIR/../dod-check.sh"

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
run() { # file -> exit code
    "$CHECK" "$1" >/dev/null 2>&1
    echo $?
}
# rows... を機械判定テーブルのデータ行として、human を人判定節の中身として書く。
write_dod() { # file human-body row...
    local file=$1 human=$2
    shift 2
    {
        echo "# 完成の定義"
        echo
        echo "- 改訂日: 2026-07-25"
        echo
        echo "## 機械判定"
        echo
        echo "| ID | 項目 | 種別 | 対象 | 条件 |"
        echo "|---|---|---|---|---|"
        local row
        for row in "$@"; do
            echo "$row"
        done
        echo
        echo "## 人判定"
        echo
        echo "$human"
    } >"$file"
}

PASS_ROW1='| DOD-01 | テストが green | ci-check | test | success |'
PASS_ROW2='| DOD-02 | 完了レポートがある | artifact | docs/test/{target}/test-summary-report.md | exists |'
PASS_ROW3='| DOD-03 | 総合判定が合格 | artifact | docs/test/{target}/test-summary-report.md | contains:合格 |'
HUMAN_OK='- [ ] 使い勝手に問題がないことを確認した'

# --- 正常系 ---
F="$WORK/pass.md" && write_dod "$F" "$HUMAN_OK" "$PASS_ROW1" "$PASS_ROW2" "$PASS_ROW3"
check "pass" 0 "$(run "$F")"

F="$WORK/pass-human-none.md" && write_dod "$F" "（なし）" "$PASS_ROW1"
check "pass-human-none" 0 "$(run "$F")"

F="$WORK/pass-human-checked.md" && write_dod "$F" "- [x] 確認済み" "$PASS_ROW1"
check "pass-human-checked" 0 "$(run "$F")"

# --- セクション欠落 ---
F="$WORK/no-machine.md"
{
    echo "# 完成の定義"
    echo "## 人判定"
    echo "$HUMAN_OK"
} >"$F"
check "missing-machine-section" 1 "$(run "$F")"
OUT=$("$CHECK" "$F" 2>&1 || true)
echo "$OUT" | grep -q 'セクション「機械判定」が見つからない' &&
    check "missing-machine-section-msg" ok ok || check "missing-machine-section-msg" ok ng

F="$WORK/no-human.md"
{
    echo "# 完成の定義"
    echo "## 機械判定"
    echo "| ID | 項目 | 種別 | 対象 | 条件 |"
    echo "|---|---|---|---|---|"
    echo "$PASS_ROW1"
} >"$F"
check "missing-human-section" 1 "$(run "$F")"

# --- 不正な種別 ---
F="$WORK/bad-kind.md" && write_dod "$F" "$HUMAN_OK" \
    '| DOD-01 | 手で確認する | manual | なし | success |'
check "bad-kind" 1 "$(run "$F")"
OUT=$("$CHECK" "$F" 2>&1 || true)
echo "$OUT" | grep -q 'manual' && check "bad-kind-named" ok ok || check "bad-kind-named" ok ng

# --- 不正な条件 ---
F="$WORK/bad-cond-ci.md" && write_dod "$F" "$HUMAN_OK" \
    '| DOD-01 | テストが green | ci-check | test | exists |'
check "bad-condition-ci-check" 1 "$(run "$F")"
OUT=$("$CHECK" "$F" 2>&1 || true)
echo "$OUT" | grep -q 'DOD-01' && check "bad-cond-ci-named" ok ok || check "bad-cond-ci-named" ok ng

F="$WORK/bad-cond-artifact.md" && write_dod "$F" "$HUMAN_OK" \
    '| DOD-01 | 成果物がある | artifact | docs/a.md | success |'
check "bad-condition-artifact" 1 "$(run "$F")"

F="$WORK/bad-cond-contains-empty.md" && write_dod "$F" "$HUMAN_OK" \
    '| DOD-01 | 成果物に記載がある | artifact | docs/a.md | contains: |'
check "bad-condition-contains-empty" 1 "$(run "$F")"

# --- DOD-# 重複 ---
F="$WORK/dup-id.md" && write_dod "$F" "$HUMAN_OK" \
    '| DOD-01 | テストが green | ci-check | test | success |' \
    '| DOD-01 | 別の項目 | artifact | docs/a.md | exists |'
check "duplicate-id" 1 "$(run "$F")"
OUT=$("$CHECK" "$F" 2>&1 || true)
echo "$OUT" | grep -q '重複した ID' && check "duplicate-id-msg" ok ok || check "duplicate-id-msg" ok ng

# --- 空欄セル ---
F="$WORK/empty-cell.md" && write_dod "$F" "$HUMAN_OK" \
    '| DOD-01 |  | ci-check | test | success |'
check "empty-cell" 1 "$(run "$F")"
OUT=$("$CHECK" "$F" 2>&1 || true)
echo "$OUT" | grep -q '空欄セルあり' && check "empty-cell-msg" ok ok || check "empty-cell-msg" ok ng

# --- 列数不正 ---
F="$WORK/bad-cols.md" && write_dod "$F" "$HUMAN_OK" \
    '| DOD-01 | テストが green | ci-check | success |'
check "bad-column-count" 1 "$(run "$F")"

# --- データ行なし ---
F="$WORK/no-rows.md" && write_dod "$F" "$HUMAN_OK"
check "no-data-rows" 1 "$(run "$F")"

# --- 人判定が空 ---
F="$WORK/human-empty.md" && write_dod "$F" "" "$PASS_ROW1"
check "human-empty" 1 "$(run "$F")"
OUT=$("$CHECK" "$F" 2>&1 || true)
echo "$OUT" | grep -q '「(なし)」の明記も無い' && check "human-empty-msg" ok ok || check "human-empty-msg" ok ng

# --- 項目総数の上限(機械判定 + 人判定 ≤ 5) ---
PASS_ROW4='| DOD-04 | README が更新済み | artifact | README.md | exists |'
F="$WORK/limit-pass.md" && write_dod "$F" "$HUMAN_OK" \
    "$PASS_ROW1" "$PASS_ROW2" "$PASS_ROW3" "$PASS_ROW4"
check "item-limit-5-pass" 0 "$(run "$F")"

F="$WORK/limit-over.md" && write_dod "$F" "$HUMAN_OK
- [ ] リリース手順を確認した" \
    "$PASS_ROW1" "$PASS_ROW2" "$PASS_ROW3" "$PASS_ROW4"
check "item-limit-over" 1 "$(run "$F")"
OUT=$("$CHECK" "$F" 2>&1 || true)
echo "$OUT" | grep -q '項目総数が上限超過' && check "item-limit-over-msg" ok ok || check "item-limit-over-msg" ok ng

# --- 引数エラー ---
"$CHECK" >/dev/null 2>&1
check "no-args" 2 "$?"
check "missing-file" 2 "$(run "$WORK/no-such-file.md")"

exit $fail
