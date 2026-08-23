#!/usr/bin/env bash
# Verifies noclobber-guard:
#   - 既存ファイルへの素の `>` -> deny（リテラル / 変数展開 / クォート / cd 相対）
#   - 存在しないファイルへの `>` -> 沈黙（初回書き込みは正当）
#   - `>>` `>|` `>&` `2>&1` `<>` `>(...)` `/dev/*` -> 沈黙（noclobber の対象外）
#   - heredoc 本文・クォート内の `>` -> 沈黙（シェルの構文ではない）
#   - 静的に解決できない書き先（$(…) / 位置パラメータ / bash -c の中）-> 沈黙（fail-open）
#
# deny ケースの多くはセッション履歴から採取した実例。
# 実測（552 セッション / Bash 実行 30,994 件の全走査）では `file exists:` が
# 245 回・73 セッションで発生していた。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/../main.sh"

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
decision() { # command
    printf '{"tool_input": {"command": %s}}' "$(printf '%s' "$1" | jq -Rs .)" \
        | "$GUARD" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

# --- 実ファイルを使う。テスト用の一時ツリーのみを触る ----------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sub" "$TMP/scratch"
printf 'x\n' >"$TMP/existing.txt"
printf 'y\n' >"$TMP/scratch/state.json"
printf 'z\n' >"$TMP/has space.txt"

# --- deny: 既存ファイルへの上書き（すべて実測で観測された形） --------------
check "literal-abs" "deny" \
    "$(decision "echo hi > $TMP/existing.txt")"
check "gh-issue-body" "deny" \
    "$(decision "gh issue view 283 --json body -q .body > $TMP/existing.txt")" # 実例: epic283-body.md
check "pipe-then-redirect" "deny" \
    "$(decision "rg -o 'id' docs/ | sort -u > $TMP/existing.txt")" # 実例: allids.txt
check "var-assigned-path" "deny" \
    "$(decision "S=$TMP/scratch
bash collect.sh > \$S/state.json")" # 実例: post-merge-cleanup の collect-merge-state.sh
check "var-braced" "deny" \
    "$(decision "SP=$TMP
cat foo > \${SP}/existing.txt")"
check "quoted-target" "deny" \
    "$(decision "echo hi > \"$TMP/existing.txt\"")"
check "target-with-space" "deny" \
    "$(decision "echo hi > \"$TMP/has space.txt\"")"
check "cd-then-relative" "deny" \
    "$(decision "cd $TMP && git show abc:file > existing.txt")" # 実例: dev/flake.nix の revert
check "heredoc-to-existing" "deny" \
    "$(decision "cat > $TMP/existing.txt <<'EOF'
data
EOF")"
check "loop-body-redirect" "deny" \
    "$(decision "cd $TMP && for f in a b c; do echo \$f > existing.txt; done")" # 最悪ケース: 124 回失敗した形
check "self-referencing" "deny" \
    "$(decision "printf '%s\n' \"\$(cat $TMP/existing.txt)\" > $TMP/existing.txt")" # noclobber がデータ消失を防いだ実例

# --- 沈黙: 初回書き込み（誤爆したら日常操作が止まる） ----------------------
check "literal-missing" "" \
    "$(decision "echo hi > $TMP/new.txt")"
check "var-path-missing" "" \
    "$(decision "S=$TMP/scratch
echo hi > \$S/fresh.json")"
check "cd-relative-missing" "" \
    "$(decision "cd $TMP && echo hi > fresh.txt")"

# --- 沈黙: noclobber の対象外な構文 ----------------------------------------
check "append" "" \
    "$(decision "echo hi >> $TMP/existing.txt")"
check "clobber-override" "" \
    "$(decision "echo hi >| $TMP/existing.txt")" # 既に正解の書き方
check "fd-dup-stderr" "" \
    "$(decision "cmd > $TMP/new.txt 2>&1")"
check "fd-dup-to-stderr" "" \
    "$(decision "echo err >&2")"
check "devnull" "" \
    "$(decision "noisy-cmd > /dev/null")"
check "devnull-both" "" \
    "$(decision "cmd >/dev/null 2>&1")"
check "process-substitution" "" \
    "$(decision "diff <(sort a) >(cat)")"
check "readwrite-fd" "" \
    "$(decision "exec 3<> $TMP/existing.txt")"
check "directory-target" "" \
    "$(decision "echo hi > $TMP/sub")" # ディレクトリは noclobber ではなく別のエラー

# --- 沈黙: シェル構文ではない `>` ------------------------------------------
check "awk-comparison" "" \
    "$(decision "awk '\$1 > 5 {print}' $TMP/existing.txt")"
check "jq-comparison" "" \
    "$(decision "jq '.[] | select(.n > 3)' $TMP/existing.txt")"
check "quoted-string" "" \
    "$(decision "echo 'redirect with > inside quotes'")"
check "heredoc-body" "" \
    "$(decision "cat > $TMP/new.sh <<'EOF'
echo x > $TMP/existing.txt
EOF")" # heredoc 本文はこのシェルが解釈しない
check "html-arrow" "" \
    "$(decision "printf '<div>text</div>' | wc -c")"

# --- 沈黙: 静的に解決できないもの（fail-open） -----------------------------
check "cmdsub-target" "" \
    "$(decision "echo hi > \$(mktemp)")"
check "undeclared-var" "" \
    "$(decision "echo hi > \$UNDECLARED_PATH/out.txt")"
check "positional-param" "" \
    "$(decision "echo hi > \$1/out.txt")"
check "inside-bash-c" "" \
    "$(decision "bash -c 'echo hi > $TMP/existing.txt'")" # 別シェル。クォート内なので対象外
check "default-expansion" "" \
    "$(decision "DB=\"\${XDG_CACHE_HOME:-\$HOME/.cache}/x.db\"
echo hi > \$DB")" # \${VAR:-default} は解決しない
check "created-within-same-command" "" \
    "$(decision "echo a > $TMP/fresh2.txt && echo b > $TMP/fresh2.txt")" # 判定は実行前なので 2 回目は検知できない（既知の限界）

# --- 沈黙: リダイレクトが無い ----------------------------------------------
check "no-redirect" "" \
    "$(decision "ls -la $TMP")"
check "git-log" "" \
    "$(decision "git log --oneline -10")"

exit "$fail"
