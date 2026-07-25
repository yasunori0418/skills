#!/usr/bin/env bash
# Verifies collect-diff.sh manifest (diff-review の差分収集):
#   - グラウンドトゥルース無し     -> GROUND_TRUTH 節を出さない(従来出力とバイト単位で一致)
#   - docs/dev/<対象>/spec.md あり -> 節に spec / basic-design / test-case のパスが出る
#   - 対象が複数                   -> 全対象が列挙される
#   - 境界ファイルあり             -> 節に .claude/task-boundary.json の内容が出る
#   - 境界ファイルのみ             -> 節が出る(対象ディレクトリ不要)
#   - 変更なし                     -> NO_CHANGES(グラウンドトゥルースがあっても)
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COLLECT="$SCRIPT_DIR/../collect-diff.sh"

WORK=$(mktemp -d)
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
hasnt() { # label haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "FAIL: $(basename "$0")[$1] unexpectedly contains '$3'"
        fail=1
    else
        echo "PASS: $(basename "$0")[$1] omits '$3'"
    fi
}

# base(main) から 1 コミット進んだ作業ブランチを持つ使い捨て repo を作る
new_repo() { # dir
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init --quiet --initial-branch=main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "test"
    git -C "$d" config commit.gpgsign false
    echo "base" >"$d/README.md"
    git -C "$d" add -A
    git -C "$d" commit --quiet -m "chore: init"
    git -C "$d" checkout --quiet -b feat
    echo "change" >>"$d/README.md"
    git -C "$d" add -A
    git -C "$d" commit --quiet -m "feat: change"
}

manifest() { # dir -> stdout
    (cd "$1" && "$COLLECT" manifest 2>/dev/null)
}

# --- グラウンドトゥルース無し: 節を出さない ---
D="$WORK/plain" && new_repo "$D"
BASELINE=$(manifest "$D")
check "plain-exit" 0 "$(
    manifest "$D" >/dev/null
    echo $?
)"
hasnt "plain-no-section" "$BASELINE" "== GROUND_TRUTH"

# --- spec.md あり: パスが出る / 後方互換(節以外は従来と一致) ---
D="$WORK/spec" && new_repo "$D"
mkdir -p "$D/docs/dev/alpha" "$D/docs/test/alpha"
echo "# spec" >"$D/docs/dev/alpha/spec.md"
echo "# design" >"$D/docs/dev/alpha/basic-design.md"
echo "# cases" >"$D/docs/test/alpha/test-case.md"
OUT=$(manifest "$D")
has "spec-section" "$OUT" "== GROUND_TRUTH"
has "spec-target" "$OUT" "対象: alpha"
has "spec-path" "$OUT" "docs/dev/alpha/spec.md"
has "spec-design-path" "$OUT" "docs/dev/alpha/basic-design.md"
has "spec-case-path" "$OUT" "docs/test/alpha/test-case.md"

# AC-07 後方互換: 節を挿入する以外の差分を持ち込んでいないこと。
# 節あり出力から GROUND_TRUTH 節だけを削ると、同一 worktree で docs を
# 不可視化(.git/info/exclude + UNTRACKED からも外す)した状態の出力に一致する。
STRIPPED=$(printf '%s\n' "$OUT" | sed '/^== GROUND_TRUTH/,/^$/d')
rm -rf "$D/docs"
HIDDEN=$(manifest "$D")
# docs 自体が未追跡ファイルだったため UNTRACKED / SIZE はその分だけ変わる。
# 節の挿入以外に差分が無いことを見たいので、この 2 節を除いて突き合わせる
strip_variable() { sed -e '/^== UNTRACKED/,/^$/d' -e '/^== SIZE/,/^$/d'; }
check "backward-compat" "$(printf '%s\n' "$STRIPPED" | strip_variable)" "$(printf '%s\n' "$HIDDEN" | strip_variable)"
hasnt "backward-compat-section-removed" "$HIDDEN" "GROUND_TRUTH"

# --- basic-design.md / test-case.md が無い対象は spec.md のみ列挙 ---
D="$WORK/spec-only" && new_repo "$D"
mkdir -p "$D/docs/dev/beta"
echo "# spec" >"$D/docs/dev/beta/spec.md"
OUT=$(manifest "$D")
has "spec-only-path" "$OUT" "docs/dev/beta/spec.md"
hasnt "spec-only-no-design" "$OUT" "basic-design.md"

# --- 対象が複数: 全部列挙 ---
D="$WORK/multi" && new_repo "$D"
mkdir -p "$D/docs/dev/alpha" "$D/docs/dev/beta" "$D/docs/dev/nospec"
echo "# a" >"$D/docs/dev/alpha/spec.md"
echo "# b" >"$D/docs/dev/beta/spec.md"
echo "# noise" >"$D/docs/dev/nospec/notes.md"
OUT=$(manifest "$D")
has "multi-alpha" "$OUT" "対象: alpha"
has "multi-beta" "$OUT" "対象: beta"
hasnt "multi-skips-nospec" "$OUT" "対象: nospec"

# --- 境界ファイルあり: 内容が節に出る ---
D="$WORK/boundary" && new_repo "$D"
mkdir -p "$D/docs/dev/alpha" "$D/.claude"
echo "# spec" >"$D/docs/dev/alpha/spec.md"
cat >"$D/.claude/task-boundary.json" <<'EOF'
{
  "task_id": "B2",
  "branch": "feat-client-retry",
  "allow": ["src/client/**"]
}
EOF
OUT=$(manifest "$D")
has "boundary-header" "$OUT" "タスク境界ファイル: .claude/task-boundary.json"
has "boundary-task-id" "$OUT" '"task_id": "B2"'
has "boundary-allow" "$OUT" '"src/client/**"'

# --- 境界ファイルのみ(グラウンドトゥルース文書なし)でも節は出る ---
D="$WORK/boundary-only" && new_repo "$D"
mkdir -p "$D/.claude"
printf '{"task_id":"A1","branch":"feat-a","allow":["src/**"]}\n' >"$D/.claude/task-boundary.json"
OUT=$(manifest "$D")
has "boundary-only-section" "$OUT" "== GROUND_TRUTH"
has "boundary-only-content" "$OUT" '"task_id":"A1"'
hasnt "boundary-only-no-target" "$OUT" "対象: "

# --- NO_CHANGES: グラウンドトゥルースがあっても維持される ---
D="$WORK/nochanges" && new_repo "$D"
git -C "$D" checkout --quiet main
mkdir -p "$D/docs/dev/alpha"
echo "# spec" >"$D/docs/dev/alpha/spec.md"
git -C "$D" add -A
git -C "$D" commit --quiet -m "docs: spec"
OUT=$(manifest "$D")
check "nochanges" "NO_CHANGES" "$OUT"

exit $fail
