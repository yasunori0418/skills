#!/usr/bin/env bash
# report.sh — ワーカー → 親（オーケストレータ）へのマイルストーン報告。
#
# 使い方: report.sh <parent-agent> <task-id> <milestone> [detail...]
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
    echo "usage: report.sh <parent-agent> <task-id> <milestone> [detail...]" >&2
    exit 2
}

[ $# -ge 3 ] || usage
parent="$1"
task="$2"
milestone="$3"
shift 3
detail="$*"

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
