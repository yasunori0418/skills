#!/usr/bin/env bash
# Verifies rules/10-push-armed.sh を dispatcher(main.sh)経由で:
#   - marker 有効 + ブランチ一致 + 単独 push(cd … && 前置のみ可) -> allow
#   - marker なし / 期限切れ(marker 削除)/ ブランチ不一致            -> 沈黙
#   - 複合コマンド / 他の ask 対象(rm・curl・wget)を含む            -> 沈黙
#   - 保護ブランチ(origin/HEAD の既定ブランチ + 静的リスト main / master / develop /
#     development / trunk / release / release/* / releases/*)への push -> 沈黙
#     (origin/HEAD が無くても静的リストで守る)
#   - force 等の許可外オプション / 非リテラルの cd / Bash 以外       -> 沈黙
#   - いずれも exit 0
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GATE="$SCRIPT_DIR/../main.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"
# 実行者の global / system gitconfig(push.default 等)に結果を左右させない
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

REPO="$TMP/repo"     # feat/x、origin/HEAD -> main
OTHER="$TMP/other"   # feat/x、marker なし(cd 先の marker を見ることの確認用)
MAINREPO="$TMP/main" # main、origin/HEAD なし(静的リストで守る)
DEVREPO="$TMP/dev"   # develop、origin/HEAD -> develop(default branch の主経路)
NOHEAD="$TMP/nohead" # develop、origin/HEAD なし(静的リストで守る)
PROD="$TMP/prod"     # production、origin/HEAD -> production(静的リストに無い既定ブランチ)
WT="$TMP/wt"         # REPO の linked worktree(feat/w)。marker は worktree ごとに別
git init -q -b feat/x "$REPO"
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b feat/w "$WT"
git init -q -b feat/x "$OTHER"
git init -q -b main "$MAINREPO"
git init -q -b develop "$DEVREPO"
git -C "$DEVREPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
git init -q -b develop "$NOHEAD"
git init -q -b production "$PROD"
git -C "$PROD" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/production

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
marker() { # repo -> marker の絶対パス(git rev-parse --git-path で解決)
    local m
    m=$(git -C "$1" rev-parse --git-path push-flow.armed)
    case "$m" in /*) echo "$m" ;; *) echo "$1/$m" ;; esac
}
arm() { # repo branch [age秒] [ttl秒]
    echo "$(($(date +%s) - ${3:-0})) ${4:-1800} $2" >|"$(marker "$1")"
}

# marker なし -> 沈黙
check "unarmed" "" "$(behavior 'git push')"

# marker 有効 + ブランチ一致 -> allow
arm "$REPO" feat/x
check "armed-bare" "allow" "$(behavior 'git push')"
check "armed-upstream" "allow" "$(behavior 'git push -u origin feat/x')"
check "armed-head" "allow" "$(behavior 'git push origin HEAD')"
check "armed-refspec" "allow" "$(behavior 'git push origin feat/x:feat/x')"
check "armed-remote-only" "allow" "$(behavior 'git push origin')"
check "armed-refs-heads" "allow" "$(behavior 'git push origin refs/heads/feat/x')"
check "armed-cd" "allow" "$(behavior "cd $REPO && git push" /)"
check "armed-cd-relative" "allow" "$(behavior 'cd repo && git push' "$TMP")"

# worktree: marker は worktree ごと(git rev-parse --git-path)。main 側の marker は linked worktree に効かない
arm "$REPO" feat/w
check "worktree-ignores-main-marker" "" "$(behavior 'git push' "$WT")"
rm -f "$(marker "$REPO")"
arm "$WT" feat/w
check "worktree-armed" "allow" "$(behavior 'git push' "$WT")"
check "main-unarmed" "" "$(behavior 'git push')"
arm "$REPO" feat/x

# push 先を設定で書き換えうる構成 -> 沈黙(simple / current は allow)
git -C "$REPO" config push.default simple
check "push-default-simple" "allow" "$(behavior 'git push')"
git -C "$REPO" config push.default current
check "push-default-current" "allow" "$(behavior 'git push')"
git -C "$REPO" config push.default upstream
check "push-default-upstream" "" "$(behavior 'git push')"
git -C "$REPO" config --unset push.default
git -C "$REPO" config remote.origin.push 'refs/heads/*:refs/heads/main'
check "remote-push-mapping" "" "$(behavior 'git push')"
git -C "$REPO" config --unset remote.origin.push

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
check "newline" "" "$(behavior $'git push\nls')"
check "too-many-refspecs" "" "$(behavior 'git push origin feat/x feat/y')"
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

# 保護ブランチへの push -> 沈黙(arm があっても)
check "dst-main-mismatch" "" "$(behavior 'git push origin HEAD:main')"
arm "$DEVREPO" develop
check "default-origin-head" "" "$(behavior 'git push' "$DEVREPO")"
arm "$MAINREPO" main
check "default-fallback-main" "" "$(behavior 'git push' "$MAINREPO")"
git -C "$MAINREPO" symbolic-ref HEAD refs/heads/master
arm "$MAINREPO" master
check "default-fallback-master" "" "$(behavior 'git push' "$MAINREPO")"
arm "$NOHEAD" develop
check "static-develop-no-origin-head" "" "$(behavior 'git push -u origin develop' "$NOHEAD")"
for b in development trunk release release/1.0 releases/2026; do
    git -C "$NOHEAD" symbolic-ref HEAD "refs/heads/$b"
    arm "$NOHEAD" "$b"
    check "static-$b" "" "$(behavior "git push -u origin $b" "$NOHEAD")"
done
git -C "$NOHEAD" symbolic-ref HEAD refs/heads/release-notes
arm "$NOHEAD" release-notes
check "static-prefix-only" allow "$(behavior 'git push -u origin release-notes' "$NOHEAD")"
arm "$PROD" production
check "origin-head-non-static" "" "$(behavior 'git push' "$PROD")"

# marker の内容が不正 -> 沈黙
: >|"$(marker "$REPO")"
check "marker-empty" "" "$(behavior 'git push')"
echo "abc 1800 feat/x" >|"$(marker "$REPO")"
check "marker-epoch-nan" "" "$(behavior 'git push')"
echo "$(date +%s) 1800" >|"$(marker "$REPO")"
check "marker-no-branch" "" "$(behavior 'git push')"

# 期限切れ -> 沈黙 + marker 削除
arm "$REPO" feat/x 3600 1800
check "expired" "" "$(behavior 'git push')"
check "expired-removed" "absent" "$([ -e "$(marker "$REPO")" ] && echo present || echo absent)"

exit "$fail"
