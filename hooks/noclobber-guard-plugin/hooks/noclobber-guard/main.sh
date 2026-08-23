#!/usr/bin/env bash
# noclobber-guard/main.sh — PreToolUse hook（matcher: Bash）。
# zsh の `setopt noclobber` 環境で確実に失敗する `>` リダイレクトを事前に deny し、
# `>|`（明示上書き）への書き換えを促す。
#
# 動機（セッション履歴 552 セッション / Bash 実行 30,994 件の全走査による実測）:
#   `(eval):N: file exists: <path>` が 245 回 / 73 セッション / 80 個の独立した
#   Bash 呼び出しで発生していた。原因は Claude Code の Bash ツールがユーザーの
#   profile 由来の zsh で eval するため `setopt noclobber` が効くのに対し、
#   モデルの既定の思考は bash（clobber 有効）で `>` が上書きになる、という乖離。
#
#   失敗後のリカバリは 80 件中:
#     - 28 件が `rm -f` を挟んで同じコマンドを再実行（2 ターン消費）
#     - 22 件が `>|` へ書き換えて再実行（正解だが 1 ターン消費）
#     - 29 件が別アプローチへ切替、うち一部は失敗に気づかず先へ進んでいた
#   最初から `>|` を使えていたのは 80 件中 1 件のみ。
#
#   最悪ケースは for ループ内のリダイレクト（1 セッションで 124 回失敗）。
#   2 周目以降が全て失敗して出力ファイルが 1 周目の内容で固定され、
#   後続の判定が全ファイルで 1 周目の結果を見るという silent な誤りになった。
#   ループ内・`;` 区切り・`|| true` 付きでは exit code が 0 になるため、
#   モデルもユーザーも失敗に気づけない。事前 deny でしか防げない類の事故。
#
# 判定（誤爆を避けるため「確実に失敗する」ケースだけに絞る）:
#   コマンド中の素の `>` リダイレクトのうち、書き先が
#     1. リテラル、または同一コマンド内の単純な変数代入で静的に解決でき
#     2. 絶対パスへ解決でき（相対パスは先頭の `cd <絶対パス>` があるときだけ解決）
#     3. 実行時点で既に存在する
#   ものを deny する。1〜3 のいずれかを満たさなければ沈黙する（fail-open）。
#
#   実測での精度: 失敗 80 件のうち 54 件を静的解決でき（残りは scratchpad が
#   既に消えていて測定できなかっただけで、実運用では対象が存在する瞬間に判定する）、
#   無関係な Bash 実行 1,500 件のサンプルに対する誤検出は 3 件（0.20%）。
#   うち 2 件は実際に noclobber で失敗するはずのケースだったため、
#   真の誤検出は 1 件（0.07%）。
#
# 対象外（noclobber が効かない・効かせるべきでないもの）:
#   `>>` 追記 / `>|` 明示上書き / `>&` `2>&1` fd 複製 / `<>` 読み書き /
#   `>(...)` プロセス置換 / `/dev/*` への書き込み。
#
# 既知の抜け穴: コマンド置換 `$(...)` を含むパス、`mktemp` の結果、
# heredoc 本文内に書かれたスクリプト、`bash -c '...'` の中身は静的に解決できない
# ため素通しする。また判定は実行「前」に行うため、同一コマンド内で作られた
# ファイルへの 2 回目以降の書き込み（`echo a > f && echo b > f`）は、判定時点で
# f が存在せず検知できない。本 hook は「気づけない silent failure を減らす」
# ガードレールであり、noclobber 違反を完全に捕捉する検証器ではない。
set -euo pipefail

