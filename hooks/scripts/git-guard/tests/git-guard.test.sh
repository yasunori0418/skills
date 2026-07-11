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

exit "$fail"
