#!/usr/bin/env bash
# Verifies teammate-leak-guard (Stop hook: background_tasks の残留を decision:block で通知):
#   - subagent / teammate が残っていれば体数と一覧を decision:block の reason で返す
#   - shell / monitor など停止対象外の type だけなら沈黙
#   - background_tasks が空・欠落・壊れた JSON なら沈黙（fail-open）
#   - stop_hook_active=true なら 2 回目以降は沈黙（8 連続上限の空転防止）
#   - description 欠落時は agent_type → id の順にフォールバック
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/../main.sh"

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}

# reason を取り出す（沈黙時は空文字）
context() { # json
    printf '%s' "$1" | "$GUARD" | jq -r 'select(.decision == "block") | .reason // empty'
}
# reason の 1 行目（体数のサマリ行）だけを取り出す
summary() { # json
    context "$1" | head -1
}

TWO_SUBAGENTS='{"background_tasks":[
  {"id":"a1","type":"subagent","status":"running","description":"design レンズでレビュー","agent_type":"diff-reviewer"},
  {"id":"a2","type":"subagent","status":"running","description":"spec レンズでレビュー","agent_type":"diff-reviewer"}
]}'
check "two-subagents" "稼働中のサブエージェント/チームメイトが 2 体残っています:" "$(summary "$TWO_SUBAGENTS")"
check "two-subagents-list" "  - design レンズでレビュー (subagent)" "$(context "$TWO_SUBAGENTS" | sed -n '2p')"

TEAMMATE='{"background_tasks":[
  {"id":"t1","type":"teammate","status":"idle","description":"nav2-e1-skill"}
]}'
check "teammate" "稼働中のサブエージェント/チームメイトが 1 体残っています:" "$(summary "$TEAMMATE")"
check "teammate-list" "  - nav2-e1-skill (teammate)" "$(context "$TEAMMATE" | sed -n '2p')"

# 停止対象外の type は数えない
check "shell-only" "" "$(context '{"background_tasks":[{"id":"s1","type":"shell","status":"running","command":"tail -f log"}]}')"
check "monitor-only" "" "$(context '{"background_tasks":[{"id":"m1","type":"monitor","status":"running","server":"datadog"}]}')"
# 混在時は subagent/teammate だけを数える
MIXED='{"background_tasks":[
  {"id":"s1","type":"shell","status":"running","command":"tail -f log"},
  {"id":"a1","type":"subagent","status":"running","description":"レビュー"}
]}'
check "mixed" "稼働中のサブエージェント/チームメイトが 1 体残っています:" "$(summary "$MIXED")"

# fail-open: 空・欠落・壊れた JSON
check "empty-array" "" "$(context '{"background_tasks":[]}')"
check "missing-field" "" "$(context '{}')"
check "broken-json" "" "$(printf 'not json' | "$GUARD" | jq -r 'select(.decision == "block") | .reason // empty' 2>/dev/null || true)"

# stop_hook_active=true なら沈黙（同じ指摘の繰り返しで空転させない）
ACTIVE='{"stop_hook_active":true,"background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"レビュー"}]}'
check "stop-hook-active" "" "$(context "$ACTIVE")"
# false は通常どおり通知する
NOT_ACTIVE='{"stop_hook_active":false,"background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"レビュー"}]}'
check "stop-hook-inactive" "稼働中のサブエージェント/チームメイトが 1 体残っています:" "$(summary "$NOT_ACTIVE")"

# 説明のフォールバック: description 無し -> agent_type -> id
check "fallback-agent-type" "  - test-reviewer (subagent)" \
    "$(context '{"background_tasks":[{"id":"a1","type":"subagent","agent_type":"test-reviewer"}]}' | sed -n '2p')"
check "fallback-id" "  - a1 (subagent)" \
    "$(context '{"background_tasks":[{"id":"a1","type":"subagent"}]}' | sed -n '2p')"

# 出力形式のリグレッション: hookSpecificOutput は cchook 経由（Stop イベント）で
# "not supported" として握り潰され Claude まで届かないため、使ってはいけない。
# decision/reason だけを出すことを固定する。
SHAPE=$(printf '%s' "$TEAMMATE" | "$GUARD" | jq -r '[(.decision // "-"), (if has("hookSpecificOutput") then "has-hso" else "no-hso" end)] | join(",")')
check "output-shape" "block,no-hso" "$SHAPE"

exit "$fail"
