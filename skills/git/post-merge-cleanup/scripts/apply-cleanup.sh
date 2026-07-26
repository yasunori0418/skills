#!/usr/bin/env bash
#
# apply-cleanup.sh — 承認済みの後片付け対象を stdin(JSON) で受け取り実行する。
#
# Usage:
#   jq '...承認された対象だけに絞る...' state.json | apply-cleanup.sh
#   apply-cleanup.sh --print-only < approved.json    # コマンド生成のみ（テスト用）
#
# 入力: collect-merge-state.sh の出力から候補を絞ったもの。
#   { "candidates": [ { "branch", "worktree_path", "tmux_session", "deletable", ... } ] }
#
# 対象を引数（ブランチ名）ではなく JSON で受け取るのは、承認した計画と実行対象の
# ズレを防ぐため。AI が名前を組み直す余地を残すと、承認していない対象が紛れ込む。
#
# 破壊操作は 2 種類だけで、いずれも force 系フラグを使わない:
#   wt remove <branch>       … worktree 削除 + マージ済みならブランチ削除
#                              （-D / --force は使わない。拒否されたら報告して次へ）
#   tmux kill-session -t <s> … 承認済みセッションのみ
# `git branch -D` / `wt remove -f` / `rm -rf` は本スクリプトに存在しない。
set -euo pipefail

print_only=false
[ "${1:-}" = "--print-only" ] && print_only=true

missing=0
for cmd in jq git; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'error: `%s` が見つかりません（PATH に必要）\n' "$cmd" >&2
        missing=1
    }
done
[ "$missing" -eq 0 ] || exit 1

input=$(cat)
if ! jq -e . >/dev/null 2>&1 <<<"$input"; then
    echo "ERROR: stdin が JSON として読めません" >&2
    exit 1
fi

# deletable=false が混ざっていたら実行せず落とす。承認済み JSON を絞る段で
# 取りこぼしたことを意味し、そのまま流すと保護対象を消しかねない。
# 「対象ゼロ」判定より先に見る — 全件が保護対象のときに NOTHING TO DO で
# 正常終了すると、絞り込みミスが成功として素通りしてしまうため。
blocked=$(jq -c '[(.candidates // [])[] | select(.deletable != true) | .branch]' <<<"$input")
if [ "$(jq 'length' <<<"$blocked")" -gt 0 ]; then
    echo "ERROR: deletable=false の対象が入力に含まれています: $(jq -r 'join(", ")' <<<"$blocked")" >&2
    echo "       collect の判定で保護された対象です。絞り込みを見直してください。" >&2
    exit 1
fi

targets=$(jq -c '[(.candidates // [])[] | select(.deletable == true)]' <<<"$input")
n=$(jq 'length' <<<"$targets")

if [ "$n" -eq 0 ]; then
    echo "=== NOTHING TO DO ==="
    echo "後片付けの対象がありません（承認済み対象が空）"
    exit 0
fi

failures=0

run() { # ラベル コマンド...
    local label="$1"
    shift
    if [ "$print_only" = true ]; then
        printf '%s\t%s\n' "$label" "$*"
        return 0
    fi
    echo "--- $label: $* ---"
    if "$@"; then
        echo "OK: $label"
    else
        # wt remove は dirty 拒否などで exit 1 を返す。ここで止めず記録して次へ進むのは、
        # 1 つの失敗で残りの承認済み対象が中途半端に残るのを避けるため。最終判断は
        # verify-cleanup.sh の突合に委ねる。
        echo "FAILED: $label（後続の対象は継続。verify で最終確認すること）"
        failures=$((failures + 1))
    fi
}

# tmux セッションを先に落とす。worktree を先に消すと、セッション内のシェルが
# 消えたディレクトリに居座り、kill 時の後始末が読みにくくなる。
while IFS=$'\t' read -r branch sess; do
    [ -n "$sess" ] && [ "$sess" != "null" ] || continue
    run "tmux kill-session ($branch)" tmux kill-session -t "$sess"
done < <(jq -r '.[] | [.branch, (.tmux_session // "")] | @tsv' <<<"$targets")

# worktree + ブランチ削除は wt remove に委譲する。
# wt remove は tree 一致でマージ済みを判定するため、rebase-merge で sha が
# 変わっていても正しくブランチまで消える（実測確認済み）。
while IFS=$'\t' read -r branch wpath; do
    [ -n "$branch" ] || continue
    if [ -n "$wpath" ] && [ "$wpath" != "null" ]; then
        run "wt remove ($branch)" wt remove "$branch" -y --foreground
    else
        # worktree が無くローカルブランチだけ残っているケース。
        # -d は未マージなら失敗する（安全側）。失敗＝判定漏れとして報告に残す。
        run "git branch -d ($branch)" git branch -d "$branch"
    fi
done < <(jq -r '.[] | [.branch, (.worktree_path // "")] | @tsv' <<<"$targets")

if [ "$print_only" = true ]; then
    exit 0
fi

echo "=== APPLY SUMMARY ==="
echo "対象: $n 件 / 失敗: $failures 件"
if [ "$failures" -gt 0 ]; then
    echo "判定: 失敗あり — verify-cleanup.sh で残存を確認し、原因を報告すること"
    exit 1
fi
echo "判定: 全て実行済み — verify-cleanup.sh で計画との一致を確認すること"
