#!/usr/bin/env bash
# Verifies collect-conventions.py (diff-review の規約列挙):
#   - paths: 単一文字列 / YAML リスト / インラインリスト / frontmatter 無し(常時適用)
#   - glob: ** 再帰 / * は / を跨がない / ? / ブレース展開(ネスト) / [...] / 末尾 ** /
#           / を含まないパターンは root 直下のみ / 展開上限超過は WARN + 不一致
#   - 祖先 CLAUDE.md / AGENTS.md の列挙、CLAUDE.local.md 除外、symlink の realpath 重複除去、
#     root の [root, injected] 注記、root AGENTS.md(別実体)は [root]
#   - CONTRIBUTING の 3 箇所
#   - DIFF_REVIEW_CONVENTIONS の追加 / 存在しないパスの WARN / none(explicit-only)
#   - 並び順(具体度)/ 上限 20 件の省略行 / 見出し 200 文字切り / フェンス内見出しの無視 / lint 行
#   - status: none でも節が出る / 変更ファイル無し(stdin 空)でも常時適用ルールは出る
# python3 が無い環境では SKIP して exit 0。
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PY="$SCRIPT_DIR/../collect-conventions.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: $(basename "$0") python3 が無い環境のためスキップ"
    exit 0
fi

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

# 変更ファイル一覧(引数)を stdin で渡して実行する。stderr は捨てる
run() { # root files...
    local root="$1"
    shift
    printf '%s\n' "$@" >"$WORK/in.txt"
    python3 "$PY" --root "$root" <"$WORK/in.txt" 2>/dev/null
}
run_err() { # root files... -> stderr
    local root="$1"
    shift
    printf '%s\n' "$@" >"$WORK/in.txt"
    python3 "$PY" --root "$root" <"$WORK/in.txt" 2>&1 >/dev/null
}
rule() { # root name paths-frontmatter-body(省略時は frontmatter 無し) [markdown]
    local root="$1" name="$2" fm="${3:-}" md="${4:-# $2}"
    mkdir -p "$root/.claude/rules/$(dirname "$name")"
    if [ -n "$fm" ]; then
        printf -- '---\n%s\n---\n%s\n' "$fm" "$md" >"$root/.claude/rules/$name"
    else
        printf -- '%s\n' "$md" >"$root/.claude/rules/$name"
    fi
}

# --- 空リポジトリ: status none でも節・lint 行が出る ---
R="$WORK/empty" && mkdir -p "$R"
OUT=$(run "$R" "src/a.kt")
has "empty-header" "$OUT" "== CONVENTIONS"
has "empty-status" "$OUT" "status: none"
has "empty-lint" "$OUT" "lint: (なし)"
check "empty-exit" 0 "$(
    run "$R" "src/a.kt" >/dev/null
    echo $?
)"

# --- paths の 3 形式 + frontmatter 無し ---
R="$WORK/forms" && mkdir -p "$R"
rule "$R" "single.md" 'paths: "src/**/*.kt"'
rule "$R" "block.md" $'paths:\n  - "lib/**/*.kt"\n  - "src/**/*.kt"'
rule "$R" "inline.md" 'paths: ["docs/*.md", src/app/x.kt]'
rule "$R" "always.md"
rule "$R" "unrelated.md" 'paths: "web/**"'
OUT=$(run "$R" "src/app/x.kt")
has "form-single" "$OUT" ".claude/rules/single.md"
has "form-block" "$OUT" ".claude/rules/block.md"
has "form-inline" "$OUT" ".claude/rules/inline.md"
has "form-always" "$OUT" ".claude/rules/always.md"
has "form-always-tag" "$OUT" "[paths: なし (常時適用)]"
hasnt "form-unrelated" "$OUT" "unrelated.md"
has "form-matched-pattern" "$OUT" "[paths: src/**/*.kt]"
has "form-status" "$OUT" "status: found"
# 常時適用ルールは変更ファイルが無くても出る
OUT=$(run "$R")
has "always-no-files" "$OUT" ".claude/rules/always.md"
hasnt "single-no-files" "$OUT" "single.md"

