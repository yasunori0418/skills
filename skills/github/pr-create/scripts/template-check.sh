#!/usr/bin/env bash
#
# template-check.sh — PR テンプレートと本文下書きの「骨組み」を照合し、
# テンプレの見出し・チェックリスト項目が削られたり勝手に足されていないかを
# 決定論的に検出する。read-only。
#
# なぜ必要か:
#   テンプレの遵守を文章ルールだけに委ねると、モデルは「このセクションは
#   該当しないから落とす」「見出しを言い換える」と加工してしまう。テンプレの
#   入力箇所は確定しているので、骨組み（見出し＋チェックリストのラベル）は
#   逐語で不変であるべき。ここで機械的な歯止めを入れ、drift があれば作成前に
#   止める。
#
# 骨組みの定義:
#   - 見出し行（# 〜 ######、行頭ハッシュ 1〜6 個 + 空白）
#   - チェックリスト項目（- / * + [ ] / [x]）。チェック状態は正規化して
#     無視し、ラベル文字列だけを比較する（[ ]→[x] は差分とみなさない）。
#   HTML コメント（<!-- ... -->）は「埋めた後に消す」慣習があるため照合対象外。
#   仮項目（テストケース1 のような書き換え前提のチェック項目）は骨組みに含めず、
#   同じ見出しの中での置き換え・削除を許す。そのまま残っていれば DRIFT（定義は skeletons()）。
#
# Usage:
#   template-check.sh <template-file> <draft-body-file>
#
# 終了コード:
#   0 = OK（骨組み一致）
#   1 = DRIFT（見出し/チェック項目の欠落・追加・並べ替え、仮項目の残りを検出）
#   2 = 使い方エラー（引数不足・ファイル無し）
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: template-check.sh <template-file> <draft-body-file>" >&2
    exit 2
fi

tmpl="$1"
draft="$2"
for f in "$tmpl" "$draft"; do
    [ -f "$f" ] || { echo "ERROR: ファイルが見つかりません: $f" >&2; exit 2; }
done

# 骨組み抽出。テンプレ → 下書きの順に 1 回の awk で読み、行頭タグ付きで出す:
#   T<TAB>H|C<TAB>…   テンプレの骨組み（仮項目は除く）
#   D<TAB>H|C<TAB>…   下書きの骨組み（仮項目のある節では、置き換えた項目を除く）
#   P / R / L<TAB><見出し><TAB><ラベル>
#                     テンプレの仮項目 / 仮項目の置き換えとみなした項目 / 残った仮項目
# 仮項目 = テンプレ作成者が「実際の内容に書き換える前提」で置いたチェック項目。
# ラベル全体が 空・連番だけ（テストケース1 / Test case 2 / 項目3 等）・<…>・xx…・…・TODO・TBD の
# いずれかに一致するものに限る（「TODO コメントを残していない」のような通常項目は含めない）。
# 仮項目のある節では、テンプレの固定項目以外のチェック項目を置き換えとして許す。
# interval 正規表現（{1,6}）に依存しないよう awk 側で長さを数える。
skeletons() {
    awk '
    function parse(line,    n, c, t) {
        kind = ""
        lab = ""
        if (substr(line, 1, 1) == "#") {
            n = 0
            while (substr(line, n + 1, 1) == "#") n++
            c = substr(line, n + 1, 1)
            if (n >= 1 && n <= 6 && (c == " " || c == "\t")) {
                sub(/[ \t]+$/, "", line)
                kind = "H"
                lab = line
                return
            }
        }
        t = line
        sub(/^[ \t]*/, "", t)
        if (t ~ /^[-*][ \t]+\[[ xX]\]/) {
            sub(/^[-*][ \t]+\[[ xX]\][ \t]*/, "", t)   # マーカーとチェック状態を除去
            sub(/[ \t]+$/, "", t)
            kind = "C"
            lab = t
        }
    }
    function is_placeholder(t,    l) {
        l = tolower(t)
        if (t == "") return 1
        if (t ~ /^<[^<>]*>$/) return 1
        if (l ~ /^xx+$/) return 1
        if (t ~ /^(\.\.\.|…)+$/) return 1
        if (l == "todo" || l == "tbd") return 1
        if (l ~ /^(テストケース|テスト項目|確認項目|項目|ケース|test ?case|case|item|step)[ \t]*[0-9]+$/) return 1
        return 0
    }
    FILENAME == ARGV[1] {
        parse($0)
        if (kind == "H") { sec = lab; print "T\tH\t" lab }
        else if (kind == "C") {
            if (is_placeholder(lab)) { ph[sec SUBSEP lab] = 1; has_ph[sec] = 1; print "P\t" sec "\t" lab }
            else { fixed[sec SUBSEP lab] = 1; print "T\tC\t" lab }
        }
        next
    }
    {
        parse($0)
        if (kind == "H") { dsec = lab; print "D\tH\t" lab }
        else if (kind == "C") {
            if (!(dsec in has_ph) || ((dsec SUBSEP lab) in fixed)) print "D\tC\t" lab
            else if ((dsec SUBSEP lab) in ph) print "L\t" dsec "\t" lab
            else print "R\t" dsec "\t" lab
        }
    }
    ' "$1" "$2"
}

