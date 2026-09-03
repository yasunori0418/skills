#!/usr/bin/env bash
# fabricated-toolcall-guard/main.sh — Stop hook。
# ツールを実行していないのに実行したかのように応答する現象を検出し、
# decision: "block" で未検証の記述を洗い直させる。
#
# 独立した 2 つのチェックを持ち、どちらか一方でも該当すれば block する。
# 両者はカバー範囲が異なるため両方要る。
#
#   1. XML 混入型（check_xml_injection）
#      ツール呼び出しの XML が assistant の text ブロックへ平文として書かれ、
#      その実行結果まで捏造される（self-rollout）。あらゆるツールが対象になる。
#      痕跡（文字列）を探す方式。
#
#   2. 未実行完了主張型（check_unbacked_claim）
#      XML の痕跡を一切残さず「ファイルを作成しました」とだけ報告し、
#      そのターンに Write/Edit の tool_use が無い。主張と実行の不一致（構造）を
#      見る方式で、ファイル作成/更新の主張のみが対象。
#
# 【検出範囲の限界 — 必読】
#   上記 2 つを足しても捏造全体の一部しか捕捉しない。特に、XML を伴わない
#   コマンド実行の捏造（「ビルドを開始しました」等）と調査結果の捏造
#   （「確認したところ〜だった」）は、検証点が本文に無いため検出できない。
#   本 hook は部分対策であり、沈黙は「捏造が無かった」ことの保証にはならない。
#   hook を入れたことで安全になったと解釈しないこと。
#
# 検出ロジック 1（XML 混入型）:
#   コードフェンス（```...```）とインラインコード（`...`）を除去してから、
#   行頭の invoke 開始タグと結果タグをマッチする。この現象を説明・引用しただけの
#   正当なテキストは、ほぼ必ずコード表記の中にあるため除去段階で落ちる。
#   開始タグは先頭の "<" が剥落した形でも格納されうるため、両形に対応する。
#   別マシンの実データで正例 25/25 検出・偽陽性 3/3 除外。加えて本マシンの
#   全 561 セッション走査で 4 セッション 10 件の実発生を検出しており、
#   そのいずれも捏造ターンを末尾に置いた再現で正しく block される。
#
# 検出ロジック 2（未実行完了主張型）:
#   そのターンに Write/Edit/NotebookEdit の tool_use があれば対象外。
#   無い場合、コードフェンスを除去し、引用（>）・リスト（-）・表（|）の行を
#   飛ばしたうえで完了主張の表現を探し、その行から 4 行以内にファイルパスが
#   あれば候補とする。さらに候補パスへ実在確認を行い、実在しないものだけを
#   block する（別ターンで作成済みのファイルに言及しただけのケースを除くため）。
#   別マシンの全 174 セッション走査で該当 1 件・偽陽性 0。
#   本マシンの全 561 セッション走査では該当 0 件（＝未発生）。
#   完了主張の表現は日本語の定型（〜しました）に依存する。英語応答のセッションでは
#   取りこぼす。
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
# 2 つのチェックそれぞれの reason 見出しに現れる（検出対象の文字列は含まない）。
# 他 hook の block（teammate-leak-guard 等）と取り違えないよう、本 hook 固有の
# 言い回しに限定する。
MARKER="ツール呼び出しが text として出力され|報告していますが、Write/Edit の実行がありません"

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
              | test($marker) )
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

    # --- 検出 2: 未実行完了主張型 ---------------------------------------
    # そのターンで実際に呼ばれたツール名。Write 系があれば本チェックの対象外。
    | ( [ $turn[]
          | select(.type == "assistant")
          | .message.content[]?
          | select(.type == "tool_use")
          | .name // ""
        ] ) as $used_tools

    | ( ($used_tools | any(. == "Write" or . == "Edit" or . == "NotebookEdit" or . == "MultiEdit")) ) as $has_writer

    # フェンスのみ除去する（インラインコードはパスの抽出に使うので残す）。
    | ( $texts | map(gsub("```[\\s\\S]*?```"; "")) | join("\n") | split("\n") ) as $blines

    | ( if $has_writer then []
        else
          [ range(0; ($blines | length)) as $i
            | ($blines[$i] | sub("^[ \\t]+"; "")) as $s
            # 引用・リスト・表の行は、事象の報告や一覧の一部なので主張と見なさない。
            | select(($s | startswith(">")) | not)
            | select(($s | startswith("- ")) | not)
            | select(($s | startswith("| ")) | not)
            | select($s | test("(作成しました|再作成しました|書き出しました|保存しました)"))
            # 主張行から 4 行以内のパス言及だけを候補にする。
            | ($blines[$i:($i + 4)] | join("\n")) as $win
            | [ $win | match("`([~/][^`\\s]*/[^`\\s]+\\.(?:md|py|sh|nix|ya?ml|json|ts|kt|txt))`"; "g")
                | .captures[0].string ]
            | .[]
          ] | unique
        end ) as $claimed

    | [ ((if $prev_was_ours then "yes" else "no" end) + "\t" + $ctx),
        (($out | length) | tostring) ]
      + $out + $claimed
    | join("\n")