# --- glob 意味論 ---
R="$WORK/glob" && mkdir -p "$R"
rule "$R" "dstar.md" 'paths: "src/**/*.kt"'
rule "$R" "star.md" 'paths: "src/*.kt"'
rule "$R" "qmark.md" 'paths: "src/?.kt"'
rule "$R" "brace.md" 'paths: "src/**/*.{kt,kts}"'
rule "$R" "nested.md" 'paths: "{src,lib}/{a,b/**}/*.{k{t,ts},java}"'
rule "$R" "class.md" 'paths: "src/[a-c].kt"'
rule "$R" "negclass.md" 'paths: "src/[!a-c].kt"'
rule "$R" "tail.md" 'paths: "src/**"'
rule "$R" "rootonly.md" 'paths: "*.md"'
# ** は 0 個以上のディレクトリ
OUT=$(run "$R" "src/a.kt")
has "dstar-zero-dirs" "$OUT" "dstar.md"
has "star-direct" "$OUT" "rules/star.md"
has "qmark-one-char" "$OUT" "qmark.md"
has "brace-kt" "$OUT" "brace.md"
has "class-a" "$OUT" "rules/class.md"
hasnt "negclass-a" "$OUT" "negclass.md"
has "tail-dstar" "$OUT" "tail.md"
OUT=$(run "$R" "src/deep/er/x.kt")
has "dstar-deep" "$OUT" "dstar.md"
hasnt "star-no-slash" "$OUT" "rules/star.md"
hasnt "qmark-no-slash" "$OUT" "qmark.md"
has "tail-deep" "$OUT" "tail.md"
OUT=$(run "$R" "src/deep/x.kts")
has "brace-kts" "$OUT" "brace.md"
hasnt "dstar-kts" "$OUT" "dstar.md"
OUT=$(run "$R" "src/ab.kt")
hasnt "qmark-two-chars" "$OUT" "qmark.md"
hasnt "class-two-chars" "$OUT" "rules/class.md"
OUT=$(run "$R" "src/z.kt")
has "negclass-z" "$OUT" "negclass.md"
OUT=$(run "$R" "lib/b/deep/x.kts")
has "nested-brace" "$OUT" "nested.md"
OUT=$(run "$R" "lib/a/x.java")
has "nested-brace-java" "$OUT" "nested.md"
OUT=$(run "$R" "lib/c/x.kt")
hasnt "nested-brace-miss" "$OUT" "nested.md"
# / を含まないパターンは root 直下のみ(公式仕様: `*.md` = Markdown files in the project root)
OUT=$(run "$R" "README.md")
has "rootonly-root" "$OUT" "rootonly.md"
OUT=$(run "$R" "docs/README.md")
hasnt "rootonly-nested" "$OUT" "rootonly.md"

# --- ブレース展開の上限超過: WARN して不一致 ---
R="$WORK/budget" && mkdir -p "$R"
big='{a,b,c,d,e,f,g,h,i,j}'
rule "$R" "huge.md" "paths: \"src/$big/$big/$big/**\"" # 1000 通り: 予算内
rule "$R" "over.md" "paths: \"src/$big/$big/$big/$big/**\"" # 10000 通り: 超過
OUT=$(run "$R" "src/a/b/c/x.kt")
has "budget-within" "$OUT" "huge.md"
hasnt "budget-over" "$OUT" "over.md"
ERR=$(run_err "$R" "src/a/b/c/x.kt")
has "budget-warn" "$ERR" "over.md の paths はブレース展開が 1000 パターンを超える"

# --- 祖先 CLAUDE.md / AGENTS.md・symlink 重複除去・local 除外・root 注記 ---
R="$WORK/ancestors" && mkdir -p "$R/src/app/sub" "$R/other"
printf '# Root\n' >"$R/AGENTS.md"
ln -s AGENTS.md "$R/CLAUDE.md"
printf '# Module\n## 責務\n' >"$R/src/app/AGENTS.md"
ln -s AGENTS.md "$R/src/app/CLAUDE.md"
printf '# Local\n' >"$R/src/app/CLAUDE.local.md"
printf '# Src\n' >"$R/src/CLAUDE.md"
printf '# Other\n' >"$R/other/CLAUDE.md"
OUT=$(run "$R" "src/app/sub/y.kt")
has "anc-module" "$OUT" "src/app/CLAUDE.md"
hasnt "anc-module-dup" "$OUT" "src/app/AGENTS.md"
has "anc-module-tag" "$OUT" "[ancestor of src/app/]"
has "anc-module-heads" "$OUT" "(h1: Module; h2: 責務)"
has "anc-src" "$OUT" "src/CLAUDE.md"
hasnt "anc-local" "$OUT" "CLAUDE.local.md"
hasnt "anc-other" "$OUT" "other/CLAUDE.md"
has "anc-root" "$OUT" "[root, injected]"
hasnt "anc-root-agents-dup" "$OUT" "- AGENTS.md"
check "anc-root-once" 1 "$(printf '%s\n' "$OUT" | grep -c '\[root, injected\]')"
# 深い祖先が上、root が下(順序)
check "anc-order" "src/app/CLAUDE.md src/CLAUDE.md CLAUDE.md" "$(printf '%s\n' "$OUT" | grep -oE '^- [^ ]+' | cut -c3- | tr '\n' ' ' | sed 's/ $//')"

