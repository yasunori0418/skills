#!/usr/bin/env bash
# rules/10-push-armed.sh — arm 済みの通常 push を allow する規則(契約は main.sh 参照)。
# 次を全て満たすときだけ理由を 1 行出す。1 つでも外れれば無出力(通常のダイアログに任せる):
#   - tool_name が Bash で、コマンドが `git push …` 単独か `cd <リテラルのパス> && git push …`
#     (; | & 改行・置換・リダイレクト・引用符・他の ask 対象 rm / curl / wget を含まない)
#   - push のオプションは -u / --set-upstream / --no-verify / -v / -q のみ(force・delete 等は対象外)、
#     refspec は 0〜1 個で送り元が現在のブランチ(HEAD)、+ 付き・削除(:dst)は対象外
#   - 判定ディレクトリ(cd 先、無ければ cwd)の `git rev-parse --git-path push-flow.armed` が
#     `<epoch> <ttl秒> <branch>` で期限内、かつ branch が現在のブランチ・push 先と一致
#     (期限切れの marker は削除する)
#   - push 先が default branch(origin/HEAD、解決できなければ main / master)でない
set -uo pipefail

input=$(cat)
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = Bash ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
dir=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cmd" ] || exit 0

# 区切り・置換・リダイレクト・引用符を含むものは扱わない(&& は cd 前置の 1 個だけ許す)
case "$cmd" in *$'\n'*) exit 0 ;; esac
case "${cmd//&&/}" in *[\;\|\&\`\$\<\>\(\)\{\}\"\'\\]*) exit 0 ;; esac
seg=$cmd
case "$cmd" in
*'&&'*'&&'*) exit 0 ;;
*'&&'*)
    read -ra pre <<<"${cmd%%&&*}"
    [ "${#pre[@]}" -eq 2 ] && [ "${pre[0]}" = cd ] || exit 0
    case "${pre[1]}" in
    '~') target=${HOME:-} ;;
    '~/'*) target=${HOME:-}/${pre[1]#\~/} ;;
    /*) target=${pre[1]} ;;
    *) target=$dir/${pre[1]} ;;
    esac
    dir=$target
    seg=${cmd#*&&}
    ;;
esac
[ -n "$dir" ] && [ -d "$dir" ] || exit 0

read -ra w <<<"$seg"
[ "${#w[@]}" -ge 2 ] && [ "${w[0]}" = git ] && [ "${w[1]}" = push ] || exit 0
pos=()
for a in "${w[@]:2}"; do
    case "$a" in
    rm | curl | wget | */rm | */curl | */wget) exit 0 ;;
    -u | --set-upstream | --no-verify | -v | --verbose | -q | --quiet) ;;
    -*) exit 0 ;;
    *) pos+=("$a") ;;
    esac
done
[ "${#pos[@]}" -le 2 ] || exit 0

current=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null) || exit 0
# 宛先を設定で書き換えうる構成(push.default が simple / current 以外、remote.*.push あり)は
# コマンドから push 先を確定できないので扱わない
case "$(git -C "$dir" config push.default 2>/dev/null || echo simple)" in
simple | current) ;;
*) exit 0 ;;
esac
git -C "$dir" config --get-regexp '^remote\..*\.push$' >/dev/null 2>&1 && exit 0
dst=$current
if [ "${#pos[@]}" -eq 2 ]; then
    spec=${pos[1]}
    case "$spec" in +* | :*) exit 0 ;; esac
    src=${spec%%:*}
    case "$spec" in *:*) dst=${spec#*:} ;; *) dst=$spec ;; esac
    src=${src#refs/heads/} dst=${dst#refs/heads/}
    [ "$src" = HEAD ] && src=$current
    [ "$dst" = HEAD ] && dst=$current
    [ "$src" = "$current" ] || exit 0
fi

marker=$(git -C "$dir" rev-parse --git-path push-flow.armed 2>/dev/null) || exit 0
case "$marker" in /*) ;; *) marker=$dir/$marker ;; esac
[ -f "$marker" ] || exit 0
read -r epoch ttl branch _ <"$marker" || true
case "$epoch$ttl" in '' | *[!0-9]*) exit 0 ;; esac
if [ "$(date +%s)" -gt "$((epoch + ttl))" ]; then
    rm -f "$marker"
    exit 0
fi
[ "${branch:-}" = "$current" ] && [ "$dst" = "$current" ] || exit 0

if default=$(git -C "$dir" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null); then
    defaults=("${default#origin/}")
else
    defaults=(main master)
fi
for d in "${defaults[@]}"; do
    [ "$dst" = "$d" ] && exit 0
done

echo "push-flow.armed が有効($branch、期限 $((epoch + ttl)))"
