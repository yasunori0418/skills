#!/usr/bin/env bash
# sudo-guard/main.sh — PreToolUse hook（matcher: Bash）。
# sudo の実行を deny する（settings.json の deny `Bash(sudo:*)` の多層防御側）。
#
# 旧 cchook 構成は command_contains "sudo" の部分一致で、パスやファイル名に
# "sudo" を含むだけの無害なコマンド（例: hooks/sudo-guard/ への操作）も
# 誤ブロックしていた。本スクリプトは「コマンド語として現れる sudo」のみ照合する:
# 行頭またはコマンド区切り（; & | ` ( や空白）の直後に sudo が単語として現れる場合のみ。
set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

if ! printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|`(])sudo([[:space:]]|$)'; then
    exit 0
fi

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "🚫 sudo は禁止（settings.json deny `Bash(sudo:*)`）。必要な場合はユーザーに確認を取ること。"
  }
}'
