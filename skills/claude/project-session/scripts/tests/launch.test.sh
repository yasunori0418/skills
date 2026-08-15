#!/usr/bin/env bash
# Verifies launch.sh の純関数（外部コマンド ghq/tmux/claude に触れない部分）。
#   - sanitize / resolve_matches / session_base_name / next_session_name /
#     inject_remote_control / detect_backend / detect_topology /
#     herdr_session_name / backend_attach_hint を source して単体検証する。
#   - ghq list の fixture はヒアドキュメントで固定し実環境に依存しない。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../launch.sh
source "$SCRIPT_DIR/../launch.sh"

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}

# ghq list fixture（basename に nixpkgs が 2 件、foo と foo-bar が同居）。
GHQ_LIST=$(
    cat <<'EOF'
github.com/NixOS/nixpkgs
github.com/yasunori0418/nixpkgs
github.com/yasunori0418/nput
github.com/yasunori0418/arto.vim
github.com/example/foo
github.com/example/foo-bar
EOF
)

# ---- sanitize -------------------------------------------------------------
check "sanitize:dot" "arto-vim" "$(sanitize 'arto.vim')"
check "sanitize:slash-dot" "a-b-c" "$(sanitize 'a/b.c')"
check "sanitize:symbols-only" "session" "$(sanitize '@@@')"
check "sanitize:keep-underscore" "a_b-c" "$(sanitize 'a_b-c')"

# ---- resolve_matches ------------------------------------------------------
# 一意部分一致。
check "resolve:unique" "github.com/yasunori0418/nput" \
    "$(printf '%s\n' "$GHQ_LIST" | resolve_matches 'nput')"
# basename 完全一致優先（foo は foo-bar と部分一致するが foo を単独採用）。
check "resolve:exact-basename" "github.com/example/foo" \
    "$(printf '%s\n' "$GHQ_LIST" | resolve_matches 'foo')"
# 複数ヒット（nixpkgs 2 件）。
check "resolve:multi" "github.com/NixOS/nixpkgs
github.com/yasunori0418/nixpkgs" \
    "$(printf '%s\n' "$GHQ_LIST" | resolve_matches 'nixpkgs')"
# 0 件。
check "resolve:none" "" \
    "$(printf '%s\n' "$GHQ_LIST" | resolve_matches 'doesnotexist')"
# 大文字小文字無視。
check "resolve:case-insensitive" "github.com/yasunori0418/nput" \
    "$(printf '%s\n' "$GHQ_LIST" | resolve_matches 'NPUT')"

# ---- session_base_name ----------------------------------------------------
# 一意 repo -> repo 名。
check "base:unique-repo" "nput" \
    "$(printf '%s\n' "$GHQ_LIST" | session_base_name 'github.com/yasunori0418/nput')"
# 一意 repo（サニタイズ込み）。
check "base:sanitized-repo" "arto-vim" \
    "$(printf '%s\n' "$GHQ_LIST" | session_base_name 'github.com/yasunori0418/arto.vim')"
# 重複 repo -> owner-repo。
check "base:dup-nixos" "NixOS-nixpkgs" \
    "$(printf '%s\n' "$GHQ_LIST" | session_base_name 'github.com/NixOS/nixpkgs')"
check "base:dup-yasunori" "yasunori0418-nixpkgs" \
    "$(printf '%s\n' "$GHQ_LIST" | session_base_name 'github.com/yasunori0418/nixpkgs')"

# ---- next_session_name ----------------------------------------------------
# 空き -> base。
check "next:free" "nput" "$(printf '%s\n' 'other' | next_session_name 'nput')"
# base 使用中 -> base-2。
check "next:used" "nput-2" \
    "$(printf '%s\n' 'nput
other' | next_session_name 'nput')"
# base と base-2 使用中 -> base-3。
check "next:used-2" "nput-3" \
    "$(printf '%s\n' 'nput
nput-2' | next_session_name 'nput')"
# 空 stdin（tmux 未起動相当）-> base。
check "next:empty" "nput" "$(printf '' | next_session_name 'nput')"

# ---- inject_remote_control ------------------------------------------------
# 末尾の値なし --remote-control -> 注入。
mapfile -d '' _out < <(inject_remote_control 'nput' --remote-control)
check "inject:trailing" "--remote-control nput" "${_out[*]}"

# 直後が -p（フラグ）-> 注入。
mapfile -d '' _out < <(inject_remote_control 'nput' --remote-control -p 'do stuff')
check "inject:before-flag" "--remote-control nput -p do stuff" "${_out[*]}"

# 値あり（--remote-control myname）-> 素通し。
mapfile -d '' _out < <(inject_remote_control 'nput' --remote-control myname)
check "inject:with-value" "--remote-control myname" "${_out[*]}"