ts=$(mktemp)
ds=$(mktemp)
trap 'rm -f "$ts" "$ds"' EXIT
tagged=$(skeletons "$tmpl" "$draft")
pick() { printf '%s\n' "$tagged" | awk -v tag="$1" 'index($0, tag "\t") == 1 { print substr($0, length(tag) + 2) }'; }
pick T > "$ts"
pick D > "$ds"
placeholders=$(pick P)
replaced=$(pick R)
leftover=$(pick L)

count() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | grep -c .; }
label() { case "$1" in H*) echo "見出し ${1#H$'\t'}";; C*) echo "チェック項目 ${1#C$'\t'}";; *) echo "$1";; esac; }

missing=$(comm -23 <(sort "$ts") <(sort "$ds") || true)
extra=$(comm -13 <(sort "$ts") <(sort "$ds") || true)
n_missing=$(count "$missing")
n_extra=$(count "$extra")
n_leftover=$(count "$leftover")
ph_line() { local sec=${1%%$'\t'*} l=${1#*$'\t'}; echo "  - ${sec:-(見出しの前)} / チェック項目 ${l:-(空ラベル)}"; }

echo "=== TEMPLATE SKELETON ==="
if [ -s "$ts" ]; then while IFS= read -r l; do label "$l"; done < "$ts"; else echo "(見出し・チェック項目なし)"; fi
echo ""
echo "=== DRAFT SKELETON ==="
if [ -s "$ds" ]; then while IFS= read -r l; do label "$l"; done < "$ds"; else echo "(見出し・チェック項目なし)"; fi
echo ""

echo "=== PLACEHOLDERS ==="
if [ -n "$placeholders" ]; then
echo "テンプレの仮項目（同じ見出しの中で実際の項目へ置き換えるか、消す）:"
while IFS= read -r l; do ph_line "$l"; done <<< "$placeholders"
if [ -n "$replaced" ]; then
echo "REPLACED（仮項目の置き換えとみなした下書きの項目）:"
while IFS= read -r l; do ph_line "$l"; done <<< "$replaced"
fi
else
echo "(仮項目なし)"
fi
echo ""

echo "=== DIFF ==="
if [ "$n_missing" -gt 0 ]; then
echo "MISSING（テンプレにあるが下書きに無い＝削り違反。該当なしでも見出しは残す）:"
while IFS= read -r l; do [ -n "$l" ] && echo "  - $(label "$l")"; done <<< "$missing"
fi
if [ "$n_extra" -gt 0 ]; then
echo "EXTRA（下書きにあるがテンプレに無い＝勝手追加。補足はテンプレ末尾に最小限）:"
while IFS= read -r l; do [ -n "$l" ] && echo "  - $(label "$l")"; done <<< "$extra"
fi
if [ "$n_leftover" -gt 0 ]; then
echo "PLACEHOLDER（テンプレの仮項目が下書きに残っている。実際の項目へ置き換えるか消す）:"
while IFS= read -r l; do ph_line "$l"; done <<< "$leftover"
fi
if [ "$n_missing" -eq 0 ] && [ "$n_extra" -eq 0 ]; then
if diff -q "$ts" "$ds" >/dev/null 2>&1; then
[ "$n_leftover" -eq 0 ] && echo "(差分なし)"
else
echo "REORDER（見出し・チェック項目の並び順がテンプレと違う＝加工。テンプレ順に戻す）"
fi
fi
echo ""

echo "=== RESULT ==="
if [ "$n_missing" -eq 0 ] && [ "$n_extra" -eq 0 ] && [ "$n_leftover" -eq 0 ] && diff -q "$ts" "$ds" >/dev/null 2>&1; then
echo "OK — 骨組みはテンプレと一致。承認フローに進んでよい。"
exit 0
fi
echo "DRIFT DETECTED — テンプレの骨組みと不一致。下書きをテンプレ構造に戻してから再チェックする。"
echo "（入力箇所を埋める・[ ]→[x] にする・仮項目を同じ見出しの中で置き換えるのは可。見出し/固定のチェック項目の削除・追加・改名・並べ替えは不可）"
exit 1
