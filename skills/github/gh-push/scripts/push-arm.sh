#!/usr/bin/env bash
#
# push-arm.sh — 承認済みの push を permission-gate hook に通させる marker を置く。
# push 本体は実行しない。
#
# marker は `git rev-parse --git-path push-flow.armed`（worktree ごとに別）に
# 1 行 `<epoch> <ttl秒> <branch>` で書く。期限切れ marker の削除は permission-gate が行う。
#
# Usage: push-arm.sh <branch> [--ttl <秒>]   （TTL 既定 1800）
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

branch=""
ttl=1800
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ttl)
            [ "$#" -ge 2 ] || die "--ttl に秒数を指定してください"
            ttl="$2"
            shift 2
            ;;
        -*) die "不明なオプション: $1" ;;
        *)
            [ -z "$branch" ] || die "branch は 1 つだけ指定してください"
            branch="$1"
            shift
            ;;
    esac
done

[ -n "$branch" ] || die "push 先ブランチ名を指定してください（Usage: push-arm.sh <branch> [--ttl <秒>]）"
case "$ttl" in '' | *[!0-9]* | 0*) die "--ttl は正の整数（秒）で指定してください: $ttl" ;; esac
git rev-parse --git-dir >/dev/null 2>&1 || die "git リポジトリ内で実行してください"

marker=$(git rev-parse --git-path push-flow.armed)
now=$(date +%s)
printf '%s %s %s\n' "$now" "$ttl" "$branch" >|"$marker"

echo "armed: $marker"
echo "expires: $((now + ttl))（${ttl} 秒後）"
