#!/usr/bin/env bash
# rules/20-rm-scratch.sh — 対象が一時領域だけの rm を allow する規則(契約は main.sh 参照)。
# 次を全て満たすときだけ理由を 1 行出す。1 つでも外れれば無出力(通常のダイアログに任せる):
#   - tool_name が Bash で、コマンドが `;` / `&&` / 改行で区切った次のセグメントだけから成る
#     (rm を 1 個以上含む。置換・引用符・glob・リダイレクト・`||` / `|` / `&` は含まない):
#       NAME=value(1 語の単純代入)/ cd <パス> / rm [-rRfvdiI | 長オプション] [--] <対象…>
#     rm 以外の処理(git push・curl・wget を含む)があれば扱わない。実シェルは zsh のこともあるので
#     ^(EXTENDED_GLOB)と語頭の =(EQUALS 展開)も扱わず、解決を変える IFS / PATH / CDPATH
#     (zsh の path / cdpath)/ PWD / OLDPWD への代入と、/ ./ ../ で始まらない cd(CDPATH で
#     解決される)・論理解決と物理解決で行き先が変わる cd も扱わない
#   - $NAME / ${NAME} は同一コマンド内の単純代入だけで解決する(環境の変数は未定義扱い)
#   - cd は以降のセグメントの基準ディレクトリを変える。cd が失敗しても後続が走らないよう、
#     cd 以降の区切りは && に限る
#   - 全対象が一時領域の内側(領域そのものは不可): /tmp/**、/var/tmp/**、$TMPDIR/**、
#     macOS の DARWIN_USER_TEMP_DIR/**、cwd のリポジトリ直下 tmp-agents/**
#     (macOS の /tmp・/var/tmp は /private 配下への symlink だが、物理パスで比べるので同じに扱う)
#     (`git check-ignore` を通るときのみ)。比較は物理パスで行い、対象は親ディレクトリを
#     解決して末尾要素を保持する(末尾 / なら全体を解決)ので、symlink 越しの削除は外れる
set -uo pipefail

input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = Bash ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cmd" ] || exit 0
case "$cwd" in /*) ;; *) exit 0 ;; esac
# GNU の realpath(-m / -s)が要る。macOS 標準の BSD realpath は -m を持たないので、
# coreutils の grealpath を優先し、どちらも使えなければ扱わない
rp=""
for c in grealpath realpath; do
    command -v "$c" >/dev/null && "$c" -m / >/dev/null 2>&1 && rp=$c && break
done
[ -n "$rp" ] || exit 0

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
    */) REPLY=$("$rp" -m -- "$p") || return 1 ;;
    *)
        parent=${p%/*} base=${p##*/}
        case "$base" in . | ..) return 1 ;; esac
        parent=$("$rp" -m -- "${parent:-/}") || return 1
        REPLY=${parent%/}/$base
        ;;
    esac
}

roots=("$("$rp" -m /tmp)" "$("$rp" -m /var/tmp)")
if [[ ${TMPDIR:-} == /?* ]] && tmpdir=$("$rp" -m -- "$TMPDIR"); then
    roots+=("$tmpdir")
fi
# macOS の利用者ごとの一時ディレクトリ(/var/folders/…/T/)。hook に TMPDIR が渡らなくても拾う
if darwin_tmp=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) && [[ $darwin_tmp == /?* ]]; then
    roots+=("$("$rp" -m -- "$darwin_tmp")")
fi
if top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) &&
    git -C "$top" check-ignore -q tmp-agents 2>/dev/null; then
    roots+=("$("$rp" -m -- "$top/tmp-agents")")
fi
in_scratch() { # 物理パス -> いずれかの一時領域の内側か
    local r
    for r in "${roots[@]}"; do
        [ "$r" != / ] || continue
        case "$1" in "$r"/?*) return 0 ;; esac
    done
    return 1
}

# 基準ディレクトリは論理(cd -L が辿る)と物理(rm の相対パスを kernel が解決する)の両方を持つ
ldir=$cwd dir=$("$rp" -m -- "$cwd") || exit 0
after_cd=0 count=0 seg=()
run_segment() { # seg の 1 セグメントを解釈する。扱えなければ失敗
    [ "${#seg[@]}" -gt 0 ] || return 0
    local w t ends=0
    case "${seg[0]}" in
    cd)
        [ "${#seg[@]}" -eq 2 ] && expand "${seg[1]}" || return 1
        case "$REPLY" in
        /*) t=$REPLY w=$REPLY ;;
        . | .. | ./* | ../*) t=$ldir/$REPLY w=$dir/$REPLY ;;
        *) return 1 ;;
        esac
        # 論理解決(cd -L)と物理解決(set -P・zsh の CHASE_DOTS)で行き先が変わるものは扱わない
        t=$("$rp" -m -s -- "$t") && w=$("$rp" -m -- "$w") || return 1
        [ "$("$rp" -m -- "$t")" = "$w" ] || return 1
        ldir=$t dir=$w
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
        case "$w" in IFS | PATH | CDPATH | path | cdpath | PWD | OLDPWD) return 1 ;; esac
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
