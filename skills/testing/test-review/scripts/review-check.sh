#!/usr/bin/env bash
# test-review の機械検査: 工程成果物のテンプレ準拠(存在・必須セクション・テーブル空欄)と
# トレーサビリティ(ID 突合)を決定論で検査する。
#
# Usage: review-check.sh <工程> <成果物ディレクトリ> [突合ディレクトリ]
#   工程: spec | design-doc | plan | analyze | design | implement | execute | monitor | report
#   成果物ディレクトリ:
#     spec / design-doc: docs/dev/<対象> のパス(spec.md / basic-design.md の置き場)
#     それ以外:          docs/test/<テスト対象名> のパス
#   突合ディレクトリ(spec / design-doc のみ・任意): 下流のテスト成果物の置き場。
#     省略時は docs/dev/<対象> → docs/test/<対象> を導出し、無ければ突合を SKIP する。
#
# 出力: 検査 1 件につき「OK|NG|SKIP: <内容>」の 1 行 + 末尾サマリ。
# exit code: 0 = NG なし / 1 = NG あり / 2 = 引数・前提エラー
#
# 前提: 成果物間の ID 表記(R1 / TC-01 / CASE-01 / D1)は同一チェーン内で一貫している。
set -uo pipefail

usage() {
    echo "Usage: $(basename "$0") <spec|design-doc|plan|analyze|design|implement|execute|monitor|report> <artifact-dir> [test-dir]"
}

STAGE=${1:-}
DIR=${2:-}
TEST_DIR=${3:-}
if [ -z "$STAGE" ] || [ -z "$DIR" ]; then
    usage >&2
    exit 2
fi
if [ ! -d "$DIR" ]; then
    echo "ERROR: 成果物ディレクトリが存在しない: $DIR" >&2
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

require_file() { # path label -> 0 if exists
    if [ -f "$1" ]; then
        note OK "$2 が存在する ($1)"
        return 0
    fi
    note NG "$2 が無い ($1)"
    return 1
}

require_section() { # file heading-text
    if grep -qE "^#{1,4} .*$2" "$1"; then
        note OK "$(basename "$1"): セクション「$2」あり"
    else
        note NG "$(basename "$1"): セクション「$2」が見つからない"
    fi
}

