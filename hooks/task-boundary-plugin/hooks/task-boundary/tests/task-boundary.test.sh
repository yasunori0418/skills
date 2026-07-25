#!/usr/bin/env bash
# Verifies task-boundary (matcher: Edit|Write|NotebookEdit):
#   - 境界ファイル無し                    -> 沈黙（fail-open / AC-09）
#   - allow 内への Edit/Write/NotebookEdit -> 沈黙（許可）
#   - allow 外への書き込み                -> deny + 自己説明メッセージ
#   - 境界ファイル自身への書き込み        -> deny（自己解錠の封じ）
#   - `**` の階層またぎ / `*` の単段 / ファイル直指定の照合
#   - 相対パス（cwd 起点）・symlink 経由アクセスの正規化
#   - JSON 破損 / allow 不正                -> deny（設計どおり fail-closed）
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/../main.sh"

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

# raw <cwd> <tool> <path> -> hook の生出力
raw() {
    local key='file_path'
    [ "$2" = "NotebookEdit" ] && key='notebook_path'
    printf '{"cwd": %s, "tool_name": %s, "tool_input": {"%s": %s}}' \
        "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)" \
        "$key" "$(printf '%s' "$3" | jq -Rs .)" \
        | "$GUARD"
}
# decision <cwd> <tool> <path> -> "deny" or ""（沈黙 = 許可）
decision() {
    raw "$1" "$2" "$3" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}
reason() {
    raw "$1" "$2" "$3" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'
}

# --- fixture: 境界ファイルのある worktree ----------------------------------
WT="$TMP/wt"
mkdir -p "$WT/.claude" "$WT/src/client/http" "$WT/src/server" "$WT/tests/client" \
    "$WT/docs/dev/shift-left-process" "$WT/docs/other"
cat > "$WT/.claude/task-boundary.json" << 'JSON'
{
  "task_id": "B2",
  "branch": "feat-client-retry",
  "allow": [
    "src/client/**",
    "tests/client/**",
    "docs/dev/shift-left-process/**",
    "README.md",
    "config/*.toml"
  ]
}
JSON

# --- 境界ファイルの無いツリー -> 沈黙（AC-09） -----------------------------
PLAIN="$TMP/plain"
mkdir -p "$PLAIN/src"
check "no-boundary-file-silent" "" "$(raw "$PLAIN" Write "$PLAIN/src/anything.ts")"
check "no-boundary-file-notebook" "" "$(raw "$PLAIN" NotebookEdit "$PLAIN/src/nb.ipynb")"

# --- allow 内 -> 許可（沈黙） ----------------------------------------------
check "allow-write" "" "$(raw "$WT" Write "$WT/src/client/api.ts")"
check "allow-edit" "" "$(raw "$WT" Edit "$WT/tests/client/api.test.ts")"
check "allow-notebook" "" "$(raw "$WT" NotebookEdit "$WT/src/client/explore.ipynb")"
# `**` はディレクトリ区切りをまたぐ（多段）
check "glob-doublestar-deep" "" "$(raw "$WT" Write "$WT/src/client/http/retry/backoff.ts")"
# `**` はディレクトリ自身にも一致（末端ファイル直下）
check "glob-doublestar-shallow" "" "$(raw "$WT" Write "$WT/src/client/index.ts")"
# ファイル直指定
check "glob-exact-file" "" "$(raw "$WT" Edit "$WT/README.md")"
# 単段 `*`
mkdir -p "$WT/config/nested"
check "glob-single-star" "" "$(raw "$WT" Write "$WT/config/app.toml")"
# 相対パス（cwd 起点）でも同じ判定
check "relative-path-allow" "" "$(raw "$WT" Write "src/client/relative.ts")"
check "dotdot-normalized-allow" "" "$(raw "$WT" Write "$WT/src/server/../client/norm.ts")"

