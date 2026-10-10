#!/usr/bin/env bash
# pr-context.sh の CONFIRMATION セクションを検証する（一時リポジトリ上で実行。ネットワーク不要）。
#
# 検証内容:
#   - 作業ブランチ                       -> confirm: skip
#   - main / trunk / master              -> confirm: required（ベースを特定できない main 上でも出る）
#   - origin/HEAD が develop を指す      -> develop も required、protected に develop が入る
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CTX="$SCRIPT_DIR/../pr-context.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
field() { # repo-dir key -> CONFIRMATION セクションの値
    (cd "$1" && bash "$CTX" 2>/dev/null) |
        awk -v k="$2: " '/^=== CONFIRMATION ===/{s=1;next} /^===/{s=0} s && index($0,k)==1 {print substr($0,length(k)+1)}'
}

R="$WORK/repo"
git init -q -b main "$R"
git -C "$R" commit -q --allow-empty -m init
git -C "$R" commit -q --allow-empty -m base

for b in feat/x trunk master; do
    git -C "$R" switch -q -c "$b" main
    git -C "$R" commit -q --allow-empty -m "work on $b"
done

git -C "$R" switch -q feat/x
check "feature-skip" skip "$(field "$R" confirm)"
check "protected-default" "main trunk master" "$(field "$R" protected)"
for b in main trunk master; do
    git -C "$R" switch -q "$b"
    check "$b-required" required "$(field "$R" confirm)"
done

# origin/HEAD が develop を指す構成
git -C "$R" switch -q -c develop main
git -C "$R" commit -q --allow-empty -m "work on develop"
git -C "$R" update-ref refs/remotes/origin/develop develop
git -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
check "origin-head-required" required "$(field "$R" confirm)"
check "origin-head-protected" "develop main trunk master" "$(field "$R" protected)"
git -C "$R" switch -q feat/x
check "origin-head-feature-skip" skip "$(field "$R" confirm)"

exit "$fail"
