#!/usr/bin/env bash
# notify-stop/main.sh — Stop hook: transcript から ai-title を抽出して
# デスクトップ通知を送る（macOS: osascript / Linux: dunstify or notify-send）。
# Claude Code の Stop hook として stdin で JSON を受け取り、transcript_path を解決する。
set -euo pipefail

input=$(cat)
TRANSCRIPT=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

extract_title() {
    [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || return 0
    jq -rs '[.[] | select(.type=="ai-title") | .aiTitle] | last // ""' "$TRANSCRIPT" 2>/dev/null
}

SUMMARY="$(extract_title)"
[ -z "$SUMMARY" ] && SUMMARY="Claude Code 完了"

case "$(uname)" in
    Darwin)
        osascript \
            -e 'on run argv' \
            -e 'display notification (item 1 of argv) with title "claude-code"' \
            -e 'end run' \
            "$SUMMARY"
        ;;
    Linux)
        # 通知デーモンが無い環境（CI 等）では黙ってスキップする
        if command -v dunstify >/dev/null 2>&1; then
            dunstify "claude-code" "$SUMMARY"
        elif command -v notify-send >/dev/null 2>&1; then
            notify-send "claude-code" "$SUMMARY"
        fi
        ;;
esac