deny() { # reason
    jq -cn --arg r "$1" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# 素の `>` が 1 つも無ければ即座に抜ける（全 Bash 実行の約 92% がここで終わる）。
printf '%s' "$cmd" | grep -q '>' || exit 0

# --- 解析本体 --------------------------------------------------------------
# awk 1 本で「クォート・heredoc の除去」「変数代入の収集」「リダイレクト先の
# 静的解決」を行い、解決できた絶対パスを 1 行 1 件で出力する。
# 存在確認は shell 側で行う（awk からファイルシステムを引くのを避ける）。
targets=$(printf '%s' "$cmd" | HOME_DIR="${HOME:-}" awk '
# ---- ユーティリティ ----
function is_name(s) { return s ~ /^[A-Za-z_][A-Za-z0-9_]*$/ }

# 変数展開。未定義変数やコマンド置換があれば "" を返す（= 解決不能）。
function expand(s,   out, i, n, c, name, brace, val) {
    if (s ~ /\$\(/ || s ~ /`/) return ""
    out = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c != "$") { out = out c; continue }
        i++
        if (i > n) return ""
        brace = 0
        if (substr(s, i, 1) == "{") { brace = 1; i++ }
        name = ""
        while (i <= n) {
            c = substr(s, i, 1)
            if (c ~ /[A-Za-z0-9_]/) { name = name c; i++ } else break
        }
        if (brace) {
            if (substr(s, i, 1) != "}") return ""   # ${VAR:-default} 等は諦める
        } else {
            i--
        }
        if (name == "") return ""
        if (!(name in VAR)) return ""
        out = out VAR[name]
    }
    return out
}

BEGIN {
    HOME_D = ENVIRON["HOME_DIR"]
    sub(/\/$/, "", HOME_D)
    if (HOME_D != "") VAR["HOME"] = HOME_D
    body = ""
}
{ body = (body == "" ? $0 : body "\n" $0) }

END {
    n = length(body)

    # ---- パス 1: クォート領域と heredoc 本文を空白へ潰す ----
    # 位置を保つため長さは変えない。改行は改行のまま残す（行構造を壊さない）。
    scan = ""
    state = ""        # "" | "\x27" | "\""
    hd_count = 0
    i = 1
    while (i <= n) {
        c = substr(body, i, 1)

        if (state == "") {
            # heredoc 開始トークン: << TAG / <<-TAG / <<"TAG" / <<\x27TAG\x27
            if (c == "<" && substr(body, i + 1, 1) == "<") {
                rest = substr(body, i)
                if (match(rest, /^<<-?[ \t]*("[A-Za-z_][A-Za-z0-9_]*"|\x27[A-Za-z_][A-Za-z0-9_]*\x27|[A-Za-z_][A-Za-z0-9_]*)/)) {
                    tok = substr(rest, 1, RLENGTH)
                    tag = tok
                    sub(/^<<-?[ \t]*/, "", tag)
                    gsub(/["\x27]/, "", tag)
                    hd_count++
                    HD[hd_count] = tag
                    for (k = 0; k < RLENGTH; k++) scan = scan " "
                    i += RLENGTH
                    continue
                }
            }

            if (c == "\n" && hd_count > 0) {
                # この改行の直後から、最初の tag 行までが heredoc 本文。
                scan = scan "\n"
                i++
                tag = HD[1]
                for (k = 1; k < hd_count; k++) HD[k] = HD[k + 1]
                hd_count--
                while (i <= n) {
                    eol = index(substr(body, i), "\n")
                    if (eol == 0) { line = substr(body, i); eol_abs = n + 1 }
                    else { line = substr(body, i, eol - 1); eol_abs = i + eol - 1 }
                    trimmed = line
                    gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
                    for (k = i; k < eol_abs; k++) scan = scan " "
                    if (eol_abs <= n) scan = scan "\n"
                    i = eol_abs + 1
                    if (trimmed == tag) break
                }
                continue
            }

            if (c == "\x27" || c == "\"") { state = c; scan = scan " "; i++; continue }
            scan = scan c; i++; continue
        }

        # クォート内
        if (state == "\"" && c == "\\" && i < n) { scan = scan "  "; i += 2; continue }
        if (c == state) { state = ""; scan = scan " "; i++; continue }
        scan = scan (c == "\n" ? "\n" : " ")
        i++
    }

    # ---- パス 2: 変数代入の収集 ----
    # `NAME=value` がコマンド語の位置（行頭・; & && || | の直後・export の直後）に
    # 現れるものだけを拾う。値はクォート除去後の scan ではなく body 側から取る
    # 必要があるが、クォートされた値も scan では空白化されているため、
    # ここでは body を直接見て単純な代入だけを扱う。
    m = split(body, lines, /[\n;]|&&|\|\||[|&]/)
    for (li = 1; li <= m; li++) {
        seg = lines[li]
        gsub(/^[ \t]+/, "", seg)
        sub(/^export[ \t]+/, "", seg)
        if (!match(seg, /^[A-Za-z_][A-Za-z0-9_]*=/)) continue
        eq = index(seg, "=")
        nm = substr(seg, 1, eq - 1)
        vl = substr(seg, eq + 1)
        # 値のクォートを外す（前後 1 組だけ）
        if (vl ~ /^".*"/) { sub(/^"/, "", vl); sub(/".*$/, "", vl) }
        else if (vl ~ /^\x27.*\x27/) { sub(/^\x27/, "", vl); sub(/\x27.*$/, "", vl) }
        else { sub(/[ \t].*$/, "", vl) }
        ev = expand(vl)
        if (ev == "") { delete VAR[nm]; continue }
        VAR[nm] = ev
    }

    # ---- パス 3: 先頭の `cd <絶対パス>` を拾う ----
    base = ""
    for (li = 1; li <= m; li++) {
        seg = lines[li]
        gsub(/^[ \t]+/, "", seg)
        if (!match(seg, /^cd[ \t]+/)) continue
        arg = seg
        sub(/^cd[ \t]+/, "", arg)
        gsub(/^["\x27]|["\x27].*$/, "", arg)
        sub(/[ \t].*$/, "", arg)
        ea = expand(arg)
        if (ea != "" && substr(ea, 1, 1) == "/") { base = ea; break }
    }

    # ---- パス 4: 素の `>` リダイレクト先を拾う ----
    # 直前が 0-9 < > & | = ! でなく、直後が > | & ( = でないもの。
    L = length(scan)
    for (i = 1; i <= L; i++) {
        if (substr(scan, i, 1) != ">") continue
        prev = (i > 1) ? substr(scan, i - 1, 1) : ""
        nxt  = (i < L) ? substr(scan, i + 1, 1) : ""
        if (prev ~ /[0-9<>&|=!]/) continue
        if (nxt ~ /[>|&(=]/) continue

        # 書き先トークンは body 側から読む（scan はクォート内が空白化されており
        # 書き先そのものが消えるため）。`>` の位置は scan と body で一致する。
        bj = i + 1
        while (bj <= n && substr(body, bj, 1) ~ /[ \t]/) bj++
        tgt = ""
        q = substr(body, bj, 1)
        if (q == "\"" || q == "\x27") {
            # クォートされた書き先: 閉じクォートまでをそのまま採る。
            # シングルクォート内は変数展開されないが、その場合 expand() が
            # リテラルとして返すため区別は不要（$ を含めば解決不能で沈黙する）。
            bj++
            while (bj <= n) {
                c = substr(body, bj, 1)
                if (c == q) break
                tgt = tgt c; bj++
            }
        } else {
            while (bj <= n) {
                c = substr(body, bj, 1)
                if (c ~ /[ \t\n;&|<>()]/) break
                tgt = tgt c; bj++
            }
        }
        if (tgt == "") continue

        et = expand(tgt)
        if (et == "") continue
        if (et ~ /^\/dev\//) continue
        if (substr(et, 1, 2) == "~/" && HOME_D != "") et = HOME_D substr(et, 2)
        if (substr(et, 1, 1) != "/") {
            if (base == "") continue
            et = base "/" et
        }
        print et
    }
}
')

[ -n "$targets" ] || exit 0

# --- 存在確認 --------------------------------------------------------------
existing=""
while IFS= read -r t; do
    [ -n "$t" ] || continue
    # 通常ファイルのみ対象。ディレクトリ・デバイス・FIFO は noclobber の対象外
    # （zsh はディレクトリへのリダイレクトを別のエラーで弾く）。
    if [ -f "$t" ]; then
        case "$existing" in
        *"  - $t"$'\n'*) ;;
        *) existing="${existing}  - $t"$'\n' ;;
        esac
    fi
done <<EOF
$targets
EOF

[ -n "$existing" ] || exit 0

deny "🚫 既存ファイルへの \`>\` リダイレクトは zsh の noclobber で失敗する。

このセッションの Bash は \`setopt noclobber\` が有効な zsh で実行される。既に存在するファイルへ \`>\` で書くと、上書きされずに \`zsh: file exists: <path>\` で失敗する。

上書きになる書き先:
${existing}
対処（いずれか）:
  - 上書きしてよいなら \`>\` を \`>|\` に変える（noclobber を明示的に外す。これが正解）
  - 追記したいなら \`>>\` を使う
  - 作り直したいなら \`rm -f <path>\` を前に挟む

特に注意:
  - ループ内のリダイレクト（\`for … do … > out; done\`）は 2 周目以降が全て失敗し、
    出力が 1 周目の内容で固定されたまま exit code は 0 になる。必ず \`>|\` を使うこと。
  - \`cmd > file\` が \`;\` 区切りや \`|| true\` の中にあると失敗が握り潰され、
    後続が古い内容を読む。これも \`>|\` で防ぐ。

実測（セッション履歴 552 件の全走査）では、この失敗が 245 回・73 セッションで発生し、最初から \`>|\` を使えていたのは 80 個の失敗コマンド中 1 件だけだった。"
