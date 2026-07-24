#!/usr/bin/env bash
# test-review の機械検査: 工程成果物のテンプレ準拠(存在・必須セクション・テーブル空欄)と
# トレーサビリティ(ID 突合)を決定論で検査する。
#
# Usage: review-check.sh <工程> <成果物ディレクトリ>
#   工程: plan | analyze | design | implement | execute | monitor | report
#   成果物ディレクトリ: docs/test/<テスト対象名> のパス
#
# 出力: 検査 1 件につき「OK|NG|SKIP: <内容>」の 1 行 + 末尾サマリ。
# exit code: 0 = NG なし / 1 = NG あり / 2 = 引数・前提エラー
#
# 前提: 成果物間の ID 表記(R1 / TC-01 / CASE-01 / D1)は同一チェーン内で一貫している。
set -uo pipefail

usage() {
    echo "Usage: $(basename "$0") <plan|analyze|design|implement|execute|monitor|report> <artifact-dir>"
}

STAGE=${1:-}
DIR=${2:-}
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

PLAN="$DIR/test-plan.md"
ANALYSIS="$DIR/test-analysis.md"
DESIGN="$DIR/test-design.md"
CASE="$DIR/test-case.md"
PROCEDURES="$DIR/test-procedures.md"
EXEC_LOG="$DIR/test-execution-log.md"
MONITORING="$DIR/test-monitoring.md"
SUMMARY="$DIR/test-summary-report.md"

case "$STAGE" in
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
