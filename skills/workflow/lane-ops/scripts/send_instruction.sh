#!/usr/bin/env bash
# send_instruction.sh — 親 → ワーカーへの指示送信（ファイル経由）。
#
# 使い方: send_instruction.sh [--force] <target-agent|pane-id> <instruction-file>
#
# 指示本文を必ずファイルから読む理由:
#   - コマンド文字列に指示リテラル（`git rebase` 等）が載らないため、
#     Bash コマンドを検査する guard hook の誤爆が構造的に起きない
#   - 長文・複数行でもクォート事故なく 1 引数で届く（herdr agent prompt が
#     bracketed paste を含めて原子的に送信する）
#   - 送った指示がファイルとして残り、監査・再送に使える
#
# blocked ガード: AskUserQuestion 等のダイアログ表示中の pane へ本文つきで
# 送信すると、本文は入力されず**末尾の Enter がハイライト中の選択肢（先頭の
# 推奨案）を確定**してしまう（herdr 0.8.0 で実証。agent prompt は blocked でも
# agent_prompted を返して成功を装う）。送信前に agent_status を確認し blocked
# なら中断する。ダイアログへの応答手順は SKILL.md の運用ループを参照。
# 分かった上で流し込むときだけ --force。
set -eu

usage() {
    echo "usage: send_instruction.sh [--force] <target-agent|pane-id> <instruction-file>" >&2
    exit 2
}

force=0
if [ "${1:-}" = "--force" ]; then
    force=1
    shift
fi

[ $# -eq 2 ] || usage
target="$1"
file="$2"

[ -s "$file" ] || {
    echo "ERROR: 指示ファイルが無い、または空: $file" >&2
    exit 1
}

status=$(herdr agent get "$target" | jq -r '.result.agent.agent_status // empty')
if [ "$force" -ne 1 ] && [ "$status" = "blocked" ]; then
    {
        echo "ERROR: $target は blocked（ダイアログ表示中）。本文つき送信は末尾の Enter が"
        echo "ハイライト中の選択肢を誤確定するため中断した。herdr agent read で内容を確認し、"
        echo "提示選択肢で足りるなら send-keys で応答、自由記述が要るなら Esc でダイアログを"
        echo "閉じてから再実行する（承知の上で流し込む場合のみ --force）。"
    } >&2
    exit 3
fi

herdr agent prompt "$target" "$(cat "$file")"
