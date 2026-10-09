#!/usr/bin/env bash
# Verifies rules/10-push-armed.sh を dispatcher(main.sh)経由で:
#   - marker 有効 + ブランチ一致 + 単独 push(cd … && 前置のみ可) -> allow
#   - marker なし / 期限切れ(marker 削除)/ ブランチ不一致            -> 沈黙
#   - 複合コマンド / 他の ask 対象(rm・curl・wget)を含む            -> 沈黙
#   - default branch(origin/HEAD、無ければ main / master)への push -> 沈黙
#   - force 等の許可外オプション / 非リテラルの cd / Bash 以外       -> 沈黙
#   - いずれも exit 0
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GATE="$SCRIPT_DIR/../main.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"

REPO="$TMP/repo"     # feat/x、origin/HEAD -> main
OTHER="$TMP/other"   # feat/x、marker なし(cd 先の marker を見ることの確認用)
MAINREPO="$TMP/main" # main、origin/HEAD なし(main / master フォールバック)
git init -q -b feat/x "$REPO"
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git init -q -b feat/x "$OTHER"
git init -q -b main "$MAINREPO"

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
behavior() { # command [cwd] [tool_name]
    local out rc=0
    out=$(jq -cn --arg c "$1" --arg d "${2:-$REPO}" --arg t "${3:-Bash}" \
        '{session_id: "s1", cwd: $d, tool_name: $t, tool_input: {command: $c}}' \
        | "$GATE") || rc=$?
    [ "$rc" -eq 0 ] || {
        echo "rc=$rc"
        return
    }
    printf '%s' "$out" | jq -r 'select(.hookSpecificOutput.hookEventName == "PermissionRequest")
        | .hookSpecificOutput.decision.behavior // empty'
}
arm() { # repo branch [age秒] [ttl秒]
    echo "$(($(date +%s) - ${3:-0})) ${4:-1800} $2" >|"$1/.git/push-flow.armed"
}

# marker なし -> 沈黙
check "unarmed" "" "$(behavior 'git push')"

# marker 有効 + ブランチ一致 -> allow
arm "$REPO" feat/x
check "armed-bare" "allow" "$(behavior 'git push')"
check "armed-upstream" "allow" "$(behavior 'git push -u origin feat/x')"
check "armed-head" "allow" "$(behavior 'git push origin HEAD')"
check "armed-refspec" "allow" "$(behavior 'git push origin feat/x:feat/x')"
check "armed-cd" "allow" "$(behavior "cd $REPO && git push" /)"

# cd 先の marker で判定する(cwd 側が arm 済みでも cd 先が未 arm なら沈黙)
check "cd-other-unarmed" "" "$(behavior "cd $OTHER && git push")"
check "cd-nonliteral" "" "$(behavior 'cd $HOME && git push')"

# ブランチ不一致 -> 沈黙
check "refspec-mismatch" "" "$(behavior 'git push origin feat/y')"
check "refspec-dst-mismatch" "" "$(behavior 'git push origin feat/x:feat/y')"
arm "$REPO" feat/y
check "marker-mismatch" "" "$(behavior 'git push')"

# 複合コマンド・他の ask 対象 -> 沈黙
arm "$REPO" feat/x
check "seq" "" "$(behavior 'git push; ls')"
check "and-prefix" "" "$(behavior 'git status && git push')"
check "and-suffix" "" "$(behavior 'git push && ls')"
check "pipe" "" "$(behavior 'git push 2>&1 | tail -3')"
check "or" "" "$(behavior 'git push || true')"
check "background" "" "$(behavior 'git push &')"
check "subst" "" "$(behavior 'git push origin $(git branch --show-current)')"
check "rm" "" "$(behavior 'rm -rf build && git push')"
check "curl" "" "$(behavior 'git push && curl -s https://example.com')"
check "wget" "" "$(behavior 'wget -q https://example.com; git push')"
check "rm-as-arg" "" "$(behavior 'git push origin rm')"

# 許可外オプション(force・delete 等)-> 沈黙
check "force" "" "$(behavior 'git push --force')"
check "force-short" "" "$(behavior 'git push -f')"
check "force-refspec" "" "$(behavior 'git push origin +feat/x')"
check "delete" "" "$(behavior 'git push origin --delete feat/x')"

# Bash 以外 -> 沈黙
check "non-bash" "" "$(behavior 'git push' "$REPO" Write)"

# default branch への push -> 沈黙(arm があっても)
check "to-default" "" "$(behavior 'git push origin HEAD:main')"
arm "$MAINREPO" main
check "default-fallback-main" "" "$(behavior 'git push' "$MAINREPO")"
git -C "$MAINREPO" symbolic-ref HEAD refs/heads/master
arm "$MAINREPO" master
check "default-fallback-master" "" "$(behavior 'git push' "$MAINREPO")"

# 期限切れ -> 沈黙 + marker 削除
arm "$REPO" feat/x 3600 1800
check "expired" "" "$(behavior 'git push')"
check "expired-removed" "absent" "$([ -e "$REPO/.git/push-flow.armed" ] && echo present || echo absent)"

exit "$fail"
