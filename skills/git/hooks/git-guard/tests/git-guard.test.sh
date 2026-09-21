#!/usr/bin/env bash
# Verifies git-guard (matcher: Bash の全コマンドを受けるディスパッチャ):
#   - 対象外コマンド                  -> 沈黙（空出力）
#   - git rebase / marker 無し        -> deny
#   - git rebase --abort              -> ask（脱出経路は常時通す）
#   - git rebase / marker 有効        -> ask
#   - git rebase / marker 期限切れ    -> deny + marker 削除
#   - git pull --rebase / git pull -r -> rebase と同じ扱い
#   - git reset / marker 無し         -> deny
#   - git push（force なし）          -> ask
#   - git push --force / -f           -> deny
#   - 複合コマンド（deny + ask 混在） -> deny 優先
#   - 引数・検索パターン・heredoc 本文のリテラル -> 沈黙（誤検知しない）
#   - cd 後の segment / git -C の global option / sh -c の引数 -> deny
#   - here-string（<<<）の後続 segment       -> deny（heredoc 扱いしない）
#   - sudo / env / command / 絶対パス git    -> deny（ラッパーを解除する）
#   - サブシェル / ブレース群 / $(…) / `…`   -> deny（区切りとして扱う）
#   - 二重引用符の中の `)`                    -> 沈黙（引数リテラルを割らない）
#   - 制御構文キーワード / 前置コマンドの後   -> deny（if / then / do / else / exec 等）
#   - ラッパーの値取りオプションの後          -> deny（-u root 等を 2 語消費する）
#   - 二重引用符の中のバックティック・置換後  -> deny
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/../main.sh"

REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q

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
    printf '{"cwd": "%s", "tool_input": {"command": %s}}' "$REPO" "$(printf '%s' "$1" | jq -Rs .)" \
        | "$GUARD" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

# 対象外コマンド -> 沈黙
OUT=$(printf '{"cwd": "%s", "tool_input": {"command": "ls -la"}}' "$REPO" | "$GUARD")
check "unrelated-silent" "" "$OUT"

# rebase: marker 無し -> deny
check "rebase-unarmed" "deny" "$(decision 'git rebase main')"

# rebase: --abort は常時 ask
check "rebase-abort" "ask" "$(decision 'git rebase --abort')"

# rebase: marker 有効 -> ask
date +%s > "$REPO/.git/rebase-flow.armed"
check "rebase-armed" "ask" "$(decision 'git rebase main')"

# rebase: marker 期限切れ -> deny + marker 削除
echo "$(($(date +%s) - 3600))" > "$REPO/.git/rebase-flow.armed"
check "rebase-expired" "deny" "$(decision 'git rebase main')"
[ ! -f "$REPO/.git/rebase-flow.armed" ] && check "expired-marker-removed" ok ok || check "expired-marker-removed" ok ng

# pull --rebase / pull -r も rebase 扱い
check "pull-rebase" "deny" "$(decision 'git pull --rebase origin main')"
check "pull-r" "deny" "$(decision 'git pull -r origin main')"

# reset: marker 無し -> deny
check "reset-unarmed" "deny" "$(decision 'git reset --hard HEAD~1')"

# push: force なし -> ask / force あり -> deny
check "push-plain" "ask" "$(decision 'git push origin feature')"
check "push-force" "deny" "$(decision 'git push --force origin feature')"
check "push-f" "deny" "$(decision 'git push -f origin feature')"

# 複合コマンド: reset(deny) + push(ask) -> deny 優先
check "compound-deny-wins" "deny" "$(decision 'git reset --hard HEAD~1 && git push origin feature')"

# --- 検出はコマンド構造で行う: 引数・検索パターン・heredoc 本文のリテラルは素通し ---
raw() { # command -> hook の生出力
    printf '{"cwd": %s, "tool_input": {"command": %s}}' \
        "$(printf '%s' "$REPO" | jq -Rs .)" "$(printf '%s' "$1" | jq -Rs .)" | "$GUARD"
}

# 報告コマンドの引数に載ったリテラル -> 沈黙
check "literal-in-argument" "" "$(raw 'bash report.sh parent T1 "停止" "git rebase の計画を提示"')"

