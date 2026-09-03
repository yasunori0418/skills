#!/usr/bin/env bash
# Verifies detect.jq in isolation (jq フィルタ単体。main.sh を介さない):
#   - main.sh との間の出力契約（ヘッダ 2 行 + XML 一覧 + 主張パス）を固定する
#   - 走査範囲の切り出し（ターン境界・tool_result・sidechain）
#   - XML 混入型の抽出（開始タグ両形・description/file_path/run_in_background・重複除去）
#   - 未実行完了主張型の候補抽出（Write 有無・引用/リスト/表の除外・4 行の近接条件）
#   - 2 連続判定フラグと累積コンテキストの算出
#
# 同ディレクトリの fabricated-toolcall-guard.test.sh は main.sh 経由の e2e。
# こちらは detect.jq だけを対象にし、破綻したときにどちらの層かを切り分けられるようにする。
#
# detect.jq は「実在確認をしない」。主張パスは実在の有無に関わらず候補として出し、
# 存在しないものだけを block へ回すのは main.sh の責務。ここではその契約を固定する。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FILTER="$SCRIPT_DIR/../detect.jq"

# main.sh が渡すのと同じマーカー（2 連続検出の判定に使う正規表現）
MARKER="ツール呼び出しが text として出力され|報告していますが、Write/Edit の実行がありません"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}

write_transcript() { # name record...
    local name="$1"
    shift
    : >"$WORK/$name.jsonl"
    local r
    for r in "$@"; do
        printf '%s\n' "$r" >>"$WORK/$name.jsonl"
    done
}

# detect.jq を直接実行する（main.sh を介さない）
detect() { # name
    jq -rs --arg marker "$MARKER" -f "$FILTER" "$WORK/$1.jsonl" 2>/dev/null || true
}
# 出力の各パート
header_flag() { detect "$1" | sed -n '1p' | cut -f1; }  # yes/no（2 連続判定）
header_ctx() { detect "$1" | sed -n '1p' | cut -f2; }   # 累積コンテキスト(k)
xml_count() { detect "$1" | sed -n '2p'; }              # XML 混入型の件数
xml_line() { detect "$1" | sed -n "$((2 + $2))p"; }     # XML 一覧の n 行目
claims() { # 3+N 行目以降 = 主張パス
    local n
    n=$(xml_count "$1")
    detect "$1" | tail -n +"$((3 + n))"
}

# --- record 組み立て ---------------------------------------------------------
user_text() { jq -cn --arg t "$1" '{type:"user", message:{role:"user", content:$t}}'; }
assistant_text() { # text [usage-json]
    if [ -n "${2:-}" ]; then
        jq -cn --arg t "$1" --argjson u "$2" \
            '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t}], usage:$u}}'
    else
        jq -cn --arg t "$1" \
            '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t}]}}'
    fi
}
assistant_with_tool() { # text tool-name
    jq -cn --arg t "$1" --arg n "$2" \
        '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t},{type:"tool_use", id:"t1", name:$n, input:{}}]}}'
}
tool_result_user() {
    jq -cn '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"x", content:"ok"}]}}'
}

FAB='antml:invoke name="Bash">
<parameter name="command">git status</parameter>
<parameter name="description">状態を確認</parameter>
</invoke>
<function_results>clean</function_results>'

# --- 出力契約 ---------------------------------------------------------------
# 検出が無いときでもヘッダ 2 行は必ず出る（main.sh はこの形を前提に切り分ける）
write_transcript quiet "$(user_text 'やって')" "$(assistant_text '完了しました。問題ありません。')"
check "contract-header-always" "2" "$(detect quiet | grep -c '^')"
check "contract-quiet-count" "0" "$(xml_count quiet)"
check "contract-quiet-flag" "no" "$(header_flag quiet)"

# 検出時は「ヘッダ 2 行 + 件数ぶんの一覧」になる
write_transcript one "$(user_text 'やって')" "$(assistant_text "$FAB")"
check "contract-count-matches-lines" "1" "$(xml_count one)"
check "contract-total-lines" "3" "$(detect one | grep -c '^')"
check "contract-line-format" "  - Bash: 状態を確認" "$(xml_line one 1)"

# --- XML 混入型の抽出 --------------------------------------------------------
# 開始タグの "<" が残った形
write_transcript angle "$(user_text 'やって')" \
    "$(assistant_text '<invoke name="Edit">
<parameter name="file_path">/src/A.kt</parameter>
</invoke>')"
check "xml-angle-form" "  - Edit: /src/A.kt" "$(xml_line angle 1)"

# run_in_background の付記
write_transcript bg "$(user_text 'やって')" \
    "$(assistant_text 'antml:invoke name="Bash">
