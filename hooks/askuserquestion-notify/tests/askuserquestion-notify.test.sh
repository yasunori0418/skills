#!/usr/bin/env bash
# Verifies askuserquestion-notify (PreToolUse:AskUserQuestion で質問内容を通知)。
#
# main.sh の OS 分岐は CLAUDE_AQ_UNAME で上書きでき、Darwin / Linux 両分岐を
# ホスト非依存で検証する。共通の本文組み立て（質問文抽出・切り詰め・件数付記・
# マーカー抑制・フォールバック）は両分岐で同一結果になることを確認する。
#
#   - question:    本文に最初の質問文が出る
#   - subtitle:    header が subtitle に出る（Darwin のみ。Linux は title/body の2引数）
#   - truncate:    80 文字超の質問文は切り詰め + … が付く
#   - multi:       質問が複数なら「（ほか N 件）」が付記される
#   - marker:      #aq-off マーカーがあるセッションでは通知しない（黙る）
#   - symbols:     特殊文字がエスケープを壊さず本文へ通る
#   - emoji:       emoji がそのまま通る
#   - fallback:    questions 欠落時はフォールバック文言
#   - title/sound: Darwin の display 行に title / sound が乗る
#   - linux-backend: dunstify 優先、無ければ notify-send、どちらも無ければ黙る
#
# 各通知バックエンドは PATH 上のモックで置き換える。
#   osascript モック（Darwin）:
#     line1: 本文（display notification の第1引数 = argv item 1）
#     line2: subtitle（argv item 2）
#     line3: -e で渡された AppleScript 本体（title / sound を含む行）
#   dunstify / notify-send モック（Linux）:
#     line1: title（第1引数）
#     line2: body（第2引数）
# を stdout に出す。POSIX /bin/sh で書き、bash 拡張を避ける。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NOTIFY="$SCRIPT_DIR/../main.sh"

TMPBIN=$(mktemp -d)
MARKER_DIR=$(mktemp -d)
trap 'rm -rf "$TMPBIN" "$MARKER_DIR"' EXIT

