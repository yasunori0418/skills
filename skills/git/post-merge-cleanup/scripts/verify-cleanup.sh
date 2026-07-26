#!/usr/bin/env bash
#
# verify-cleanup.sh — 実行後の状態を再取得し、承認された計画と突合する。
# read-only。apply が途中で失敗しても単独で再実行できる（だから collect/apply とは
# 別スクリプトにしてある）。
#
# Usage:
#   verify-cleanup.sh < approved.json
#     approved.json は apply-cleanup.sh に渡したものと同じ JSON。
#
# 期待: 承認された各対象について worktree / ローカルブランチ / tmux セッションが
#       いずれも消えていること。残っていれば RESIDUAL として列挙する。
set -euo pipefail

command -v jq >/dev/null 2>&1 || {
    echo "ERROR: jq が必要です" >&2
    exit 1
}
git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "ERROR: git リポジトリ内で実行してください" >&2
    exit 1
}

input=$(cat)
targets=$(jq -c '[(.candidates // [])[] | select(.deletable == true)]' <<<"$input")
n=$(jq 'length' <<<"$targets")

echo "=== VERIFY ==="
echo "検証対象: $n 件"

residual=0
while IFS=$'\t' read -r branch wpath sess; do
    [ -n "$branch" ] || continue
    left=()

    if [ -n "$wpath" ] && [ "$wpath" != "null" ] && [ -d "$wpath" ]; then
        left+=("worktree が残存: $wpath")
    fi
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        left+=("ローカルブランチが残存: $branch")
    fi
    if [ -n "$sess" ] && [ "$sess" != "null" ] &&
        command -v tmux >/dev/null 2>&1 &&
        tmux has-session -t "$sess" 2>/dev/null; then
        left+=("tmux セッションが残存: $sess")
    fi

    if [ ${#left[@]} -eq 0 ]; then
        echo "OK: $branch — worktree / ブランチ / tmux とも削除済み"
    else
        for l in "${left[@]}"; do
            echo "RESIDUAL: $branch — $l"
        done
        residual=$((residual + 1))
    fi
done < <(jq -r '.[] | [.branch, (.worktree_path // ""), (.tmux_session // "")] | @tsv' <<<"$targets")

echo "=== CURRENT STATE ==="
if command -v wt >/dev/null 2>&1; then
    wt list 2>/dev/null || true
else
    git worktree list
fi
echo "--- local branches ---"
git branch
if command -v tmux >/dev/null 2>&1; then
    echo "--- tmux sessions ---"
    tmux ls 2>/dev/null || echo "(なし)"
fi

echo "=== SUMMARY ==="
if [ "$residual" -gt 0 ]; then
    echo "判定: 残存あり $residual 件 — 計画と不一致。原因を報告し、force 系での強行はしないこと"
    exit 1
fi
echo "判定: 計画どおり — 残存なし"
