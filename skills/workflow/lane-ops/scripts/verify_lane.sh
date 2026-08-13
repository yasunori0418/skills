#!/usr/bin/env bash
# verify_lane.sh — レーンの自己申告を機械検証する読み取り専用フィルタ。
#
# 使い方: verify_lane.sh <branch> [worktree-path]
#
# 事実だけをセクション区切りで出力する（判断は呼び出し側の親が行う）:
#   PR        : gh pr list --head <branch>（存在・base・draft）
#   PUSH SYNC : リモート sha とローカル HEAD の一致
#   DIRTY     : worktree の未コミット変更
#   CHANGED   : origin のデフォルトブランチとの merge-base 以降に触れたファイル
#   BOUNDARY  : 境界ファイルの allow 宣言（CHANGED と突き合わせる材料）
set -u

usage() {
    echo "usage: verify_lane.sh <branch> [worktree-path]" >&2
    exit 2
}

[ $# -ge 1 ] || usage
branch="$1"
worktree="${2:-}"

section() { printf '\n=== %s ===\n' "$1"; }

section "PR"
if pr=$(gh pr list --head "$branch" --json number,baseRefName,isDraft,url 2>&1); then
    if [ "$pr" = "[]" ]; then
        echo "(PR なし)"
    else
        printf '%s\n' "$pr"
    fi
else
    echo "ERROR: gh pr list に失敗: $pr"
fi

section "PUSH SYNC"
if remote=$(git ${worktree:+-C "$worktree"} ls-remote origin "refs/heads/$branch" 2>&1); then
    remote_sha=$(printf '%s' "$remote" | cut -f1)
    [ -n "$remote_sha" ] || remote_sha="(リモートにブランチなし)"
    echo "remote: $remote_sha"
else
    echo "remote: ERROR: $remote"
fi
if [ -n "$worktree" ]; then
    echo "local:  $(git -C "$worktree" rev-parse HEAD 2>&1)"
else
    echo "local:  $(git rev-parse "refs/heads/$branch" 2>&1)"
fi

if [ -n "$worktree" ]; then
    section "DIRTY"
    dirty=$(git -C "$worktree" status --porcelain 2>&1)
    if [ -n "$dirty" ]; then
        printf '%s\n' "$dirty"
    else
        echo "clean"
    fi

    section "CHANGED (origin デフォルトブランチとの merge-base 以降)"
    def=$(git -C "$worktree" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    def="${def:-main}"
    if base=$(git -C "$worktree" merge-base HEAD "origin/$def" 2>/dev/null); then
        git -C "$worktree" diff --name-only "$base"..HEAD
    else
        echo "(merge-base を特定できず。origin/$def が無い可能性)"
    fi

    section "BOUNDARY (allow 宣言)"
    bfile="$worktree/.claude/task-boundary.json"
    if [ -f "$bfile" ]; then
        jq -r '.allow[]?' "$bfile" 2>/dev/null || echo "(境界ファイルが読めない: $bfile)"
    else
        echo "(境界ファイルなし)"
    fi
fi
