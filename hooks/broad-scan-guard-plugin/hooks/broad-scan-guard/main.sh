#!/usr/bin/env bash
# broad-scan-guard/main.sh — PreToolUse hook（matcher: Bash）。
# find / fd による「探索範囲の仮説を立てない広域探索」を deny する。
#
# 動機（セッション履歴 4,851 件の Bash 実行を全走査した実測）:
#   真の `find /` は 11 コマンド / 10 セッション。うち 9 件が既定 2 分の
#   タイムアウトで打ち切られ、出力ゼロのまま合計 約23分 を捨てていた。
#   最長 180.4 秒。正当な用途は 1 件も無かった。
#   11 件中 6 件は workflow のサブエージェント由来で、6 体が同時に同じ
#   `investigate.md` を `/` から探して全員タイムアウトしていた。
#   いずれも正解のディレクトリ（~/.claude/plugins・~/.gradle 等）は
#   数秒で当たる範囲にあり、範囲の仮説を立てれば済む話だった。
#
# 判定（2 軸のみ。特定パスの特別扱いはしない）:
#   1. 起点が `/`                    -> 無条件 deny（maxdepth の有無を問わない）
#   2. 起点が $HOME ちょうど         -> -maxdepth（fd は --max-depth/-d）が無ければ deny
#      （$HOME 配下のサブディレクトリ起点は対象外。実測でいずれも高速に完了している）
#
# 対象コマンドを find / fd に限ったのは実測にもとづく。ルート起点で有害だったのは
# find 11 件 + fd 1 件のみで、rg / grep -r / ls -R のルート起点は 1 件も無い一方、
# 素朴な照合では 19 件の誤検出（プロジェクト内検索）を出したため対象外とした。
#
# /nix/store はスコープ外。深さ無制限だと 20 秒でも終わらない一方、実測 3 件は
# すべて -maxdepth 1 付き（0.14〜0.31s）で実害が無く、かつ正しい代替手段の選択が
# 文脈依存（drv 既知 / PATH 上 / flake input / upstream）で hook では決められない。
# 別途スキルとして扱う。
#
# 既知の抜け穴: ヒアドキュメント内のスクリプト（python3 - <<'EOF' … EOF）に
# 書かれた find は素通しする。実測で該当例はゼロのため許容する残余リスク。
# 本 hook は「勢いによる無計画な全探索」を止めるガードレールであり、
# 敵対的エージェントに対するセキュリティ境界ではない（sudo-guard と同格）。
set -euo pipefail

