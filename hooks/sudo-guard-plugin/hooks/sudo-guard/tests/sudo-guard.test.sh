#!/usr/bin/env bash
# Verifies sudo-guard:
#   - コマンド語としての sudo（行頭・区切り直後）-> deny
#   - パス・ファイル名・単語の一部に "sudo" を含むだけ -> 沈黙
#     （旧 cchook 構成の command_contains "sudo" が誤爆していたケース）
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/../main.sh"

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
decision() { # command
    printf '{"tool_input": {"command": %s}}' "$(printf '%s' "$1" | jq -Rs .)" \
        | "$GUARD" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

# コマンド語としての sudo -> deny
check "head" "deny" "$(decision 'sudo ls /root')"
check "after-semicolon" "deny" "$(decision 'echo hi; sudo rm -rf /tmp/x')"
check "after-and" "deny" "$(decision 'true && sudo systemctl restart foo')"
check "after-pipe" "deny" "$(decision 'echo pw | sudo -S id')"
check "bare" "deny" "$(decision 'sudo')"

# 単語の一部・パスに含まれるだけ -> 沈黙
check "dir-name" "" "$(decision 'mkdir -p hooks/sudo-guard/tests')"
check "file-arg" "" "$(decision 'cat docs/sudoers-note.md')"
check "word-prefix" "" "$(decision 'echo visudo')"
check "word-suffix" "" "$(decision 'echo sudoku')"

exit "$fail"
