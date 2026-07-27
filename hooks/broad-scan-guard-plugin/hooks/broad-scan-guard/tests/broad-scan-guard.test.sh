#!/usr/bin/env bash
# Verifies broad-scan-guard:
#   - find / fd のルート（/）起点 -> deny（-maxdepth の有無を問わない）
#   - $HOME ちょうど起点で深さ制限なし -> deny
#   - $HOME ちょうど起点でも -maxdepth 付き -> 沈黙
#   - $HOME 配下のサブディレクトリ起点 -> 沈黙（実測でいずれも高速に完了）
#   - rg / grep -r / ls -R -> 対象外（素朴な照合では誤検出が 19 件出たため）
#   - クォート内の文字列としての "find /" -> 沈黙（暴走 find を止める復旧手段を奪わない）
#
# deny ケースの多くはセッション履歴から採取した実例（コメントに実測時間を記す）。
# $HOME はテスト用のダミー値を注入する（実装は実行時 $HOME を正とするため、
# 公開リポジトリに実ユーザー名を残さずに実運用パスを検証できる）。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/../main.sh"

DUMMY_HOME=/Users/dummy-user

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
decision() { # command
    printf '{"tool_input": {"command": %s}}' "$(printf '%s' "$1" | jq -Rs .)" \
        | HOME="$DUMMY_HOME" "$GUARD" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

# --- deny: ルート起点（すべて実測で観測された実例） ------------------------
check "root-investigate" "deny" \
    "$(decision 'find / -name "investigate.md" 2>/dev/null | head -20')" # 180.4s
check "root-poi-jar" "deny" \
    "$(decision 'find / -iname "poi-ooxml-*.jar" 2>/dev/null | head -5')" # 122.9s
check "root-compound" "deny" \
    "$(decision 'cat ~/.claude/settings.json | head; find / -name "managed-settings.json"')" # 121.2s
check "root-multi-start" "deny" \
    "$(decision "find ~/.gradle $DUMMY_HOME -name 'FileReadWrite.kt'")" # 120.7s・$HOME ちょうどを含む
check "root-fd" "deny" \
    "$(decision "fd -L -t d 'perf-pipeline' /")"
check "root-with-maxdepth" "deny" \
    "$(decision 'find / -maxdepth 3 -name foo')" # ルート起点は maxdepth があっても deny

# --- deny: $HOME ちょうど起点で深さ制限なし --------------------------------
check "home-abs-no-maxdepth" "deny" \
    "$(decision "find $DUMMY_HOME -iname \"investigate.md\"")"
check "home-tilde" "deny" \
    "$(decision 'find ~ -name "*.md"')"
check "home-var" "deny" \
    "$(decision 'find $HOME -name "*.md"')"

# --- 沈黙: 誤爆したら困るもの ----------------------------------------------
check "quoted-pkill" "" \
    "$(decision 'pkill -f "find / -iname SKILL.md"')" # 復旧手段を奪わない
check "home-with-maxdepth" "" \
    "$(decision "find $DUMMY_HOME -maxdepth 6 -name \"investigate.md\"")"
check "home-subdir-claude" "" \
    "$(decision "find $DUMMY_HOME/.claude -iname \"investigate*.md\"")"
check "home-subdir-perf" "" \
    "$(decision "find $DUMMY_HOME/perf-analysis -name \"*.md\"")"
check "nix-store-scoped" "" \
    "$(decision "find /nix/store -maxdepth 1 -name '*nput*' -type d")" # スコープ外
check "relative-path" "" \
    "$(decision 'find . -name "*.kt"')"
check "rg-project" "" \
    "$(decision "rg -n 'LoglassCsvFileBuilder' --type kotlin")" # rg は対象外
check "ls-R-project" "" \
    "$(decision "ls -R $DUMMY_HOME/src/github.com/yasunori0418/skills/skills/learning/")" # ls -R は対象外
check "fd-home-subdir" "" \
    "$(decision "fd -L -t f 'investigate.md' ~/.claude ~/dotfiles")"
check "echo-only" "" \
    "$(decision 'echo "find / is slow"')"

exit "$fail"