# Markdown テーブルの空欄セル検出。区切り行(|---|)は除外する。
check_empty_cells() { # file
    local hits
    hits=$(awk '
        /^\|/ {
            line = $0
            if (line ~ /^\|[ \t:|-]+$/) next
            n = split(line, c, "|")
            for (i = 2; i < n; i++) {
                gsub(/^[ \t]+|[ \t]+$/, "", c[i])
                if (c[i] == "") { print FNR; break }
            }
        }' "$1")
    if [ -z "$hits" ]; then
        note OK "$(basename "$1"): テーブルに空欄セルなし"
    else
        note NG "$(basename "$1"): テーブルに空欄セルあり (行: $(echo "$hits" | paste -sd, -))。値なしは「-」を明記する"
    fi
}

# 前後が英数字でない位置の <prefix>[-]<数字> を ID として抽出する(重複排除・ソート済み)。
extract_ids() { # prefix file
    grep -oE "(^|[^[:alnum:]_])$1-?[0-9]+" "$2" 2>/dev/null |
        grep -oE "$1-?[0-9]+" | sort -u
}

# src 内で参照される prefix ID がすべて ref 内に存在するか。
check_refs_exist() { # prefix src ref label
    local missing
    missing=$(comm -23 <(extract_ids "$1" "$2") <(extract_ids "$1" "$3"))
    if [ -z "$missing" ]; then
        note OK "$4"
    else
        note NG "$4: 参照先が見つからない ID → $(echo "$missing" | paste -sd, -)"
    fi
}

# ref 内で定義された prefix ID がすべて src 内で参照されているか(網羅)。
check_all_covered() { # prefix ref src label
    local missing
    missing=$(comm -23 <(extract_ids "$1" "$2") <(extract_ids "$1" "$3"))
    if [ -z "$missing" ]; then
        note OK "$4"
    else
        note NG "$4: カバーされていない ID → $(echo "$missing" | paste -sd, -)"
    fi
}

require_ids() { # prefix file label
    if [ -n "$(extract_ids "$1" "$2")" ]; then
        note OK "$3"
    else
        note NG "$3: $1 系の ID が 1 件も無い"
    fi
}

# `### REQ-#` 形式の定義見出しが一意か(同じ ID の見出しが 2 回以上出たら NG)。
# 欠番は NG にしない(改訂で追番・削除が起きるため、連番であることは契約ではない)。
check_unique_defs() { # prefix file label
    local dup
    dup=$(grep -E "^#{1,4} +$1-?[0-9]+" "$2" | grep -oE "$1-?[0-9]+" | sort | uniq -d)
    if [ -z "$dup" ]; then
        note OK "$3"
    else
        note NG "$3: 定義見出しが重複している ID → $(echo "$dup" | paste -sd, -)"
    fi
}

# 定義見出し `### <prefix>-#` が 1 件以上あるか。
require_defs() { # prefix file label
    if grep -qE "^#{1,4} +$1-?[0-9]+" "$2"; then
        note OK "$3"
    else
        note NG "$3: $1-# の定義見出し(### $1-01 形式)が 1 件も無い"
    fi
}

# 見出し以外の本文で参照される prefix ID がすべて定義見出しに存在するか(同一ファイル内)。
check_defs_cover_refs() { # prefix file label
    local used defined missing
    used=$(grep -vE "^#{1,4} " "$2" | grep -oE "(^|[^[:alnum:]_])$1-?[0-9]+" | grep -oE "$1-?[0-9]+" | sort -u)
    defined=$(grep -E "^#{1,4} " "$2" | grep -oE "$1-?[0-9]+" | sort -u)
    if [ -z "$used" ]; then
        note SKIP "$(basename "$2"): $1-# の参照が無いため定義突合をスキップ"
        return
    fi
    missing=$(comm -23 <(echo "$used") <(echo "$defined"))
    if [ -z "$missing" ]; then
        note OK "$3"
    else
        note NG "$3: 定義見出しの無い $1-# → $(echo "$missing" | paste -sd, -)"
    fi
}

# Markdown テーブルのデータ行(区切り行・ヘッダ行を除く)が prefix ID を参照しているか。
# section が指定されたらその見出し配下の最初のテーブルだけを対象にする。
check_table_refs() { # prefix file section label
    local rows missing_rows ids
    rows=$(awk -v sec="$3" '
        BEGIN { in_sec = (sec == "") ; seen_table = 0 }
        /^#{1,6} / {
            if (sec != "") { in_sec = (index($0, sec) > 0) }
            if (seen_table && !in_sec) exit
            next
        }
        !in_sec { next }
        /^\|/ {
            if ($0 ~ /^\|[ \t:|-]+$/) { seen_table = 1; next }
            if (!seen_table) next          # 区切り行より前 = ヘッダ行
            print FNR "\t" $0
            next
        }
        seen_table && $0 !~ /^[ \t]*$/ { exit }
    ' "$2")
    if [ -z "$rows" ]; then
        note SKIP "$(basename "$2"): $4 の対象テーブルが見つからないため参照検査をスキップ"
        return
    fi
    missing_rows=$(echo "$rows" | while IFS=$'\t' read -r ln body; do
        ids=$(echo "$body" | grep -oE "(^|[^[:alnum:]_])$1-?[0-9]+" | grep -oE "$1-?[0-9]+")
        [ -z "$ids" ] && echo "$ln"
    done)
    if [ -z "$missing_rows" ]; then
        note OK "$4"
    else
        note NG "$4: $1-# 参照の無い行 (行: $(echo "$missing_rows" | paste -sd, -))。「-」ではなく該当 $1-# を明記する"
    fi
}

PLAN="$DIR/test-plan.md"
ANALYSIS="$DIR/test-analysis.md"
DESIGN="$DIR/test-design.md"
CASE="$DIR/test-case.md"
PROCEDURES="$DIR/test-procedures.md"
EXEC_LOG="$DIR/test-execution-log.md"
MONITORING="$DIR/test-monitoring.md"
SUMMARY="$DIR/test-summary-report.md"

# spec / design-doc は docs/dev/<対象> を見る。下流の突合先 docs/test/<対象> は
# 引数で明示されなければ docs/dev/<対象> から導出する(無ければ突合を SKIP)。
SPEC="$DIR/spec.md"
BASIC_DESIGN="$DIR/basic-design.md"
if [ -z "$TEST_DIR" ]; then
    TEST_DIR="$(dirname "$(dirname "$DIR")")/test/$(basename "$DIR")"
fi
DOWNSTREAM_ANALYSIS="$TEST_DIR/test-analysis.md"
DOWNSTREAM_CASE="$TEST_DIR/test-case.md"

case "$STAGE" in
spec)
    if require_file "$SPEC" "仕様書 spec.md"; then
        require_section "$SPEC" "目的"
        require_section "$SPEC" "スコープ"
        require_section "$SPEC" "機能要求"
        require_section "$SPEC" "非機能要求"
        require_section "$SPEC" "受け入れ条件"
        require_section "$SPEC" "スコープ外"
        require_defs REQ "$SPEC" "機能要求(REQ-#)の定義見出しが 1 件以上ある"
        check_unique_defs REQ "$SPEC" "機能要求(REQ-#)の定義見出しが一意である"
        check_empty_cells "$SPEC"
        check_table_refs REQ "$SPEC" "受け入れ条件" "受け入れ条件の各行が REQ-# を参照している"
        check_defs_cover_refs REQ "$SPEC" "本文が参照する REQ-# が定義見出しに存在する"
        if [ -f "$DOWNSTREAM_ANALYSIS" ]; then
            check_refs_exist REQ "$DOWNSTREAM_ANALYSIS" "$SPEC" "test-analysis.md が参照する REQ-# が spec.md に存在する(孤児参照なし)"
        else
            note SKIP "$DOWNSTREAM_ANALYSIS が無いため下流参照(REQ-#)の破壊検査をスキップ"
        fi
    fi
    ;;
