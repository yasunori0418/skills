#!/usr/bin/env bash
# Verifies webfetch-github-guard:
#   - https://github.com 配下の URL -> deny（gh コマンドへ誘導）
#   - それ以外の URL / URL なし     -> 沈黙
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
decision() { # url-json-fragment
    printf '{"tool_input": %s}' "$1" | "$GUARD" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

check "github-pr" "deny" "$(decision '{"url": "https://github.com/owner/repo/pull/1"}')"
check "github-root" "deny" "$(decision '{"url": "https://github.com"}')"
check "other-host" "" "$(decision '{"url": "https://example.com/github.com"}')"
check "gist" "" "$(decision '{"url": "https://gist.github.com/x"}')"
check "no-url" "" "$(decision '{}')"

exit "$fail"
