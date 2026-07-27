#!/usr/bin/env bash
# Verifies collect_store_lookup.sh (/nix/store 探索の決定論収集):
#   - 入力の分類          -> command_on_path / derivation / store_path / name_query
#   - resolved の一意性   -> コマンド名から store path が確定する / nix 管理外は null
#   - exists 判定         -> DB にあるがディスクに無い path を false で返す
#   - upstream の警告     -> exists_locally=false の候補があれば warnings に出す
#   - upstream の skip    -> resolved 確定時は既定 skip、--all で照会
#   - truncate            -> 候補が上限超過なら truncated と warnings で明示
#   - DB/fs のずれ検出    -> 件数差があれば warnings に出す
#   - JSON 妥当性・エラー系
#
# 実環境の /nix/store には依存しない。偽の store（一時ディレクトリ）と偽の DB を
# 作り、NIX_STORE_DIR / STORE_DB で差し込む。nix-store / nix-locate は PATH 先頭の
# スタブに差し替える。
#
# 実物を使わない理由:
#   - nix-locate は upstream nixpkgs の index で内容が更新で変わるため、テストが
#     不安定になる。かつ最も検証したい「返る path がローカルに実在しない」状態は
#     実物では意図的に作れない
#   - nix-store の実物を使うと「サンドボックスに都合のよい drv が実在するか」に
#     依存し、GC で壊れる。検証したいのは JSON への組み立てであって nix の挙動ではない
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COLLECT="$SCRIPT_DIR/../collect_store_lookup.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: $(basename "$0") jq が無い環境のためスキップ"; exit 0; }
command -v sqlite3 >/dev/null 2>&1 || { echo "SKIP: $(basename "$0") sqlite3 が無い環境のためスキップ"; exit 0; }

# macOS の $TMPDIR は /var -> /private/var の symlink 配下に来る。readlink -f が
# 返す物理パスと NIX_STORE_DIR が食い違うと command_on_path の前方一致が外れるため、
# 先に物理パスへ寄せる（実運用の /nix/store は symlink ではないので影響しない）。
WORK=$(cd "$(mktemp -d)" && pwd -P)
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
has() { # label haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "PASS: $(basename "$0")[$1] contains '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] missing '$3'"
        fail=1
    fi
}

# --- 偽の store と DB ------------------------------------------------------
STORE="$WORK/store"
mkdir -p "$STORE"

H1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
H2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
H3=cccccccccccccccccccccccccccccccc
GHOST=dddddddddddddddddddddddddddddddd

# 実体を作る（= ディスク上に存在する）
mkdir -p "$STORE/$H1-widget-1.0/bin"
printf '#!/bin/sh\necho widget\n' > "$STORE/$H1-widget-1.0/bin/widget"
chmod +x "$STORE/$H1-widget-1.0/bin/widget"
touch "$STORE/$H2-widget-1.0.drv"
mkdir -p "$STORE/$H3-other-2.0"
# $GHOST は DB にだけ登録し、実体は作らない（exists=false の検証用）

DB="$WORK/db.sqlite"
sqlite3 "$DB" "create table ValidPaths (id integer primary key, path text unique);" 2>/dev/null
for p in "$STORE/$H1-widget-1.0" "$STORE/$H2-widget-1.0.drv" "$STORE/$H3-other-2.0" "$STORE/$GHOST-widget-ghost-1.0"; do
    sqlite3 "$DB" "insert into ValidPaths (path) values ('$p');" 2>/dev/null
done

# --- スタブ ----------------------------------------------------------------
BIN="$WORK/bin"
mkdir -p "$BIN"

cat > "$BIN/nix-store" <<STUB
#!/usr/bin/env bash
# --query --outputs <drv> / --query --deriver <path> だけを模す
case "\$*" in
    *--outputs*) echo "$STORE/$H1-widget-1.0" ;;
    *--deriver*) echo "$STORE/$H2-widget-1.0.drv" ;;