design-doc)
    if require_file "$BASIC_DESIGN" "基本設計書 basic-design.md"; then
        require_section "$BASIC_DESIGN" "機能一覧"
        require_section "$BASIC_DESIGN" "モジュール構成"
        require_section "$BASIC_DESIGN" "インターフェース"
        require_section "$BASIC_DESIGN" "データフロー"
        check_empty_cells "$BASIC_DESIGN"
        check_table_refs REQ "$BASIC_DESIGN" "機能一覧" "機能一覧の各行が REQ-# を参照している"
        if [ -f "$SPEC" ]; then
            check_refs_exist REQ "$BASIC_DESIGN" "$SPEC" "機能一覧が参照する REQ-# が spec.md に存在する"
        else
            note SKIP "$SPEC が無いため REQ-# の実在突合をスキップ"
        fi
        if [ -f "$DOWNSTREAM_CASE" ]; then
            if [ -n "$(extract_ids CASE "$BASIC_DESIGN")" ]; then
                check_refs_exist CASE "$BASIC_DESIGN" "$DOWNSTREAM_CASE" "basic-design.md が参照する CASE-# が test-case.md に存在する"
            else
                note SKIP "basic-design.md に CASE-# の参照が無いため突合をスキップ"
            fi
        else
            note SKIP "$DOWNSTREAM_CASE が無いため CASE-# 突合をスキップ"
        fi
    fi
    ;;
plan)
    if require_file "$PLAN" "テスト計画 test-plan.md"; then
        require_section "$PLAN" "スコープ"
        require_section "$PLAN" "プロダクトリスク評価"
        require_section "$PLAN" "テストアプローチ"
        require_section "$PLAN" "開始基準・完了基準"
        check_empty_cells "$PLAN"
        require_ids R "$PLAN" "リスク項目(R#)が 1 件以上ある"
    fi
    ;;
analyze)
    if require_file "$ANALYSIS" "テスト分析 test-analysis.md"; then
        require_section "$ANALYSIS" "テスト観点一覧"
        require_section "$ANALYSIS" "優先度の根拠"
        require_section "$ANALYSIS" "カバレッジの見立て"
        check_empty_cells "$ANALYSIS"
        require_ids TC "$ANALYSIS" "テスト条件(TC-#)が 1 件以上ある"
        if [ -f "$PLAN" ]; then
            check_refs_exist R "$ANALYSIS" "$PLAN" "参照リスク(R#)が test-plan.md に存在する"
        else
            note SKIP "test-plan.md が無いためリスク(R#)突合をスキップ"
        fi
    fi
    ;;
