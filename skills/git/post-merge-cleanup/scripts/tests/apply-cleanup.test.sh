#!/usr/bin/env bash
# apply-cleanup.sh の検証:
#   - deletable=true だけがコマンド生成される
#   - deletable=false が 1 件でも混ざれば実行せず exit 1（保護対象の巻き込み防止）
#   - 対象ゼロなら NOTHING TO DO で正常終了
#   - worktree あり -> wt remove / worktree なし -> git branch -d に振り分ける
#   - tmux kill-session が worktree 削除より先に出る（消えた cwd への居座り回避）
#   - force 系フラグ（-D / --force / -f / rm -rf）を一切生成しない
#   - 壊れた JSON は exit 1
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
APPLY="$SCRIPT_DIR/../apply-cleanup.sh"

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
contains() { # label haystack needle
    case "$2" in
        *"$3"*) echo "PASS: $(basename "$0")[$1] contains '$3'" ;;
        *)
            echo "FAIL: $(basename "$0")[$1] missing '$3'"
            fail=1
            ;;
    esac
}
lacks() { # label haystack needle
    case "$2" in
        *"$3"*)
            echo "FAIL: $(basename "$0")[$1] should not contain '$3'"
            fail=1
            ;;
        *) echo "PASS: $(basename "$0")[$1] lacks '$3'" ;;
    esac
}

plan() { bash "$APPLY" --print-only <<<"$1"; }
status_of() {
    bash "$APPLY" --print-only <<<"$1" >/dev/null 2>&1
    echo $?
}

# --- 1. 通常ケース: worktree あり + tmux セッションあり ----------------------
both='{"candidates":[{"branch":"feat-x","worktree_path":"/tmp/wt.feat-x",
  "tmux_session":"feat-x","deletable":true}]}'
out=$(plan "$both")
contains "wt-remove" "$out" "wt remove feat-x -y --foreground"
contains "tmux-kill" "$out" "tmux kill-session -t feat-x"
lacks "no-force-D" "$out" " -D"
lacks "no-force" "$out" "--force "
lacks "no-rm" "$out" "rm -rf"

# tmux が worktree 削除より先に出ること
tmux_line=$(printf '%s\n' "$out" | grep -n 'tmux kill-session' | cut -d: -f1)
wt_line=$(printf '%s\n' "$out" | grep -n 'wt remove' | cut -d: -f1)
if [ "$tmux_line" -lt "$wt_line" ]; then
    echo "PASS: $(basename "$0")[order] tmux kill precedes wt remove"
else
    echo "FAIL: $(basename "$0")[order] tmux($tmux_line) should precede wt($wt_line)"
    fail=1
fi

# --- 2. worktree が無くローカルブランチだけ -> git branch -d ----------------
branch_only='{"candidates":[{"branch":"stale","worktree_path":null,
  "tmux_session":null,"deletable":true}]}'
out=$(plan "$branch_only")
contains "branch-d" "$out" "git branch -d stale"
lacks "branch-not-wt" "$out" "wt remove"
lacks "branch-no-force" "$out" "branch -D"

# --- 3. deletable=false が混ざれば実行前に落とす -----------------------------
mixed='{"candidates":[
  {"branch":"ok","worktree_path":"/tmp/wt.ok","tmux_session":null,"deletable":true},
  {"branch":"dirty-one","worktree_path":"/tmp/wt.d","tmux_session":null,"deletable":false}]}'
check "mixed-exit" "1" "$(status_of "$mixed")"
err=$(bash "$APPLY" --print-only <<<"$mixed" 2>&1 || true)
contains "mixed-msg" "$err" "dirty-one"
lacks "mixed-no-exec" "$err" "wt remove ok"

# --- 4. 保護対象のみ -> やはり実行しない -------------------------------------
all_blocked='{"candidates":[{"branch":"main","worktree_path":"/tmp/main",
  "tmux_session":null,"deletable":false}]}'
check "blocked-exit" "1" "$(status_of "$all_blocked")"

# --- 5. 対象ゼロ -> NOTHING TO DO で正常終了 ---------------------------------
empty='{"candidates":[]}'
check "empty-exit" "0" "$(status_of "$empty")"
contains "empty-msg" "$(plan "$empty")" "NOTHING TO DO"
check "nokey-exit" "0" "$(status_of '{}')"

# --- 6. 壊れた JSON -> exit 1 ------------------------------------------------
broken_status=$(bash "$APPLY" --print-only <<<'{not json' >/dev/null 2>&1 || echo $?)
check "broken-json" "1" "$broken_status"

# --- 7. 複数対象が全て生成される ---------------------------------------------
multi='{"candidates":[
  {"branch":"a","worktree_path":"/tmp/wt.a","tmux_session":"a","deletable":true},
  {"branch":"b","worktree_path":"/tmp/wt.b","tmux_session":null,"deletable":true}]}'
out=$(plan "$multi")
contains "multi-a" "$out" "wt remove a -y --foreground"
contains "multi-b" "$out" "wt remove b -y --foreground"
contains "multi-a-tmux" "$out" "tmux kill-session -t a"
check "multi-tmux-count" "1" "$(printf '%s\n' "$out" | grep -c 'tmux kill-session')"

# --- 8. ブランチ名にシェルメタ文字が含まれても引数として壊れない --------------
weird='{"candidates":[{"branch":"feat/a b;rm","worktree_path":"/tmp/wt.x",
  "tmux_session":null,"deletable":true}]}'
out=$(plan "$weird")
contains "meta-branch" "$out" "wt remove feat/a b;rm"

exit "$fail"