# --- allow 外 -> deny ------------------------------------------------------
check "deny-outside" "deny" "$(decision "$WT" Write "$WT/src/server/handler.ts")"
check "deny-outside-edit" "deny" "$(decision "$WT" Edit "$WT/docs/other/notes.md")"
check "deny-outside-notebook" "deny" "$(decision "$WT" NotebookEdit "$WT/src/server/nb.ipynb")"
check "deny-relative-outside" "deny" "$(decision "$WT" Write "src/server/rel.ts")"
# 単段 `*` はディレクトリ区切りをまたがない
check "deny-single-star-crosses-dir" "deny" "$(decision "$WT" Write "$WT/config/nested/deep.toml")"
# 拡張子違いも glob どおり不一致
check "deny-single-star-ext" "deny" "$(decision "$WT" Write "$WT/config/app.json")"
# prefix が同じだけの兄弟ディレクトリを誤許可しない（`src/client**` 的な取り違え）
mkdir -p "$WT/src/client-legacy"
check "deny-sibling-prefix" "deny" "$(decision "$WT" Write "$WT/src/client-legacy/old.ts")"
# 境界ルートより上（親ディレクトリ）への脱出は境界ファイルが見つからないので沈黙する
# = worktree の外は本 hook の関知外（fail-open の帰結）
check "outside-root-is-silent" "" "$(raw "$WT" Write "$TMP/elsewhere.txt")"

# deny メッセージの自己説明性（AC-09）
MSG=$(reason "$WT" Write "$WT/src/server/handler.ts")
contains "deny-msg-task-id" "$MSG" "B2"
contains "deny-msg-branch" "$MSG" "feat-client-retry"
contains "deny-msg-boundary-path" "$MSG" "$WT/.claude/task-boundary.json"
contains "deny-msg-glob-1" "$MSG" "src/client/**"
contains "deny-msg-glob-2" "$MSG" "tests/client/**"
contains "deny-msg-glob-3" "$MSG" "config/*.toml"
contains "deny-msg-unlock-user-edit" "$MSG" "ユーザーが"
contains "deny-msg-unlock-手順" "$MSG" "allow を手で編集"

# --- 境界ファイル自身への書き込み -> deny（自己解錠の封じ） ----------------
check "deny-self-unlock" "deny" "$(decision "$WT" Write "$WT/.claude/task-boundary.json")"
check "deny-self-unlock-edit" "deny" "$(decision "$WT" Edit "$WT/.claude/task-boundary.json")"
SELF_MSG=$(reason "$WT" Edit "$WT/.claude/task-boundary.json")
contains "self-msg-self-unlock" "$SELF_MSG" "自己解錠"
contains "self-msg-path" "$SELF_MSG" "$WT/.claude/task-boundary.json"
contains "self-msg-unlock-手順" "$SELF_MSG" "ユーザーが"

# allow に境界ファイル自身を含めても deny される（自己解錠の封じが優先）
WT2="$TMP/wt2"
mkdir -p "$WT2/.claude"
cat > "$WT2/.claude/task-boundary.json" << 'JSON'
{"task_id": "X1", "branch": "feat-x", "allow": [".claude/**", "src/**"]}
JSON
check "deny-self-unlock-even-if-allowed" "deny" "$(decision "$WT2" Write "$WT2/.claude/task-boundary.json")"
check "allow-other-dotclaude-file" "" "$(raw "$WT2" Write "$WT2/.claude/settings.json")"

# --- symlink 経由でも同じ判定 ----------------------------------------------
# 別名（symlink）で worktree に入っても、物理パスへ正規化してから相対化するため
# 境界判定が一貫する。
ln -s "$WT" "$TMP/wt-link"
check "symlink-root-allow" "" "$(raw "$TMP/wt-link" Write "$TMP/wt-link/src/client/via-link.ts")"
check "symlink-root-deny" "deny" "$(decision "$TMP/wt-link" Write "$TMP/wt-link/src/server/via-link.ts")"
# worktree 内の symlink ディレクトリ経由でも実体側の位置で判定される
ln -s "$WT/src/server" "$WT/src/client/server-link"
check "symlink-inner-escape-deny" "deny" \
    "$(decision "$WT" Write "$WT/src/client/server-link/handler.ts")"

# --- 異常系: JSON 破損 / allow 不正 -> deny（設計どおり fail-closed） -------
BROKEN="$TMP/broken"
mkdir -p "$BROKEN/.claude/../src"
printf '{"task_id": "B9", "allow": [' > "$BROKEN/.claude/task-boundary.json"
check "broken-json-deny" "deny" "$(decision "$BROKEN" Write "$BROKEN/src/a.ts")"
BROKEN_MSG=$(reason "$BROKEN" Write "$BROKEN/src/a.ts")
contains "broken-msg-path" "$BROKEN_MSG" "$BROKEN/.claude/task-boundary.json"
contains "broken-msg-repair" "$BROKEN_MSG" "修復"