design)
    if require_file "$DESIGN" "テスト設計書 test-design.md"; then
        require_section "$DESIGN" "採用テスト技法と選定根拠"
        require_section "$DESIGN" "カバレッジの確認"
        require_section "$DESIGN" "自動/手動の区分基準"
        check_empty_cells "$DESIGN"
    fi
    if require_file "$CASE" "テストケース一覧 test-case.md"; then
        check_empty_cells "$CASE"
        require_ids CASE "$CASE" "テストケース(CASE-#)が 1 件以上ある"
        if [ -f "$ANALYSIS" ]; then
            check_refs_exist TC "$CASE" "$ANALYSIS" "ケースが参照するテスト条件(TC-#)が test-analysis.md に存在する"
            check_all_covered TC "$ANALYSIS" "$CASE" "全テスト条件(TC-#)がケース化されている"
        else
            note SKIP "test-analysis.md が無いためテスト条件(TC-#)突合をスキップ"
        fi
    fi
    ;;
implement)
    if require_file "$CASE" "テストケース一覧 test-case.md(実装の入力)"; then
        if grep -qE '\|[[:space:]]*手動[[:space:]]*\|' "$CASE"; then
            require_file "$PROCEDURES" "手動テスト手順書 test-procedures.md(手動ケースがあるため必須)"
            [ -f "$PROCEDURES" ] && check_empty_cells "$PROCEDURES"
        else
            note SKIP "手動区分のケースが無いため test-procedures.md の検査をスキップ"
        fi
    fi
    note SKIP "テストコード本体はプロジェクト規約パスに置かれるため機械検査の対象外(定性レビューで確認)"
    ;;
execute)
    if require_file "$EXEC_LOG" "テスト実行ログ test-execution-log.md"; then
        require_section "$EXEC_LOG" "実行サマリ"
        require_section "$EXEC_LOG" "実行結果詳細"
        # 参照される欠陥候補 D# に定義見出し(### D#)があるか
        used=$(grep -vE '^#{1,4} ' "$EXEC_LOG" | grep -oE '(^|[^[:alnum:]_])D-?[0-9]+' | grep -oE 'D-?[0-9]+' | sort -u)
        defined=$(grep -E '^#{1,4} ' "$EXEC_LOG" | grep -oE 'D-?[0-9]+' | sort -u)
        if [ -z "$used" ]; then
            note SKIP "欠陥候補(D#)の参照が無いため突合をスキップ(失敗ゼロなら正当)"
        else
            missing=$(comm -23 <(echo "$used") <(echo "$defined"))
            if [ -z "$missing" ]; then
                note OK "参照される欠陥候補(D#)に定義見出しがある"
            else
                note NG "定義見出しの無い欠陥候補 ID → $(echo "$missing" | paste -sd, -)"
            fi
        fi
        note SKIP "実行結果詳細テーブルの空欄検査はスキップ(合格ケースの「実際結果(失敗時)」列は空欄が正当。定性レビューで確認)"
    fi
    ;;
monitor)
    if require_file "$MONITORING" "モニタリング定義 test-monitoring.md"; then
        require_section "$MONITORING" "目的"
        require_section "$MONITORING" "メトリクス定義"
        require_section "$MONITORING" "計測基盤"
        check_empty_cells "$MONITORING"
    fi
    ;;
report)
    if require_file "$SUMMARY" "テスト完了レポート test-summary-report.md"; then
        require_section "$SUMMARY" "サマリ"
        require_section "$SUMMARY" "実行結果の集約"
        require_section "$SUMMARY" "完了基準"
        if grep -q '総合判定' "$SUMMARY"; then
            note OK "総合判定の記載がある"
        else
            note NG "総合判定の記載が見つからない"
        fi
        if [ -f "$PLAN" ]; then
            check_refs_exist R "$SUMMARY" "$PLAN" "参照リスク(R#)が test-plan.md に存在する"
        else
            note SKIP "test-plan.md が無いためリスク(R#)突合をスキップ"
        fi
        note SKIP "集約テーブルの空欄検査はスキップ(備考列は空欄が正当。定性レビューで確認)"
    fi
    ;;
*)
    echo "ERROR: 不明な工程: $STAGE" >&2
    usage >&2
    exit 2
    ;;
esac

echo "---"
echo "SUMMARY: OK=$ok NG=$ng SKIP=$skip"
if [ "$ng" -gt 0 ]; then
    exit 1
fi
exit 0
