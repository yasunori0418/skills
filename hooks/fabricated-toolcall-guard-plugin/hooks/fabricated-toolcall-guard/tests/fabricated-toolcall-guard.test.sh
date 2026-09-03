#!/usr/bin/env bash
# Verifies fabricated-toolcall-guard (Stop hook: text へ混入した捏造ツール呼び出しを decision:block で差し戻す):
#   - 捏造ブロックを検出し、ツール名・description・file_path・run_in_background を列挙する
#   - コードフェンス／インラインコード内の言及は偽陽性として除外する
#   - 走査範囲は「今回のターン」に限る（前ターンの捏造は数えない／tool_result は跨ぐ）
#   - 本 hook 由来の block が直前にあり stop_hook_active なら D4 のエスカレーション文面へ切り替える
#   - transcript 欠落・壊れた JSON・sidechain のみ等では沈黙（fail-open）
#
# fixture の出自について:
#   検出精度の検証（正例 25/25・偽陽性 3/3 除外）は別マシンの実セッションに対して
#   実施されたもので、その transcript は本リポジトリからは参照できない。
#   ここでの fixture は調査資料 §1.1 / §1.2 に記録された実ブロックの「形」
#   （"<" 剥落・description 重複・function_results・Edit の file_path・
#   run_in_background）を手で再現したものであり、実データの写しではない。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/../main.sh"

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

# transcript を組み立てる。各引数が 1 record（JSON）。
write_transcript() { # name record...
    local name="$1"
    shift
    : >"$WORK/$name.jsonl"
    local r
    for r in "$@"; do
        printf '%s\n' "$r" >>"$WORK/$name.jsonl"
    done
}

# hook を走らせ reason を取り出す（沈黙時は空文字）
run() { # name [stdin-extra-json]
    local extra="${2:-}"
    local input
    if [ -n "$extra" ]; then
        input=$(jq -cn --arg p "$WORK/$1.jsonl" --argjson e "$extra" '$e + {transcript_path: $p}')
    else
        input=$(jq -cn --arg p "$WORK/$1.jsonl" '{transcript_path: $p}')
    fi
    printf '%s' "$input" | "$GUARD" | jq -r 'select(.decision == "block") | .reason // empty'
}
first_line() { run "$@" | head -1; }

# --- record の組み立てヘルパ ------------------------------------------------
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
tool_result_user() {
    jq -cn '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"x", content:"ok"}]}}'
}

# --- fixture 本文 -----------------------------------------------------------
# 資料 §1.1 の record 359 相当。開始タグの "<" が剥落し、description が重複する。
FAB_359='worktree 作成完了。ベースが正しいか確認する。

antml:invoke name="Bash">
<parameter name="command">cd /x && git branch --show-current</parameter>
<parameter name="description">worktreeのブランチとベースを確認</parameter>
<parameter name="description">worktreeのブランチとベースを確認</parameter>
</invoke>
<function_results>fix/RPT-1157
failing SHA is ancestor: OK</function_results>

ベースは失敗 run と同一 SHA。'

# 資料 §1.2 の record 1300 相当。Edit(file_path) と Bash(run_in_background) が混在する。
FAB_MULTI='修正を適用してビルドする。

antml:invoke name="Edit">
<parameter name="file_path">/src/PLReportTableDetailSnapshotTestDataCreator.kt</parameter>
</invoke>
<function_results>applied</function_results>

antml:invoke name="Bash">
<parameter name="command">./gradlew build</parameter>
<parameter name="description">nix環境でスナップショットテストを実行</parameter>
<parameter name="run_in_background">true</parameter>
</invoke>
<function_results>started</function_results>
'

# --- 正例: 検出 -------------------------------------------------------------
write_transcript pos359 "$(user_text 'worktree 作って')" \
    "$(assistant_text "$FAB_359" '{"input_tokens":100,"cache_read_input_tokens":126000,"cache_creation_input_tokens":900}')"
