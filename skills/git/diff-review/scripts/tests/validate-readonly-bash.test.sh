#!/usr/bin/env bash
# Verifies validate-readonly-bash.sh (diff-reviewer の PreToolUse hook) と、その配線:
#   - スクリプト本体: 書き込み系(rm / cp / go test / ファイルへのリダイレクト) -> exit 2
#                     参照系(git diff / rg / stderr の /dev/null 捨て)        -> exit 0
#   - diff-reviewer.md の frontmatter にある hook の command 文字列を抽出して実行:
#       (a) CLAUDE_PLUGIN_ROOT 未設定 + $HOME/.claude/skills に配置(nput 配置) -> 解決でき rm が exit 2
#       (b) CLAUDE_PLUGIN_ROOT 未設定 + $HOME が空(スクリプト不在)             -> exit 2 + not found
#       (c) CLAUDE_PLUGIN_ROOT=<repo>/skills/git(plugin 配置)                  -> 解決でき git diff が exit 0
#     不在時に exit 127(非ブロック扱い)で素通しになる退行を固定する。
# command の抽出は YAML として読む(uv も python3 も無い環境では配線テストだけ SKIP)。
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
HOOK="$SCRIPT_DIR/../validate-readonly-bash.sh"
RUN_PY="$SCRIPT_DIR/../run-python.sh" # uv → python3 の順に実行経路を選ぶ
AGENT_MD="$SCRIPT_DIR/../../agents/diff-reviewer.md"
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd) # category root(skills/git)

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
has() { # label haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "PASS: $(basename "$0")[$1] contains '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] missing '$3'"
        fail=1
    fi
}
payload() { # command -> hook 入力 JSON を $WORK/in.json に書く
    printf '{"tool_input": {"command": %s}}' "$(printf '%s' "$1" | jq -Rs .)" >| "$WORK/in.json"
}
hook_exit() { # command -> スクリプト本体の exit code
    payload "$1"
    "$HOOK" < "$WORK/in.json" > /dev/null 2>&1
    echo $?
}

# --- スクリプト本体 ---
check "rm-blocked" "2" "$(hook_exit 'rm -rf x')"
check "cp-blocked" "2" "$(hook_exit 'cp a b')"
check "go-test-blocked" "2" "$(hook_exit 'go test ./...')"
check "redirect-blocked" "2" "$(hook_exit 'git diff > out.txt')"
check "chained-write-blocked" "2" "$(hook_exit 'git status && touch x')"
check "git-push-blocked" "2" "$(hook_exit 'git push origin main')"
check "git-diff-allowed" "0" "$(hook_exit 'git diff main...HEAD')"
check "rg-allowed" "0" "$(hook_exit 'rg -n foo src | head -5')"
check "stderr-devnull-allowed" "0" "$(hook_exit 'git log -1 2>/dev/null')"

payload 'rm x'
ERR=$("$HOOK" < "$WORK/in.json" 2>&1 > /dev/null)
has "blocked-reason" "$ERR" "Blocked"

# --- frontmatter の command(配線) ---
if ! command -v uv > /dev/null 2>&1 && ! command -v python3 > /dev/null 2>&1; then
    echo "SKIP: $(basename "$0")[wiring] uv も python3 も無い環境のためスキップ"
    [ "$fail" -eq 0 ]
    exit
fi

CMD=$("$RUN_PY" -c '
import sys, frontmatter
hooks = frontmatter.load(sys.argv[1])["hooks"]["PreToolUse"]
print(next(h["command"] for m in hooks if m["matcher"] == "Bash" for h in m["hooks"]))
' "$AGENT_MD")
has "command-extracted" "$CMD" "validate-readonly-bash.sh"

# プレースホルダ置換に依存しない書き方であること(plugin 無効の配置では置換されず未設定のまま走る)
case "$CMD" in
    *'${CLAUDE_PLUGIN_ROOT}'*) check "no-placeholder-literal" "absent" "present" ;;
    *) check "no-placeholder-literal" "absent" "absent" ;;
esac

wired() { # label expected-exit command [env 代入...] -> exit code を検査し stderr を WIRED_ERR に残す
    local label="$1" expected="$2" cmd="$3"
    shift 3
    payload "$cmd"
    WIRED_ERR=$(env -u CLAUDE_PLUGIN_ROOT "$@" sh -c "$CMD" < "$WORK/in.json" 2>&1 > /dev/null)
    check "$label" "$expected" "$?"
}

# (a) nput 配置: $HOME/.claude/skills/diff-review/scripts/ にスクリプトがある
HOME_OK="$WORK/home-ok"
mkdir -p "$HOME_OK/.claude/skills/diff-review/scripts"
cp "$HOOK" "$HOME_OK/.claude/skills/diff-review/scripts/"
wired "home-resolves-rm" "2" 'rm x' HOME="$HOME_OK"
has "home-resolves-reason" "$WIRED_ERR" "Blocked"
wired "home-resolves-git-diff" "0" 'git diff' HOME="$HOME_OK"

# (b) スクリプト不在: 127 で素通しにせず exit 2 で倒れる
HOME_EMPTY="$WORK/home-empty"
mkdir -p "$HOME_EMPTY"
wired "missing-blocks" "2" 'git diff' HOME="$HOME_EMPTY"
has "missing-reason" "$WIRED_ERR" "not found"

# (c) plugin 配置: CLAUDE_PLUGIN_ROOT(category root)が優先して解決される
wired "plugin-root-git-diff" "0" 'git diff' HOME="$HOME_EMPTY" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
wired "plugin-root-rm" "2" 'rm x' HOME="$HOME_EMPTY" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

[ "$fail" -eq 0 ]