# 検索パターン内のリテラル -> 沈黙
check "literal-in-grep-pattern" "" "$(raw "grep -n -E 'git reset|Ask rule' file")"

# heredoc 本文のリテラル -> 沈黙
check "literal-in-heredoc" "" "$(raw "$(printf 'git commit -F - <<%s\nfix: 手順を改める\n\ngit reset の記述を削除した\nEOF' "'EOF'")")"

# 実コマンドは segment ごとに検出する -> deny
check "compound-cd-reset" "deny" "$(decision 'cd x && git reset --hard')"
check "git-global-option-reset" "deny" "$(decision 'git -C x reset --soft HEAD~1')"
check "shell-c-rebase" "deny" "$(decision 'bash -c "git rebase main"')"

# here-string（<<<）は heredoc ではないので後続の segment を飲み込まない -> deny
check "here-string-not-heredoc" "deny" "$(decision "$(printf 'cat <<< x\ngit reset --hard')")"

# --- 退行防止: ラッパー・サブシェル・コマンド置換の中の git も検出する ---
# 旧実装（部分一致）が deny していた形。構造判定で素通しにしないこと
check "wrapper-sudo" "deny" "$(decision 'sudo git reset --hard')"
check "wrapper-env" "deny" "$(decision 'env git reset --hard')"
check "wrapper-command" "deny" "$(decision 'command git reset --hard')"
check "absolute-path-git" "deny" "$(decision '/usr/bin/git reset --hard')"
check "subshell" "deny" "$(decision '(git reset --hard)')"
check "brace-group" "deny" "$(decision '{ git reset --hard; }')"
check "command-substitution" "deny" "$(decision 'echo $(git reset --hard)')"
check "command-substitution-quoted" "deny" "$(decision "echo \"\$(git reset --hard)\"")"
check "backtick-substitution" "deny" "$(decision 'echo `git reset --hard`')"
check "shell-o-operand-then-c" "deny" "$(decision 'bash -o pipefail -c "git rebase main"')"

# --- 誤爆の再発防止: 引数リテラル・検索パターンは素通しのまま ---
check "echo-literal-silent" "" "$(raw "echo 'git reset --hard'")"
check "grep-pattern-silent" "" "$(raw "grep -n 'reset' file.txt")"
# 二重引用符の中の `)` は区切りではない（引数リテラルを割らない）
check "paren-in-quoted-arg-silent" "" "$(raw "echo \"x) git reset --hard\"")"

# --- 退行防止: ラッパーの値取りオプション・制御構文・前置コマンド ---
check "wrapper-sudo-value-opt" "deny" "$(decision 'sudo -u root git reset --hard')"
check "wrapper-env-value-opt" "deny" "$(decision 'env -u VAR git reset --hard')"
check "keyword-if" "deny" "$(decision 'if git rebase main; then echo x; fi')"
check "keyword-then" "deny" "$(decision 'if true; then git reset --hard; fi')"
check "keyword-do" "deny" "$(decision 'for x in a b; do git reset --hard; done')"
check "keyword-else" "deny" "$(decision 'if false; then echo x; else git reset --hard; fi')"
check "keyword-while" "deny" "$(decision 'while git reset; do :; done')"
check "negation" "deny" "$(decision '! git reset --hard')"
check "prefix-exec" "deny" "$(decision 'exec git reset --hard')"
check "prefix-time" "deny" "$(decision 'time git reset --hard')"
check "prefix-nohup" "deny" "$(decision 'nohup git push --force origin x')"
check "shell-opt-cluster-with-o" "deny" "$(decision 'bash -euo pipefail -c "git reset --hard"')"
check "backtick-in-quotes" "deny" "$(decision "echo \"\`git reset --hard\`\"")"
check "after-substitution-in-quotes" "deny" "$(decision "echo \"\$(true) git reset --hard\"")"

# キーワードのリテラルは素通しのまま（誤爆の再発防止）
check "keyword-literal-silent" "" "$(raw 'echo then do else in')"
check "keyword-in-quoted-literal-silent" "" "$(raw "echo 'if x; then git reset; fi'")"

exit "$fail"