check "detect-359-summary" "以下 1 件のツール呼び出しが text として出力され、実行されていません:" "$(first_line pos359)"
check "detect-359-list" "  - Bash: worktreeのブランチとベースを確認" "$(run pos359 | sed -n '2p')"
# 累積コンテキストは表示のみ（判定には使わない）
check "detect-359-context" "現在のコンテキスト: 約 127k トークン" "$(run pos359 | tail -1)"

write_transcript posmulti "$(user_text '直して')" "$(assistant_text "$FAB_MULTI")"
check "detect-multi-count" "以下 2 件のツール呼び出しが text として出力され、実行されていません:" "$(first_line posmulti)"
check "detect-multi-bg" "  - Bash: nix環境でスナップショットテストを実行 (run_in_background)" "$(run posmulti | sed -n '2p')"
check "detect-multi-path" "  - Edit: /src/PLReportTableDetailSnapshotTestDataCreator.kt" "$(run posmulti | sed -n '3p')"

# 開始タグの "<" が残った形。本マシンの実セッション（22fa08dc / 10e744bd）で
# 実際に観測された形で、剥落形と両方に対応する必要がある。
write_transcript posangle "$(user_text '直して')" \
    "$(assistant_text 'テストを直します。

<invoke name="Edit">
<parameter name="file_path">/home/yasunori/dotfiles/scripts/test_plan.py</parameter>
</invoke>')"
check "detect-angle-form" "  - Edit: /home/yasunori/dotfiles/scripts/test_plan.py" "$(run posangle | sed -n '2p')"

# 開始タグが無く結果タグだけでも捏造と見なす
write_transcript resultonly "$(user_text 'やって')" \
    "$(assistant_text '確認した。
<function_results>clean</function_results>
問題なし。')"
check "result-tag-only" "  - (ツール名不明)" "$(run resultonly | sed -n '2p')"

# --- 偽陽性の除外 -----------------------------------------------------------
# フェンス引用（資料の 4bb91136 相当）。フェンス内にインラインバッククォートを含み、
# インラインコード除去を先に走らせるとフェンスの対応が崩れるケースを兼ねる。
write_transcript fpfence "$(user_text '現象を説明して')" \
    "$(assistant_text '現象の実例を引用する:

```
antml:invoke name="Bash">
<parameter name="command">git status</parameter>
</invoke>
<function_results>`clean` と表示された</function_results>
```

このように text へ混入する。')"
check "fp-fence" "" "$(run fpfence)"

# インラインコードでの言及（資料の 34b538d5 / 117ae7a0 相当）
write_transcript fpinline "$(user_text '分析して')" \
    "$(assistant_text 'サブエージェントの `invoke name="StructuredOutput"` 呼び出しが失敗し、`<function_results>` が返らなかった。')"
check "fp-inline" "" "$(run fpinline)"

# 通常の応答
write_transcript fpplain "$(user_text 'やって')" "$(assistant_text '完了しました。テストは通っています。')"
check "fp-plain" "" "$(run fpplain)"

# 文中（行頭以外）での言及は拾わない
write_transcript fpmidline "$(user_text '説明して')" \
    "$(assistant_text 'ログ中に invoke name="Bash" という文字列が現れることがある。')"
check "fp-mid-line" "" "$(run fpmidline)"

# --- 走査範囲 ---------------------------------------------------------------
# 前ターンの捏造は今回のターンに数えない（実 user 発話が境界になる）
write_transcript scopeprev "$(user_text '最初の依頼')" "$(assistant_text "$FAB_359")" \
    "$(user_text '次の依頼')" "$(assistant_text '今回は普通の応答です。')"
check "scope-prev-turn-excluded" "" "$(run scopeprev)"

# tool_result のみの user record はターンの途中なので跨いで走査する
write_transcript scopetr "$(user_text '依頼')" "$(assistant_text '実行する。')" \
    "$(tool_result_user)" "$(assistant_text "$FAB_359")"
check "scope-cross-tool-result" "以下 1 件のツール呼び出しが text として出力され、実行されていません:" "$(first_line scopetr)"

