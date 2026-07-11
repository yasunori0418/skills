#!/usr/bin/env bash
# askuserquestion-guard/main.sh — PreToolUse hook for AskUserQuestion.
#
# AskUserQuestion をセッション単位で無効化する。remote-control 経由のスマホ/web
# セッションでは、質問文・選択肢の文脈が選択 UI の前に表示されない挙動があるため、
# そのセッションだけテキスト質問へ倒したい。判定マーカーは
#   /tmp/claude-no-askuserquestion.<session_id>
# でセッションごとに独立。作成/削除は askuserquestion-toggle（UserPromptSubmit で
# プロンプトに #aq-off / #aq-on）が行う。/tmp なので再起動で消え既定（有効）へ復帰。
#
# Claude Code の PreToolUse hook として stdin で JSON を受け取り、stdout の JSON が
# そのまま応答になる:
#   マーカー無し → 何も出さず exit 0 → 意見なし（通常どおり進む）
#   マーカー有り → permissionDecision: deny（テキスト質問へ倒す指示を Claude が読む）
set -euo pipefail

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')

# session_id 不明、またはこのセッションのマーカー不在なら意見なし（沈黙 → 通常進行）
[ -n "$sid" ] || exit 0
marker="/tmp/claude-no-askuserquestion.${sid}"
[ -e "$marker" ] || exit 0

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "このセッションでは AskUserQuestion は無効化されている（#aq-on で再有効化）。選択肢はメッセージ本文に番号付きで列挙し、ユーザーには番号または自由記述での回答を求めること。"
  }
}'
