#!/usr/bin/env bash
# review-aggregator の PreToolUse hook: Bash の書き込みを統合報告の出力先だけに限定する。
# 拒否リスト方式: ファイルへのリダイレクトは basename が review-converge-round-<数字>.md で、
# かつ書き込み先が worktree 内か scratchpad 配下(`..` の遡上は不可)のときだけ通し、
# 書き込み・ビルド系コマンド(tee / cp / mv / rm / go / cargo / npm / make /
# nix build)は exit 2 でブロック(stderr がエージェントに返る)。それ以外は通す
# (diff-review スキルの実行に要る uv / python3 / git / 各スクリプトを塞がないため)。
#
# 判定はコマンドの「構造」に対して行い、データは見ない。統合報告の本文は heredoc や
# 引用文字列に載ってこの hook を通るため、本文中の `rm` の説明や markdown の引用行 `>` を
# コマンド・リダイレクトと読むと、唯一許可すべき書き出しを塞いで周回が空転する。
set -euo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
# 判定の基準ディレクトリは hook 入力の cwd(= Bash ツールの作業ディレクトリ)。
# hook プロセス自身の cwd と一致する保証が無いため、git-guard/main.sh と同じ慣行に揃える。
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[[ -n "$CWD" && -d "$CWD" ]] || CWD="$PWD"
[[ -z "$COMMAND" ]] && exit 0

deny() {
    echo "Blocked (review-aggregator can only write the round report): $1" >&2
    exit 2
}

# 1) heredoc の本体を落とす。`<<EOF` / `<<'EOF'` / `<<-EOF` の区切り語を拾い、
#    区切り行までを本文として取り除く(本文はデータでありコマンドではない)。
# awk(POSIX ERE)は後方参照を持たないため、引用の有無を明示の選択で書く
HEREDOC_RE='<<-?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*|"[A-Za-z_][A-Za-z0-9_]*"|\x27[A-Za-z_][A-Za-z0-9_]*\x27)'
STRIPPED=$(printf '%s' "$COMMAND" | awk -v re="$HEREDOC_RE" '
    function delim(s,   t) {
        t = s
        sub(/^<<-?[[:space:]]*/, "", t)
        gsub(/^["\x27]|["\x27]$/, "", t)
        return t
    }
    {
        if (skip) {
            stripped = $0
            sub(/^[[:space:]]+/, "", stripped)
            if (stripped == term) { skip = 0 }
            next
        }
        line = $0
        if (match(line, re)) {
            term = delim(substr(line, RSTART, RLENGTH))
            skip = 1
            line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
        }
        print line
    }
')

# 2) 引用文字列の中身を落とす(検索パターンの `>` や本文の説明をコマンドと読まないため)。
#    リダイレクト先が引用符で括られている場合に備え、引用符自体は目印として残す。
STRIPPED=$(printf '%s' "$STRIPPED" | sed -E "s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g")

# 3) stderr の /dev/null 捨てと 2>&1 は書き込みではないので落とす
STRIPPED=$(printf '%s' "$STRIPPED" | sed -E 's#[0-9]*>>?[[:space:]]*(&[0-9]+|/dev/null)##g')

# 残ったリダイレクトの出力先を 1 つずつ検査する(> / >> / >| のいずれも対象)
REPORT_RE='^review-converge-round-[0-9]+\.md$'
# 書き込み先として許すディレクトリ。統合報告の置き場は review-converge の規定で
# 「<STATE> と同じディレクトリ」= セッションの scratchpad、無ければ worktree 内の
# tmp_claude/ のいずれか。basename 一致だけでは任意のディレクトリへ書けるため、
# 解決後のパスがこのどちらかの配下にあることも要求する。
WORKTREE_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
# scratchpad は worktree 外にある正当な書き込み先になり得るため許可枝を残す。
# ただし現行のハーネスはそのパスを hook へ渡さない(入力 JSON に該当キーは無く、
# CLAUDE_SCRATCHPAD_DIR も供給されない)ので、この枝は実運用では到達しない。
# review-converge の規定も scratchpad が無ければ worktree 内 tmp_claude/ へ落ちる
# (SKILL.md の「無ければ」フォールバック)ので、実経路は下の WORKTREE_ROOT 側。
# 将来 scratchpad が供給される構成になったとき、正当な出力を deny しないための防御。
SCRATCH_ROOT="${CLAUDE_SCRATCHPAD_DIR:-}"

while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    # 引用の中身は 2) で落ちているため、引用符付き・変数展開の出力先は空文字などになり
    # 静的に解決できない先として拒否される(リテラルの絶対パスで書かせる)
    if [[ "$target" == '""' || "$target" == "''" || "$target" == *'$'* ]]; then
        deny "リダイレクト先を静的に解決できない(引用符・変数展開を使わずリテラルの絶対パスで書くこと): ${target}"
    fi
    if ! [[ "$(basename -- "$target")" =~ $REPORT_RE ]]; then
        deny "統合報告(review-converge-round-<数字>.md)以外への書き込みは不可: ${target}"
    fi

    # `..` による遡上を拒否する。正規化はシンボリックリンクを辿らず字句上で行う
    # (worktree 内の tmp_claude は primary リポジトリへの symlink であり、実体を
    #  解決すると規定の出力先が worktree 外と判定されるため)
    if [[ "$target" == *'..'* ]]; then
        deny "相対パスの遡上(..)を含む書き込み先は不可: ${target}"
    fi
    resolved="$target"
    if [[ "$resolved" != /* ]]; then
        resolved="$CWD/$resolved"
    fi
    # `//` と `/./` を畳むだけの字句正規化
    while [[ "$resolved" == *//* ]]; do resolved="${resolved//\/\//\/}"; done
    while [[ "$resolved" == *"/./"* ]]; do resolved="${resolved//\/.\//\/}"; done
    in_allowed=0
    if [[ -n "$WORKTREE_ROOT" && "$resolved" == "$WORKTREE_ROOT"/* ]]; then
        in_allowed=1
    fi
    if [[ -n "$SCRATCH_ROOT" && "$resolved" == "$SCRATCH_ROOT"/* ]]; then
        in_allowed=1
    fi
    if (( in_allowed == 0 )); then
        deny "書き込み先が worktree(${WORKTREE_ROOT:-不明})・scratchpad の外を指している: ${resolved}"
    fi
done < <(printf '%s' "$STRIPPED" | grep -oE '[0-9]*>>?\|?[[:space:]]*[^[:space:];|&()<>]+' | sed -E 's#^[0-9]*>>?\|?[[:space:]]*##')

# パイプ・連結・コマンド置換を区切りに分割し、各コマンドの先頭語を検証
NORMALIZED=$(printf '%s' "$STRIPPED" | tr '\n`' ';;' | sed -E 's/\$\(/;/g; s/[()]/;/g; s/\|\|/;/g; s/&&/;/g; s/\|/;/g')

DENY_RE='^(tee|cp|mv|rm|go|cargo|npm|make)$'

IFS=';' read -ra SEGMENTS <<< "$NORMALIZED"
for seg in "${SEGMENTS[@]}"; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [[ -z "$seg" ]] && continue
    read -ra words <<< "$seg"
    first="${words[0]}"
    # パス付きで呼ばれても拒否できるよう basename で突き合わせる
    first_base="$(basename -- "$first")"

    if [[ "$first_base" =~ $DENY_RE ]]; then
        deny "コマンド ${first_base} は不可(書き込み・ビルドを伴うため)"
    fi
    if [[ "$first_base" == "nix" && "${words[1]:-}" == "build" ]]; then
        deny "nix build は不可(ビルド成果物を作るため)"
    fi
done

exit 0
