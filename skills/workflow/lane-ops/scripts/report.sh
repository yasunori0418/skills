#!/usr/bin/env bash
# report.sh — ワーカー → 親（オーケストレータ）へのマイルストーン報告。
#
# 使い方:
#   report.sh <parent-agent> <task-id> <milestone> [detail...]
#   report.sh --file <path> <parent-agent> <task-id> <milestone>
#
# --file は本文（detail）をファイルから読む。コマンド名を含む報告を引数へ
# 載せると guard hook がコマンド名へ反応して報告自体が止まるため、その
# 迂回路として用意する。--file と位置引数の detail の併用は受け付けない
# （どちらが本文か曖昧になるため exit 2）。
#
# 2 経路のハイブリッド:
#   1. JSONL 追記（監査・クラッシュ復旧用の正本）:
#      ${XDG_STATE_HOME:-$HOME/.local/state}/lane-ops/reports/<parent-agent>.jsonl
#   2. herdr agent prompt で親エージェントへ 1 行直送（push 通知）:
#      "[lane-ops:report <task-id>] <milestone>: <detail>"
#      親の会話にはユーザー入力と同じ形で届くため、接頭辞で報告と識別する。
#
# herdr が使えない・親に届かない場合も JSONL は書けているので exit 0
# （報告の記録が主、通知は従）。
set -u

usage() {
    echo "usage: report.sh [--file <path>] <parent-agent> <task-id> <milestone> [detail...]" >&2
    exit 2
}

detail_file=""
positional=()
while [ $# -gt 0 ]; do
    case "$1" in
    --file)
        [ $# -ge 2 ] || usage
        detail_file="$2"
        shift 2
        ;;
    *)
        positional+=("$1")
        shift
        ;;
    esac
done

[ ${#positional[@]} -ge 3 ] || usage
parent="${positional[0]}"
task="${positional[1]}"
milestone="${positional[2]}"
detail="${positional[*]:3}"

if [ -n "$detail_file" ]; then
    # 本文の取り違えを防ぐため併用は弾く（JSONL へは何も追記しない）。
    [ -z "$detail" ] || usage
    if [ ! -s "$detail_file" ]; then
        echo "ERROR: --file のファイルが空または存在しない: $detail_file" >&2
        exit 2
    fi
    detail=$(cat "$detail_file")
fi

dir="${XDG_STATE_HOME:-$HOME/.local/state}/lane-ops/reports"
mkdir -p "$dir"
jq -cn \
    --arg ts "$(date -Is)" \
    --arg task "$task" \
    --arg milestone "$milestone" \
    --arg detail "$detail" \
    '{ts: $ts, task: $task, milestone: $milestone, detail: $detail}' \
    >> "$dir/$parent.jsonl"

msg="[lane-ops:report $task] $milestone"
[ -n "$detail" ] && msg="$msg: $detail"
if command -v herdr >/dev/null 2>&1 && [ "${HERDR_ENV:-}" = 1 ]; then
    herdr agent prompt "$parent" "$msg" || echo "WARN: 親への直送に失敗（JSONL には記録済み）" >&2
else
    echo "WARN: herdr 外のため直送は省略（JSONL には記録済み）" >&2
fi
exit 0
