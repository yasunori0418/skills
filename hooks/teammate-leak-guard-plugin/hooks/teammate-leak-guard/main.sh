#!/usr/bin/env bash
# teammate-leak-guard/main.sh — Stop hook。
# stdin JSON の background_tasks から稼働中のサブエージェント/チームメイトを抽出し、
# 残っていれば decision: "block" で「使い終わったものは TaskStop で停止せよ」と伝える。
#
# 出力形式に decision/reason を使う理由（hookSpecificOutput.additionalContext ではなく）:
#   公式仕様では additionalContext のほうが「hook は設計どおり動いた」ことを示す
#   穏当な形だが、cchook 経由で運用すると Stop イベントの hookSpecificOutput は
#   "Field 'hookSpecificOutput' is not supported for Stop hooks" として握り潰され、
#   {"continue": true} に置き換えられて Claude まで届かない（実測）。
#   decision/reason は cchook がそのまま素通しするため、両経路（plugin 直・cchook）で
#   同じように機能するこちらを採る。継続時のループ保護（stop_hook_active・8 連続上限）は
#   どちらの形式でも同じく効く。
#
# 背景: サブエージェントが送る idle_notification（idleReason: "available"）は
# 「終了した」ではなく「空いて待機中」の意味で、明示的に停止しない限り滞留し続ける。
# 親がこれを完了通知と誤解して放置し、イテレーションのたびに残骸が累積する事故を防ぐ。
#
# fail-open 設計（sudo-guard の無条件 deny とは逆向き）:
#   jq が無い・JSON が壊れている・background_tasks が空/欠落のいずれでも黙って exit 0。
#   Stop hook は全ターンの終端で発火するため、誤作動のコストが高い。
#
# 対象は type が subagent / teammate のものだけに絞る。shell（run_in_background の
# Bash 等）・monitor・cron は「停止し忘れ」の概念が無い、または別の運用対象なので触れない。
#
# background_tasks は Claude Code v2.1.145 以降で Stop hook 入力に含まれる。
# それ以前のバージョンでは配列が存在せず、この hook は常に沈黙する（害は無い）。
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

# stop_hook_active が true = 既に stop hook 起因で継続中。ここで再度 additionalContext を
# 返すと同じ指摘を繰り返して 8 連続上限まで空転するため、2 回目以降は黙って通す。
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
[ "$active" = "true" ] && exit 0

# 稼働中のサブエージェント/チームメイトを "  - <説明> (<type>)" の行に整形する。
# 説明は description → agent_type → id の順に取れたものを使う（description は
# 最大 1000 文字で切り詰められうるので、行が膨らまないよう 80 文字で丸める）。
leaked=$(printf '%s' "$input" | jq -r '
    (.background_tasks // [])
    | map(select(.type == "subagent" or .type == "teammate"))
    | map("  - " + ((.description // .agent_type // .id // "(unnamed)") | .[0:80]) + " (" + (.type // "?") + ")")
    | .[]
' 2>/dev/null || true)

[ -n "$leaked" ] || exit 0

count=$(printf '%s\n' "$leaked" | grep -c '^' || true)

reason="稼働中のサブエージェント/チームメイトが ${count} 体残っています:
${leaked}
これらは idle（待機中）であって終了していません。成果物を回収済みで追加依頼が無いものは TaskStop で停止してください。まだ使う予定があるものは残して構いません。停止の要否を判断し、必要な TaskStop を済ませてから応答を終えてください。"

jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
