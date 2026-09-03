# detect.jq — fabricated-toolcall-guard の検出フィルタ。
#
# main.sh から `jq -rs --arg marker <正規表現> -f detect.jq <transcript>` として
# 呼ばれる。transcript(JSONL)全体を配列として受け取り、結果を行区切りで返す。
#
# 出力形式:
#   1 行目: "<yes|no>\t<累積コンテキスト k トークン。取れなければ空>"
#           yes = 直前のターンの境界が本 hook 由来の block だった(2 連続判定用)
#   2 行目: XML 混入型の検出件数 N(10 進)
#   3 行目〜(3+N-1): XML 混入型の一覧("  - <ツール名>: <説明>" 形式)
#   以降: 未実行完了主張型で主張されたファイルパス(実在確認は main.sh 側)
#
# 検出内容とその根拠は main.sh 冒頭のコメントを参照。

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
