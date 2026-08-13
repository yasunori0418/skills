#!/usr/bin/env bash
# widen_boundary.sh — タスク境界（allow glob）の拡張。親（オーケストレータ）専用。
#
# 使い方: widen_boundary.sh <worktree-path> <追加glob>...
#
# task-boundary hook は境界ファイルへの Edit/Write を無条件 deny する
# （自己解錠の防止）ため、正当な拡張はこのスクリプトが正規経路になる。
# Bash 実行は hook の matcher 対象外なので hook 改修なしで通る。
# ワーカーは自分で叩かない（ワーカー規約で禁止。拡張の判断は親が
# 計画と突き合わせて行い、計画の範囲外ならユーザーへ上げる）。
set -eu

usage() {
    echo "usage: widen_boundary.sh <worktree-path> <追加glob>..." >&2
    exit 2
}

[ $# -ge 2 ] || usage
worktree="$1"
shift

bfile="$worktree/.claude/task-boundary.json"
[ -f "$bfile" ] || {
    echo "ERROR: 境界ファイルが無い: $bfile" >&2
    exit 1
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
jq --args '.allow = ((.allow // []) + $ARGS.positional | unique)' "$bfile" "$@" > "$tmp"
mv "$tmp" "$bfile"
trap - EXIT

echo "widened: $bfile"
jq . "$bfile"