# フラグ無し -> 素通し。
mapfile -d '' _out < <(inject_remote_control 'nput' -p 'hi there')
check "inject:no-flag" "-p hi there" "${_out[*]}"

# 空白・改行入りプロンプト引数が壊れないこと（NUL 区切り検証）。
mapfile -d '' _out < <(inject_remote_control 'nput' -p 'multi
line prompt' --remote-control)
check "inject:preserve-count" "4" "${#_out[@]}"
check "inject:preserve-prompt" "multi
line prompt" "${_out[1]}"
check "inject:preserve-trailing-inject" "nput" "${_out[3]}"

# 最初の 1 個のみ処理（2 つ目の --remote-control は素通し）。
mapfile -d '' _out < <(inject_remote_control 'nput' --remote-control --remote-control)
check "inject:only-first" "--remote-control nput --remote-control" "${_out[*]}"

# detect_backend: HERDR_ENV=1 なら herdr、それ以外は tmux にフォールバック。
check "backend:herdr-env" "herdr" "$(detect_backend 1 '')"
check "backend:unset" "tmux" "$(detect_backend '' '')"
check "backend:env-zero" "tmux" "$(detect_backend 0 '')"
check "backend:env-other" "tmux" "$(detect_backend yes '')"
# override（PROJECT_SESSION_BACKEND）は環境より優先する。
check "backend:override-tmux" "tmux" "$(detect_backend 1 tmux)"
check "backend:override-herdr" "herdr" "$(detect_backend '' herdr)"

# herdr_session_name: HERDR_SESSION をそのまま使い、空・未設定は default へ畳む
# （`herdr --session ""` は session name cannot be empty で拒否されるため）。
check "hsession:named" "sub" "$(herdr_session_name sub)"
check "hsession:default" "default" "$(herdr_session_name default)"
check "hsession:empty" "default" "$(herdr_session_name '')"
check "hsession:unset" "default" "$(herdr_session_name)"

# detect_topology: 既定は workspace、フラグ / 環境変数で上書きする。
check "topology:default" "workspace" "$(detect_topology '')"
check "topology:unset" "workspace" "$(detect_topology)"
check "topology:session" "session" "$(detect_topology session)"
check "topology:explicit-workspace" "workspace" "$(detect_topology workspace)"

# extract_topology_flag: query より前の --session だけを抜き、残りはそのまま返す。
# 出力は NUL 区切りで「topology」「残りの引数...」の順。
mapfile -d '' _out < <(extract_topology_flag --session nput --model opus)
check "extopo:flag" "session" "${_out[0]}"
check "extopo:rest" "nput --model opus" "${_out[*]:1}"

# フラグ無しは topology 空（呼び出し側が環境変数へフォールバックする）。
mapfile -d '' _out < <(extract_topology_flag nput --model opus)
check "extopo:noflag" "" "${_out[0]}"
check "extopo:noflag-rest" "nput --model opus" "${_out[*]:1}"

# query 以降の --session は claude への passthrough なので抜き取らない。
mapfile -d '' _out < <(extract_topology_flag nput --session)
check "extopo:after-query" "" "${_out[0]}"
check "extopo:after-query-rest" "nput --session" "${_out[*]:1}"

# 空白・改行入り passthrough 引数が壊れないこと（NUL 区切り検証）。
mapfile -d '' _out < <(extract_topology_flag --session nput -p 'multi
line prompt')
check "extopo:preserve-count" "4" "${#_out[@]}"
check "extopo:preserve-prompt" "multi
line prompt" "${_out[3]}"

# query だけ・引数なしでも topology 要素は必ず 1 つ返る。
mapfile -d '' _out < <(extract_topology_flag nput)
check "extopo:query-only" "1" "$((${#_out[@]} - 1))"
mapfile -d '' _out < <(extract_topology_flag --session)
check "extopo:flag-only" "session" "${_out[0]}"
check "extopo:flag-only-count" "0" "$((${#_out[@]} - 1))"

# backend_attach_hint: topology=session だけ attach コマンドをそのまま案内する
# （detached で立てた session はユーザーが attach するまで画面に現れないため）。
check "attach:herdr-workspace" "herdr（workspace ラベル: nput）に切り替える" \
    "$(backend_attach_hint herdr nput workspace)"
check "attach:herdr-session" "herdr session attach nput" \
    "$(backend_attach_hint herdr nput session)"
check "attach:herdr-default-topology" "herdr（workspace ラベル: nput）に切り替える" \
    "$(backend_attach_hint herdr nput)"
check "attach:tmux" "tmux attach -t nput" "$(backend_attach_hint tmux nput session)"

exit "$fail"
