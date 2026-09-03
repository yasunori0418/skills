#!/usr/bin/env bash
# fabricated-toolcall-guard/main.sh — Stop hook。
# 「ツール呼び出しの XML が assistant の text ブロックに平文として書かれ、
# その実行結果まで捏造される」現象（self-rollout）を検出し、decision: "block" で
# 未検証の記述を洗い直させる。
#
# 【検出範囲の限界 — 必読】
#   本 hook が捕捉できるのは「XML 混入型」だけである。捏造にはツール呼び出しの
#   痕跡が一切残らない型（「ファイルを作成しました」等の主張のみで tool_use が無い）
#   も実在し、そちらは文字列マッチでは原理的に検出できない。全体を捕捉するには
#   「完了を主張するテキスト」と「そのターンの実 tool_use」を突き合わせる別ロジックが
#   要るが、本 hook はその設計を含まない部分対策である。
#   沈黙は「捏造が無かった」ことの保証にはならない。
#
# 検出ロジック（実データ 25 件で正例 25/25 検出・偽陽性 3/3 除外を確認した方式）:
#   コードフェンス（```...```）とインラインコード（`...`）を除去してから、
#   行頭の invoke 開始タグと結果タグをマッチする。この現象を説明・引用しただけの
#   正当なテキストは、ほぼ必ずコード表記の中にあるため除去段階で落ちる。
#   開始タグは先頭の "<" が剥落した形でも格納されうるため、両形に対応する。
#
# 走査範囲:
#   transcript を末尾から遡り、type=user かつ content が tool_result 以外の record
#   （＝実際のユーザー発話、または前回の block reason）までを「今回のターン」とする。
#   block reason は user record として transcript に入るので、範囲が自然に切れる。
#   state ファイルは要らない。
#
# 出力形式に decision/reason を使う理由（hookSpecificOutput ではなく）:
#   cchook 経由だと Stop の hookSpecificOutput は "not supported" として握り潰され
#   Claude まで届かない（teammate-leak-guard で実測済み）。decision/reason は
#   両経路（plugin 直・cchook）で素通しされる。
#
# reason の文面には検出対象の文字列そのものを含めない。含めると、次ターンで
# モデルが reason を引用しただけで再検出される自家中毒が起きる。
#
# fail-open 設計:
#   jq が無い・JSON が壊れている・transcript_path が欠落/不在のいずれでも黙って exit 0。
#   Stop hook は全ターンの終端で発火するため、誤作動のコストが高い。
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)

# 前ターンの本 hook 由来 block を見分けるための安定マーカー。
# reason の 1 行目に必ず現れる（検出対象の文字列は含まない）。
MARKER="ツール呼び出しが text として出力され"

