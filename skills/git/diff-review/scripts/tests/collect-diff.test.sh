#!/usr/bin/env bash
# Verifies collect-diff.sh manifest (diff-review の差分収集):
#   - グラウンドトゥルース無し     -> GROUND_TRUTH 節を出さない(節の挿入以外は従来出力と一致)
#   - docs/dev/<対象>/spec.md あり -> 節に spec / basic-design / test-case のパスが出る
#   - 対象が複数                   -> 全対象が列挙される
#   - 境界ファイルあり             -> 節に .claude/task-boundary.json の内容が出る
#   - 境界ファイルのみ             -> 節が出る(対象ディレクトリ不要)
#   - 変更なし                     -> NO_CHANGES(グラウンドトゥルースがあっても)
#   - CONVENTIONS 節               -> manifest には常に出る(規約が無くても status: none)。
#                                     .claude/rules の paths 照合・未追跡ファイルの照合・削除ファイルの除外、
#                                     commit / worktree / cumulative には出ない、python3 不在で status: unavailable
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
conv_section() { # manifest-output -> CONVENTIONS 節のみ(UNTRACKED 等に同じパスが出るため絞る)
    printf '%s\n' "$1" | sed -n '/^== CONVENTIONS/,/^$/p'
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

# --- CONVENTIONS 節: 規約が無くても常に出る(status: none) ---
has "conv-plain-section" "$BASELINE" "== CONVENTIONS"
has "conv-plain-none" "$BASELINE" "status: none"
has "conv-plain-lint" "$BASELINE" "lint: (なし)"

# --- CONVENTIONS 節: .claude/rules の paths が変更ファイルに一致すると found ---
D="$WORK/conv-rules" && new_repo "$D"
mkdir -p "$D/.claude/rules"
printf -- '---\npaths: "*.md"\n---\n# Root docs\n' >"$D/.claude/rules/root-md.md"
printf -- '---\npaths: "src/**/*.kt"\n---\n# Kotlin\n' >"$D/.claude/rules/kotlin.md"
OUT=$(conv_section "$(manifest "$D")")
has "conv-rules-found" "$OUT" "status: found"
has "conv-rules-matched" "$OUT" ".claude/rules/root-md.md"
hasnt "conv-rules-unmatched" "$OUT" ".claude/rules/kotlin.md"
# 未追跡ファイルも照合対象(src/a.kt を未追跡で置く)
mkdir -p "$D/src"
echo "fun main() {}" >"$D/src/a.kt"
OUT=$(conv_section "$(manifest "$D")")
has "conv-untracked-matched" "$OUT" ".claude/rules/kotlin.md"

# --- CONVENTIONS 節: 削除ファイルは照合に使われない ---
D="$WORK/conv-deleted" && new_repo "$D"
git -C "$D" checkout --quiet main
mkdir -p "$D/src/legacy" "$D/.claude/rules"
echo "old" >"$D/src/legacy/gone.kt"
printf -- '---\npaths: "src/legacy/**"\n---\n# Legacy\n' >"$D/.claude/rules/legacy.md"
git -C "$D" add -A
git -C "$D" commit --quiet -m "chore: legacy"
git -C "$D" checkout --quiet -b feat-del
git -C "$D" rm --quiet src/legacy/gone.kt
git -C "$D" commit --quiet -m "refactor: remove legacy"
OUT=$(conv_section "$(manifest "$D")")
has "conv-deleted-section" "$OUT" "== CONVENTIONS"
hasnt "conv-deleted-not-matched" "$OUT" ".claude/rules/legacy.md"

# --- CONVENTIONS 節: manifest 以外のサブコマンドには出ない ---
D="$WORK/conv-subcmds" && new_repo "$D"
mkdir -p "$D/.claude/rules"
printf -- '---\npaths: "*.md"\n---\n# Root docs\n' >"$D/.claude/rules/root-md.md"
SHA=$(git -C "$D" rev-parse HEAD)
hasnt "conv-not-in-commit" "$(cd "$D" && "$COLLECT" commit "$SHA" 2>/dev/null)" "== CONVENTIONS"
hasnt "conv-not-in-worktree" "$(cd "$D" && "$COLLECT" worktree 2>/dev/null)" "== CONVENTIONS"
hasnt "conv-not-in-cumulative" "$(cd "$D" && "$COLLECT" cumulative 2>/dev/null)" "== CONVENTIONS"

# --- CONVENTIONS 節: python3 が PATH に無ければ status: unavailable で manifest は完走する ---
BIN="$WORK/bin-nopython"
mkdir -p "$BIN"
for tool in bash git awk sed cut wc tr sort grep head find uniq basename dirname; do
    src=$(command -v "$tool" 2>/dev/null) && ln -s "$src" "$BIN/$tool"
done
D="$WORK/conv-nopython" && new_repo "$D"
OUT=$(cd "$D" && PATH="$BIN" "$COLLECT" manifest 2>/dev/null)
check "conv-nopython-exit" 0 "$(
    cd "$D" && PATH="$BIN" "$COLLECT" manifest >/dev/null 2>&1
    echo $?
)"
has "conv-nopython-status" "$OUT" "status: unavailable"
has "conv-nopython-completes" "$OUT" "== SIZE =="
ERR=$(cd "$D" && PATH="$BIN" "$COLLECT" manifest 2>&1 >/dev/null)
has "conv-nopython-warn" "$ERR" "python3 が無いため CONVENTIONS 節を生成できない"

