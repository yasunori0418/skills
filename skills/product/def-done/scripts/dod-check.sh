#!/usr/bin/env bash
# def-done の機械検査: 完成の定義 definition-of-done.md の形式契約
# (二部構成・機械判定テーブルの列規約・DOD-# 規約・種別と条件の語彙・項目総数の上限) を
# 決定論で検査する。
#
# Usage: dod-check.sh <definition-of-done.md のパス>
#
# 出力: 検査 1 件につき「OK|NG|SKIP: <内容>」の 1 行 + 末尾サマリ。
# exit code: 0 = NG なし / 1 = NG あり / 2 = 引数・前提エラー
#
# 検査するのは形式のみ。条件が完成の定義として妥当かどうか(意味)には踏み込まない。
set -uo pipefail

usage() {
    echo "Usage: $(basename "$0") <definition-of-done.md>"
}

DOC=${1:-}
if [ -z "$DOC" ]; then
    usage >&2
    exit 2
fi
if [ ! -f "$DOC" ]; then
    echo "ERROR: 完成の定義が存在しない: $DOC" >&2
    exit 2
fi

ok=0
ng=0
skip=0
note() { # status message
    case "$1" in
    OK) ok=$((ok + 1)) ;;
    NG) ng=$((ng + 1)) ;;
    SKIP) skip=$((skip + 1)) ;;
    esac
    echo "$1: $2"
}

note OK "完成の定義が存在する ($DOC)"

# セクション見出しの行番号を取る(見つからなければ空)。
heading_line() { # heading-text
    grep -nE "^#{1,4}[[:space:]]+$1[[:space:]]*$" "$DOC" | head -n 1 | cut -d: -f1
}

MACHINE_LINE=$(heading_line "機械判定")
HUMAN_LINE=$(heading_line "人判定")

if [ -n "$MACHINE_LINE" ]; then
    note OK "セクション「機械判定」あり"
else
    note NG "セクション「機械判定」が見つからない"
fi
if [ -n "$HUMAN_LINE" ]; then
    note OK "セクション「人判定」あり"
else
    note NG "セクション「人判定」が見つからない"
fi

# --- 機械判定節のテーブル検査 ---
if [ -n "$MACHINE_LINE" ]; then
    # 機械判定節の範囲: 見出しの次行から、人判定見出しの手前(無ければ末尾)まで。
    if [ -n "$HUMAN_LINE" ] && [ "$HUMAN_LINE" -gt "$MACHINE_LINE" ]; then
        MACHINE_END=$((HUMAN_LINE - 1))
    else
        MACHINE_END=$(wc -l <"$DOC")
    fi
    MACHINE_BODY=$(sed -n "$((MACHINE_LINE + 1)),${MACHINE_END}p" "$DOC")

    # DOD-# 始まりのデータ行のみを対象にする(ヘッダ行・区切り行・説明文を除外)。
    DATA_ROWS=$(echo "$MACHINE_BODY" | grep -E '^\|[[:space:]]*DOD-' || true)
    ROW_COUNT=$(echo -n "$DATA_ROWS" | grep -c '' || true)

    if [ "$ROW_COUNT" -ge 1 ]; then
        note OK "機械判定テーブルにデータ行が $ROW_COUNT 件ある"
    else
        note NG "機械判定テーブルに DOD-# のデータ行が 1 件も無い"
    fi

    if [ "$ROW_COUNT" -ge 1 ]; then
        # 列数・空欄セル検査(| ID | 項目 | 種別 | 対象 | 条件 | = 5 列)
        bad_cols=$(echo "$DATA_ROWS" | awk -F'|' '{
            n = NF - 2   # 先頭と末尾の空フィールドを除く
            if (n != 5) print NR ":" n
        }')
        if [ -z "$bad_cols" ]; then
            note OK "機械判定テーブルの列数が全行 5 列 (ID/項目/種別/対象/条件)"
        else
            note NG "機械判定テーブルの列数が 5 列でない行あり (データ行番号:列数 → $(echo "$bad_cols" | paste -sd, -))"
        fi

        empty_cells=$(echo "$DATA_ROWS" | awk -F'|' '{
            for (i = 2; i < NF; i++) {
                cell = $i
                gsub(/^[ \t]+|[ \t]+$/, "", cell)
                if (cell == "") { print NR; break }
            }
        }')
        if [ -z "$empty_cells" ]; then
            note OK "機械判定テーブルに空欄セルなし"
        else
            note NG "機械判定テーブルに空欄セルあり (データ行番号: $(echo "$empty_cells" | paste -sd, -))。値なしは「-」を明記する"
        fi

        # DOD-# の形式検査
        bad_ids=$(echo "$DATA_ROWS" | awk -F'|' '{
            id = $2
            gsub(/^[ \t]+|[ \t]+$/, "", id)
            if (id !~ /^DOD-[0-9]+$/) print id
        }')
        if [ -z "$bad_ids" ]; then
            note OK "全 ID が DOD-<数字> 形式"
        else
            note NG "DOD-<数字> 形式でない ID → $(echo "$bad_ids" | paste -sd, -)"
        fi

        # DOD-# の一意性検査
        dup_ids=$(echo "$DATA_ROWS" | awk -F'|' '{
            id = $2
            gsub(/^[ \t]+|[ \t]+$/, "", id)
            print id
        }' | sort | uniq -d)
        if [ -z "$dup_ids" ]; then
            note OK "ID(DOD-#)が一意"
        else
            note NG "重複した ID → $(echo "$dup_ids" | paste -sd, -)"
        fi

        # 種別の語彙検査(ci-check | artifact のみ)
        bad_kinds=$(echo "$DATA_ROWS" | awk -F'|' '{
            id = $2; kind = $4
            gsub(/^[ \t]+|[ \t]+$/, "", id)
            gsub(/^[ \t]+|[ \t]+$/, "", kind)
            if (kind != "ci-check" && kind != "artifact") print id "(" kind ")"
        }')
        if [ -z "$bad_kinds" ]; then
            note OK "種別が ci-check | artifact のみ"
        else
            note NG "未定義の種別 → $(echo "$bad_kinds" | paste -sd, -)。ci-check | artifact のみ使える"
        fi

        # 条件の語彙検査(種別に対応する条件か)
        bad_conds=$(echo "$DATA_ROWS" | awk -F'|' '{
            id = $2; kind = $4; cond = $6
            gsub(/^[ \t]+|[ \t]+$/, "", id)
            gsub(/^[ \t]+|[ \t]+$/, "", kind)
            gsub(/^[ \t]+|[ \t]+$/, "", cond)
            if (kind == "ci-check") {
                if (cond != "success") print id "(" cond ")"
            } else if (kind == "artifact") {
                if (cond != "exists" && cond !~ /^contains:.+$/) print id "(" cond ")"
            }
        }')
        if [ -z "$bad_conds" ]; then
            note OK "条件が種別に対応する語彙のみ (ci-check→success / artifact→exists|contains:<文字列>)"
        else
            note NG "種別に対応しない条件 → $(echo "$bad_conds" | paste -sd, -)"
        fi
    else
        note SKIP "データ行が無いためテーブル内容の検査をスキップ"
    fi
