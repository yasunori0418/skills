#!/usr/bin/env bash
# Verifies widen_boundary.sh:
#   - glob 2 個以上の追加       -> 既存 allow 維持 + 追加 glob が入る（truncate 回帰の検証）
#   - 重複 glob                 -> unique に畳まれる
#   - 境界ファイル無し          -> exit 1
#   - 境界ファイルが不正 JSON   -> 非 0 で abort し、元ファイルを破壊しない
#   - stdin が開いたままでも待たない（jq の入力欠落バグは stdin 待ちハングとしても現れた）
#
# 回帰の背景: `jq --args '<filter>' "$bfile" "$@"` は --args 以降の非オプション引数を
# すべて positional 文字列として扱うため、$bfile が入力ファイルとして読まれず
# stdin（空なら空出力）から読んでいた。空出力の mv で境界ファイルが 0 バイトになり、
# task-boundary hook が全 Edit/Write を deny してワーカーが停止する。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
WIDEN="$SCRIPT_DIR/../widen_boundary.sh"

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

make_boundary() { # 初期状態の境界ファイルを作る
    mkdir -p "$WORK/wt/.claude"
    printf '%s' '{"task_id":"t1","branch":"b1","allow":["src/**"]}' \
        > "$WORK/wt/.claude/task-boundary.json"
}
bfile="$WORK/wt/.claude/task-boundary.json"

# glob 2 個以上の追加: 既存 allow 維持 + 追加分が入る（0 バイト truncate の回帰）
make_boundary
bash "$WIDEN" "$WORK/wt" 'docs/**' 'tests/**' > /dev/null
check "keeps-existing" "true" "$(jq '.allow | contains(["src/**"])' "$bfile")"
check "adds-globs" "true" "$(jq '.allow | contains(["docs/**","tests/**"])' "$bfile")"
check "keeps-other-keys" "t1" "$(jq -r '.task_id' "$bfile")"
check "non-empty" "yes" "$([ -s "$bfile" ] && echo yes || echo no)"

# 重複 glob は unique に畳まれる
make_boundary
bash "$WIDEN" "$WORK/wt" 'src/**' 'docs/**' > /dev/null
check "unique" "1" "$(jq '[.allow[] | select(. == "src/**")] | length' "$bfile")"

# 境界ファイル無し -> exit 1
rm -f "$bfile"
rc=0
bash "$WIDEN" "$WORK/wt" 'docs/**' > /dev/null 2>&1 || rc=$?
check "missing-file" "1" "$rc"

# 不正 JSON -> 非 0 で abort し、元ファイルは破壊しない
mkdir -p "$WORK/wt/.claude"
printf '%s' 'not-json' > "$bfile"
rc=0
bash "$WIDEN" "$WORK/wt" 'docs/**' > /dev/null 2>&1 || rc=$?
check "broken-json-aborts" "no" "$([ "$rc" -eq 0 ] && echo yes || echo no)"
check "broken-json-preserved" "not-json" "$(cat "$bfile")"

# stdin に依存しない（入力欠落バグの回帰）。/dev/zero は EOF が来ず JSON としても
# 不正なので、stdin から読む実装ならハングか失敗し、境界ファイルから読む実装だけが
# 正しく完走する。
make_boundary
rc=0
bash "$WIDEN" "$WORK/wt" 'docs/**' < /dev/zero > /dev/null || rc=$?
check "stdin-independent-rc" "0" "$rc"
check "stdin-independent-content" "true" "$(jq '.allow | contains(["src/**","docs/**"])' "$bfile")"

exit "$fail"
