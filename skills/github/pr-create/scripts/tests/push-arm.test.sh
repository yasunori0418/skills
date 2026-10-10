#!/usr/bin/env bash
# push-arm.sh を検証する（一時リポジトリ上で実行。ネットワーク不要）。
#
# 検証内容:
#   - 既定 TTL                -> push-flow.armed に "<epoch> 1800 <branch>" を 1 行書く
#   - --ttl 指定              -> TTL を反映し、path と期限を出す
#   - branch 無し・不正な TTL -> exit 1
#   - git リポジトリの外      -> exit 1
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ARM="$SCRIPT_DIR/../push-arm.sh"

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
has() { # label haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "PASS: $(basename "$0")[$1] contains '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] missing '$3'"
        fail=1
    fi
}

git init -q "$WORK/repo"
MARKER="$WORK/repo/.git/push-flow.armed"

# --- 既定 TTL ---
OUT="$(cd "$WORK/repo" && bash "$ARM" feat 2>&1)"
check "default-exit" 0 "$?"
read -r M_EPOCH M_TTL M_BRANCH M_REST <"$MARKER" 2>/dev/null || true
check "default-ttl" 1800 "${M_TTL:-}"
check "default-branch" feat "${M_BRANCH:-}"
check "default-no-extra-field" "" "${M_REST:-}"
check "default-single-line" 1 "$(wc -l <"$MARKER" 2>/dev/null | tr -d ' ')"
case "${M_EPOCH:-x}" in *[!0-9]*) check "default-epoch" numeric "${M_EPOCH:-}" ;;
    *) check "default-epoch-recent" ok "$([ $(($(date +%s) - M_EPOCH)) -le 60 ] && echo ok || echo stale)" ;; esac
has "default-path" "$OUT" "push-flow.armed"

# --- --ttl 指定（既存の marker を上書きする） ---
OUT="$(cd "$WORK/repo" && bash "$ARM" feat --ttl 60 2>&1)"
check "ttl-exit" 0 "$?"
read -r M_EPOCH M_TTL M_BRANCH <"$MARKER" 2>/dev/null || true
check "ttl-value" 60 "${M_TTL:-}"
has "ttl-expires" "$OUT" "expires: $((${M_EPOCH:-0} + 60))"

# --- 不正な引数 ---
(cd "$WORK/repo" && bash "$ARM" >/dev/null 2>&1)
check "no-branch" 1 "$?"
for bad in abc 0 08; do
    (cd "$WORK/repo" && bash "$ARM" feat --ttl "$bad" >/dev/null 2>&1)
    check "bad-ttl-$bad" 1 "$?"
done
(cd "$WORK/repo" && bash "$ARM" feat extra >/dev/null 2>&1)
check "two-branches" 1 "$?"

# --- git リポジトリの外 ---
mkdir -p "$WORK/plain"
(cd "$WORK/plain" && GIT_CEILING_DIRECTORIES="$WORK" bash "$ARM" feat >/dev/null 2>&1)
check "outside-repo" 1 "$?"

exit "$fail"
