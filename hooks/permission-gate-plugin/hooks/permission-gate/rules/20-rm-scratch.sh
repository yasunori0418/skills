#!/usr/bin/env bash
# rules/20-rm-scratch.sh — 対象が一時領域だけの rm を allow する規則(契約は main.sh 参照)。
# 次を全て満たすときだけ理由を 1 行出す。1 つでも外れれば無出力(通常のダイアログに任せる)で、
# 外れた段を fd 3 へ 1 行書く:
#   - tool_name が Bash で、コマンドが `;` / `&&` / `||` / 改行で区切った次のセグメントだけから成る
#     (rm / rmdir を 1 個以上含む。置換・引用符・glob・`|` / `&` は含まない。リダイレクトは語として
#     独立したリテラルの 2>/dev/null / 2>&1 だけを許し、判定の前に取り除く):
#       NAME=value(1 語の単純代入)/ cd <パス> / rm [-rRfvdiI | 長オプション] [--] <対象…> /
#       rmdir [-v | --verbose | --ignore-fail-on-non-empty] [--] <対象…> /
#       確認用の読み取り: ls [オプション] [パス…] / echo <リテラル…> / printf <リテラル…>(- 始まりを除く)/
#       git status [--short]
#     `||` の右辺には確認用の echo / printf だけを置ける(`ls … || echo deleted` の形)。
#     これ以外の処理(git push・curl・wget・git log / diff を含む)があれば扱わない。実シェルは zsh のこともあるので
#     ^(EXTENDED_GLOB)と語頭の =(EQUALS 展開)も扱わず、解決を変える IFS / PATH / CDPATH
#     (zsh の path / cdpath)/ PWD / OLDPWD への代入と、/ ./ ../ で始まらない cd(CDPATH で
#     解決される)・論理解決と物理解決で行き先が変わる cd も扱わない
#   - $NAME / ${NAME} は同一コマンド内の単純代入だけで解決する(環境の変数は未定義扱い)
#   - cd は以降のセグメントの基準ディレクトリを変える。cd が失敗しても後続が走らないよう、
#     cd 以降の区切りは && に限る(; / || は扱わない)
#   - 全対象が一時領域の内側(領域そのものは不可): /tmp/**、/var/tmp/**、$TMPDIR/**、
#     macOS の DARWIN_USER_TEMP_DIR/**、cwd のリポジトリ直下 tmp-agents/**
#     (macOS の /tmp・/var/tmp は /private 配下への symlink だが、物理パスで比べるので同じに扱う)
#     (`git check-ignore` を通るときのみ)。比較は物理パスで行い、対象は親ディレクトリを
#     解決して末尾要素を保持する(末尾 / なら全体を解決)ので、symlink 越しの削除は外れる
# 意図して扱わない書き方(受理範囲を広げない理由):
#   - 引用符("…" / '…'): 空白・日本語・$ を含むパスで要るが、正しく扱うにはトークナイザを
#     作り直す必要があり、回収できる件数に見合わない
#   - rm 引数の glob: 展開結果が静的に決まらず、対象が一時領域に収まるか判定できない
#   - cd X; / cd X || …: cd が失敗すると後続が元のディレクトリで走る
#   - コマンド外で定義された変数($PPID・$PWD・$HOME 等): hook の環境と実行時の環境が一致しない
#   - パイプ・バックグラウンド・heredoc・rm 以外の書き込みや実行: PermissionRequest の allow は
#     コマンド全体に効くため、rm に便乗した処理まで通る。一時領域の rm は単独の Bash 呼び出しに分ける
set -uo pipefail