<parameter name="description">ビルド</parameter>
<parameter name="run_in_background">true</parameter>
</invoke>')"
check "xml-run-in-background" "  - Bash: ビルド (run_in_background)" "$(xml_line bg 1)"

# description が重複しても 1 件に畳む（実データで重複が観測されている）
write_transcript dup "$(user_text 'やって')" \
    "$(assistant_text 'antml:invoke name="Bash">
<parameter name="description">確認</parameter>
<parameter name="description">確認</parameter>
</invoke>')"
check "xml-dedup" "1" "$(xml_count dup)"

# description が無ければ file_path、どちらも無ければツール名だけ
write_transcript nodesc "$(user_text 'やって')" \
    "$(assistant_text 'antml:invoke name="Read">
</invoke>')"
check "xml-name-only" "  - Read" "$(xml_line nodesc 1)"

# 結果タグだけでも検出する（開始タグが欠けた場合）
write_transcript resonly "$(user_text 'やって')" \
    "$(assistant_text '確認した。
<function_results>clean</function_results>')"
check "xml-result-tag-only" "  - (ツール名不明)" "$(xml_line resonly 1)"

# コードフェンス／インラインコード内は除外
write_transcript fenced "$(user_text 'やって')" \
    "$(assistant_text '例:

```
antml:invoke name="Bash">
<function_results>`ok`</function_results>
```

以上。')"
check "xml-fence-excluded" "0" "$(xml_count fenced)"
write_transcript inlined "$(user_text 'やって')" \
    "$(assistant_text '`invoke name="Bash"` と `<function_results>` について。')"
check "xml-inline-excluded" "0" "$(xml_count inlined)"

# 行頭アンカーは最後の砦。文中（行の途中）に現れた言及は拾わない。
# ここを外すと、この現象を地の文で説明しただけの応答が誤検出される。
write_transcript midline "$(user_text '説明して')" \
    "$(assistant_text 'ログ中に invoke name="Bash" という文字列が現れることがある。')"
check "xml-mid-line-anchor" "0" "$(xml_count midline)"
write_transcript midline2 "$(user_text '説明して')" \
    "$(assistant_text '出力が <invoke name="Edit"> のようになる場合を考える。')"
check "xml-mid-line-anchor-angle" "0" "$(xml_count midline2)"

# --- 走査範囲 ---------------------------------------------------------------
# 実ユーザー発話が境界。前ターンの捏造は数えない
write_transcript prev "$(user_text '最初')" "$(assistant_text "$FAB")" \
    "$(user_text '次')" "$(assistant_text '普通の応答')"
check "scope-boundary" "0" "$(xml_count prev)"

# tool_result のみの user record はターン途中なので跨ぐ
write_transcript cross "$(user_text 'やって')" "$(assistant_text '実行する')" \
    "$(tool_result_user)" "$(assistant_text "$FAB")"
check "scope-cross-tool-result" "1" "$(xml_count cross)"

# sidechain（サブエージェント側）は親ターンの成果ではないので除外
write_transcript side "$(user_text 'やって')" \
    "$(jq -cn --arg t "$FAB" '{type:"assistant", isSidechain:true, message:{role:"assistant", content:[{type:"text", text:$t}]}}')" \
    "$(assistant_text '普通の応答')"
check "scope-sidechain" "0" "$(xml_count side)"

# --- 2 連続判定フラグ --------------------------------------------------------
OURS='Stop hook feedback:
以下 1 件のツール呼び出しが text として出力され、実行されていません:'
OTHER='Stop hook feedback:
稼働中のサブエージェント/チームメイトが 1 体残っています:'
CLAIM_FB='Stop hook feedback:
このターンでファイル作成/更新を報告していますが、Write/Edit の実行がありません:'

write_transcript flagours "$(user_text 'やって')" "$(assistant_text "$FAB")" \
    "$(jq -cn --arg t "$OURS" '{type:"user", isMeta:true, message:{role:"user", content:$t}}')" \
    "$(assistant_text "$FAB")"
check "flag-ours-xml" "yes" "$(header_flag flagours)"

# 完了主張型の reason 見出しでもマーカーに一致する
write_transcript flagclaim "$(user_text 'やって')" "$(assistant_text "$FAB")" \
    "$(jq -cn --arg t "$CLAIM_FB" '{type:"user", isMeta:true, message:{role:"user", content:$t}}')" \
    "$(assistant_text "$FAB")"
check "flag-ours-claim" "yes" "$(header_flag flagclaim)"

# 他 hook 由来の block は自分のものとして数えない
write_transcript flagother "$(user_text 'やって')" "$(assistant_text "$FAB")" \
    "$(jq -cn --arg t "$OTHER" '{type:"user", isMeta:true, message:{role:"user", content:$t}}')" \
    "$(assistant_text "$FAB")"
