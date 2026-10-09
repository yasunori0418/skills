#!/usr/bin/env bash
# Verifies permission-gate の notify.sh(dispatcher が決定後に hook JSON + decision を渡す):
#   - LANE_OPS_PARENT・LANE_OPS_TASK・LANE_OPS_REPORT_SH が全て設定 -> report.sh に
#     <parent> <task> ダイアログ待ち "<tool_name>: <command 先頭 120 字>" を渡し、デスクトップ通知はしない
#   - 1 つでも欠ける -> dunstify / notify-send / osascript のうち存在するもので通知
#   - 通知コマンドが 1 つも無い -> 沈黙・exit 0
#   - report.sh が失敗しても・不正な入力でも exit 0
#   - decision が allow -> 報告も通知もしない
# 通知コマンドは最小 PATH 上のモックで置き換え、呼び出し引数をファイルへ記録して検証する。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NOTIFY="$SCRIPT_DIR/../notify.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# 実機の dunstify 等に当たらないよう、モックと必要なコマンドだけの PATH に置き換える
MOCK="$TMP/mock" BASE="$TMP/base" REC="$TMP/rec"
mkdir -p "$MOCK" "$BASE" "$REC"
for c in bash cat jq; do ln -s "$(command -v "$c")" "$BASE/$c"; done
# モックは実行時生成のため patchShebangs が及ばない。nix sandbox にも存在する /bin/sh で書く
for c in dunstify notify-send osascript; do
    printf '#!/bin/sh\nprintf "%%s|" "$@" >>"%s/%s"\n' "$REC" "$c" >"$TMP/$c"
done
printf '#!/bin/sh\nprintf "%%s|" "$@" >>"%s/report"\n' "$REC" >"$TMP/report.sh"
printf '#!/bin/sh\nexit 1\n' >"$TMP/report-fail.sh"
chmod +x "$TMP/dunstify" "$TMP/notify-send" "$TMP/osascript" "$TMP/report.sh" "$TMP/report-fail.sh"

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
input() { # decision tool_name command
    jq -cn --arg d "$1" --arg t "$2" --arg c "$3" \
        '{session_id: "s1", tool_name: $t, tool_input: {command: $c}, decision: $d}'
}
# run <mocks(空白区切り)> <stdin> [env 代入...] -> stdout + rc。呼び出し記録は毎回消す
run() {
    local mocks=$1 in=$2 m out rc=0
    shift 2
    rm -f "$REC"/* "$MOCK"/*
    for m in $mocks; do cp "$TMP/$m" "$MOCK/$m"; done
    out=$(printf '%s' "$in" | env -u LANE_OPS_PARENT -u LANE_OPS_TASK -u LANE_OPS_REPORT_SH \
        PATH="$MOCK:$BASE" "$@" "$BASE/bash" "$NOTIFY" 2>&1) || rc=$?
    printf '%src=%s' "$out" "$rc"
}
rec() { [ -f "$REC/$1" ] && cat "$REC/$1" || echo none; }
LANE=(LANE_OPS_PARENT=p1 LANE_OPS_TASK=T1 LANE_OPS_REPORT_SH="$TMP/report.sh")

# レーン: report.sh が引数を受け取り、デスクトップ通知はしない
check "lane-rc" "rc=0" "$(run notify-send "$(input prompt Bash 'rm -rf x')" "${LANE[@]}")"
check "lane-args" "p1|T1|ダイアログ待ち|Bash: rm -rf x|" "$(rec report)"
check "lane-no-desktop" "none" "$(rec notify-send)"

# command は先頭 120 字(文字単位)
LONG=$(printf 'あ%.0s' $(seq 1 200))
run "" "$(input prompt Bash "$LONG")" "${LANE[@]}" >/dev/null
check "lane-truncated" "Bash: $(printf 'あ%.0s' $(seq 1 120))|" "$(rec report | cut -d'|' -f4-)"

# report.sh が失敗しても exit 0
check "lane-report-fail" "rc=0" \
    "$(run "" "$(input prompt Bash 'rm x')" LANE_OPS_PARENT=p1 LANE_OPS_TASK=T1 \
        LANE_OPS_REPORT_SH="$TMP/report-fail.sh")"

# 変数が 1 つ欠ける -> デスクトップ通知
for i in 0 1 2; do
    PARTIAL=("${LANE[@]}")
    unset "PARTIAL[$i]"
    run notify-send "$(input prompt Bash 'rm x')" "${PARTIAL[@]}" >/dev/null
    check "partial-$i" "none claude-code|Bash: rm x|" "$(rec report) $(rec notify-send)"
done

# 通常セッション: notify-send が呼ばれる / osascript しか無ければ osascript
run notify-send "$(input prompt Bash 'curl x')" >/dev/null
check "desktop-notify-send" "claude-code|Bash: curl x|" "$(rec notify-send)"
run osascript "$(input prompt Bash 'curl x')" >/dev/null
check "desktop-osascript" "yes" "$(rec osascript | grep -q '|Bash: curl x|$' && echo yes || echo no)"
# 優先順は dunstify > notify-send > osascript
run "dunstify notify-send osascript" "$(input prompt Bash 'curl x')" >/dev/null
check "prefer-dunstify" "claude-code|Bash: curl x| none none" "$(rec dunstify) $(rec notify-send) $(rec osascript)"
run "notify-send osascript" "$(input prompt Bash 'curl x')" >/dev/null
check "prefer-notify-send" "claude-code|Bash: curl x| none" "$(rec notify-send) $(rec osascript)"

# command の無い tool(Write 等)-> tool 名だけの本文
run notify-send '{"tool_name":"Write","tool_input":{"file_path":"/etc/hosts"},"decision":"prompt"}' >/dev/null
check "no-command" "claude-code|Write: |" "$(rec notify-send)"

# 通知コマンドが無い -> 沈黙
check "no-notifier" "rc=0" "$(run "" "$(input prompt Bash 'curl x')")"

# allow -> 報告も通知もしない
check "allow-lane-rc" "rc=0" "$(run notify-send "$(input allow Bash 'git push')" "${LANE[@]}")"
check "allow-no-report" "none none" "$(rec report) $(rec notify-send)"
run notify-send "$(input allow Bash 'git push')" >/dev/null
check "allow-no-desktop" "none" "$(rec notify-send)"

# 不正な入力 -> exit 0・何も呼ばない
check "invalid" "rc=0 none" "$(run notify-send 'not json') $(rec notify-send)"

exit "$fail"