# root の AGENTS.md が CLAUDE.md と別実体なら注入済みではない
R="$WORK/root-agents" && mkdir -p "$R/src"
printf '# C\n' >"$R/CLAUDE.md"
printf '# A\n' >"$R/AGENTS.md"
OUT=$(run "$R" "src/a.kt")
has "root-claude-injected" "$OUT" "CLAUDE.md  [root, injected]"
has "root-agents-plain" "$OUT" "AGENTS.md  [root]"
# .claude/CLAUDE.md も root 注入済み
R="$WORK/dot-claude" && mkdir -p "$R/.claude"
printf '# C\n' >"$R/.claude/CLAUDE.md"
OUT=$(run "$R" "src/a.kt")
has "dot-claude-injected" "$OUT" ".claude/CLAUDE.md  [root, injected]"

# --- CONTRIBUTING の 3 箇所 ---
R="$WORK/contrib" && mkdir -p "$R/.github" "$R/docs"
printf '# C1\n' >"$R/CONTRIBUTING.md"
printf '# C2\n' >"$R/.github/CONTRIBUTING.md"
printf '# C3\n' >"$R/docs/CONTRIBUTING.md"
OUT=$(run "$R" "src/a.kt")
has "contrib-root" "$OUT" "- CONTRIBUTING.md"
has "contrib-github" "$OUT" ".github/CONTRIBUTING.md"
has "contrib-docs" "$OUT" "docs/CONTRIBUTING.md"
check "contrib-tags" 3 "$(printf '%s\n' "$OUT" | grep -c '\[contributing\]')"

# --- DIFF_REVIEW_CONVENTIONS: 追加 / 欠損 WARN / none ---
R="$WORK/env" && mkdir -p "$R/docs"
rule "$R" "always.md"
printf '# Conv\n## 命名\n' >"$R/docs/conv.md"
printf '# Style\n' >"$R/docs/style.md"
printf '%s\n' "src/a.kt" >"$WORK/in.txt"
OUT=$(DIFF_REVIEW_CONVENTIONS="docs/conv.md:docs/style.md" python3 "$PY" --root "$R" <"$WORK/in.txt" 2>/dev/null)
has "env-explicit-a" "$OUT" "docs/conv.md"
has "env-explicit-b" "$OUT" "docs/style.md"
has "env-explicit-tag" "$OUT" "[explicit: DIFF_REVIEW_CONVENTIONS]"
has "env-explicit-plus-auto" "$OUT" "always.md"
has "env-explicit-status" "$OUT" "status: found"
ERR=$(DIFF_REVIEW_CONVENTIONS="nope/x.md" python3 "$PY" --root "$R" <"$WORK/in.txt" 2>&1 >/dev/null)
has "env-missing-warn" "$ERR" "DIFF_REVIEW_CONVENTIONS のパスが存在しない: nope/x.md"
OUT=$(DIFF_REVIEW_CONVENTIONS="nope/x.md" python3 "$PY" --root "$R" <"$WORK/in.txt" 2>/dev/null)
has "env-missing-still-section" "$OUT" "status: found"
# 絶対パスも受ける
OUT=$(DIFF_REVIEW_CONVENTIONS="$R/docs/conv.md" python3 "$PY" --root "$R" <"$WORK/in.txt" 2>/dev/null)
has "env-abs" "$OUT" "- docs/conv.md"
# none: 自動探索を止め明示分のみ
OUT=$(DIFF_REVIEW_CONVENTIONS="none" python3 "$PY" --root "$R" <"$WORK/in.txt" 2>/dev/null)
has "env-none-status" "$OUT" "status: explicit-only"
hasnt "env-none-no-auto" "$OUT" "always.md"
OUT=$(DIFF_REVIEW_CONVENTIONS="none:docs/conv.md" python3 "$PY" --root "$R" <"$WORK/in.txt" 2>/dev/null)
has "env-none-explicit-status" "$OUT" "status: explicit-only"
has "env-none-explicit-path" "$OUT" "docs/conv.md"
hasnt "env-none-explicit-no-auto" "$OUT" "always.md"
# 自動探索と重複する明示注入は 1 行にまとまる
OUT=$(DIFF_REVIEW_CONVENTIONS=".claude/rules/always.md" python3 "$PY" --root "$R" <"$WORK/in.txt" 2>/dev/null)
check "env-dup-once" 1 "$(printf '%s\n' "$OUT" | grep -c 'always.md')"