esac
STUB

# upstream index の模擬。実在するもの 1 件と実在しないもの 1 件を返し、
# 「nix-locate の結果はローカルに存在しないことがある」状況を再現する。
cat > "$BIN/nix-locate" <<STUB
#!/usr/bin/env bash
echo "widget.out    123 x $STORE/$H1-widget-1.0/bin/widget"
echo "ghost.out     456 x $STORE/$GHOST-widget-ghost-1.0/bin/widget"
STUB

# PATH 上のコマンドとして解決させる対象（store 配下の実体への symlink）
ln -s "$STORE/$H1-widget-1.0/bin/widget" "$BIN/widget"
# nix 管理外のコマンド（store 配下ではない）
printf '#!/bin/sh\necho outside\n' > "$BIN/outsider"
chmod +x "$BIN/outsider"

chmod +x "$BIN/nix-store" "$BIN/nix-locate"

run() { # args... -> stdout(JSON)
    PATH="$BIN:$PATH" NIX_STORE_DIR="$STORE" STORE_DB="$DB" \
        bash "$COLLECT" "$@" 2>/dev/null
}

# --- 分類 ------------------------------------------------------------------
check "cls-command" "command_on_path" "$(run widget | jq -r '.classified_as')"
check "cls-derivation" "derivation" "$(run "$STORE/$H2-widget-1.0.drv" | jq -r '.classified_as')"
check "cls-store-path" "store_path" "$(run "$STORE/$H1-widget-1.0" | jq -r '.classified_as')"
check "cls-name-query" "name_query" "$(run other | jq -r '.classified_as')"

# --- resolved の一意性 -----------------------------------------------------
check "resolved-command" "$STORE/$H1-widget-1.0" "$(run widget | jq -r '.resolved.store_path')"
check "resolved-command-exists" "true" "$(run widget | jq -r '.resolved.exists')"
# store 配下でないコマンドは store_path を持たない
check "resolved-outside-null" "null" "$(run outsider | jq -r '.resolved.store_path')"
has "resolved-outside-warn" "$(run outsider | jq -r '.warnings[]')" "nix store 配下ではない"
# drv -> 出力パス（スタブの --outputs 経由）
check "resolved-drv-output" "$STORE/$H1-widget-1.0" \
    "$(run "$STORE/$H2-widget-1.0.drv" | jq -r '.resolved.outputs[0].path')"
check "resolved-drv-exists" "true" \
    "$(run "$STORE/$H2-widget-1.0.drv" | jq -r '.resolved.outputs[0].exists')"
# store path -> deriver（スタブの --deriver 経由）
check "resolved-deriver" "$STORE/$H2-widget-1.0.drv" \
    "$(run "$STORE/$H1-widget-1.0" | jq -r '.resolved.deriver')"
# name_query は一意に決まらない
check "resolved-name-null" "null" "$(run other | jq -r '.resolved')"

# --- exists 判定（DB にあるがディスクに無い） ------------------------------
# 'widget' で DB を引くと実体ありの 2 件と実体なしの ghost が返る。
check "local-ghost-exists-false" "false" \
    "$(run widget-ghost | jq -r '.candidates.local_db.matches[] | select(.path | endswith("widget-ghost-1.0")) | .exists')"
check "local-real-exists-true" "true" \
    "$(run other | jq -r '.candidates.local_db.matches[] | select(.is_drv == false) | .exists')"
check "local-is-drv" "true" \
    "$(run widget | jq -r '.candidates.local_db.matches[] | select(.path | endswith(".drv")) | .is_drv')"