' "$transcript" 2>/dev/null || true)

[ -n "$result" ] || exit 0

prev_was_ours=$(printf '%s\n' "$result" | sed -n '1p' | cut -f1)
ctx=$(printf '%s\n' "$result" | sed -n '1p' | cut -f2)
xml_count=$(printf '%s\n' "$result" | sed -n '2p')
[ -n "$xml_count" ] || exit 0

# 3 行目以降を XML 混入型の一覧と、完了主張型の候補パスへ分ける。
detected=""
[ "$xml_count" -gt 0 ] 2>/dev/null && detected=$(printf '%s\n' "$result" | sed -n "3,$((2 + xml_count))p")
claimed=$(printf '%s\n' "$result" | tail -n +"$((3 + xml_count))")

# 完了主張型は、主張されたパスが実在しないものだけを採る。
# 別ターンで作成済みのファイルに言及しただけのケースを構造的に除くため。
missing=""
if [ -n "$claimed" ]; then
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        # 先頭の ~ はホームへ展開する（パラメータ展開のみ。eval はしない）。
        case "$p" in
            "~/"*) resolved="$HOME/${p#\~/}" ;;
            *) resolved="$p" ;;
        esac
        [ -e "$resolved" ] && continue
        missing="${missing}  - ${p} （存在しません）
"
    done <<EOF
$claimed
EOF
fi
missing=${missing%$'\n'}

[ -n "$detected" ] || [ -n "$missing" ] || exit 0

# D4: 前ターンも本 hook で block していた場合は、再検証を促さずエスカレーションする。
# 同一コンテキストでの retry は解決にならない（retry 後に 4 回再発した実績がある）。
if [ "$prev_was_ours" = "yes" ] && [ "$active" = "true" ]; then
    reason="実行されていないツール呼び出しが text として出力され、2 ターン連続で検出されました。
再試行では解決しません（同一コンテキストでの retry 後に 4 回再発した実績があります）。
これ以上の検証を試みず、コンテキストを切る必要がある旨をユーザーへ報告して応答を終えてください。"
else
    reason=""
    if [ -n "$detected" ]; then
        count=$(printf '%s\n' "$detected" | grep -c '^' || true)
        reason="以下 ${count} 件のツール呼び出しが text として出力され、実行されていません:
${detected}
この応答でこれらの結果に依拠した記述は全て未検証です。各項目について実際に再実行するか、
効果を確認できる手段で実状態を確かめてください（背景タスクなら出力ファイルの存在、
ファイル編集なら git diff、ビルド開始ならプロセスや生成物の確認 — 手段は対象に応じて選ぶこと）。"
    fi
    if [ -n "$missing" ]; then
        [ -n "$reason" ] && reason="${reason}

"
        reason="${reason}このターンでファイル作成/更新を報告していますが、Write/Edit の実行がありません:
${missing}
報告した内容は実行されていません。実際にファイルを作成してから応答し直してください。
既に別のターンで作成済みの場合は、その旨が分かる表現に直してください。"
    fi
    if [ -n "$ctx" ]; then
        reason="${reason}
現在のコンテキスト: 約 ${ctx}k トークン"
    fi
fi

jq -cn --arg r "$reason" '{decision: "block", reason: $r}'
