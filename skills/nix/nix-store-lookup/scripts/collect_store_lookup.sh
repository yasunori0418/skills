#!/usr/bin/env bash
# collect_store_lookup.sh — /nix/store の探索対象を決定論的に解決する収集スクリプト。
#
# 目的:
#   `find /nix/store` による名前の総当たりを、入力から一意に引くクエリへ置き換える。
#   /nix/store は数万エントリあり深さ無制限の find は完了しない（実測 35,220 件・
#   20 秒経っても終わらず出力ゼロ）。一方、入力として何を持っているかが分かれば
#   0.005〜0.9 秒で解ける公式コマンドがある。その「入力の分類」と「解決」を
#   AI の推論に任せず、ここで機械的に確定させる。
#
# 使い方:
#   collect_store_lookup.sh <query> [--all] [--flake <dir>]
#
#     <query>   探索したいもの。種別は指定不要（スクリプトが分類する）:
#               - PATH に通ったコマンド名        （例: nput, rg）
#               - store path                     （例: /nix/store/xxx-foo-1.0）
#               - derivation パス                （例: /nix/store/xxx-foo.drv）
#               - パッケージ名・部分文字列        （例: nix-unit, ripgrep）
#
#     --all     ローカルで一意に解決できた場合でも upstream index（nix-locate）を
#               照会する。既定では skip する: nix-locate は upstream nixpkgs の
#               index であってローカル store の索引ではなく、返す path は
#               ローカルに存在しないことがある（実測で 3 件中 2 件が MISSING）。
#               ローカルで解決済みなのに紛らわしい候補を並べると誤誘導になるため。
#
#     --flake <dir>  flake input の store path も収集する（既定: カレントが
#                    flake なら自動で収集）。`nix flake archive --json --dry-run`
#                    を使うのでダウンロードは発生しない。
#
# 出力: JSON（1 オブジェクト）。主要キー:
#   .classified_as  入力の種別（store_path / derivation / command_on_path /
#                   name_query のいずれか）
#   .resolved       一意に確定した結果。null でなければ AI 側の分岐は不要
#   .candidates     一意に決まらないときの材料。local_db / upstream_index
#   .context        環境の事実（store 件数・利用可能ツール・flake inputs）
#   .warnings       誤誘導を招く事象（upstream 候補がローカル未存在 等）
#
# 設計上の要点:
#   全候補に exists（ディスク上の実在）を付ける。nix-locate の「返る path が
#   実在しない」という反直感的な挙動を、AI の記憶ではなくデータとして渡すため。
#
# 前提: nix, jq。sqlite3 があればローカル DB を高速に引く（0.022s）。
#       無ければ `nix path-info --all`（2.85s）へフォールバックする。
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

STORE_DB="/nix/var/nix/db/db.sqlite"

query=""
want_all=0
flake_dir=""

while [ $# -gt 0 ]; do
    case "$1" in
        --all) want_all=1; shift ;;
        --flake) flake_dir="${2:?--flake にはディレクトリを指定してください}"; shift 2 ;;
        -h | --help) sed -n '2,45p' "$0"; exit 0 ;;
        -*) die "未知のオプション: $1" ;;
        *)
            [ -z "$query" ] || die "query は 1 つだけ指定してください（'$query' と '$1'）"
            query="$1"; shift
            ;;
    esac
done

[ -n "$query" ] || die "探索対象を指定してください（コマンド名・store path・drv・パッケージ名のいずれか）"
command -v jq >/dev/null 2>&1 || die "jq が見つかりません"

have() { command -v "$1" >/dev/null 2>&1; }

