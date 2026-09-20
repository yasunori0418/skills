#!/usr/bin/env bash
# Verifies report.sh:
#   - 位置引数で呼ぶと JSONL へ 1 行追記される（既存インターフェースの互換）
#   - --file <path> で本文をファイルから読める
#   - --file のファイルが空・不在なら exit 2 で JSONL へ追記しない
#   - herdr が無い環境でも exit 0（JSONL が正本、直送は従）
#
# --file の背景: 報告本文を引数へ載せるとコマンド名を含む報告が guard hook の
# 検出に掛かり、報告自体が止まる。本文をファイル経由にすると引数へ乗らない。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPORT="$SCRIPT_DIR/../report.sh"

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

# 実際の親へ直送しないよう herdr 連携を落とし、JSONL も一時ディレクトリへ向ける。
export XDG_STATE_HOME="$WORK/state"
unset HERDR_ENV
JSONL="$XDG_STATE_HOME/lane-ops/reports/test-parent.jsonl"

# 位置引数 -> JSONL へ 1 行追記（herdr 不在でも exit 0）
rc=0
bash "$REPORT" test-parent T1 "最初のコミット完了" 実装と テスト > /dev/null 2>&1 || rc=$?
check "positional-exit0" "0" "$rc"
check "positional-one-line" "1" "$(wc -l < "$JSONL" | tr -d ' ')"
check "positional-fields" "0" \
    "$(jq -e 'select(.task == "T1" and .milestone == "最初のコミット完了" and .detail == "実装と テスト")' \
        "$JSONL" > /dev/null; echo $?)"

# --file -> detail がファイルの内容になる
printf '%s\n' '本文の 1 行目' > "$WORK/detail.txt"
rc=0
bash "$REPORT" --file "$WORK/detail.txt" test-parent T2 "push 完了" > /dev/null 2>&1 || rc=$?
check "file-exit0" "0" "$rc"
check "file-detail" "本文の 1 行目" "$(tail -1 "$JSONL" | jq -r '.detail')"
check "file-appends" "2" "$(wc -l < "$JSONL" | tr -d ' ')"

# --file が空 -> exit 2・追記しない
: > "$WORK/empty.txt"
rc=0
bash "$REPORT" --file "$WORK/empty.txt" test-parent T3 "ブロック" > /dev/null 2>&1 || rc=$?
check "empty-file-exit2" "2" "$rc"
check "empty-file-no-append" "2" "$(wc -l < "$JSONL" | tr -d ' ')"

# --file が不在 -> exit 2・追記しない
rc=0
bash "$REPORT" --file "$WORK/missing.txt" test-parent T4 "ブロック" > /dev/null 2>&1 || rc=$?
check "missing-file-exit2" "2" "$rc"
check "missing-file-no-append" "2" "$(wc -l < "$JSONL" | tr -d ' ')"

# --file と位置引数の詳細の併用 -> exit 2・追記しない
rc=0
bash "$REPORT" --file "$WORK/detail.txt" test-parent T6 "push 完了" 余分な詳細 > /dev/null 2>&1 || rc=$?
check "both-detail-exit2" "2" "$rc"
check "both-detail-no-append" "2" "$(wc -l < "$JSONL" | tr -d ' ')"

# 引数不足 -> exit 2
rc=0
bash "$REPORT" test-parent T5 > /dev/null 2>&1 || rc=$?
check "missing-args" "2" "$rc"

# --file に値が無い -> exit 2（オプション直後に引数が尽きる境界）
rc=0
bash "$REPORT" --file > /dev/null 2>&1 || rc=$?
check "file-without-value" "2" "$rc"

exit "$fail"
