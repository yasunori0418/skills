#!/usr/bin/env bash
# rules/20-rm-scratch.sh — 対象が一時領域だけの rm を allow する規則(契約は main.sh 参照)。
# 次を全て満たすときだけ理由を 1 行出す。1 つでも外れれば無出力(通常のダイアログに任せる):
#   - tool_name が Bash で、コマンドが `;` / `&&` / 改行で区切った次のセグメントだけから成る
#     (rm を 1 個以上含む。置換・引用符・glob・リダイレクト・`||` / `|` / `&` は含まない):
#       NAME=value(1 語の単純代入)/ cd <パス> / rm [-rRfvdiI | 長オプション] [--] <対象…>
#     rm 以外の処理(git push・curl・wget を含む)があれば扱わない。実シェルは zsh のこともあるので
#     ^(EXTENDED_GLOB)と語頭の =(EQUALS 展開)も扱わず、解決を変える IFS / PATH / CDPATH
#     (zsh の path / cdpath)への代入と、/ ./ ../ で始まらない cd(CDPATH で解決される)も扱わない
#   - $NAME / ${NAME} は同一コマンド内の単純代入だけで解決する(環境の変数は未定義扱い)
#   - cd は以降のセグメントの基準ディレクトリを変える。cd が失敗しても後続が走らないよう、
#     cd 以降の区切りは && に限る
#   - 全対象が一時領域の内側(領域そのものは不可): /tmp/claude-<uid>/**、
#     /tmp/nix-shell.*/claude-<uid>/**、$TMPDIR/**、cwd のリポジトリ直下 tmp-agents/**
#     (`git check-ignore` を通るときのみ)。比較は物理パスで行い、対象は親ディレクトリを
#     解決して末尾要素を保持する(末尾 / なら全体を解決)ので、symlink 越しの削除は外れる
set -uo pipefail

input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = Bash ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cmd" ] || exit 0
case "$cwd" in /*) ;; *) exit 0 ;; esac
command -v realpath >/dev/null && realpath -m / >/dev/null 2>&1 || exit 0

# 置換・引用符・glob・リダイレクト・コメント・チルダ・単独の & | を含むものは扱わない
case "$cmd" in *__AND__* | *__SEQ__*) exit 0 ;; esac
case "${cmd//&&/}" in *[\`\(\)\<\>\"\'\\\*\?\[\]\#\~\!\^\|\&]*) exit 0 ;; esac
s=${cmd//&&/ __AND__ }
s=${s//;/ __SEQ__ }
s=${s//$'\n'/ __SEQ__ }
read -ra toks <<<"$s"

declare -A vars=()
expand() { # word -> $NAME / ${NAME} をコマンド内の代入で展開して $REPLY へ。未定義・不正なら失敗
    local w=$1 out="" name
    while [[ $w =~ ^([^\$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$ ]]; do
        name=${BASH_REMATCH[3]}${BASH_REMATCH[4]}
        [ -n "${vars[$name]+x}" ] || return 1
        out+=${BASH_REMATCH[1]}${vars[$name]}
        w=${BASH_REMATCH[5]}
    done
    case "$w" in *[\$\{\}]*) return 1 ;; esac
    REPLY=$out$w
    case "$REPLY" in =*) return 1 ;; esac
}
physical() { # 絶対パス -> rm が実際に消す実体の物理パスを $REPLY へ
    local p=$1 parent base
    case "$p" in
    */) REPLY=$(realpath -m -- "$p") || return 1 ;;
    *)
        parent=${p%/*} base=${p##*/}
        case "$base" in . | ..) return 1 ;; esac
        parent=$(realpath -m -- "${parent:-/}") || return 1
        REPLY=${parent%/}/$base
        ;;
    esac
}

uid=$(id -u)
tmp_phys=$(realpath -m /tmp)
roots=("$(realpath -m "/tmp/claude-$uid")")
case "${TMPDIR:-}" in /?*) roots+=("$(realpath -m -- "$TMPDIR")") ;; esac
if top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) &&
    git -C "$top" check-ignore -q tmp-agents 2>/dev/null; then
    roots+=("$(realpath -m -- "$top/tmp-agents")")
fi
in_scratch() { # 物理パス -> いずれかの一時領域の内側か
    local r
    for r in "${roots[@]}"; do
        [ "$r" != / ] || continue
        case "$1" in "$r"/?*) return 0 ;; esac
    done
    [[ ${1#"$tmp_phys"} != "$1" && ${1#"$tmp_phys"} =~ ^/nix-shell\.[^/]+/claude-$uid/.+ ]]
}

dir=$cwd after_cd=0 count=0 seg=()
run_segment() { # seg の 1 セグメントを解釈する。扱えなければ失敗
    [ "${#seg[@]}" -gt 0 ] || return 0
    local w t ends=0
    case "${seg[0]}" in
    cd)
        [ "${#seg[@]}" -eq 2 ] && expand "${seg[1]}" || return 1
        case "$REPLY" in /*) ;; . | .. | ./* | ../*) REPLY=$dir/$REPLY ;; *) return 1 ;; esac
        dir=$(realpath -m -s -- "$REPLY") || return 1
        after_cd=1
        ;;
    rm)
        t=0
        for w in "${seg[@]:1}"; do
            if [ "$ends" -eq 0 ]; then
                case "$w" in
                --) ends=1 && continue ;;
                --recursive | --force | --verbose | --dir) continue ;;
                -*) [[ $w =~ ^-[rRfvdiI]+$ ]] && continue || return 1 ;;
                esac
            fi
            expand "$w" || return 1
            case "$REPLY" in '') return 1 ;; /*) ;; *) REPLY=$dir/$REPLY ;; esac
            physical "$REPLY" && in_scratch "$REPLY" || return 1
            t=$((t + 1))
        done
        [ "$t" -gt 0 ] || return 1
        count=$((count + t))
        ;;
    *)
        [ "${#seg[@]}" -eq 1 ] && [[ ${seg[0]} =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 1
        w=${BASH_REMATCH[1]}
        case "$w" in IFS | PATH | CDPATH | path | cdpath) return 1 ;; esac
        expand "${BASH_REMATCH[2]}" || return 1
        vars[$w]=$REPLY
        ;;
    esac
}
for t in "${toks[@]}" __END__; do
    case "$t" in
    __AND__ | __SEQ__ | __END__)
        run_segment || exit 0
        [ "$t" = __SEQ__ ] && [ "$after_cd" -eq 1 ] && exit 0
        seg=()
        ;;
    *) seg+=("$t") ;;
    esac
done
[ "$count" -gt 0 ] || exit 0

echo "rm の対象 $count 件が全て一時領域の内側"
