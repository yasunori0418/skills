#!/usr/bin/env bash
# webfetch-github-guard/main.sh — PreToolUse hook（matcher: WebFetch）。
# github.com への WebFetch を差し戻し、gh コマンド経由の取得へ誘導する。
# WebFetch では GitHub の PR・Issue・Actions ログ等は取れない（HTML しか返らない）
# ため、URL を渡された時点で gh に解決させる。
set -euo pipefail

input=$(cat)
url=$(printf '%s' "$input" | jq -r '.tool_input.url // empty')

case "$url" in
    "https://github.com"*) ;;
    *) exit 0 ;;
esac

jq -cn '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: "WebFetchではなく、`gh`コマンド経由で情報を取得"
  }
}'
