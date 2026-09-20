#!/usr/bin/env bash
# review-aggregator の PreToolUse hook: Bash の書き込みを統合報告の出力先だけに限定する。
# 拒否リスト方式: ファイルへのリダイレクトは basename が review-converge-round-<数字>.md の
# ときだけ通し、書き込み・ビルド系コマンド(tee / cp / mv / rm / go / cargo / npm / make /
# nix build)は exit 2 でブロック(stderr がエージェントに返る)。それ以外は通す
# (diff-review スキルの実行に要る uv / python3 / git / 各スクリプトを塞がないため)。
set -euo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0

deny() {
    echo "Blocked (review-aggregator can only write the round report): $1" >&2
    exit 2
}

# stderr の /dev/null 捨てと 2>&1 は書き込みではないので先に落とす
STRIPPED=$(printf '%s' "$COMMAND" | sed -E 's#[0-9]*>>?[[:space:]]*(&[0-9]+|/dev/null)##g')

# 残ったリダイレクトの出力先を 1 つずつ検査する(> / >> / >| のいずれも対象)
REPORT_RE='^review-converge-round-[0-9]+\.md$'
while IFS= read -r target; do
    [[ -z "$target" ]] && continue
    if ! [[ "$(basename -- "$target")" =~ $REPORT_RE ]]; then
        deny "統合報告(review-converge-round-<数字>.md)以外への書き込みは不可: ${target}"
    fi
done < <(printf '%s' "$STRIPPED" | grep -oE '[0-9]*>>?\|?[[:space:]]*[^[:space:];|&()<>]+' | sed -E 's#^[0-9]*>>?\|?[[:space:]]*##')

# パイプ・連結・コマンド置換を区切りに分割し、各コマンドの先頭語を検証
NORMALIZED=$(printf '%s' "$STRIPPED" | tr '\n`' ';;' | sed -E 's/\$\(/;/g; s/[()]/;/g; s/\|\|/;/g; s/&&/;/g; s/\|/;/g')

DENY_RE='^(tee|cp|mv|rm|go|cargo|npm|make)$'

IFS=';' read -ra SEGMENTS <<< "$NORMALIZED"
for seg in "${SEGMENTS[@]}"; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [[ -z "$seg" ]] && continue
    read -ra words <<< "$seg"
    first="${words[0]}"
    # パス付きで呼ばれても拒否できるよう basename で突き合わせる
    first_base="$(basename -- "$first")"

    if [[ "$first_base" =~ $DENY_RE ]]; then
        deny "コマンド ${first_base} は不可(書き込み・ビルドを伴うため)"
    fi
    if [[ "$first_base" == "nix" && "${words[1]:-}" == "build" ]]; then
        deny "nix build は不可(ビルド成果物を作るため)"
    fi
done

exit 0
