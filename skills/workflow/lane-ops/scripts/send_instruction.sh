#!/usr/bin/env bash
# send_instruction.sh — 親 → ワーカーへの指示送信（ファイル経由）。
#
# 使い方: send_instruction.sh <target-agent|pane-id> <instruction-file>
#
# 指示本文を必ずファイルから読む理由:
#   - コマンド文字列に指示リテラル（`git rebase` 等）が載らないため、
#     Bash コマンドを検査する guard hook の誤爆が構造的に起きない
#   - 長文・複数行でもクォート事故なく 1 引数で届く（herdr agent prompt が
#     bracketed paste を含めて原子的に送信する）
#   - 送った指示がファイルとして残り、監査・再送に使える
set -eu

usage() {
    echo "usage: send_instruction.sh <target-agent|pane-id> <instruction-file>" >&2
    exit 2
}

[ $# -eq 2 ] || usage
target="$1"
file="$2"

[ -s "$file" ] || {
    echo "ERROR: 指示ファイルが無い、または空: $file" >&2
    exit 1
}

herdr agent prompt "$target" "$(cat "$file")"
