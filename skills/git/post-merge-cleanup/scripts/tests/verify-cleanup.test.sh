#!/usr/bin/env bash
# verify-cleanup.sh の検証（使い捨てリポジトリ上で実行）:
#   - 全て消えていれば OK / exit 0
#   - worktree ディレクトリが残っていれば RESIDUAL / exit 1
#   - ローカルブランチが残っていれば RESIDUAL / exit 1
#   - deletable=false の対象は検証対象に含めない
#   - 対象ゼロでも落ちない
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VERIFY="$SCRIPT_DIR/../verify-cleanup.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

# --- fixture: main のみのリポジトリ + 残存させる用のブランチ 1 本 -------------
repo="$TMP/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email t@e.x
git -C "$repo" config user.name t
echo base >"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm base
git -C "$repo" branch leftover

run_verify() { # json -> stdout（exit code は $? に残す）
    (cd "$repo" && bash "$VERIFY" <<<"$1" 2>&1) || true
}
verify_status() {
    (cd "$repo" && bash "$VERIFY" <<<"$1" >/dev/null 2>&1)
    echo $?
}

# --- 1. 全て消えている（存在しない branch / path）-> OK ----------------------
gone='{"candidates":[{"branch":"already-gone","worktree_path":"/nonexistent/wt.x",
  "tmux_session":null,"deletable":true}]}'
out=$(run_verify "$gone")
contains "gone-ok" "$out" "OK: already-gone"
contains "gone-summary" "$out" "計画どおり"
check "gone-exit" "0" "$(verify_status "$gone")"

# --- 2. ローカルブランチが残存 -> RESIDUAL / exit 1 --------------------------
left_branch='{"candidates":[{"branch":"leftover","worktree_path":null,
  "tmux_session":null,"deletable":true}]}'
out=$(run_verify "$left_branch")
contains "branch-residual" "$out" "RESIDUAL: leftover"
contains "branch-residual-msg" "$out" "ローカルブランチが残存"
check "branch-residual-exit" "1" "$(verify_status "$left_branch")"

# --- 3. worktree ディレクトリが残存 -> RESIDUAL / exit 1 ---------------------
mkdir -p "$TMP/still-here"
left_wt=$(printf '{"candidates":[{"branch":"nobranch","worktree_path":"%s",
  "tmux_session":null,"deletable":true}]}' "$TMP/still-here")
out=$(run_verify "$left_wt")
contains "wt-residual" "$out" "worktree が残存"
check "wt-residual-exit" "1" "$(verify_status "$left_wt")"

# --- 4. deletable=false は検証対象外（残っていても RESIDUAL にしない）--------
skipped='{"candidates":[{"branch":"leftover","worktree_path":null,
  "tmux_session":null,"deletable":false}]}'
out=$(run_verify "$skipped")
lacks "skip-not-checked" "$out" "RESIDUAL: leftover"
contains "skip-count" "$out" "検証対象: 0 件"
check "skip-exit" "0" "$(verify_status "$skipped")"

# --- 5. 対象ゼロでも落ちない -------------------------------------------------
check "empty-exit" "0" "$(verify_status '{"candidates":[]}')"
check "nokey-exit" "0" "$(verify_status '{}')"

# --- 6. 複数対象の混在: 片方 OK / 片方 RESIDUAL -> exit 1 --------------------
mix='{"candidates":[
  {"branch":"already-gone","worktree_path":null,"tmux_session":null,"deletable":true},
  {"branch":"leftover","worktree_path":null,"tmux_session":null,"deletable":true}]}'
out=$(run_verify "$mix")
contains "mix-ok" "$out" "OK: already-gone"
contains "mix-residual" "$out" "RESIDUAL: leftover"
check "mix-exit" "1" "$(verify_status "$mix")"

exit "$fail"
