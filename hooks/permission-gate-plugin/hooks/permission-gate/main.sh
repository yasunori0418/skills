#!/usr/bin/env bash
# permission-gate/main.sh — PermissionRequest hook(matcher なし。全 tool の許可ダイアログを受ける)。
# settings の ask ルールで出るダイアログの直前に呼ばれ、rules/*.sh を名前順に実行して
# 最初の allow を採用する dispatcher。どの規則も allow しなければ何も出力せず通常の
# ダイアログに任せる(PreToolUse の allow は ask ルールを上書きできないため、この hook で応答する)。
#
# 規則の契約: stdin に hook JSON を受け、allow なら理由を stdout に 1 行出す。それ以外は無出力。
#   各規則は tool_name が Bash のときだけ判定する(Bash 以外は記録のみ)。
#   allow しなかった理由(外れた段)を fd 3 に 1 行書いてよい(任意)。書かれた理由はログの misses に
#   {規則名: 理由} として残す(stdout は allow 専用のまま変えない)。
# 記録: 全入力を ${XDG_STATE_HOME:-$HOME/.local/state}/claude/permission-prompts.jsonl に 1 行追記する
#   (ts は JST、command は先頭 2000 字、has_rm はコマンドに rm という語を含むか(切り詰め前に判定)、
#   decision は allow / prompt、misses は allow しなかった規則の理由)。
#   ダイアログの最終結果(承認 / 拒否)は記録しない。PermissionRequest の入力に tool_use_id が無く、
#   PostToolUse との結び付けが session_id とコマンド文字列の照合頼みになり、同じコマンドの連続で
#   取り違えるため。
# 通知: notify.sh が実行可能なら決定後に呼ぶ(stdin に hook JSON + decision)。stdout は捨てる。
# どの失敗でもダイアログを壊さないよう、常に exit 0 で allow 以外は何も出力しない。
set -uo pipefail
export LC_ALL=C

DIR=$(cd "$(dirname "$0")" && pwd)
input=$(cat)
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0

decision=prompt rule="" reason="規則に該当せず" misses='{}'
# fd 3 の受け口。作れなければ理由の記録だけ諦める
wf=$(mktemp 2>/dev/null) || wf=""
trap '[ -z "$wf" ] || rm -f "$wf"' EXIT
for r in "$DIR"/rules/*.sh; do
    [ -f "$r" ] || continue
    [ -z "$wf" ] || : >"$wf"
    out=$(printf '%s' "$input" | bash "$r" 3>"${wf:-/dev/null}" 2>/dev/null | head -n 1) || true
    if [ -n "$out" ]; then
        decision=allow rule=$(basename "$r" .sh) reason=$out
        break
    fi
    why=""
    [ -z "$wf" ] || why=$(head -n 1 "$wf" 2>/dev/null) || why=""
    [ -z "$why" ] ||
        misses=$(jq -c --arg k "$(basename "$r" .sh)" --arg v "$why" '. + {($k): $v}' <<<"$misses" 2>/dev/null) ||
        misses='{}'
done

log_dir="${XDG_STATE_HOME:-${HOME:-}/.local/state}/claude"
ts=$(TZ=JST-9 date +%Y-%m-%dT%H:%M:%S%z)
ts="${ts%??}:${ts: -2}"
{
    mkdir -p "$log_dir" &&
        printf '%s' "$input" | jq -c --arg ts "$ts" --arg d "$decision" --arg r "$rule" --arg why "$reason" \
            --argjson m "$misses" '{
          ts: $ts,
          session_id: (.session_id // ""),
          cwd: (.cwd // ""),
          tool_name: (.tool_name // ""),
          command: ((.tool_input.command // "") | tostring | .[:2000]),
          has_rm: ((.tool_input.command // "") | tostring | test("(^|[\\s;&|(`])rm(\\s|$)")),
          decision: $d,
          rule: $r,
          reason: $why,
          misses: $m
        }' >>"$log_dir/permission-prompts.jsonl"
} 2>/dev/null || true

if [ -x "$DIR/notify.sh" ]; then
    printf '%s' "$input" | jq -c --arg d "$decision" '. + {decision: $d}' 2>/dev/null |
        "$DIR/notify.sh" >/dev/null 2>&1 || true
fi

if [ "$decision" = allow ]; then
    jq -cn '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}}}'
fi
exit 0