else
    note SKIP "機械判定セクションが無いためテーブル検査をスキップ"
fi

# --- 人判定節の検査 ---
if [ -n "$HUMAN_LINE" ]; then
    if [ -n "$MACHINE_LINE" ] && [ "$MACHINE_LINE" -gt "$HUMAN_LINE" ]; then
        HUMAN_END=$((MACHINE_LINE - 1))
    else
        HUMAN_END=$(wc -l <"$DOC")
    fi
    HUMAN_BODY=$(sed -n "$((HUMAN_LINE + 1)),${HUMAN_END}p" "$DOC")

    ITEM_COUNT=$(echo "$HUMAN_BODY" | grep -cE '^[[:space:]]*- \[[ xX]\] ' || true)
    if [ "$ITEM_COUNT" -ge 1 ]; then
        note OK "人判定節にチェックリスト項目が $ITEM_COUNT 件ある"
    elif echo "$HUMAN_BODY" | grep -qE '（なし）|\(なし\)'; then
        note OK "人判定節に該当項目なし(「(なし)」の明記あり)"
    else
        note NG "人判定節にチェックリスト項目(- [ ])が無く「(なし)」の明記も無い"
    fi
else
    note SKIP "人判定セクションが無いため項目検査をスキップ"
fi

# --- 項目総数の上限検査 (機械判定 + 人判定で最大 5 件) ---
# 項目が多いほど各項目のクリアが重くなり完成が遠のくため、定義は 5 件以内に絞らせる。
MAX_ITEMS=5
total_items=$((${ROW_COUNT:-0} + ${ITEM_COUNT:-0}))
if [ "$total_items" -le "$MAX_ITEMS" ]; then
    note OK "項目総数が上限内 (機械判定 ${ROW_COUNT:-0} + 人判定 ${ITEM_COUNT:-0} = $total_items / 最大 $MAX_ITEMS)"
else
    note NG "項目総数が上限超過 (機械判定 ${ROW_COUNT:-0} + 人判定 ${ITEM_COUNT:-0} = $total_items > $MAX_ITEMS)。統合または削除で $MAX_ITEMS 件以内に絞る"
fi

echo "---"
echo "SUMMARY: OK=$ok NG=$ng SKIP=$skip"
if [ "$ng" -gt 0 ]; then
    exit 1
fi
exit 0
