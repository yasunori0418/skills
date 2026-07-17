#!/usr/bin/env bash
# askuserquestion-notify/main.sh — PreToolUse hook for AskUserQuestion.
#
# AskUserQuestion が呼ばれた瞬間（＝ユーザーへ選択式の質問を投げ、回答待ちに入る
# 直前）にデスクトップ通知を出す。remote-control 経由などで選択 UI に気づかず
# 回答が遅れるのを防ぐのが目的。
#
# 検知は「PreToolUse で tool_name=AskUserQuestion」で確実に行える（Notification
# イベントの permission_prompt は通常のツール許可待ちと区別できないため使わない）。
#
# askuserquestion-guard と同じ /tmp/claude-no-askuserquestion.<session_id> マーカーを
# 見て、マーカーが有る（＝そのセッションでは AskUserQuestion が deny され、テキスト
# 質問に倒れる）ときは選択 UI で止まらないので通知しない。
#
# Claude Code の PreToolUse hook として stdin で JSON を受け取る。permissionDecision
# は何も出さない（通知は副作用のみで、ツール実行の可否には関与しない）。
set -euo pipefail

input=$(cat)

sid=$(printf '%s' "$input" | jq -r '.session_id // empty')

# マーカー置き場。既定は askuserquestion-guard / askuserquestion-toggle と同じ /tmp。
# テスト時のみ CLAUDE_AQ_MARKER_DIR で差し替える（本番では未設定 → /tmp 固定）。
marker_dir="${CLAUDE_AQ_MARKER_DIR:-/tmp}"

# deny されるセッション（#aq-off）では選択 UI で止まらないので通知不要
if [ -n "$sid" ] && [ -e "${marker_dir}/claude-no-askuserquestion.${sid}" ]; then
    exit 0
fi

# 質問文（先頭の質問）と header、質問数を取り出す
QUESTION=$(printf '%s' "$input" | jq -r '.tool_input.questions[0].question // empty')
HEADER=$(printf '%s' "$input" | jq -r '.tool_input.questions[0].header // empty')
COUNT=$(printf '%s' "$input" | jq -r '(.tool_input.questions | length) // 0')

# 質問が取れないときはフォールバック文言
[ -n "$QUESTION" ] || QUESTION="Claude が入力を待っています"

# 本文は先頭 80 文字に切り詰め（マルチバイト対応。超過時は末尾に … を付ける）
LIMIT=80
if [ "$(printf '%s' "$QUESTION" | wc -m | tr -d ' ')" -gt "$LIMIT" ]; then
    QUESTION=$(printf '%s' "$QUESTION" | cut -c1-"$LIMIT")…
fi

# 質問が複数あれば件数を付記
if [ "${COUNT:-0}" -gt 1 ]; then
    BODY="${QUESTION}（ほか $((COUNT - 1)) 件）"
else
    BODY="$QUESTION"
fi

TITLE="Claude が質問中"

case "$(uname)" in
    Darwin)
        # 引数渡しでエスケープを回避（item 1 = 本文, item 2 = subtitle=header）。
        # subtitle は空文字でも AppleScript 上問題なく通る。
        osascript \
            -e 'on run argv' \
            -e 'display notification (item 1 of argv) with title "'"$TITLE"'" subtitle (item 2 of argv) sound name "Glass"' \
            -e 'end run' \
            "$BODY" "$HEADER"
        ;;
    Linux)
        # 通知デーモンが無い環境（CI 等）では黙ってスキップする
        if command -v dunstify >/dev/null 2>&1; then
            dunstify "$TITLE" "$BODY"
        elif command -v notify-send >/dev/null 2>&1; then
            notify-send "$TITLE" "$BODY"
        fi
        ;;
esac
