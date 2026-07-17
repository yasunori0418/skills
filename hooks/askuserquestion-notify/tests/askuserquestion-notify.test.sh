#!/usr/bin/env bash
# Verifies askuserquestion-notify (PreToolUse:AskUserQuestion で質問内容を通知):
#   - question:    本文に最初の質問文が出る
#   - subtitle:    header が subtitle に出る
#   - truncate:    80 文字超の質問文は切り詰め + … が付く
#   - multi:       質問が複数なら「（ほか N 件）」が付記される
#   - marker:      #aq-off マーカーがあるセッションでは通知しない（黙る）
#   - symbols:     特殊文字がエスケープを壊さず本文へ通る
#   - emoji:       emoji がそのまま通る
#   - fallback:    questions 欠落時はフォールバック文言
#
# osascript は PATH 上のモックで置き換える。モックは
#   line1: 本文（display notification の第1引数 = argv item 1）
#   line2: subtitle（argv item 2）
#   line3: -e で渡された AppleScript 本体（title / sound を含む行）
# を stdout に出す。POSIX /bin/sh で書き、bash 拡張を避ける。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NOTIFY="$SCRIPT_DIR/../main.sh"

TMPBIN=$(mktemp -d)
MARKER_DIR=$(mktemp -d)
trap 'rm -rf "$TMPBIN" "$MARKER_DIR"' EXIT

# osascript モック: 末尾2引数が本文と subtitle。-e で渡る display 行も拾って
# title/sound 検証に使えるようにする。
cat > "$TMPBIN/osascript" <<'MOCK'
#!/bin/sh
# 末尾から2つ（body, subtitle）を取り出す
prev=""
last=""
display_line=""
expect_e=0
for a in "$@"; do
    if [ "$expect_e" = "1" ]; then
        case "$a" in
            "display notification"*) display_line="$a" ;;
        esac
        expect_e=0
    fi
    [ "$a" = "-e" ] && expect_e=1
    prev="$last"
    last="$a"
done
# echo は /bin/sh によりバックスラッシュ列を解釈して壊すため printf で素通しする
printf '%s\n' "$prev"          # body (argv item 1)
printf '%s\n' "$last"          # subtitle (argv item 2)
printf '%s\n' "$display_line"  # AppleScript display line (title / sound)
MOCK
chmod +x "$TMPBIN/osascript"

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}

# run <json> : hook を実行し stdout（body / subtitle / display line の3行）を返す
run() {
    printf '%s' "$1" | PATH="$TMPBIN:$PATH" CLAUDE_AQ_MARKER_DIR="$MARKER_DIR" "$NOTIFY"
}
line() { printf '%s\n' "$2" | sed -n "${1}p"; }

# --- question: 本文に質問文が出る ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"どちらの方式で進めますか","header":"方式"}]}}'
OUT=$(run "$J")
check "question-body" "どちらの方式で進めますか" "$(line 1 "$OUT")"
check "question-subtitle" "方式" "$(line 2 "$OUT")"

# --- subtitle: header が空でも通る ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"質問だけ"}]}}'
OUT=$(run "$J")
check "no-header-body" "質問だけ" "$(line 1 "$OUT")"
check "no-header-subtitle" "" "$(line 2 "$OUT")"

# --- truncate: 80 文字超は切り詰め + …（ASCII で境界問題を避ける） ---
LONG=$(printf 'a%.0s' $(seq 1 100))
EXPECT_TRUNC="$(printf 'a%.0s' $(seq 1 80))…"
J=$(printf '{"session_id":"s1","tool_input":{"questions":[{"question":"%s","header":"h"}]}}' "$LONG")
OUT=$(run "$J")
check "truncate" "$EXPECT_TRUNC" "$(line 1 "$OUT")"

# --- 80 文字ちょうどは切り詰めない ---
EXACT=$(printf 'b%.0s' $(seq 1 80))
J=$(printf '{"session_id":"s1","tool_input":{"questions":[{"question":"%s","header":"h"}]}}' "$EXACT")
OUT=$(run "$J")
check "no-truncate-at-limit" "$EXACT" "$(line 1 "$OUT")"

# --- multi: 質問が複数なら（ほか N 件） ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"一つ目","header":"h1"},{"question":"二つ目","header":"h2"},{"question":"三つ目","header":"h3"}]}}'
OUT=$(run "$J")
check "multi-count" "一つ目（ほか 2 件）" "$(line 1 "$OUT")"

# --- marker: #aq-off セッションは黙る（何も出力しない） ---
touch "$MARKER_DIR/claude-no-askuserquestion.s1"
J='{"session_id":"s1","tool_input":{"questions":[{"question":"抑制されるはず","header":"h"}]}}'
OUT=$(run "$J")
check "marker-suppress" "" "$OUT"
rm -f "$MARKER_DIR/claude-no-askuserquestion.s1"

# --- symbols: 特殊文字（バックスラッシュ \b 含む）がそのまま本文へ ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"記号: \"q\" \\b $v `c` (p) [b] | & ; * ? ! ~ < >","header":"h"}]}}'
OUT=$(run "$J")
check "symbols" '記号: "q" \b $v `c` (p) [b] | & ; * ? ! ~ < >' "$(line 1 "$OUT")"

# --- emoji: そのまま通る ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"完了 🎉 👍🏻","header":"h"}]}}'
OUT=$(run "$J")
check "emoji" "完了 🎉 👍🏻" "$(line 1 "$OUT")"

# --- fallback: questions 欠落 ---
J='{"session_id":"s1","tool_input":{}}'
OUT=$(run "$J")
check "fallback" "Claude が入力を待っています" "$(line 1 "$OUT")"

# --- title / sound が display 行に含まれる ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"q","header":"h"}]}}'
OUT=$(run "$J")
DISP=$(line 3 "$OUT")
case "$DISP" in
    *'with title "Claude が質問中"'*'sound name "Glass"'*)
        echo "PASS: $(basename "$0")[title-sound] -> ok" ;;
    *)
        echo "FAIL: $(basename "$0")[title-sound] display line lacks title/sound: '$DISP'"
        fail=1 ;;
esac

exit "$fail"