# --- upstream の skip と警告 -----------------------------------------------
# resolved が確定していれば既定で照会しない
check "upstream-skipped" "null" "$(run widget | jq -r '.candidates.upstream_index.matches')"
has "upstream-skip-reason" "$(run widget | jq -r '.candidates.upstream_index.skipped')" "ローカルで一意に解決済み"
# --all なら照会し、実在しない候補を検出して警告する
check "upstream-all-count" "2" "$(run widget --all | jq -r '.candidates.upstream_index.count')"
check "upstream-ghost-false" "false" \
    "$(run widget --all | jq -r '.candidates.upstream_index.matches[] | select(.attr == "ghost.out") | .exists_locally')"
has "upstream-warn" "$(run widget --all | jq -r '.warnings[]')" "ローカルに存在しない"
# resolved が無いケースでは既定でも照会される
check "upstream-queried-when-unresolved" "2" "$(run other | jq -r '.candidates.upstream_index.count')"

# --- truncate --------------------------------------------------------------
# 上限を 2 に絞ると、widget にマッチする 3 件（実体2 + ghost）が切り詰められる
trunc=$(PATH="$BIN:$PATH" NIX_STORE_DIR="$STORE" STORE_DB="$DB" LOCAL_MATCH_LIMIT=2 \
    bash "$COLLECT" widget 2>/dev/null)
check "trunc-flag" "true" "$(printf '%s' "$trunc" | jq -r '.candidates.local_db.truncated')"
check "trunc-count" "2" "$(printf '%s' "$trunc" | jq -r '.candidates.local_db.count')"
check "trunc-total" "3" "$(printf '%s' "$trunc" | jq -r '.candidates.local_db.total_matched')"
has "trunc-warn" "$(printf '%s' "$trunc" | jq -r '.warnings[]')" "絞り込めていない"
# 上限内なら truncated は false
check "no-trunc" "false" "$(run other | jq -r '.candidates.local_db.truncated')"

# --- DB と filesystem のずれ検出 -------------------------------------------
# 偽 store のディレクトリ実体は 3 件、DB は 4 件（ghost が DB のみ）。
# fs > db のときだけ警告する仕様なので、ここでは出ない。
check "context-store-entries" "3" "$(run widget | jq -r '.context.store_entries')"
check "context-db-valid" "4" "$(run widget | jq -r '.context.db_valid_paths')"
# fs 側を増やして db を上回らせると警告が出る
touch "$STORE/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-extra-1" "$STORE/ffffffffffffffffffffffffffffffff-extra-2"
has "fs-db-skew-warn" "$(run widget | jq -r '.warnings[]')" "DB クエリには出ない"
rm -f "$STORE/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-extra-1" "$STORE/ffffffffffffffffffffffffffffffff-extra-2"

# --- context.tools ---------------------------------------------------------
check "tools-sqlite" "true" "$(run widget | jq -r '.context.tools.sqlite3')"
check "tools-locate" "true" "$(run widget | jq -r '.context.tools.nix_locate')"

# --- JSON 妥当性 -----------------------------------------------------------
for q in widget other "$STORE/$H1-widget-1.0" "$STORE/$H2-widget-1.0.drv" no-such-thing-xyz; do
    if run "$q" | jq -e . >/dev/null 2>&1; then
        echo "PASS: $(basename "$0")[json-valid:$(basename "$q")]"
    else
        echo "FAIL: $(basename "$0")[json-valid:$(basename "$q")] 不正な JSON"
        fail=1
    fi
done
# 何にもマッチしない入力でも候補は空配列で返る（null ではない）
check "empty-matches" "0" "$(run no-such-thing-xyz | jq -r '.candidates.local_db.count')"

# --- エラー系 --------------------------------------------------------------
err_code() { # args... -> exit code
    PATH="$BIN:$PATH" NIX_STORE_DIR="$STORE" STORE_DB="$DB" \
        bash "$COLLECT" "$@" >/dev/null 2>&1
    echo $?
}
check "err-no-arg" "1" "$(err_code)"
check "err-unknown-opt" "1" "$(err_code widget --bogus)"
check "err-two-queries" "1" "$(err_code widget other)"

exit "$fail"
