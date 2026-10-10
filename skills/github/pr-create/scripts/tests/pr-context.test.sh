#!/usr/bin/env bash
# pr-context.sh の CONFIRMATION セクションを検証する（一時リポジトリ上で実行。ネットワーク不要。gh は偽物に差し替える）。
#
# 検証内容:
#   - 作業ブランチ（release-notes のように静的リストの語で始まるだけのものも） -> confirm: skip
#   - 静的リスト（main / master / develop / development / trunk / release / release/* / releases/*）
#     -> confirm: required（origin/HEAD が無くても。ベースを特定できない main 上でも出る）
#   - origin/HEAD が静的リストに無いブランチを指す                 -> そのブランチも required
#   - origin が GitHub で、gh が既定ブランチを返す                   -> そのブランチも required
#   - gh が失敗する                                                  -> github=(取得できず)、静的リストで判定
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
for b in feat/x release-notes develop development trunk master release releases/2026 production staging; do
    git -C "$R" switch -q -c "$b" main
    git -C "$R" commit -q --allow-empty -m "work on $b"
done
STATIC="main master develop development trunk release release/* releases/*"

# origin なし・origin/HEAD なし: 静的リストだけで判定する
for b in feat/x release-notes; do
    git -C "$R" switch -q "$b"
    check "$b-skip" skip "$(field "$R" confirm)"
done
check "protected-static" "$STATIC" "$(field "$R" protected)"
check "default-none" "origin/HEAD=(なし) github=(対象外)" "$(field "$R" default)"
for b in main master develop development trunk release releases/2026; do
    git -C "$R" switch -q "$b"
    check "$b-required" required "$(field "$R" confirm)"
done
# release と release/1.0 は同じリポジトリに共存できないので別に作る
R2="$WORK/repo2"
git init -q -b main "$R2"
git -C "$R2" commit -q --allow-empty -m init
git -C "$R2" switch -q -c release/1.0
git -C "$R2" commit -q --allow-empty -m "work on release/1.0"
check "release/1.0-required" required "$(field "$R2" confirm)"

# origin/HEAD が静的リストに無い production を指す
git -C "$R" update-ref refs/remotes/origin/production production
git -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/production
git -C "$R" switch -q production
check "origin-head-required" required "$(field "$R" confirm)"
check "origin-head-protected" "$STATIC production" "$(field "$R" protected)"
# 静的リストにある develop を指すときは重複させない
git -C "$R" update-ref refs/remotes/origin/develop develop
git -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
check "origin-head-no-dup" "$STATIC" "$(field "$R" protected)"
git -C "$R" symbolic-ref --delete refs/remotes/origin/HEAD

# origin が GitHub: 偽の gh が既定ブランチ staging を返す
BIN="$WORK/bin"
mkdir -p "$BIN"
printf '#!/bin/sh\necho staging\n' >"$BIN/gh"
chmod +x "$BIN/gh"
git -C "$R" remote add origin git@github.com:example/repo.git
git -C "$R" switch -q staging
check "github-default-required" required "$(PATH="$BIN:$PATH" field "$R" confirm)"
check "github-default-shown" "origin/HEAD=(なし) github=staging" "$(PATH="$BIN:$PATH" field "$R" default)"
git -C "$R" switch -q feat/x
check "github-default-feature-skip" skip "$(PATH="$BIN:$PATH" field "$R" confirm)"
# gh が失敗する: 取得できない旨を出し、静的リストで判定する
printf '#!/bin/sh\nexit 1\n' >"$BIN/gh"
git -C "$R" switch -q develop
check "github-fail-shown" "origin/HEAD=(なし) github=(取得できず)" "$(PATH="$BIN:$PATH" field "$R" default)"
check "github-fail-static" required "$(PATH="$BIN:$PATH" field "$R" confirm)"

exit "$fail"