# transcript を 1 度だけ読む。捏造ツールの一覧は行として、
# 付随情報（2 連続判定・表示用コンテキスト）は先頭のヘッダ 1 行として受け取る。
#   1 行目: "<yes|no>\t<累積コンテキスト k トークン。取れなければ空>"
#   2 行目以降: 捏造ツールの一覧（空なら未検出）
result=$(jq -rs --arg marker "$MARKER" '
    # --- ヘルパ ---------------------------------------------------------
    # コードフェンス → インラインコードの順に除去する。順序は重要で、
    # 逆にするとフェンス内のバッククォートで囲まれた断片が先に消え、
    # フェンス自体の対応が崩れる。
    # jq(Oniguruma) の "." は改行にマッチしないため [\s\S] を使う。
    def strip_code:
        gsub("```[\\s\\S]*?```"; "")
        | gsub("`[^`\\n]*`"; "");

    # user record の content が tool_result のみか（＝ターンの途中か）を判定する。
    # tool_result も type=user で流れてくるため、content の形で見分ける必要がある。
    def is_tool_result_only:
        (.message.content // null) as $c
        | if ($c | type) == "array"
          then ($c | length > 0) and ([ $c[] | (.type? // "") ] | all(. == "tool_result"))
          else false
          end;

    # --- 走査範囲の切り出し ---------------------------------------------
    # サブエージェント側の record（isSidechain）は親ターンの成果ではないので除く。
    [ .[] | select((.isSidechain // false) | not) ] as $records

    # 末尾から遡り、境界となる user record の位置を探す。
    | ( [ $records | to_entries[]
          | select(.value.type == "user" and ((.value | is_tool_result_only) | not))
          | .key ] | last ) as $boundary

    | (if $boundary == null then $records else $records[($boundary + 1):] end) as $turn

    # 境界 record が本 hook の block reason かどうか（2 連続検出の判定に使う）。
    | (if $boundary == null then false
       else ( ($records[$boundary].message.content // "")
              | if type == "string" then . else ([ .[]? | .text? // "" ] | join("\n")) end
              | contains($marker) )
       end) as $prev_was_ours

    # --- 検出 -----------------------------------------------------------
    | [ $turn[]
        | select(.type == "assistant")
        | .message.content[]?
        | select(.type == "text")
        | .text // ""
      ] as $texts

    | ($texts | map(strip_code)) as $clean

    # 各 text から invoke 開始タグを拾い、その直後の断片から補足情報を取り出す。
    # 開始タグは "<" 付き・剥落・接頭辞付きのいずれの形も許す。
    # 行頭アンカーを外さないこと（文中での言及を拾わないための最後の砦）。
    | [ $clean[]
        | . as $t
        | [ match("(?:^|\\n)[ \\t]*<?(?:antml:)?invoke name=\"([^\"]+)\""; "g") ] as $ms
        | range(0; ($ms | length)) as $i
        | $ms[$i] as $m
        # 次の invoke までを 1 呼び出し分の断片として切り出す。
        | ( if ($i + 1) < ($ms | length) then $ms[$i + 1].offset else ($t | length) end ) as $end
        | ($t[($m.offset):$end]) as $frag
        | {
            tool: ($m.captures[0].string // "?"),
            desc: ( [ $frag | match("parameter name=\"description\">([^<\\n]*)"; "g") ][0]
                    | if . == null then null else (.captures[0].string // null) end ),
            path: ( [ $frag | match("parameter name=\"file_path\">([^<\\n]*)"; "g") ][0]
                    | if . == null then null else (.captures[0].string // null) end ),
            bg:   ( $frag | test("parameter name=\"run_in_background\">[ \\t]*true") )
          }
      ] as $calls

    # 開始タグが 1 つも無くても、結果タグだけが出ていれば捏造と見なす。
    | ( [ $clean[] | select(test("<function_results>")) ] | length > 0 ) as $has_result

    | ( $calls
        | map( "  - " + .tool
               + ( if .desc != null and (.desc | length) > 0
                   then ": " + (.desc | .[0:100])
                   elif .path != null and (.path | length) > 0
                   then ": " + (.path | .[0:100])
                   else "" end )
               + ( if .bg then " (run_in_background)" else "" end ) )
        | unique
      ) as $lines

    # --- 表示用の累積コンテキスト（判定には使わない） --------------------
    | ( [ $turn[] | select(.type == "assistant") | .message.usage // empty ] | last ) as $usage
    | ( if $usage == null then ""
        else ( ( ($usage.input_tokens // 0)
                 + ($usage.cache_read_input_tokens // 0)
                 + ($usage.cache_creation_input_tokens // 0) ) / 1000 | floor | tostring )
        end ) as $ctx

    | ( if ($lines | length) == 0 and ($has_result | not) then []
        elif ($lines | length) == 0 then ["  - (ツール名不明)"]
        else $lines end ) as $out

    | [ ((if $prev_was_ours then "yes" else "no" end) + "\t" + $ctx) ] + $out
    | join("\n")
' "$transcript" 2>/dev/null || true)

[ -n "$result" ] || exit 0

header=$(printf '%s\n' "$result" | head -1)
detected=$(printf '%s\n' "$result" | tail -n +2)
prev_was_ours=$(printf '%s' "$header" | cut -f1)
ctx=$(printf '%s' "$header" | cut -f2)

[ -n "$detected" ] || exit 0

count=$(printf '%s\n' "$detected" | grep -c '^' || true)

# D4: 前ターンも本 hook で block していた場合は、再検証を促さずエスカレーションする。
# 同一コンテキストでの retry は解決にならない（retry 後に 4 回再発した実績がある）。
if [ "$prev_was_ours" = "yes" ] && [ "$active" = "true" ]; then
    reason="実行されていないツール呼び出しが text として出力され、2 ターン連続で検出されました。
再試行では解決しません（同一コンテキストでの retry 後に 4 回再発した実績があります）。
これ以上の検証を試みず、コンテキストを切る必要がある旨をユーザーへ報告して応答を終えてください。"
else
    reason="以下 ${count} 件のツール呼び出しが text として出力され、実行されていません:
${detected}
この応答でこれらの結果に依拠した記述は全て未検証です。各項目について実際に再実行するか、
効果を確認できる手段で実状態を確かめてください（背景タスクなら出力ファイルの存在、
ファイル編集なら git diff、ビルド開始ならプロセスや生成物の確認 — 手段は対象に応じて選ぶこと）。"
    if [ -n "$ctx" ]; then
        reason="${reason}
現在のコンテキスト: 約 ${ctx}k トークン"
    fi
fi

jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