# テスト用の最小 PATH。実ホストの通知バックエンド（dunstify / notify-send）を
# 排除してモックだけを見せるため、main.sh が実際に使うコマンドのディレクトリ
# だけを動的に集めて TMPBIN を先頭に束ねる。nix 環境では coreutils・bash・jq が
# それぞれ別 store パスに散るので、パスは決め打ちせず command -v で解決する。
# こうしないと実ホストの dunstify が拾われ、フォールバックや「黙る」検証ができない。
MIN_PATH="$TMPBIN"
for _cmd in bash jq cat wc tr cut sed uname dirname mktemp basename seq; do
    _p=$(command -v "$_cmd" 2>/dev/null) || continue
    case "$_p" in
        /*) : ;;                     # 絶対パスのみ採用
        *) continue ;;               # builtin 等（dirname が '.' を返すので除外）
    esac
    _d=$(dirname "$_p")
    case ":$MIN_PATH:" in
        *":$_d:"*) : ;;              # 既に含む
        *) MIN_PATH="$MIN_PATH:$_d" ;;
    esac
done

# 束ねた MIN_PATH に通知バックエンドが紛れ込んでいないか検証する。coreutils 等と
# 同じディレクトリに dunstify/notify-send が同居する環境だと、モックを rm した
# 「黙る」ケースで実体が拾われてしまうため、その場合はテスト前提が崩れると明示する。
for _nb in dunstify notify-send; do
    if PATH="$MIN_PATH" command -v "$_nb" >/dev/null 2>&1; then
        echo "FATAL: 実ホストの $_nb が最小 PATH に混入している（テスト前提が成立しない）" >&2
        echo "  $(PATH="$MIN_PATH" command -v "$_nb")" >&2
        exit 2
    fi
done

# osascript モック（Darwin 分岐）: 末尾2引数が本文と subtitle。-e で渡る
# display 行も拾って title/sound 検証に使えるようにする。
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

# dunstify / notify-send モック（Linux 分岐）: 第1引数=title, 第2引数=body。
# どちらのバックエンドが呼ばれたか分かるよう、3行目に自分の名前を出す。
make_linux_mock() { # name
    cat > "$TMPBIN/$1" <<MOCK
#!/bin/sh
printf '%s\n' "\$1"   # title
printf '%s\n' "\$2"   # body
printf '%s\n' "$1"    # backend name (dunstify / notify-send)
MOCK
    chmod +x "$TMPBIN/$1"
}

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}

line() { printf '%s\n' "$2" | sed -n "${1}p"; }

# run_darwin <json> : Darwin 分岐を強制。stdout は body / subtitle / display 行の3行。
# 実ホストの通知バックエンドを排除するため最小 PATH（osascript モックのみ通知系）で走らせる。
run_darwin() {
    printf '%s' "$1" | PATH="$MIN_PATH" \
        CLAUDE_AQ_UNAME=Darwin CLAUDE_AQ_MARKER_DIR="$MARKER_DIR" "$NOTIFY"
}

# run_linux <json> : Linux 分岐を強制。stdout は title / body / backend 名の3行。
# 呼び出し側は事前に make_linux_mock で使いたいバックエンドを用意しておく。
# 最小 PATH で実ホストの dunstify/notify-send を排除し、モックだけを見せる。
run_linux() {
    printf '%s' "$1" | PATH="$MIN_PATH" \
        CLAUDE_AQ_UNAME=Linux CLAUDE_AQ_MARKER_DIR="$MARKER_DIR" "$NOTIFY"
}

# ===========================================================================
# 共通の本文組み立て（両分岐で同一結果になることを確認）
# Darwin では body=item1 / Linux では body=line2。同じ入力・同じ期待値で回す。
# ===========================================================================

# Linux バックエンドとして dunstify を用意（この節を通して有効）
make_linux_mock dunstify

# body を両分岐から取り出すヘルパ
darwin_body() { line 1 "$(run_darwin "$1")"; }
linux_body() { line 2 "$(run_linux "$1")"; }

# --- question: 本文に質問文が出る ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"どちらの方式で進めますか","header":"方式"}]}}'
check "question-body-darwin" "どちらの方式で進めますか" "$(darwin_body "$J")"
check "question-body-linux"  "どちらの方式で進めますか" "$(linux_body "$J")"
# subtitle は Darwin のみ（Linux には subtitle 概念が無い）
check "question-subtitle-darwin" "方式" "$(line 2 "$(run_darwin "$J")")"

# --- header が空でも通る ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"質問だけ"}]}}'
check "no-header-body-darwin" "質問だけ" "$(darwin_body "$J")"
check "no-header-body-linux"  "質問だけ" "$(linux_body "$J")"
check "no-header-subtitle-darwin" "" "$(line 2 "$(run_darwin "$J")")"

# --- truncate: 80 文字超は切り詰め + …（ASCII で境界問題を避ける） ---
LONG=$(printf 'a%.0s' $(seq 1 100))
EXPECT_TRUNC="$(printf 'a%.0s' $(seq 1 80))…"
J=$(printf '{"session_id":"s1","tool_input":{"questions":[{"question":"%s","header":"h"}]}}' "$LONG")
check "truncate-darwin" "$EXPECT_TRUNC" "$(darwin_body "$J")"
check "truncate-linux"  "$EXPECT_TRUNC" "$(linux_body "$J")"

# --- 80 文字ちょうどは切り詰めない ---
EXACT=$(printf 'b%.0s' $(seq 1 80))
J=$(printf '{"session_id":"s1","tool_input":{"questions":[{"question":"%s","header":"h"}]}}' "$EXACT")
check "no-truncate-at-limit-darwin" "$EXACT" "$(darwin_body "$J")"
check "no-truncate-at-limit-linux"  "$EXACT" "$(linux_body "$J")"

# --- multi: 質問が複数なら（ほか N 件） ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"一つ目","header":"h1"},{"question":"二つ目","header":"h2"},{"question":"三つ目","header":"h3"}]}}'
check "multi-count-darwin" "一つ目（ほか 2 件）" "$(darwin_body "$J")"
check "multi-count-linux"  "一つ目（ほか 2 件）" "$(linux_body "$J")"

# --- marker: #aq-off セッションは黙る（何も出力しない） 両分岐で ---
touch "$MARKER_DIR/claude-no-askuserquestion.s1"
J='{"session_id":"s1","tool_input":{"questions":[{"question":"抑制されるはず","header":"h"}]}}'
check "marker-suppress-darwin" "" "$(run_darwin "$J")"
check "marker-suppress-linux"  "" "$(run_linux "$J")"
rm -f "$MARKER_DIR/claude-no-askuserquestion.s1"

# --- symbols: 特殊文字（バックスラッシュ \b 含む）がそのまま本文へ ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"記号: \"q\" \\b $v `c` (p) [b] | & ; * ? ! ~ < >","header":"h"}]}}'
EXPECT_SYM='記号: "q" \b $v `c` (p) [b] | & ; * ? ! ~ < >'
check "symbols-darwin" "$EXPECT_SYM" "$(darwin_body "$J")"
check "symbols-linux"  "$EXPECT_SYM" "$(linux_body "$J")"

# --- emoji: そのまま通る ---
J='{"session_id":"s1","tool_input":{"questions":[{"question":"完了 🎉 👍🏻","header":"h"}]}}'
check "emoji-darwin" "完了 🎉 👍🏻" "$(darwin_body "$J")"
check "emoji-linux"  "完了 🎉 👍🏻" "$(linux_body "$J")"

# --- fallback: questions 欠落 ---
J='{"session_id":"s1","tool_input":{}}'
check "fallback-darwin" "Claude が入力を待っています" "$(darwin_body "$J")"
check "fallback-linux"  "Claude が入力を待っています" "$(linux_body "$J")"

# ===========================================================================
# Darwin 固有: title / sound が display 行に含まれる
# ===========================================================================
J='{"session_id":"s1","tool_input":{"questions":[{"question":"q","header":"h"}]}}'
DISP=$(line 3 "$(run_darwin "$J")")
case "$DISP" in
    *'with title "Claude が質問中"'*'sound name "Glass"'*)
        echo "PASS: $(basename "$0")[title-sound] -> ok" ;;
    *)
        echo "FAIL: $(basename "$0")[title-sound] display line lacks title/sound: '$DISP'"
        fail=1 ;;
esac

# Darwin: title が第1引数ではなく AppleScript 側に固定なので body は title を含まない
check "darwin-title-not-in-body" "q" "$(darwin_body "$J")"

# ===========================================================================
# Linux 固有: バックエンド選択（dunstify 優先 → notify-send → 黙る）と
#             title が第1引数で渡ること
# ===========================================================================
J='{"session_id":"s1","tool_input":{"questions":[{"question":"りなっくす通知","header":"h"}]}}'

# dunstify があれば dunstify が使われ、title/body が引数で渡る
make_linux_mock dunstify
rm -f "$TMPBIN/notify-send"
OUT=$(run_linux "$J")
check "linux-title"          "Claude が質問中" "$(line 1 "$OUT")"
check "linux-body"           "りなっくす通知" "$(line 2 "$OUT")"
check "linux-backend-dunstify" "dunstify" "$(line 3 "$OUT")"

# dunstify が無ければ notify-send にフォールバック
rm -f "$TMPBIN/dunstify"
make_linux_mock notify-send
OUT=$(run_linux "$J")
check "linux-backend-notify-send" "notify-send" "$(line 3 "$OUT")"
check "linux-fallback-body"        "りなっくす通知" "$(line 2 "$OUT")"

# どちらも無ければ黙る（CI 等）。TMPBIN からモックを消せば、最小 PATH
# （TMPBIN + bash + jq）に通知バックエンドは一切残らない。
rm -f "$TMPBIN/dunstify" "$TMPBIN/notify-send"
OUT=$(run_linux "$J")
check "linux-no-backend-silent" "" "$OUT"

exit "$fail"
