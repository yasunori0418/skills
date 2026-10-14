#!/usr/bin/env bash
# Verifies rm-split-hint(PreToolUse・matcher: Bash):
#   - rm を含み、20-rm-scratch が書き方の理由(rm 以外の処理・禁止文字・cd の後の ; 等)で
#     allow しない                                       -> additionalContext に理由つきの注意
#   - 20-rm-scratch が allow する / 一時領域外の対象を含む / rm を含まない(git rm・firm 等)/
#     Bash 以外 / 不正な入力                             -> 沈黙
#   - permissionDecision は返さない(呼び出しを止めない)。いずれも exit 0
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
HINT="$SCRIPT_DIR/../main.sh"
U=$(id -u)
SP="/tmp/claude-$U/sess/scratchpad" # scratchpad 相当(存在しなくてよい)

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
run() { # command [tool_name] -> stdout(exit≠0 なら rc=N)
    local out rc=0
    out=$(jq -cn --arg c "$1" --arg t "${2:-Bash}" \
        '{session_id: "s1", cwd: "/", tool_name: $t, tool_input: {command: $c}}' | "$HINT") || rc=$?
    [ "$rc" -eq 0 ] && printf '%s' "$out" || echo "rc=$rc"
}
hint() { # command [tool_name] -> 注意の有無と理由(hint:<理由> / 空)
    local out
    out=$(run "$@")
    [ -n "$out" ] || return 0
    printf '%s' "$out" | jq -r 'if .hookSpecificOutput.hookEventName == "PreToolUse"
        and (.hookSpecificOutput | has("permissionDecision") | not)
        then "hint:" + (.hookSpecificOutput.additionalContext | capture("理由: (?<w>[^)]*)").w)
        else "bad:" + tojson end'
}

# 注意: 書き方を変えれば自動承認に乗りうる
check "mixed-cmd" "hint:未対応のコマンド: npx" "$(hint "rm -rf $SP/x && npx agent-browser open")"
check "pipe" "hint:禁止文字を含む: |" "$(hint "rm -rfv $SP/x | tail -1")"
check "quote" "hint:禁止文字を含む: \"" "$(hint "rm -rf \"$SP/x\"")"
check "cd-seq" "hint:cd の後の区切りが && でない" "$(hint "cd $SP; rm -rf smoke")"
check "after-newline" "hint:未対応のコマンド: mkdir" "$(hint $'mkdir -p '"$SP"$'/a\nrm -f '"$SP"/b)"
check "after-paren" "hint:禁止文字を含む: (" "$(hint "(rm -f $SP/x)")"

# 沈黙
check "allowed" "" "$(hint "rm -rf $SP/x && ls $SP")"
check "outside" "" "$(hint "rm -rf /etc/x")"
check "outside-mixed" "" "$(hint "rm -f $SP/a && rm -rf /etc/x")"
check "git-rm" "" "$(hint "git rm x && npx foo")"
check "substring" "" "$(hint "echo firm && npx foo")"
check "rmdir-word" "" "$(hint "rmdir $SP/a && npx foo")"
check "no-rm" "" "$(hint "ls -la")"
check "non-bash" "" "$(hint "rm -rf $SP/x && npx foo" Write)"
OUT=$(printf 'not json' | "$HINT" && echo "rc=0") || OUT="rc=$?"
check "invalid-input" "rc=0" "$OUT"

exit "$fail"