# --- 規定パス外の候補: gitignored な tmp_claude/ の仕様書も候補として出る ---
# 実運用の失敗例(tmp_claude/<日付>_<対象>_spec.md が検出されずレビューが仕様を無視した)の回帰
D="$WORK/candidate" && new_repo "$D"
mkdir -p "$D/tmp_claude"
printf 'tmp_claude/\n' >"$D/.gitignore"
echo "# spec" >"$D/tmp_claude/20260715_batch_optimize_spec.md"
OUT=$(manifest "$D")
has "candidate-section" "$OUT" "== GROUND_TRUTH"
has "candidate-header" "$OUT" "候補(規定パス外"
has "candidate-path" "$OUT" "tmp_claude/20260715_batch_optimize_spec.md"
hasnt "candidate-not-confirmed" "$OUT" "対象: "

# --- 候補は未確定である旨が明記される(採否確認前に判断基準へ使わせない) ---
has "candidate-unconfirmed-note" "$OUT" "採否をユーザーに確認するまで判断基準に使わない"

# --- 仕様らしくない md は候補に入らない ---
D="$WORK/candidate-noise" && new_repo "$D"
mkdir -p "$D/docs"
echo "# notes" >"$D/docs/notes.md"
echo "# readme" >"$D/docs/architecture.md"
OUT=$(manifest "$D")
hasnt "candidate-noise-no-section" "$OUT" "== GROUND_TRUTH"

# --- 明示注入: 確定側に出て候補には重複しない ---
D="$WORK/injected" && new_repo "$D"
mkdir -p "$D/tmp_claude"
echo "# spec" >"$D/tmp_claude/my_spec.md"
OUT=$(cd "$D" && DIFF_REVIEW_GROUND_TRUTH="tmp_claude/my_spec.md" "$COLLECT" manifest 2>/dev/null)
has "injected-header" "$OUT" "明示指定(DIFF_REVIEW_GROUND_TRUTH)"
has "injected-path" "$OUT" "tmp_claude/my_spec.md"
hasnt "injected-not-candidate" "$OUT" "候補(規定パス外"

# --- 明示注入: ':' 区切りで複数指定できる ---
D="$WORK/injected-multi" && new_repo "$D"
mkdir -p "$D/design"
echo "# a" >"$D/design/a_spec.md"
echo "# b" >"$D/design/b_basic-design.md"
OUT=$(cd "$D" && DIFF_REVIEW_GROUND_TRUTH="design/a_spec.md:design/b_basic-design.md" "$COLLECT" manifest 2>/dev/null)
has "injected-multi-a" "$OUT" "design/a_spec.md"
has "injected-multi-b" "$OUT" "design/b_basic-design.md"

# --- 明示注入: 存在しないパスは WARN して落とす(節は壊れない) ---
D="$WORK/injected-missing" && new_repo "$D"
ERR=$(cd "$D" && DIFF_REVIEW_GROUND_TRUTH="nope/x.md" "$COLLECT" manifest 2>&1 >/dev/null)
has "injected-missing-warn" "$ERR" "DIFF_REVIEW_GROUND_TRUTH のパスが存在しない"
OUT=$(cd "$D" && DIFF_REVIEW_GROUND_TRUTH="nope/x.md" "$COLLECT" manifest 2>/dev/null)
hasnt "injected-missing-no-section" "$OUT" "== GROUND_TRUTH"

# --- set -e 回帰: 規定パスの一部(basic-design/test-case)が不在でも manifest が完走する ---
# emit_confirmed_paths / find_candidates の末尾が偽になり set -e で中断した不具合の回帰
D="$WORK/partial-paths" && new_repo "$D"
mkdir -p "$D/docs/dev/alpha"
echo "# spec" >"$D/docs/dev/alpha/spec.md"
check "partial-paths-exit" 0 "$(
    manifest "$D" >/dev/null
    echo $?
)"
OUT=$(manifest "$D")
has "partial-paths-section" "$OUT" "docs/dev/alpha/spec.md"
has "partial-paths-completes" "$OUT" "== SIZE =="

# --- set -e 回帰: 候補が全件確定済みで除外され尽くしても完走する ---
D="$WORK/all-confirmed" && new_repo "$D"
mkdir -p "$D/docs/dev/alpha" "$D/docs/test/alpha"
echo "# spec" >"$D/docs/dev/alpha/spec.md"
echo "# design" >"$D/docs/dev/alpha/basic-design.md"
echo "# cases" >"$D/docs/test/alpha/test-case.md"
check "all-confirmed-exit" 0 "$(
    manifest "$D" >/dev/null
    echo $?
)"
OUT=$(manifest "$D")
has "all-confirmed-completes" "$OUT" "== SIZE =="

exit $fail