# サブエージェント側の record は親ターンの成果ではないので除外する
write_transcript sidechain "$(user_text '依頼')" \
    "$(jq -cn --arg t "$FAB_359" '{type:"assistant", isSidechain:true, message:{role:"assistant", content:[{type:"text", text:$t}]}}')" \
    "$(assistant_text '普通の応答')"
check "scope-sidechain-excluded" "" "$(run sidechain)"

# --- D4: 2 連続検出時のエスカレーション -------------------------------------
OURS_FEEDBACK='Stop hook feedback:
以下 1 件のツール呼び出しが text として出力され、実行されていません:
  - Bash: 前回の捏造'
OTHER_FEEDBACK='Stop hook feedback:
稼働中のサブエージェント/チームメイトが 1 体残っています:'

write_transcript escours "$(user_text '依頼')" "$(assistant_text "$FAB_359")" \
    "$(jq -cn --arg t "$OURS_FEEDBACK" '{type:"user", isMeta:true, message:{role:"user", content:$t}}')" \
    "$(assistant_text "$FAB_359")"
check "escalate-second-hit" "実行されていないツール呼び出しが text として出力され、2 ターン連続で検出されました。" \
    "$(first_line escours '{"stop_hook_active":true}')"
# stop_hook_active が false なら通常文面のまま（block 経由の再応答ではない）
check "escalate-needs-active" "以下 1 件のツール呼び出しが text として出力され、実行されていません:" \
    "$(first_line escours '{"stop_hook_active":false}')"

# 他 hook 由来の block で継続中なら、本 hook としては 1 回目なので通常文面
write_transcript escother "$(user_text '依頼')" "$(assistant_text "$FAB_359")" \
    "$(jq -cn --arg t "$OTHER_FEEDBACK" '{type:"user", isMeta:true, message:{role:"user", content:$t}}')" \
    "$(assistant_text "$FAB_359")"
check "escalate-foreign-block" "以下 1 件のツール呼び出しが text として出力され、実行されていません:" \
    "$(first_line escother '{"stop_hook_active":true}')"

# --- 未実行完了主張型（XML の痕跡を残さない捏造） ----------------------------
# 資料の追補 record 435 相当。Write の tool_use が無いまま作成を報告し、
# 主張されたパスが実在しない。
CLAIM_435='引き継ぎ書を再作成しました。

**ファイル**: `~/src/github.com/yasunori0418/skills/tmp_claude/DOES_NOT_EXIST_plan.md`

内容は削除前と同一です。私のコンテキストに全文が残っていたため、欠落なく復元できています。'

write_transcript claimpos "$(user_text '元に戻して')" "$(assistant_text '確認する。')" \
    "$(tool_result_user)" "$(assistant_text "$CLAIM_435")"
check "claim-detect" "このターンでファイル作成/更新を報告していますが、Write/Edit の実行がありません:" "$(first_line claimpos)"
check "claim-detect-path" "  - ~/src/github.com/yasunori0418/skills/tmp_claude/DOES_NOT_EXIST_plan.md （存在しません）" \
    "$(run claimpos | sed -n '2p')"

# 同一ターンに Write があれば対象外（実行の痕跡が構造として残っている）
write_transcript claimwrite "$(user_text '作って')" \
    "$(jq -cn --arg t '作成しました。

**ファイル**: `~/DOES_NOT_EXIST_b.md`' \
        '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t},{type:"tool_use", id:"t1", name:"Write", input:{}}]}}')"
check "claim-has-write" "" "$(run claimwrite)"

# 引用行（事象を報告するための正当な引用）は主張と見なさない
write_transcript claimquote "$(user_text '報告して')" \
    "$(assistant_text 'モデルは次のように出力していた:

> 引き継ぎ書を再作成しました。
> **ファイル**: `~/DOES_NOT_EXIST_c.md`

これは虚偽だった。')"
check "claim-quoted" "" "$(run claimquote)"

# 実在するファイルへの言及は、別ターンで作成済みの可能性があるので検出しない
write_transcript claimexists "$(user_text 'やって')" \
    "$(assistant_text "レポートを保存しました。

