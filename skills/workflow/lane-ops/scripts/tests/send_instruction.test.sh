#!/usr/bin/env bash
# Verifies send_instruction.sh:
#   - idle のワーカーへは送信する
#   - blocked のワーカーへは中断する（exit 3・prompt を呼ばない）
#   - blocked でも --force なら送信する
#   - 指示ファイルが無い・空 -> exit 1
#   - 引数不足 -> exit 2
#
# blocked ガードの背景: ダイアログ（AskUserQuestion 等）表示中の pane へ
# 本文つきで送信すると、本文は入力されず末尾の Enter がハイライト中の
# 選択肢（先頭の推奨案）を確定してしまう（herdr 0.8.0 で実証）。
# herdr 本体は blocked でも agent_prompted を返して成功を装うため、
# スクリプト側で送信前に agent_status を確認する。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SEND="$SCRIPT_DIR/../send_instruction.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}

# herdr スタブ: agent get は $WORK/status の状態を返し、agent prompt は
# 呼び出し記録を $WORK/prompt.log へ残す。
mkdir -p "$WORK/bin"
cat > "$WORK/bin/herdr" << 'STUB'
#!/usr/bin/env bash
case "$1 $2" in
"agent get")
    printf '{"id":"cli:agent:get","result":{"agent":{"agent_status":"%s"},"type":"agent_info"}}\n' \
        "$(cat "$STUB_DIR/status")"
    ;;
"agent prompt")
    printf '%s\n' "$4" >> "$STUB_DIR/prompt.log"
    echo '{"id":"cli:agent:prompt","result":{"type":"agent_prompted"}}'
    ;;
*)
    echo "unexpected: $*" >&2
    exit 9
    ;;
esac
STUB
chmod +x "$WORK/bin/herdr"
export STUB_DIR="$WORK"
export PATH="$WORK/bin:$PATH"

printf '裁定: 案Bで進めてください。\n理由は…\n' > "$WORK/instr.txt"

# idle -> 送信する
echo idle > "$WORK/status"
: > "$WORK/prompt.log"
rc=0
bash "$SEND" worker1 "$WORK/instr.txt" > /dev/null || rc=$?
check "idle-sends" "0" "$rc"
check "idle-body-delivered" "裁定: 案Bで進めてください。" "$(head -1 "$WORK/prompt.log")"

# blocked -> 中断（exit 3・prompt 未呼び出し）
echo blocked > "$WORK/status"
: > "$WORK/prompt.log"
rc=0
bash "$SEND" worker1 "$WORK/instr.txt" > /dev/null 2>&1 || rc=$?
check "blocked-aborts" "3" "$rc"
check "blocked-no-prompt" "0" "$(wc -l < "$WORK/prompt.log" | tr -d ' ')"

# blocked + --force -> 送信する
rc=0
bash "$SEND" --force worker1 "$WORK/instr.txt" > /dev/null || rc=$?
check "force-sends" "0" "$rc"
check "force-body-delivered" "1" "$(grep -c '案B' "$WORK/prompt.log")"

# 指示ファイルが空 -> exit 1
echo idle > "$WORK/status"
: > "$WORK/empty.txt"
rc=0
bash "$SEND" worker1 "$WORK/empty.txt" > /dev/null 2>&1 || rc=$?
check "empty-file" "1" "$rc"

# 引数不足 -> exit 2
rc=0
bash "$SEND" worker1 > /dev/null 2>&1 || rc=$?
check "missing-args" "2" "$rc"

exit "$fail"