# 外れた理由を fd 3 に 1 行書いて沈黙する(契約は main.sh 参照。fd 3 が閉じていれば書かない)
miss() {
    printf '%s\n' "$1" 2>/dev/null >&3
    exit 0
}
input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = Bash ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cmd" ] || exit 0
case "$cwd" in /*) ;; *) miss "cwd が絶対パスでない" ;; esac
# GNU の realpath(-m / -s)が要る。macOS 標準の BSD realpath は -m を持たないので、
# coreutils の grealpath を優先し、どちらも使えなければ扱わない
rp=""
for c in grealpath realpath; do
    command -v "$c" >/dev/null && "$c" -m / >/dev/null 2>&1 && rp=$c && break
done
[ -n "$rp" ] || miss "GNU の realpath が無い"

case "$cmd" in *__AND__* | *__SEQ__* | *__OR__*) miss "内部の区切りトークンを含む" ;; esac
# 確認時の stderr の破棄(語として独立したリテラルの 2>/dev/null・2>&1)は削除の対象を変えないので、
# 剥がしてから判定する。&・| が続く形や語に繋がった形は剥がさず、下の禁止文字で落とす
while [[ $cmd =~ ^(.*[[:space:]])2\>(/dev/null|\&1)([[:space:]\;].*|\&\&.*|\|\|.*)?$ ]]; do
    cmd="${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"
done
# 置換・引用符・glob・リダイレクト・コメント・チルダ・単独の & | を含むものは扱わない
s=${cmd//&&/}
s=${s//||/}
case "$s" in
*[\`\(\)\<\>\"\'\\\*\?\[\]\#\~\!\^\|\&]*)
    miss "禁止文字を含む: $(printf '%s' "$s" | grep -o '[][`()<>"'\''\\*?#~!^|&]' | head -n 1)"
    ;;
esac
s=${cmd//&&/ __AND__ }
s=${s//||/ __OR__ }
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
ldir=$cwd dir=$("$rp" -m -- "$cwd") || miss "cwd を解決できない"
after_cd=0 count=0 fallback=0 seg=() why=""
run_segment() { # seg の 1 セグメントを解釈する。扱えなければ失敗し、理由を why に残す
    [ "${#seg[@]}" -gt 0 ] || return 0
    local w t ends=0
    # || の右辺は失敗時の確認用の出力(echo / printf)に限る
    why="|| の右辺が echo / printf でない: ${seg[0]}"
    [ "$fallback" -eq 0 ] || case "${seg[0]}" in echo | printf) ;; *) return 1 ;; esac
    case "${seg[0]}" in
    cd)
        why="解決できない cd: ${seg[*]}"
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
    rm | rmdir)
        t=0
        for w in "${seg[@]:1}"; do
            why="未対応の ${seg[0]} のオプション: $w"
            if [ "$ends" -eq 0 ]; then
                case "${seg[0]}:$w" in
                *:--) ends=1 && continue ;;
                rm:--recursive | rm:--force | rm:--verbose | rm:--dir) continue ;;
                rmdir:--verbose | rmdir:--ignore-fail-on-non-empty) continue ;;
                rm:-*) [[ $w =~ ^-[rRfvdiI]+$ ]] && continue || return 1 ;;
                # -p は親を辿って領域そのもの(tmp-agents 等)まで消しうるので扱わない
                rmdir:-*) [ "$w" = -v ] && continue || return 1 ;;
                esac
            fi
            why="解決できない対象: $w"
            expand "$w" || return 1
            case "$REPLY" in '') return 1 ;; /*) ;; *) REPLY=$dir/$REPLY ;; esac
            why="一時領域の外(または領域そのもの): $w"
            physical "$REPLY" && in_scratch "$REPLY" || return 1
            t=$((t + 1))
        done
        why="${seg[0]} の対象が無い"
        [ "$t" -gt 0 ] || return 1
        count=$((count + t))
        ;;
    ls) # 確認用の読み取り。対象は領域を問わないが、静的に解決できるパスと短い/長いオプションに限る
        why="扱えない ls: ${seg[*]}"
        for w in "${seg[@]:1}"; do
            case "$w" in -*) [[ $w =~ ^(-[A-Za-z0-9]+|--[a-z][a-z-]*)$ ]] && continue || return 1 ;; esac
            expand "$w" || return 1
        done
        ;;
    echo | printf) # 確認用の出力。引数はリテラルに限る(printf -v は変数への代入になるので - 始まりを扱わない)
        why="扱えない ${seg[0]}: ${seg[*]}"
        [ "${seg[0]}" = echo ] || [ "${#seg[@]}" -gt 1 ] || return 1
        for w in "${seg[@]:1}"; do
            case "$w" in *[\$\{\}]* | =*) return 1 ;; esac
            [ "${seg[0]}" = echo ] || case "$w" in -*) return 1 ;; esac
        done
        ;;
    git) # 確認用の git status だけ(他のサブコマンドは pager・外部 diff・textconv を起動しうる)
        why="git status 以外の git: ${seg[*]}"
        case "${seg[*]}" in "git status" | "git status --short") ;; *) return 1 ;; esac
        ;;
    *)
        why="未対応のコマンド: ${seg[0]}"
        [ "${#seg[@]}" -eq 1 ] && [[ ${seg[0]} =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || return 1
        w=${BASH_REMATCH[1]}
        why="扱えない代入: ${seg[0]}"
        case "$w" in IFS | PATH | CDPATH | path | cdpath | PWD | OLDPWD) return 1 ;; esac
        expand "${BASH_REMATCH[2]}" || return 1
        vars[$w]=$REPLY
        ;;
    esac
}
for t in "${toks[@]}" __END__; do
    case "$t" in
    __AND__ | __SEQ__ | __OR__ | __END__)
        run_segment || miss "$why"
        # cd が失敗しても後続が走る区切り(; / ||)は cd 以降に置けない
        case "$t" in __SEQ__ | __OR__) [ "$after_cd" -eq 0 ] || miss "cd の後の区切りが && でない" ;; esac
        fallback=0
        [ "$t" != __OR__ ] || fallback=1
        seg=()
        ;;
    *) seg+=("$t") ;;
    esac
done
[ "$count" -gt 0 ] || miss "rm / rmdir を含まない"

echo "rm の対象 $count 件が全て一時領域の内側"
