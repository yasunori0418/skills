#!/usr/bin/env bash
# Verifies ensure-ignored.sh (tmp-output の一時出力先 tmp-agents/ の ignore 保証):
#   - git リポジトリ外            -> skip(何も書かない)
#   - .gitignore で ignore 済み   -> already-ignored(info/exclude を触らない)
#   - .gitignore が tmp-agents/ のみ -> 実ディレクトリの有無によらず追記(ディレクトリ限定は symlink に一致しない)
#   - core.excludesFile / XDG 既定の全体設定で ignore 済み -> already-ignored
#   - 未 ignore                   -> info/exclude へ追記(2 回目は already-ignored、行は重複しない)
#   - サブディレクトリから実行    -> リポジトリルート基準で判定・追記
#   - 末尾改行の無い exclude      -> 既存最終行と連結しない
#   - worktree から実行           -> 共通の .git/info/exclude へ追記し、symlink の tmp-agents も ignore される
#   - .gitignore の否定パターン   -> 追記しても ignore にならないので exit 1
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ENSURE="$SCRIPT_DIR/../ensure-ignored.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 実環境の全体設定(~/.config/git/ignore 等)に左右されないよう隔離する
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/xdg" GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
: >"$GIT_CONFIG_GLOBAL"

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}

new_repo() { # dir
    git init -q "$1"
    git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
}
exclude_of() { # dir
    git -C "$1" rev-parse --path-format=absolute --git-path info/exclude
}
count_lines() { # file
    grep -cxF tmp-agents "$1" 2>/dev/null || true
}

# --- git リポジトリ外 ---
mkdir -p "$WORK/plain"
check "outside-repo" "skip: not a git repository" "$(bash "$ENSURE" "$WORK/plain")"
check "outside-repo-rc" 0 "$(
    bash "$ENSURE" "$WORK/plain" >/dev/null
    echo $?
)"

# --- .gitignore で ignore 済み ---
D="$WORK/gitignored" && new_repo "$D"
echo "tmp-agents" >"$D/.gitignore"
check "gitignore" "already-ignored" "$(bash "$ENSURE" "$D")"
check "gitignore-exclude-untouched" 0 "$(count_lines "$(exclude_of "$D")")"

# --- .gitignore がディレクトリ限定(tmp-agents/)だけ: symlink に一致しないので追記する ---
D="$WORK/gitignored-dir-only" && new_repo "$D"
echo "tmp-agents/" >"$D/.gitignore"
check "gitignore-dir-only" "added: $(exclude_of "$D")" "$(bash "$ENSURE" "$D")"
check "gitignore-dir-only-rerun" "already-ignored" "$(bash "$ENSURE" "$D")"
check "gitignore-dir-only-line" 1 "$(count_lines "$(exclude_of "$D")")"

# --- 同上で実ディレクトリが既にある: 判定が実体の有無に左右されない ---
D="$WORK/gitignored-dir-exists" && new_repo "$D"
echo "tmp-agents/" >"$D/.gitignore"
mkdir -p "$D/tmp-agents"
check "gitignore-dir-exists" "added: $(exclude_of "$D")" "$(bash "$ENSURE" "$D")"

# --- core.excludesFile で ignore 済み ---
D="$WORK/global" && new_repo "$D"
echo "tmp-agents" >"$WORK/global-ignore"
git config --file "$GIT_CONFIG_GLOBAL" core.excludesFile "$WORK/global-ignore"
check "core-excludesfile" "already-ignored" "$(bash "$ENSURE" "$D")"
: >"$GIT_CONFIG_GLOBAL"

# --- XDG 既定の全体設定で ignore 済み ---
D="$WORK/xdg-default" && new_repo "$D"
mkdir -p "$XDG_CONFIG_HOME/git"
echo "tmp-agents" >"$XDG_CONFIG_HOME/git/ignore"
check "xdg-default" "already-ignored" "$(bash "$ENSURE" "$D")"
rm "$XDG_CONFIG_HOME/git/ignore"

# --- 未 ignore: 追記し、再実行では重複しない ---
D="$WORK/fresh" && new_repo "$D"
EX=$(exclude_of "$D")
check "fresh-added" "added: $EX" "$(bash "$ENSURE" "$D")"
check "fresh-line" 1 "$(count_lines "$EX")"
check "fresh-ignored" 0 "$(
    git -C "$D" check-ignore -q --no-index tmp-agents
    echo $?
)"
check "fresh-rerun" "already-ignored" "$(bash "$ENSURE" "$D")"
check "fresh-rerun-line" 1 "$(count_lines "$EX")"

# --- サブディレクトリから実行してもルート基準 ---
D="$WORK/subdir" && new_repo "$D"
mkdir -p "$D/a/b"
check "subdir-added" "added: $(exclude_of "$D")" "$(bash "$ENSURE" "$D/a/b")"
check "subdir-root-ignored" 0 "$(
    git -C "$D" check-ignore -q --no-index tmp-agents
    echo $?
)"

# --- 末尾改行の無い exclude ---
D="$WORK/no-eol" && new_repo "$D"
EX=$(exclude_of "$D")
printf '*.log' >"$EX"
bash "$ENSURE" "$D" >/dev/null
check "no-eol-keeps-last-line" 1 "$(grep -cxF '*.log' "$EX")"
check "no-eol-line" 1 "$(count_lines "$EX")"

# --- worktree: 共通の exclude へ追記し、symlink の tmp-agents も ignore される ---
D="$WORK/primary" && new_repo "$D"
git -C "$D" worktree add -q "$WORK/linked" 2>/dev/null
mkdir -p "$D/tmp-agents" && echo x >"$D/tmp-agents/note.md"
ln -s "$D/tmp-agents" "$WORK/linked/tmp-agents"
check "worktree-added" "added: $D/.git/info/exclude" "$(bash "$ENSURE" "$WORK/linked")"
check "worktree-symlink-clean" "" "$(git -C "$WORK/linked" status --porcelain)"
check "worktree-primary-clean" "" "$(git -C "$D" status --porcelain)"

# --- .gitignore の否定パターンで打ち消される ---
D="$WORK/negated" && new_repo "$D"
echo '!tmp-agents' >"$D/.gitignore"
check "negated-rc" 1 "$(
    bash "$ENSURE" "$D" >/dev/null 2>&1
    echo $?
)"

exit $fail