deny() { # reason
    jq -cn --arg r "$1" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# --- クォート領域の除去 ----------------------------------------------------
# `pkill -f "find / -iname SKILL.md"` のように、クォート内の文字列として
# find が現れるだけのコマンドを誤爆させない。これを落とすと暴走した find を
# 止める復旧手段そのものを奪うことになる。
# クォート内は「中身を消して空にする」のではなく空白へ潰す（語の連結を防ぐ）。
strip_quoted() { # command-string -> command-string（クォート内を空白化）
    printf '%s' "$1" | awk '
    {
        out = ""
        n = length($0)
        state = ""   # "" | "\x27" | "\""
        for (i = 1; i <= n; i++) {
            c = substr($0, i, 1)
            if (state == "") {
                if (c == "\x27" || c == "\"") { state = c; out = out " "; continue }
                out = out c
            } else {
                # シングルクォート内はエスケープが効かない。ダブルクォート内の
                # \" は閉じないので 2 文字読み飛ばす。
                if (state == "\"" && c == "\\" && i < n) { out = out "  "; i++; continue }
                if (c == state) { state = ""; out = out " "; continue }
                out = out " "
            }
        }
        print out
    }'
}

scan=$(strip_quoted "$cmd")

# --- $HOME の表記ゆれ ------------------------------------------------------
# 実行時の $HOME を正とする（公開プラグインとして配布するため、ユーザー名を
# ハードコードしない）。$HOME 未設定の異常環境では `/` 起点の判定だけ生かす。
home="${HOME:-}"
home="${home%/}"

# --- 段落分割してコマンド語位置の find / fd を拾う -------------------------
# `;` `&&` `||` `|` `&` `(` `)` `` ` `` `{` `}` および改行をコマンド区切りとみなし、
# 各セグメントの先頭語が find / fd であるものだけを検査する。
# `cat x; find / -name y` のような複合コマンドは、その find の部分で 2 分溶けるため
# セグメント単位で拾えば deny できる。
segments=$(printf '%s' "$scan" | tr '\n' ';' | sed -E 's/(\|\||&&|[;|&(){}`])/\n/g')

# 起点引数が「ルート」か「$HOME ちょうど」かを判定する。
# find/fd のオプション（-name 等）とその値を読み飛ばし、非オプション引数だけを見る。
classify_segment() { # segment -> "root" | "home" | ""
    local seg="$1"
    printf '%s' "$seg" | HOME_DIR="$home" awk '
    function is_root(a) { return a == "/" }
    function is_home(a,   h) {
        h = ENVIRON["HOME_DIR"]
        if (a == "~" || a == "~/") return 1
        if (a == "$HOME" || a == "${HOME}" || a == "$HOME/" || a == "${HOME}/") return 1
        if (h != "" && (a == h || a == h "/")) return 1
        return 0
    }
    {
        n = split($0, w, /[ \t]+/)
        # 先頭の非空語を探す
        s = 0
        for (i = 1; i <= n; i++) if (w[i] != "") { s = i; break }
        if (s == 0) next
        tool = w[s]
        if (tool != "find" && tool != "fd" && tool != "fdfind") next

        depth_bounded = 0
        root_start = 0
        home_start = 0

        for (i = s + 1; i <= n; i++) {
            a = w[i]
            if (a == "") continue

            # 深さ制限オプション（find: -maxdepth / fd: --max-depth, -d）
            if (a == "-maxdepth" || a == "--maxdepth" || a == "--max-depth" || a == "-d") { depth_bounded = 1; i++; continue }
            if (a ~ /^--max-depth=/ || a ~ /^--maxdepth=/ || a ~ /^-d[0-9]+$/) { depth_bounded = 1; continue }

            # find の式（-name foo 等）以降は探索起点ではない。値を取るものは読み飛ばす。
            if (a ~ /^-/) continue

            # 非オプション引数。fd は第1引数がパターンで第2引数以降が起点だが、
            # ここでは「/ または $HOME ちょうどが単独で現れたか」だけを見るため
            # 位置を区別する必要がない（パターンが "/" や "~" になることは無い）。
            if (is_root(a)) root_start = 1
            else if (is_home(a)) home_start = 1
        }

        if (root_start) { print "root"; exit }
        if (home_start && !depth_bounded) { print "home"; exit }
    }'
}

verdict=""
while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    r=$(classify_segment "$seg")
    if [ "$r" = "root" ]; then
        verdict="root"
        break
    fi
    [ "$r" = "home" ] && verdict="home"
done <<EOF
$segments
EOF

[ -n "$verdict" ] || exit 0

ALTERNATIVES='かわりに次のいずれかを使うこと:
  - プロジェクト内を探すなら Glob / Grep ツール（この hook の対象外・高速）
  - 探索範囲の仮説を立て、具体的なディレクトリを起点にする
    （実測では ~/.claude/plugins・~/.gradle など、正解は数秒で当たる範囲にあった）
  - ~/.claude 配下は symlink 追従が要るので `-L` を付ける（rg -L / fd -L / find -L）
  - どうしても広い範囲が要るなら `-maxdepth`（fd は --max-depth）で深さを区切る'

if [ "$verdict" = "root" ]; then
    deny "🚫 ルート（/）起点の全探索は禁止。

実測（セッション履歴の全走査）では \`find /\` は 11 回実行され、うち 9 回が 2 分のタイムアウトで打ち切られて出力ゼロだった。合計 約23分 を消費して得られた情報は無い。正当だった用途は 1 件も無かった。

$ALTERNATIVES

それでもファイルシステム全域を舐める必要が本当にあるなら、その理由をユーザーに説明して指示を仰ぐこと（AI 側にこのガードを解除する手段は無い）。"
fi

deny "🚫 \$HOME 直下（${home}）起点の探索には深さ制限が必要。

\$HOME ちょうどを起点にした深さ無制限の探索は、実測で 2 分のタイムアウトに達して出力ゼロに終わっている。

対処:
  - \`-maxdepth <n>\`（fd は \`--max-depth <n>\`）を付ける
  - または起点を \$HOME 配下の具体的なディレクトリまで絞る（こちらは制限対象外）

$ALTERNATIVES"