**ファイル**: \`$SCRIPT_DIR/../main.sh\`")"
check "claim-file-exists" "" "$(run claimexists)"

# 主張行から 4 行を超えて離れたパス言及は拾わない
write_transcript claimfar "$(user_text 'やって')" \
    "$(assistant_text '作成しました。

あ
い
う
え
お

参考: `~/DOES_NOT_EXIST_d.md`')"
check "claim-far-path" "" "$(run claimfar)"

# 完了主張だけでパス言及が無ければ検証点が無いので検出しない
write_transcript claimnopath "$(user_text 'やって')" "$(assistant_text '作成しました。問題ありません。')"
check "claim-no-path" "" "$(run claimnopath)"

# 2 つのチェックは独立しており、両方該当すれば両方が reason に出る
write_transcript claimboth "$(user_text 'やって')" \
    "$(assistant_text 'antml:invoke name="Bash">
<parameter name="description">ビルド実行</parameter>
</invoke>
<function_results>ok</function_results>

レポートを作成しました。

**ファイル**: `~/DOES_NOT_EXIST_both.md`')"
check "both-checks-xml" "以下 1 件のツール呼び出しが text として出力され、実行されていません:" "$(first_line claimboth)"
check "both-checks-claim" "1" "$(run claimboth | grep -c 'Write/Edit の実行がありません')"

# 完了主張型の block が直前にあっても D4 のエスカレーションへ入る
CLAIM_FEEDBACK='Stop hook feedback:
このターンでファイル作成/更新を報告していますが、Write/Edit の実行がありません:
  - ~/DOES_NOT_EXIST_e.md （存在しません）'
write_transcript claimesc "$(user_text 'やって')" \
    "$(assistant_text '作成しました。

`~/DOES_NOT_EXIST_e.md`')" \
    "$(jq -cn --arg t "$CLAIM_FEEDBACK" '{type:"user", isMeta:true, message:{role:"user", content:$t}}')" \
    "$(assistant_text '作成しました。

`~/DOES_NOT_EXIST_e.md`')"
check "claim-escalates" "実行されていないツール呼び出しが text として出力され、2 ターン連続で検出されました。" \
    "$(first_line claimesc '{"stop_hook_active":true}')"

# --- fail-open --------------------------------------------------------------
check "missing-transcript-path" "" \
    "$(printf '%s' '{}' | "$GUARD" | jq -r 'select(.decision == "block") | .reason // empty')"
check "nonexistent-file" "" \
    "$(printf '%s' '{"transcript_path":"/nonexistent/transcript.jsonl"}' | "$GUARD" | jq -r 'select(.decision == "block") | .reason // empty')"
check "broken-stdin" "" \
    "$(printf 'not json' | "$GUARD" | jq -r 'select(.decision == "block") | .reason // empty' 2>/dev/null || true)"
: >"$WORK/empty.jsonl"
check "empty-transcript" "" "$(run empty)"
printf 'not json at all\n' >"$WORK/brokenjsonl.jsonl"
check "broken-transcript" "" "$(run brokenjsonl)"

# --- 出力形式のリグレッション ------------------------------------------------
# cchook は Stop の hookSpecificOutput を "not supported" として握り潰すため、
# decision/reason 形式だけを出すことを固定する。
SHAPE=$(jq -cn --arg p "$WORK/pos359.jsonl" '{transcript_path:$p}' | "$GUARD" \
    | jq -r '[(.decision // "-"), (if has("hookSpecificOutput") then "has-hso" else "no-hso" end)] | join(",")')
check "output-shape" "block,no-hso" "$SHAPE"

# reason 自身が検出対象の文字列を含まないこと。含むと、次ターンでモデルが
# reason を引用しただけで再検出される自家中毒が起きる。
SELF=$(run pos359 | grep -cE 'invoke name="|<function_results>' || true)
check "reason-is-not-self-triggering" "0" "$SELF"

exit "$fail"
