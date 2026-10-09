#!/usr/bin/env bash
# Verifies permission-gate の dispatcher(main.sh):
#   - 全入力がログ(${XDG_STATE_HOME}/claude/permission-prompts.jsonl)に 1 行追記される
#     項目は ts(JST)・session_id・cwd・tool_name・command(先頭 300 字)・decision・rule・reason
#   - rule が allow を返せば stdout に decision.behavior: allow、decision=allow・rule=規則名
#   - Bash 以外の tool_name -> 記録のみ(stdout なし、decision=prompt)
#   - rules/*.sh は名前順に呼ばれ、最初の allow を採用する
#   - notify.sh が実行可能なら決定後に呼ばれ、その stdout は hook 出力に混ざらない
#   - 不正な入力でも exit 0・stdout なし
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GATE_DIR="$SCRIPT_DIR/.."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export XDG_STATE_HOME="$TMP/state"
LOG="$XDG_STATE_HOME/claude/permission-prompts.jsonl"

REPO="$TMP/repo"
git init -q -b feat/x "$REPO"
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
run() { # gate_dir tool_name tool_input_json -> stdout(exit≠0 なら rc=N)
    local out rc=0
    out=$(jq -cn --arg d "$REPO" --arg t "$2" --argjson i "$3" \
        '{session_id: "s1", cwd: $d, tool_name: $t, tool_input: $i}' \
        | "$1/main.sh") || rc=$?
    [ "$rc" -eq 0 ] && printf '%s' "$out" || echo "rc=$rc"
}
bash_input() { jq -cn --arg c "$1" '{command: $c}'; }
lines() { [ -f "$LOG" ] && wc -l <"$LOG" | tr -d ' ' || echo 0; }
last() { tail -n 1 "$LOG" | jq -r "$1"; }

# Bash 以外 -> 記録のみ
OUT=$(run "$GATE_DIR" Write '{"file_path": "/etc/hosts", "content": "x"}')
check "non-bash-silent" "" "$OUT"
check "non-bash-logged" "1" "$(lines)"
check "non-bash-decision" "prompt" "$(last .decision)"
check "non-bash-tool" "Write" "$(last .tool_name)"
check "fields" "ts,session_id,cwd,tool_name,command,decision,rule,reason" \
    "$(last 'keys_unsorted | join(",")')"
check "session-cwd" "s1 $REPO" "$(last '"\(.session_id) \(.cwd)"')"
check "ts-jst" "ok" "$(last '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\+09:?00$") | if . then "ok" else "ng" end')"

# 規則に当たらない Bash -> 沈黙 + prompt 記録、command は先頭 300 字
LONG="echo $(printf 'a%.0s' $(seq 1 400))"
check "unmatched-silent" "" "$(run "$GATE_DIR" Bash "$(bash_input "$LONG")")"
check "unmatched-logged" "2" "$(lines)"
check "unmatched-decision" "prompt" "$(last .decision)"
check "command-truncated" "300" "$(last '.command | length')"

# 規則が allow -> stdout に allow、decision=allow・rule=規則名
echo "$(date +%s) 1800 feat/x" >|"$REPO/.git/push-flow.armed"
OUT=$(run "$GATE_DIR" Bash "$(bash_input 'git push')")
check "allow-output" "PermissionRequest allow" \
    "$(printf '%s' "$OUT" | jq -r '"\(.hookSpecificOutput.hookEventName) \(.hookSpecificOutput.decision.behavior)"')"
check "allow-logged" "3" "$(lines)"
check "allow-decision" "allow 10-push-armed" "$(last '"\(.decision) \(.rule)"')"
check "allow-reason" "yes" "$(last 'if (.reason | length) > 0 then "yes" else "no" end')"

# 不正な入力 -> exit 0・stdout なし
OUT=$(printf 'not json' | "$GATE_DIR/main.sh" && echo "rc=0") || OUT="rc=$?"
check "invalid-input" "rc=0" "$OUT"

# 名前順・最初の allow を採用、notify.sh の呼び出し(スタブ構成のコピー上で検証)
STUB="$TMP/stub"
mkdir -p "$STUB/rules"
cp "$GATE_DIR/main.sh" "$STUB/main.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' >"$STUB/rules/05-none.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "from b"\n' >"$STUB/rules/20-b.sh"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "from a"\n' >"$STUB/rules/10-a.sh"
OUT=$(run "$STUB" Bash "$(bash_input 'ls')")
check "order-output" "allow" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.behavior')"
check "order-first-allow" "10-a from a" "$(last '"\(.rule) \(.reason)"')"

cat >"$STUB/notify.sh" <<EOF
#!$BASH
cat >"$TMP/notified.json"
echo "noise from notify"
EOF
chmod +x "$STUB/notify.sh"
OUT=$(run "$STUB" Bash "$(bash_input 'ls')")
check "notify-stdout-clean" "allow" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.behavior')"
check "notify-received" "ls allow" "$(jq -r '"\(.tool_input.command) \(.decision)"' "$TMP/notified.json")"

rm -f "$STUB"/rules/*.sh
OUT=$(run "$STUB" Read '{"file_path": "/etc/hosts"}')
check "notify-prompt" "Read prompt" "$(jq -r '"\(.tool_name) \(.decision)"' "$TMP/notified.json")"
check "notify-prompt-silent" "" "$OUT"

# notify.sh の失敗・ログに書けない状況でも exit 0 で allow を保つ
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "from a"\n' >|"$STUB/rules/10-a.sh"
printf '#!%s\ncat >/dev/null\nexit 1\n' "$BASH" >|"$STUB/notify.sh"
check "notify-fail" "allow" "$(run "$STUB" Bash "$(bash_input 'ls')" | jq -r '.hookSpecificOutput.decision.behavior')"
: >"$TMP/not-a-dir"
OUT=$(XDG_STATE_HOME="$TMP/not-a-dir" run "$STUB" Bash "$(bash_input 'ls')")
check "log-unwritable" "allow" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.decision.behavior')"

exit "$fail"