NOALLOW="$TMP/noallow"
mkdir -p "$NOALLOW/.claude" "$NOALLOW/src"
printf '{"task_id": "B8", "branch": "feat-b8"}' > "$NOALLOW/.claude/task-boundary.json"
check "missing-allow-deny" "deny" "$(decision "$NOALLOW" Write "$NOALLOW/src/a.ts")"
NOALLOW_MSG=$(reason "$NOALLOW" Write "$NOALLOW/src/a.ts")
contains "missing-allow-msg-task" "$NOALLOW_MSG" "B8"

BADALLOW="$TMP/badallow"
mkdir -p "$BADALLOW/.claude" "$BADALLOW/src"
printf '{"task_id": "B7", "branch": "feat-b7", "allow": "src/**"}' \
    > "$BADALLOW/.claude/task-boundary.json"
check "allow-not-array-deny" "deny" "$(decision "$BADALLOW" Write "$BADALLOW/src/a.ts")"

EMPTYALLOW="$TMP/emptyallow"
mkdir -p "$EMPTYALLOW/.claude" "$EMPTYALLOW/src"
printf '{"task_id": "B6", "branch": "feat-b6", "allow": []}' \
    > "$EMPTYALLOW/.claude/task-boundary.json"
check "empty-allow-deny" "deny" "$(decision "$EMPTYALLOW" Write "$EMPTYALLOW/src/a.ts")"

# task_id / branch 欠落でも allow が正しければ照合は動く（欠落は "(未宣言)" 表示）
MINIMAL="$TMP/minimal"
mkdir -p "$MINIMAL/.claude" "$MINIMAL/src" "$MINIMAL/other"
printf '{"allow": ["src/**"]}' > "$MINIMAL/.claude/task-boundary.json"
check "minimal-allow" "" "$(raw "$MINIMAL" Write "$MINIMAL/src/a.ts")"
check "minimal-deny" "deny" "$(decision "$MINIMAL" Write "$MINIMAL/other/a.ts")"
contains "minimal-msg-undeclared" "$(reason "$MINIMAL" Write "$MINIMAL/other/a.ts")" "(未宣言)"

# --- パスが取れない入力 -> 沈黙（fail-open） -------------------------------
check "no-path-silent" "" "$(printf '{"cwd": "%s", "tool_input": {}}' "$WT" | "$GUARD")"
check "empty-input-silent" "" "$(printf '{}' | "$GUARD")"

# --- glob メタ文字を含むパスの取り違え防止 ---------------------------------
# allow の `.` は正規表現のワイルドカードとして解釈されてはならない
DOTS="$TMP/dots"
mkdir -p "$DOTS/.claude" "$DOTS/srcX"
printf '{"task_id": "D1", "branch": "feat-d", "allow": ["src.ts", "a+b/**"]}' \
    > "$DOTS/.claude/task-boundary.json"
check "dot-is-literal" "" "$(raw "$DOTS" Write "$DOTS/src.ts")"
check "dot-not-wildcard" "deny" "$(decision "$DOTS" Write "$DOTS/srcXts")"
check "plus-is-literal" "" "$(raw "$DOTS" Write "$DOTS/a+b/c.ts")"
check "plus-not-quantifier" "deny" "$(decision "$DOTS" Write "$DOTS/aab/c.ts")"

# `[...]` `(...)` も ERE メタとして解釈されず、リテラルとして照合される
META="$TMP/meta"
mkdir -p "$META/.claude"
printf '{"task_id": "M1", "branch": "feat-m", "allow": ["src/[a]/**", "d(1)/*.ts"]}' \
    > "$META/.claude/task-boundary.json"
check "bracket-is-literal" "" "$(raw "$META" Write "$META/src/[a]/k.ts")"
check "bracket-not-charclass" "deny" "$(decision "$META" Write "$META/src/a/k.ts")"
check "paren-is-literal" "" "$(raw "$META" Write "$META/d(1)/k.ts")"
check "paren-not-group" "deny" "$(decision "$META" Write "$META/d1/k.ts")"

# 空白を含むパスも壊れない
SPACED="$TMP/spaced"
mkdir -p "$SPACED/.claude"
printf '{"task_id": "S1", "branch": "feat-s", "allow": ["src/**"]}' \
    > "$SPACED/.claude/task-boundary.json"
check "path-with-space-allow" "" "$(raw "$SPACED" Write "$SPACED/src/a b/c d.ts")"
check "path-with-space-deny" "deny" "$(decision "$SPACED" Write "$SPACED/other dir/c d.ts")"

# 境界ルート直下のファイルは `src/**` に一致しない
check "root-level-file-deny" "deny" "$(decision "$SPACED" Write "$SPACED/top.ts")"

exit "$fail"