check "flag-foreign" "no" "$(header_flag flagother)"

# --- 累積コンテキスト --------------------------------------------------------
# input + cache_read + cache_creation を 1000 で割って切り捨て
write_transcript ctx "$(user_text 'やって')" \
    "$(assistant_text "$FAB" '{"input_tokens":100,"cache_read_input_tokens":126000,"cache_creation_input_tokens":900}')"
check "ctx-sum" "127" "$(header_ctx ctx)"
# usage が無ければ空（main.sh 側で行を出さない）
check "ctx-absent" "" "$(header_ctx one)"

# --- 未実行完了主張型の候補抽出 ----------------------------------------------
# detect.jq は実在確認をしない。実在の有無に関わらず候補として出す（確認は main.sh）
write_transcript claim "$(user_text 'やって')" \
    "$(assistant_text '引き継ぎ書を再作成しました。

**ファイル**: `~/x/plan.md`')"
check "claim-candidate" "~/x/plan.md" "$(claims claim)"
check "claim-no-xml" "0" "$(xml_count claim)"

# 同一ターンに Write があれば候補を出さない
write_transcript claimwrite "$(user_text 'やって')" \
    "$(assistant_with_tool '作成しました。

`~/x/b.md`' 'Write')"
check "claim-has-write" "" "$(claims claimwrite)"
# Edit / NotebookEdit も同様に対象外
write_transcript claimedit "$(user_text 'やって')" \
    "$(assistant_with_tool '保存しました。

`~/x/c.md`' 'Edit')"
check "claim-has-edit" "" "$(claims claimedit)"
# Write 系でないツール（Bash 等）は対象外にしない
write_transcript claimbash "$(user_text 'やって')" \
    "$(assistant_with_tool '作成しました。

`~/x/d.md`' 'Bash')"
check "claim-bash-not-exempt" "~/x/d.md" "$(claims claimbash)"

# 引用・リスト・表の行は主張と見なさない
write_transcript claimquote "$(user_text 'やって')" \
    "$(assistant_text '> 引き継ぎ書を再作成しました。
> `~/x/q.md`')"
check "claim-quote" "" "$(claims claimquote)"
write_transcript claimlist "$(user_text 'やって')" \
    "$(assistant_text '- 作成しました: `~/x/l.md`')"
check "claim-list" "" "$(claims claimlist)"
write_transcript claimtable "$(user_text 'やって')" \
    "$(assistant_text '| 作成しました | `~/x/t.md` |')"
check "claim-table" "" "$(claims claimtable)"

# 主張行から 4 行以内のパスだけを拾う
write_transcript claimnear "$(user_text 'やって')" \
    "$(assistant_text '作成しました。

**ファイル**: `~/x/near.md`')"
check "claim-within-4-lines" "~/x/near.md" "$(claims claimnear)"
write_transcript claimfar "$(user_text 'やって')" \
    "$(assistant_text '作成しました。

あ
い
う
え

`~/x/far.md`')"
check "claim-beyond-4-lines" "" "$(claims claimfar)"

# 完了表現のバリエーション
for w in 作成しました 書き出しました 保存しました; do
    write_transcript "claimw" "$(user_text 'やって')" \
        "$(assistant_text "レポートを${w}。

\`~/x/w.md\`")"
    check "claim-verb-${w}" "~/x/w.md" "$(claims claimw)"
done

# フェンス内の主張は拾わない
write_transcript claimfence "$(user_text 'やって')" \
    "$(assistant_text '例:

```
作成しました。
`~/x/f.md`
```')"
check "claim-fence" "" "$(claims claimfence)"

# --- 2 チェックの併存 --------------------------------------------------------
# XML 一覧と主張パスが同時に出る場合、件数行で境界が引けること
write_transcript both "$(user_text 'やって')" \
    "$(assistant_text "$FAB

レポートを作成しました。

\`~/x/both.md\`")"
check "both-xml-count" "1" "$(xml_count both)"
check "both-xml-line" "  - Bash: 状態を確認" "$(xml_line both 1)"
check "both-claim" "~/x/both.md" "$(claims both)"

# --- 壊れた入力 --------------------------------------------------------------
# 空の transcript でもヘッダは返す（main.sh 側が xml_count で判定できる）
: >"$WORK/empty.jsonl"
check "empty-transcript" "0" "$(xml_count empty)"
# 壊れた JSONL は jq が失敗するので空文字（main.sh は fail-open）
printf 'not json\n' >"$WORK/broken.jsonl"
check "broken-transcript" "" "$(detect broken)"

exit "$fail"
