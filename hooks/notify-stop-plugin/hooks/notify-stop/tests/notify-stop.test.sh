#!/usr/bin/env bash
# Verifies notify-stop (stdin JSON の transcript_path から ai-title を抽出して通知):
#   - with-title:    ai-title があればその値
#   - tool-use-last: 複数あれば最後の値
#   - no-title:      無ければ 'Claude Code 完了'
#   - emoji/symbols: 特殊文字がそのまま通る
#   - missing:       transcript_path 欠落・存在しないパスでもフォールバック
# osascript / dunstify は PATH 上のモックで置き換え、通知本文を stdout で検証する。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NOTIFY="$SCRIPT_DIR/../main.sh"

# モックは実行時生成のため patchShebangs が及ばない。nix sandbox にも存在する
# /bin/sh を使い、bash 拡張（負のインデックス等）を避けた POSIX 構文で書く。
TMPBIN=$(mktemp -d)
trap 'rm -rf "$TMPBIN"' EXIT
# echo は /bin/sh 実装によりバックスラッシュ列（\b 等）を解釈して壊すため
# printf '%s\n' で素通しする。
cat > "$TMPBIN/osascript" <<'MOCK'
#!/bin/sh
for a in "$@"; do last=$a; done
printf '%s\n' "$last"
MOCK
cat > "$TMPBIN/dunstify" <<'MOCK'
#!/bin/sh
printf '%s\n' "$2"
MOCK
chmod +x "$TMPBIN/osascript" "$TMPBIN/dunstify"

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
run() { # transcript-path
    printf '{"transcript_path": %s}' "$(printf '%s' "$1" | jq -Rs .)" \
        | PATH="$TMPBIN:$PATH" "$NOTIFY"
}

check "with-title" "テストタイトル" "$(run "$SCRIPT_DIR/with-title.test.jsonl")"
check "tool-use-last" "前のタイトル" "$(run "$SCRIPT_DIR/tool-use-last.test.jsonl")"
check "no-title" "Claude Code 完了" "$(run "$SCRIPT_DIR/no-title.test.jsonl")"
check "emoji" "完了 🎉 👨‍💻 🇯🇵 ❤️ 👍🏻" "$(run "$SCRIPT_DIR/emoji.test.jsonl")"
EXPECTED_SYMBOLS='記号: "q" \b $v `c` (p) [b] | & ; * ? ! ~ < > '"'"'a'"'"
check "symbols" "$EXPECTED_SYMBOLS" "$(run "$SCRIPT_DIR/symbols.test.jsonl")"
check "missing-file" "Claude Code 完了" "$(run "/nonexistent/transcript.jsonl")"
OUT=$(printf '{}' | PATH="$TMPBIN:$PATH" "$NOTIFY")
check "missing-field" "Claude Code 完了" "$OUT"

exit "$fail"
