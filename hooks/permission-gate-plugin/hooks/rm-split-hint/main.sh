#!/usr/bin/env bash
# rm-split-hint/main.sh — PreToolUse hook(matcher: Bash)。呼び出しは止めず、additionalContext で
# Claude に rm の書き方を促すだけの hook。
#
# 動機: permission-gate の rules/20-rm-scratch.sh(一時領域の rm の自動承認)は、PermissionRequest の
#   allow がコマンド全体に効くため rm 以外の処理の混在を受理しない。ところが実運用の rm は他の処理と
#   1 コマンドに混ぜて書かれることがほとんどで、規則は導入後一度も発火していなかった。規則を広げる
#   代わりに、書き方(rm を単独の Bash 呼び出しに分ける)を Claude 側へ返す。
#
# 判定: コマンドの区切り(行頭・; & | ( `)の直後に rm があり、20-rm-scratch が allow しないときに、
#   規則が fd 3 に書いた外れた理由を添えて注意を返す。ただし次の理由では沈黙する(書き方を変えても
#   自動承認に乗らないので、注意しても雑音になる):
#     - 一時領域の外(または領域そのもの)の対象を含む
#     - rm / rmdir を含まない(git rm 等)
#   additionalContext はツールの結果と一緒に届くので、そのコマンドのダイアログは避けられない。
#   次回以降の書き方を変えさせる効果だけを持つ。どの失敗でも exit 0 で何も出力しない。
set -uo pipefail
export LC_ALL=C

DIR=$(cd "$(dirname "$0")" && pwd)
RULE="$DIR/../permission-gate/rules/20-rm-scratch.sh"
[ -f "$RULE" ] || exit 0
input=$(cat)
cmd=$(printf '%s' "$input" | jq -r 'select(.tool_name == "Bash") | .tool_input.command // empty' 2>/dev/null) || exit 0
[[ $cmd =~ (^|[$'\n'\;\&\|\(\`])[[:blank:]]*rm([[:space:]]|$) ]] || exit 0

out=$(printf '%s' "$input" | bash "$RULE" 3>&1 >/dev/null 2>/dev/null) || exit 0
why=${out%%$'\n'*}
[ -n "$why" ] || exit 0
case "$why" in "一時領域の外"* | "rm / rmdir を含まない") exit 0 ;; esac

msg="permission-gate: この rm は一時領域の自動承認に乗りません(理由: $why)。"
msg+="対象が一時領域(scratchpad・/tmp・gitignore 済みの tmp-agents 等)なら、次回から rm を他の処理と"
msg+="混ぜずに単独の Bash 呼び出しにしてください。対象は絶対パスか同じコマンド内の単純な代入で書き、"
msg+="引用符・glob・パイプ・バックグラウンド実行を使わないこと(確認用の ls / echo / git status と"
msg+=" 2>/dev/null・|| echo は並べてよい)。"
jq -cn --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
exit 0
