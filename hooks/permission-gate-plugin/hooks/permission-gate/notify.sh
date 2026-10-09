#!/usr/bin/env bash
# permission-gate/notify.sh — dispatcher(main.sh)が決定後に呼ぶ通知。
# ダイアログで止まったレーンが親に気付かれず放置されるのを防ぐため、ダイアログ発生を知らせる。
#
# 入力: stdin に hook JSON + decision(allow / prompt)。allow ならダイアログは出ないので何もしない。
# 本文: "<tool_name>: <command 先頭 120 字>"
# レーン: LANE_OPS_PARENT・LANE_OPS_TASK・LANE_OPS_REPORT_SH が全て設定されていれば
#   $LANE_OPS_REPORT_SH <parent> <task> ダイアログ待ち <本文> で親へ報告する(デスクトップ通知はしない)。
# 通常セッション: dunstify / notify-send / osascript のうち最初に見つかったもので通知する(無ければ沈黙)。
# どの失敗でもダイアログを壊さないよう、常に exit 0。
set -uo pipefail

input=$(cat)
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
decision=$(printf '%s' "$input" | jq -r '.decision // ""' 2>/dev/null) || exit 0
[ "$decision" = allow ] && exit 0
detail=$(printf '%s' "$input" |
    jq -r '"\(.tool_name // ""): \((.tool_input.command // "") | tostring | .[:120])"' 2>/dev/null) || exit 0

if [ -n "${LANE_OPS_PARENT:-}" ] && [ -n "${LANE_OPS_TASK:-}" ] && [ -n "${LANE_OPS_REPORT_SH:-}" ]; then
    "$LANE_OPS_REPORT_SH" "$LANE_OPS_PARENT" "$LANE_OPS_TASK" ダイアログ待ち "$detail" </dev/null || true
elif command -v dunstify >/dev/null 2>&1; then
    dunstify claude-code "$detail" || true
elif command -v notify-send >/dev/null 2>&1; then
    notify-send claude-code "$detail" || true
elif command -v osascript >/dev/null 2>&1; then
    osascript \
        -e 'on run argv' \
        -e 'display notification (item 1 of argv) with title "claude-code"' \
        -e 'end run' \
        "$detail" || true
fi
exit 0
