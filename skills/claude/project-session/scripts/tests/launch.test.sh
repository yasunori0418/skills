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

# inherited_session_vars: 親セッション固有のマーカーを列挙する（新セッションへ
# 引き継ぐと transcript 保存が切られる・親宛の経路を掴む等の不整合が起きる）。
check "inherit:has-child-session" "1" \
    "$(inherited_session_vars | grep -c '^CLAUDE_CODE_CHILD_SESSION$')"
check "inherit:has-messaging" "2" \
    "$(inherited_session_vars | grep -c '^CLAUDE_CODE_MESSAGING_')"
check "inherit:has-session-ids" "2" \
    "$(inherited_session_vars | grep -c 'SESSION_ID$')"
# prefix の付かない GIT_EDITOR も同じ経路で注入される（値は no-op の `true`）。
# 落とすと git は core.editor / VISUAL / EDITOR へフォールバックする。
check "inherit:has-git-editor" "1" \
    "$(inherited_session_vars | grep -c '^GIT_EDITOR$')"
# ユーザー設定・実行ファイル解決に使うものは引き継ぐので挙げない。
check "inherit:keeps-execpath" "0" \
    "$(inherited_session_vars | grep -c '^CLAUDE_CODE_EXECPATH$')"
check "inherit:keeps-user-prefs" "0" \
    "$(inherited_session_vars | grep -c 'DISABLE_FEEDBACK_SURVEY\|AGENT_TEAMS')"
# 空行を含まない（env -u '' は不正な呼び出しになる）。
check "inherit:no-empty-line" "0" "$(inherited_session_vars | grep -c '^$')"

# env_unset_prefix: `env -u <var> ...` の引数列へ展開する。multiplexer server の
# 起動もこの prefix 越しに行うため（server の environ は配下の全 pane へ継承される）。
check "envprefix:starts-with-env" "env" "$(env_unset_prefix | head -1)"
# 先頭 env + (-u, var) * N 行になる。
check "envprefix:line-count" \
    "$((1 + 2 * $(inherited_session_vars | grep -c .)))" \
    "$(env_unset_prefix | grep -c .)"
check "envprefix:flag-count" \
    "$(inherited_session_vars | grep -c .)" \
    "$(env_unset_prefix | grep -c '^-u$')"
check "envprefix:has-child-session" "1" \
    "$(env_unset_prefix | grep -c '^CLAUDE_CODE_CHILD_SESSION$')"
check "envprefix:no-empty-line" "0" "$(env_unset_prefix | grep -c '^$')"

# subtract_ids: 自分が作った workspace 以外（server が起動時に作る既定 workspace）を
# 差分で拾う。ID は決め打ちしない。
check "subtract:drops-kept" "w1" \
    "$(printf 'w1\nw2\n' | subtract_ids w2)"
check "subtract:keeps-order" "w1 w3" \
    "$(printf 'w1\nw2\nw3\n' | subtract_ids w2 | tr '\n' ' ' | sed 's/ $//')"
# 自分の workspace しか無ければ何も返さない（閉じる対象なし）。
check "subtract:only-self" "" "$(printf 'w1\n' | subtract_ids w1)"
# 空行は無視する（herdr の応答が空でも空文字を close しない）。
check "subtract:skips-empty" "w2" "$(printf '\nw2\n\n' | subtract_ids w1)"
check "subtract:empty-input" "" "$(printf '' | subtract_ids w1)"

# is_path_query: パス形の query だけ ghq 解決を飛ばす。裸の名前は ghq キーのまま。
check_rc() { # label expected_rc actual_rc
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> rc=$3"
    else
        echo "FAIL: $(basename "$0")[$1] expected rc=$2, got rc=$3"
        fail=1
    fi
}
is_path_query '/home/yasunori/dotfiles' && rc=0 || rc=1
check_rc "ispath:absolute" 0 "$rc"
is_path_query '~/dotfiles' && rc=0 || rc=1
check_rc "ispath:tilde-slash" 0 "$rc"
is_path_query '~' && rc=0 || rc=1
check_rc "ispath:tilde-only" 0 "$rc"
is_path_query './sub' && rc=0 || rc=1
check_rc "ispath:dot-slash" 0 "$rc"
is_path_query '../sibling' && rc=0 || rc=1
check_rc "ispath:dotdot-slash" 0 "$rc"
# 裸の名前は ghq キー（ローカルの同名ディレクトリを意図せず掴まないため）。
is_path_query 'dotfiles' && rc=0 || rc=1
check_rc "ispath:bare-name" 1 "$rc"
is_path_query 'github.com/yasunori0418/nput' && rc=0 || rc=1
check_rc "ispath:ghq-relpath" 1 "$rc"
# ~name（他ユーザーのホーム）は展開規則を持たないので ghq キー扱いにする。
is_path_query '~otheruser/x' && rc=0 || rc=1
check_rc "ispath:tilde-user" 1 "$rc"

# expand_path_query: 先頭 ~ だけを HOME へ展開する（HOME は第 2 引数で固定）。
check "expand:tilde-slash" "/h/dotfiles" "$(expand_path_query '~/dotfiles' /h)"
check "expand:tilde-only" "/h" "$(expand_path_query '~' /h)"
check "expand:absolute" "/opt/x" "$(expand_path_query '/opt/x' /h)"
check "expand:relative" "./sub" "$(expand_path_query './sub' /h)"
# 中間の ~ は展開しない（先頭のみが対象）。
check "expand:inner-tilde" "/opt/~/x" "$(expand_path_query '/opt/~/x' /h)"

# backend_required_tools: 直接パス指定（needs_ghq=0）では ghq を要求しない。
check "tools:herdr-with-ghq" "herdr ghq claude" "$(backend_required_tools herdr 1 | tr '\n' ' ' | sed 's/ $//')"
check "tools:herdr-no-ghq" "herdr claude" "$(backend_required_tools herdr 0 | tr '\n' ' ' | sed 's/ $//')"
check "tools:tmux-with-ghq" "tmux ghq claude" "$(backend_required_tools tmux 1 | tr '\n' ' ' | sed 's/ $//')"
check "tools:tmux-no-ghq" "tmux claude" "$(backend_required_tools tmux 0 | tr '\n' ' ' | sed 's/ $//')"
# 既定（第 2 引数省略）は従来どおり ghq を要求する。
check "tools:default-needs-ghq" "herdr ghq claude" "$(backend_required_tools herdr | tr '\n' ' ' | sed 's/ $//')"

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
