#!/usr/bin/env bash
# Verifies rules/20-rm-scratch.sh を規則単体と dispatcher(main.sh)経由の両方で:
#   - 全 rm の対象が一時領域(/tmp/claude-<uid>/**・/tmp/nix-shell.*/claude-<uid>/**・$TMPDIR/**・
#     cwd のリポジトリ直下で gitignore 済みの tmp-agents/**)に収まる      -> allow
#     (対象は同一コマンド内の単純代入と cd 前置だけで静的解決する)
#   - 一時領域外 / 解決不能(置換・コマンド外の変数・glob 等)/ root そのもの /
#     symlink 越し / gitignore されていない tmp-agents / rm 以外の処理を含む  -> 沈黙
#   - いずれも exit 0
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RULE="$SCRIPT_DIR/../rules/20-rm-scratch.sh"

U=$(id -u)
# fixture は一時領域の外に置く(実行者の TMPDIR が一時領域の中だと「領域外」のケースが成り立たない)
base=${TMPDIR:-/tmp}
case "$base/" in /tmp/claude-"$U"/* | /tmp/nix-shell.*/claude-"$U"/*) base=/tmp ;; esac
TMP=$(mktemp -d -p "$base")
trap 'rm -rf "$TMP"' EXIT
# 本物の notify.sh は実通知・親レーンへの報告を出すため、ダミーに差し替えたコピー上で検証する
GATE_DIR="$TMP/gate"
mkdir -p "$GATE_DIR"
cp -R "$SCRIPT_DIR/../main.sh" "$SCRIPT_DIR/../rules" "$GATE_DIR/"
printf '#!%s\ncat >/dev/null\n' "$BASH" >"$GATE_DIR/notify.sh"
chmod +x "$GATE_DIR/notify.sh"
GATE="$GATE_DIR/main.sh"
export XDG_STATE_HOME="$TMP/state"
# 実行者の gitconfig と既定の excludesFile($XDG_CONFIG_HOME/git/ignore)に結果を左右させない
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$TMP/xdg"
# $TMPDIR/** は一時領域なので、fixture の repo を含まない兄弟ディレクトリに向ける
export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR"
SP="/tmp/claude-$U/sess/scratchpad" # scratchpad 相当(存在しなくてよい)

REPO="$TMP/repo"     # tmp-agents/ を .gitignore 済み
BARE="$TMP/bare"     # tmp-agents/ を ignore していない
SHARED="$TMP/shared" # 別 repo と共有する tmp-agents の実体(symlink 先)
LINKED="$TMP/linked" # tmp-agents -> $SHARED/、ignore 済み
for r in "$REPO" "$BARE" "$LINKED"; do git init -q "$r"; done
mkdir -p "$REPO/tmp-agents" "$BARE/tmp-agents" "$SHARED"
echo tmp-agents/ >"$REPO/.gitignore"
ln -s "$SHARED/" "$LINKED/tmp-agents"
echo tmp-agents >"$LINKED/.gitignore"
ln -s "$REPO" "$TMPDIR/esc" # 一時領域から外へ向く symlink
mkdir -p "$TMPDIR/sub"
ln -s "$TMPDIR/sub" "$REPO/in" # 一時領域の外から中へ向く symlink

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
hook_json() { # command cwd [tool_name]
    jq -cn --arg c "$1" --arg d "$2" --arg t "${3:-Bash}" \
        '{session_id: "s1", cwd: $d, tool_name: $t, tool_input: {command: $c}}'
}
via_gate() { # command [cwd] [tool_name] -> allow / 空
    local out rc=0
    out=$(hook_json "$1" "${2:-$REPO}" "${3:-}" | "$GATE") || rc=$?
    [ "$rc" -eq 0 ] || {
        echo "rc=$rc"
        return
    }
    printf '%s' "$out" | jq -r 'select(.hookSpecificOutput.hookEventName == "PermissionRequest")
        | .hookSpecificOutput.decision.behavior // empty'
}
via_rule() { # command [cwd] [tool_name] -> allow / 空(規則の契約: allow なら理由を 1 行)
    local out rc=0
    out=$(hook_json "$1" "${2:-$REPO}" "${3:-}" | bash "$RULE") || rc=$?
    [ "$rc" -eq 0 ] || {
        echo "rc=$rc"
        return
    }
    [ -n "$out" ] && echo allow || true
}
expect() { # label expected command [cwd] [tool_name] -> 規則単体と dispatcher の両方を検証
    check "$1:rule" "$2" "$(via_rule "${@:3}")"
    check "$1:gate" "$2" "$(via_gate "${@:3}")"
}

# allow: 一時領域だけの rm
expect "assign-scratchpad" allow "S=$SP; rm -rf \$S/wt2"
expect "assign-braces" allow "S=$SP && rm -rf \${S}/wt2"
expect "assign-chain" allow "S=$SP; D=\$S/a; rm -rf \$D/b"
expect "cd-scratchpad" allow "cd $SP && rm -rf smoke"
expect "abs-scratchpad" allow "rm -rf $SP/x $SP/y"
expect "multi-rm" allow "rm -f $SP/a; rm -rf $SP/b"
expect "long-options" allow "rm --recursive --force $SP/x"
expect "double-dash" allow "rm -f -- $SP/-x"
expect "nix-shell" allow "rm -rf /tmp/nix-shell.AbC123/claude-$U/x"
expect "tmpdir" allow "rm -rf $TMPDIR/x"
expect "tmpdir-symlink-itself" allow "rm -f $TMPDIR/esc"
expect "tmp-agents" allow "rm -rf tmp-agents/x"
expect "tmp-agents-abs" allow "rm -f $REPO/tmp-agents/x"
expect "tmp-agents-subdir-cwd" allow "rm -f ../tmp-agents/x" "$REPO/tmp-agents"
expect "tmp-agents-symlinked" allow "rm -rf tmp-agents/x" "$LINKED"
expect "cd-relative" allow "cd ./tmp-agents && rm -rf x"
expect "cd-dotdot" allow "cd .. && rm -rf tmp-agents/x" "$REPO/tmp-agents"

# 沈黙: 一時領域外・root そのもの・symlink 越し
expect "outside" "" "rm -rf ./build"
expect "outside-abs" "" "rm -rf $TMP/repo/x"
expect "mixed" "" "rm -rf $SP/x ./build"
expect "root-itself" "" "rm -rf /tmp/claude-$U"
expect "root-trailing-slash" "" "S=/tmp/claude-$U; rm -rf \$S/"
expect "dotdot" "" "rm -rf /tmp/claude-$U/../x"
expect "dot-last" "" "rm -rf $SP/."
expect "other-uid" "" "rm -rf /tmp/claude-0$U/x"
expect "root-prefix" "" "rm -rf /tmp/claude-${U}0/x"
expect "nix-shell-prefix" "" "rm -rf /tmp/nix-shell.a/claude-${U}0/x"
expect "cd-symlink-escape" "" "cd $TMPDIR/esc && rm -rf x"
check "tmpdir-root:rule" "" "$(TMPDIR=/ via_rule "rm -rf $TMP/repo/x")"
check "tmpdir-root:gate" "" "$(TMPDIR=/ via_gate "rm -rf $TMP/repo/x")"
check "tmpdir-shared-tmp:rule" "" "$(TMPDIR=/tmp via_rule "rm -rf /tmp/x")"
check "tmpdir-shared-tmp:gate" "" "$(TMPDIR=/tmp via_gate "rm -rf /tmp/x")"
check "tmpdir-shared-var-tmp:rule" "" "$(TMPDIR=/var/tmp via_rule "rm -rf /var/tmp/x")"
check "tmpdir-shared-var-tmp:gate" "" "$(TMPDIR=/var/tmp via_gate "rm -rf /var/tmp/x")"
check "tmpdir-nix-shell:rule" "allow" "$(TMPDIR=/tmp/nix-shell.xxx via_rule "rm -rf /tmp/nix-shell.xxx/x")"
check "tmpdir-nix-shell:gate" "allow" "$(TMPDIR=/tmp/nix-shell.xxx via_gate "rm -rf /tmp/nix-shell.xxx/x")"
expect "nix-shell-nested" "" "rm -rf /tmp/nix-shell.a/b/claude-$U/x"
expect "nix-shell-other" "" "rm -rf /tmp/nix-shell.a/x"
expect "symlink-escape" "" "rm -rf $TMPDIR/esc/x"
expect "symlink-trailing-slash" "" "rm -rf $TMPDIR/esc/"
expect "tmp-agents-not-ignored" "" "rm -rf tmp-agents/x" "$BARE"
expect "tmp-agents-root" "" "rm -rf tmp-agents"
expect "tmp-agents-other-repo" "" "cd $REPO && rm -rf tmp-agents/x" "$BARE"
expect "tmp-agents-no-repo" "" "rm -rf tmp-agents/x" "$TMP"

# 沈黙: 静的に解決できない
expect "subst" "" "rm \$(mktemp -d)/x"
expect "backtick" "" "rm -rf \`pwd\`/x"
expect "outer-var" "" "rm -rf \$TMPDIR/x"
expect "outer-var-home" "" "rm -rf \$HOME/x"
expect "prefix-assign" "" "S=$SP rm -rf \$S/x"
expect "glob" "" "rm -rf $SP/*"
expect "quote" "" "rm -rf '$SP/x'"
expect "tilde" "" "rm -rf ~/x"
expect "redirect" "" "rm -rf $SP/x 2>/dev/null"
expect "brace" "" "cd $SP && rm -rf {/etc,x}"
expect "caret" "" "rm -rf $SP/^x"
expect "equals" "" "cd $SP && rm -f =ls"
expect "equals-assign" "" "S==ls; cd $SP && rm -f \$S"
expect "assign-path" "" "PATH=$SP; rm -f $SP/x"
expect "assign-ifs" "" "IFS=/; rm -f $SP/x"
expect "assign-cdpath" "" "CDPATH=$SP; rm -f $SP/x"
expect "assign-path-zsh" "" "path=$SP; rm -f $SP/x"
expect "assign-cdpath-zsh" "" "cdpath=$SP; rm -f $SP/x"
expect "assign-pwd" "" "PWD=$TMP/a; cd .. && rm -rf tmp-agents/x" "$REPO/tmp-agents"
expect "cd-symlink-dotdot" "" "cd $TMPDIR/esc/.. && rm -rf x"
expect "cd-symlink-in-dotdot" "" "cd $REPO/in/.. && rm -rf x"
expect "cd-chain-symlink" "" "cd $REPO/in && cd .. && rm -rf x"
expect "cwd-symlink-dotdot" "" "cd .. && rm -rf x" "$REPO/in"
expect "cd-chain" allow "cd $SP && cd ./a && rm -rf x"
expect "cd-cdpath-relative" "" "cd tmp-agents && rm -rf x"
expect "cd-seq" "" "cd $SP; rm -rf smoke"
expect "cd-then-seq" "" "cd $SP && rm -f a; rm -f b"
expect "cd-newline" "" $'cd '"$SP"$'\nrm -rf smoke'
expect "newline-allow" allow $'rm -f '"$SP"$'/a\nrm -f '"$SP"/b
expect "cd-dash" "" "cd - && rm -rf x"
expect "cd-bare" "" "cd && rm -rf x"
expect "or" "" "rm -rf $SP/x || true"
expect "pipe" "" "rm -rfv $SP/x | tail -1"
expect "background" "" "rm -rf $SP/x &"
expect "unknown-option" "" "rm --no-preserve-root -rf $SP/x"
expect "no-target" "" "rm -rf"
expect "no-rm" "" "S=$SP"

# 沈黙: 他の ask 対象・rm 以外の処理を含む
expect "git-push" "" "rm -rf $SP/x && git push"
expect "curl" "" "rm -rf $SP/x; curl -s https://example.com"
expect "git-push-newline" "" $'rm -rf '"$SP"$'/x\ngit push'
expect "wget" "" "wget -q https://example.com && rm -rf $SP/x"
expect "other-cmd" "" "rm -rf $SP/x && python3 x.py"
expect "export" "" "export S=$SP; rm -rf \$S/x"
expect "non-bash" "" "rm -rf $SP/x" "$REPO" Write

exit "$fail"