# --- 並び順: rules(具体度順)→ 祖先 → root → contributing → explicit ---
R="$WORK/order" && mkdir -p "$R/src/app" "$R/docs"
rule "$R" "broad.md" 'paths: "**/*.kt"'
rule "$R" "mid.md" 'paths: "src/**/*.kt"'
rule "$R" "narrow.md" 'paths: "src/app/*.kt"'
rule "$R" "always.md"
printf '# M\n' >"$R/src/app/CLAUDE.md"
printf '# R\n' >"$R/CLAUDE.md"
printf '# C\n' >"$R/CONTRIBUTING.md"
printf '# E\n' >"$R/docs/e.md"
OUT=$(DIFF_REVIEW_CONVENTIONS="docs/e.md" python3 "$PY" --root "$R" <"$WORK/in.txt" 2>/dev/null)
printf '%s\n' "src/app/x.kt" >"$WORK/in.txt"
OUT=$(DIFF_REVIEW_CONVENTIONS="docs/e.md" python3 "$PY" --root "$R" <"$WORK/in.txt" 2>/dev/null)
check "order" ".claude/rules/narrow.md .claude/rules/mid.md .claude/rules/broad.md .claude/rules/always.md src/app/CLAUDE.md CLAUDE.md CONTRIBUTING.md docs/e.md" \
    "$(printf '%s\n' "$OUT" | grep -oE '^- [^ ]+' | cut -c3- | tr '\n' ' ' | sed 's/ $//')"

# --- 上限 20 件: 超過分は省略行 ---
R="$WORK/limit" && mkdir -p "$R"
for i in $(seq -w 1 25); do
    rule "$R" "r$i.md"
done
OUT=$(run "$R" "src/a.kt")
check "limit-shown" 20 "$(printf '%s\n' "$OUT" | grep -c '^- ')"
has "limit-omitted" "$OUT" "(残り 5 件は省略。DIFF_REVIEW_CONVENTIONS で対象を明示すること)"

# --- 見出し: h1/h2 のみ・フェンス内無視・200 文字で切る ---
R="$WORK/heads" && mkdir -p "$R"
long=$(printf 'あ%.0s' $(seq 1 300))
rule "$R" "h.md" "" "$(printf '# %s\n## Two\n### Three\n```\n# fenced\n```\n' "$long")"
OUT=$(run "$R" "src/a.kt")
hasnt "heads-h3" "$OUT" "h3:"
hasnt "heads-fenced" "$OUT" "fenced"
has "heads-ellipsis" "$OUT" "…)"
# 文字数は python3 で数える(nix sandbox は C ロケールで awk の length がバイト数になる)
printf '%s\n' "$OUT" | grep '^- ' | sed -E 's/.*\((h1.*)\)$/\1/' >"$WORK/heads.txt"
LEN=$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read().rstrip("\n")))' "$WORK/heads.txt")
check "heads-truncated" 200 "$LEN"
rule "$R" "short.md" "" "$(printf '# One\n## Two\n### Three\n')"
OUT=$(run "$R" "src/a.kt")
has "heads-h1h2" "$OUT" "(h1: One; h2: Two)"

# --- lint 検出: 存在検出のみ・pyproject は [tool.ruff] があるときだけ ---
R="$WORK/lint" && mkdir -p "$R"
touch "$R/.editorconfig" "$R/detekt.yml" "$R/eslint.config.mjs" "$R/.prettierrc.json"
printf '[project]\nname = "x"\n' >"$R/pyproject.toml"
OUT=$(run "$R" "src/a.kt")
has "lint-line" "$OUT" "lint: detekt.yml, .editorconfig, eslint.config.mjs, .prettierrc.json   (書式系は lint に委ね指摘しない)"
hasnt "lint-pyproject-plain" "$OUT" "pyproject.toml"
printf '[tool.ruff]\nline-length = 100\n' >>"$R/pyproject.toml"
OUT=$(run "$R" "src/a.kt")
has "lint-pyproject-ruff" "$OUT" "pyproject.toml"

# --- 壊れた frontmatter(閉じ --- 無し)は常時適用として扱い落とさない ---
R="$WORK/broken" && mkdir -p "$R/.claude/rules"
printf -- '---\npaths: "src/**"\n# never closed\n' >"$R/.claude/rules/broken.md"
OUT=$(run "$R" "other/z.go")
has "broken-frontmatter-always" "$OUT" "broken.md"

exit $fail