# --- 入力の分類（決定論） --------------------------------------------------
# ここで種別が決まれば、以降の解決経路は一意に定まる。
classify() {
    case "$query" in
        /nix/store/*.drv) echo "derivation"; return ;;
        /nix/store/*) echo "store_path"; return ;;
    esac
    # PATH 上のコマンドかどうか。nix 管理なら profile 経由の symlink を辿れば
    # store path が一意に出る（実測 0.005s / 最優先経路）。
    if have "$query"; then
        echo "command_on_path"; return
    fi
    echo "name_query"
}

classified=$(classify)

# --- 解決（種別ごとに一意な経路をとる） ------------------------------------
resolved_json="null"
warnings=()

exists_of() { # path -> "true" | "false"
    [ -e "$1" ] && echo true || echo false
}

# store path から drv / 出力パスを相互に辿る。失敗しても致命ではない。
query_deriver() { nix-store --query --deriver "$1" 2>/dev/null || true; }
query_outputs() { nix-store --query --outputs "$1" 2>/dev/null || true; }

case "$classified" in
    command_on_path)
        real=$(readlink -f "$(command -v "$query")" 2>/dev/null || true)
        if [ -n "$real" ]; then
            # /nix/store/<hash>-<name>/... から store path 本体を切り出す
            root=$(printf '%s' "$real" | sed -E 's#^(/nix/store/[^/]+).*#\1#')
            case "$root" in
                /nix/store/*)
                    resolved_json=$(jq -cn \
                        --arg sp "$root" --arg bin "$real" \
                        --arg via 'readlink -f "$(command -v <cmd>)"' \
                        --argjson ex "$(exists_of "$root")" \
                        '{store_path: $sp, resolved_file: $bin, via: $via, exists: $ex}')
                    ;;
                *)
                    # nix 管理ではない（/usr/bin 等）。store path は存在しない。
                    resolved_json=$(jq -cn --arg bin "$real" \
                        '{store_path: null, resolved_file: $bin, via: "readlink -f", exists: true, note: "nix 管理外のコマンド（store path は無い）"}')
                    warnings+=("'$query' は PATH 上にあるが nix store 配下ではない（$real）")
                    ;;
            esac
        fi
        ;;

    store_path)
        root=$(printf '%s' "$query" | sed -E 's#^(/nix/store/[^/]+).*#\1#')
        resolved_json=$(jq -cn --arg sp "$root" \
            --arg drv "$(query_deriver "$root")" \
            --argjson ex "$(exists_of "$root")" \
            '{store_path: $sp, deriver: (if $drv == "" then null else $drv end), via: "input は既に store path", exists: $ex}')
        [ -e "$root" ] || warnings+=("指定された store path はディスク上に存在しない: $root")
        ;;

    derivation)
        outs=$(query_outputs "$query")
        if [ -n "$outs" ]; then
            resolved_json=$(printf '%s\n' "$outs" | jq -R . | jq -sc \
                --arg drv "$query" \
                '{derivation: $drv, via: "nix-store --query --outputs", outputs: [.[] | {path: ., exists: null}]}')
            # exists を各出力に埋める（jq 内では判定できないので shell 側で）
            tmp="$resolved_json"
            resolved_json=$(printf '%s' "$tmp" | jq -c '.outputs |= map(.)')
            filled="[]"
            while IFS= read -r o; do
                [ -n "$o" ] || continue
                filled=$(printf '%s' "$filled" | jq -c --arg p "$o" --argjson e "$(exists_of "$o")" '. + [{path: $p, exists: $e}]')
            done <<EOF
$outs
EOF
            resolved_json=$(printf '%s' "$resolved_json" | jq -c --argjson f "$filled" '.outputs = $f')
        else
            warnings+=("derivation の出力パスを取得できなかった（未ビルド、または drv がローカルに無い）: $query")
        fi
        ;;
esac

# --- 候補の収集（一意に決まらないとき用） ----------------------------------
# ローカル store の検索。DB を読み取り専用（immutable=1）で引く。
# sqlite3 が無ければ公式コマンドへフォールバックする。
local_db_json="[]"
local_db_via=""
local_db_total=0
# 実在確認を回す上限。超えると候補として使い物にならず、時間もかかる。
LOCAL_MATCH_LIMIT="${LOCAL_MATCH_LIMIT:-50}"

collect_local() {
    local pattern="$1" lines="" total=0
    # 短い検索語は大量にマッチする（実測: '%rg%' で 5,984 件）。全件に実在確認を
    # かけると桁違いに遅くなるうえ、数千件の候補は AI にとって選択不能で
    # 「find が 20 件返して選べない」問題を悪化させるだけ。上限で打ち切り、
    # 超過したことを warning で明示して絞り込みを促す。
    if have sqlite3 && [ -r "$STORE_DB" ]; then
        local_db_via="sqlite3 ValidPaths (immutable=1)"
        local esc="${pattern//\'/}"
        total=$(sqlite3 "file:${STORE_DB}?immutable=1" \
            "select count(*) from ValidPaths where path like '%${esc}%';" 2>/dev/null || echo 0)
        lines=$(sqlite3 "file:${STORE_DB}?immutable=1" \
            "select path from ValidPaths where path like '%${esc}%' order by path limit ${LOCAL_MATCH_LIMIT};" 2>/dev/null || true)
    elif have nix; then
        local_db_via="nix path-info --all"
        local all
        all=$(nix path-info --all 2>/dev/null | grep -- "$pattern" || true)
        total=$(printf '%s' "$all" | grep -c . || true)
        lines=$(printf '%s\n' "$all" | head -n "$LOCAL_MATCH_LIMIT")
    else
        warnings+=("sqlite3 も nix も使えないためローカル store を検索できなかった")
        return
    fi
    local_db_total="$total"
    if [ "${total:-0}" -gt "$LOCAL_MATCH_LIMIT" ]; then
        warnings+=("ローカル候補が ${total} 件あり先頭 ${LOCAL_MATCH_LIMIT} 件だけを返した。検索語 '${pattern}' が短すぎて絞り込めていない。より長い名前・バージョンを含めて再実行するか、PATH 上のコマンド名や derivation を入力にすること")
    fi
    # 1 行ずつ jq を起動すると候補数に比例してプロセス生成コストが効く
    # （実測で数十秒規模になった）。TSV に整形して jq 1 回で組み立てる。
    local_db_json=$(
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            local isdrv=false
            case "$p" in *.drv) isdrv=true ;; esac
            printf '%s\t%s\t%s\n' "$p" "$isdrv" "$(exists_of "$p")"
        done <<EOF | jq -Rsc '[splits("\n") | select(. != "") | split("\t")
                               | {path: .[0], is_drv: (.[1] == "true"), exists: (.[2] == "true")}]'
$lines
EOF
    )
}

# 検索キーは name_query ならそのまま、それ以外は store path の name 部分を使う。
search_key="$query"
case "$classified" in
    store_path | derivation)
        search_key=$(basename "$query" | sed -E 's/^[a-z0-9]{32}-//; s/\.drv$//')
        ;;
esac
collect_local "$search_key"

# upstream index（nix-locate）。既定では resolved が確定していれば照会しない。
# 理由: nix-locate は upstream nixpkgs の index であってローカルの索引ではなく、
# 返る path はローカルに存在しないことがある（実測 3 件中 2 件 MISSING）。
# ローカルで解決済みなら、紛らわしい候補を並べる方が誤誘導になる。
upstream_json="null"
upstream_skipped_reason=""

if have nix-locate; then
    if [ "$resolved_json" != "null" ] && [ "$want_all" -eq 0 ]; then
        upstream_skipped_reason="ローカルで一意に解決済みのため skip（--all で強制照会）"
    else
        # nix-locate は upstream index 全体を舐めるため、短い検索語だと
        # 大量マッチして時間がかかる。上限時間を設けて打ち切る（打ち切っても
        # ローカル解決には影響しない）。
        locate_raw=$(timeout 15 nix-locate -w "$search_key" 2>/dev/null | head -20 || true)
        upstream_json=$(
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                p=$(printf '%s' "$line" | awk '{print $NF}')
                case "$p" in /nix/store/*) ;; *) continue ;; esac
                printf '%s\t%s\t%s\n' "$(printf '%s' "$line" | awk '{print $1}')" "$p" "$(exists_of "$p")"
            done <<EOF | jq -Rsc '[splits("\n") | select(. != "") | split("\t")
                                   | {attr: .[0], path: .[1], exists_locally: (.[2] == "true")}]'
$locate_raw
EOF
        )
        out="$upstream_json"
        missing=$(printf '%s' "$out" | jq '[.[] | select(.exists_locally == false)] | length')
        total=$(printf '%s' "$out" | jq 'length')
        if [ "${missing:-0}" -gt 0 ]; then
            warnings+=("upstream index の候補 ${total} 件中 ${missing} 件はローカルに存在しない。nix-locate は upstream nixpkgs の索引であり、ローカル store の索引ではない。これらの path を掴むと後続の操作が失敗する")
        fi
    fi
else
    upstream_skipped_reason="nix-locate が未導入"
fi

# --- 環境の事実 ------------------------------------------------------------
store_entries=$(ls /nix/store 2>/dev/null | wc -l | tr -d ' ')
db_valid=""
if have sqlite3 && [ -r "$STORE_DB" ]; then
    db_valid=$(sqlite3 "file:${STORE_DB}?immutable=1" "select count(*) from ValidPaths;" 2>/dev/null || true)
fi
# filesystem と DB の差は、ビルド中の一時ファイル・.lock・GC 待ちの残骸。
# これらは DB クエリでは出ないため、探しているのがそれなら find -maxdepth 1 が要る。
if [ -n "$db_valid" ] && [ "$store_entries" -gt "$db_valid" ]; then
    warnings+=("filesystem($store_entries) と DB($db_valid) が $((store_entries - db_valid)) 件ずれている。差分はビルド中の一時ファイル・.lock・GC 待ちの残骸で、DB クエリには出ない")
fi

# flake inputs。--flake 指定、またはカレントが flake なら収集する。
flake_json="null"
target_flake=""
if [ -n "$flake_dir" ]; then
    target_flake="$flake_dir"
elif [ -f "./flake.nix" ]; then
    target_flake="."
fi
if [ -n "$target_flake" ] && have nix; then
    # --dry-run なのでダウンロードは発生しない（実測 0.086s）。
    flake_json=$(nix flake archive --json --dry-run "$target_flake" 2>/dev/null || echo null)
fi

warnings_json=$(printf '%s\n' "${warnings[@]+"${warnings[@]}"}" | jq -R . | jq -sc '[.[] | select(. != "")]')

jq -n \
    --arg q "$query" \
    --arg cls "$classified" \
    --argjson resolved "$resolved_json" \
    --argjson local_db "$local_db_json" \
    --arg local_via "$local_db_via" \
    --arg total "${local_db_total:-0}" \
    --argjson upstream "$upstream_json" \
    --arg upstream_skip "$upstream_skipped_reason" \
    --arg entries "$store_entries" \
    --arg dbvalid "${db_valid:-}" \
    --argjson flake "$flake_json" \
    --argjson warnings "$warnings_json" \
    --argjson has_sqlite "$(have sqlite3 && echo true || echo false)" \
    --argjson has_locate "$(have nix-locate && echo true || echo false)" \
    '{
      query: $q,
      classified_as: $cls,
      resolved: $resolved,
      candidates: {
        local_db: {
          via: $local_via,
          matches: $local_db,
          count: ($local_db | length),
          total_matched: ($total | tonumber),
          truncated: (($total | tonumber) > ($local_db | length))
        },
        upstream_index: (if $upstream == null
                         then {skipped: $upstream_skip, matches: null}
                         else {skipped: null, matches: $upstream, count: ($upstream | length)} end)
      },
      context: {
        store_entries: ($entries | tonumber),
        db_valid_paths: (if $dbvalid == "" then null else ($dbvalid | tonumber) end),
        tools: {sqlite3: $has_sqlite, nix_locate: $has_locate},
        flake: $flake
      },
      warnings: $warnings
    }'
