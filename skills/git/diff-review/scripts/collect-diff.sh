#!/usr/bin/env bash
# diff-review: レビュー対象差分の決定論的収集(読み取り専用・stdout のみ)
#
# usage:
#   collect-diff.sh manifest [<base-ref>]                    範囲解決 + 規約列挙 + コミット一覧 + 統計(小径なら全文同梱)
#   collect-diff.sh commit <sha>                             単一コミットの diff(除外適用)
#   collect-diff.sh worktree                                 未コミット変更の diff(staged + unstaged)
#   collect-diff.sh cumulative [<base-ref>] [-- <path>...]   累積 diff(path 明示時は除外を適用しない)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INLINE_THRESHOLD=300 # 累積 diff(除外分を除く)がこの行数以下なら manifest に全文を同梱

# lockfile・生成物: 全文は出力せず統計のみ(git pathspec、'*' はディレクトリ区切りもまたぐ)
EXCLUDE_PATTERNS=(
    '*.lock'
    '*.lockfile'
    '*package-lock.json'
    '*pnpm-lock.yaml'
    '*go.sum'
    '*.min.js'
    '*.min.css'
)
EXCLUDE_PATHSPEC=()
for p in "${EXCLUDE_PATTERNS[@]}"; do
    EXCLUDE_PATHSPEC+=(":(exclude)$p")
done

usage() {
    sed -n '2,8p' "$0" | cut -c3-
}

# BASE_REF / BASE_SHA を解決する。引数 > origin/HEAD > main / master の順
resolve_base() {
    local base_ref="${1:-}"
    if [[ -z "$base_ref" ]]; then
        base_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    fi
    if [[ -z "$base_ref" ]]; then
        local c
        for c in main master; do
            if git rev-parse --quiet --verify "refs/heads/$c" >/dev/null; then
                base_ref="$c"
                break
            fi
        done
    fi
    if [[ -z "$base_ref" ]]; then
        echo "ERROR: デフォルトブランチを特定できない。base-ref を引数で指定すること" >&2
        exit 1
    fi
    BASE_REF="$base_ref"
    BASE_SHA=$(git merge-base "$base_ref" HEAD)
}

# numstat をインデント付き "path +adds -dels" に整形する
format_numstat() {
    awk -F'\t' '{printf "  %s +%s -%s\n", $3, $1, $2}'
}

# numstat の総変更行数(バイナリ "-" は除く)
sum_numstat() {
    awk -F'\t' '{ if ($1 != "-") t += $1; if ($2 != "-") t += $2 } END { print t + 0 }'
}

# 規定パス外のグラウンドトゥルース候補の探索範囲(git pathspec ではなく find 相対パス)。
# 「仕様・設計・テストケースらしい名前」だけを拾い、無関係な md を混ぜない。
CANDIDATE_DIRS=(tmp_claude docs doc design specs spec)
CANDIDATE_NAME_PATTERNS=('*spec*.md' '*basic-design*.md' '*basic_design*.md' '*test-case*.md' '*test_case*.md' '*要件*.md' '*仕様*.md')
CANDIDATE_LIMIT=20 # これを超える候補は打ち切って件数だけ報告する(コンテキスト保護)

# 規定パスのグラウンドトゥルース(既に確定として扱うもの)を相対パスで列挙する。
emit_confirmed_paths() { # root target...
    local root="$1" t p
    shift
    for t in "$@"; do
        for p in "docs/dev/$t/spec.md" "docs/dev/$t/basic-design.md" "docs/test/$t/test-case.md"; do
            if [[ -f "$root/$p" ]]; then
                echo "$p"
            fi
        done
    done
    # 最後の候補が不在でも失敗扱いにしない(呼び出し側は set -e)
    return 0
}

# 規定パス外の候補を探索して相対パスで列挙する(確定済みパスは除く)。
# gitignored なファイル(tmp_claude/ 等)も対象にするため git ls-files は使わない。
find_candidates() { # root confirmed_list
    local root="$1" confirmed="$2"
    local dir args=() first=1 p
    for dir in "${CANDIDATE_DIRS[@]}"; do
        [[ -d "$root/$dir" ]] || continue
        args=()
        local pat
        for pat in "${CANDIDATE_NAME_PATTERNS[@]}"; do
            if ((first)); then
                args+=(-name "$pat")
                first=0
            else
                args+=(-o -name "$pat")
            fi
        done
        first=1
        find "$root/$dir" -type f \( "${args[@]}" \) 2>/dev/null
    done | sed "s|^$root/||" | sort -u | {
        while IFS= read -r p; do
            if ! printf '%s\n' "$confirmed" | grep -qxF -- "$p"; then
                echo "$p"
            fi
        done
        # 全件が確定済みで除外され尽くしても失敗扱いにしない(呼び出し側は set -e)
        return 0
    }
}

# グラウンドトゥルース(仕様・基本設計・テストケース)と タスク境界ファイルの機械検出。
# 該当が 1 つも無ければ何も出力しない(節ごと出さない = 従来と完全一致の出力)。
#
# 3 系統を区別して出す:
#   確定  = 規定パス(docs/dev/<対象>/spec.md 等)、または DIFF_REVIEW_GROUND_TRUTH で明示注入されたもの
#   候補  = 規定パス外で見つかった仕様らしきファイル。採否はメインセッションがユーザーに確認する
#   境界  = .claude/task-boundary.json
emit_ground_truth() {
    local root
    root=$(git rev-parse --show-toplevel)

    # docs/dev/*/spec.md の走査で対象を特定する(対象名 = spec.md の親ディレクトリ名)
    local targets=() d
    if [[ -d "$root/docs/dev" ]]; then
        for d in "$root"/docs/dev/*/; do
            [[ -f "$d/spec.md" ]] || continue
            targets+=("$(basename "$d")")
        done
    fi

    # 明示注入(改行 or ':' 区切りの相対/絶対パス)。存在しないパスは警告して落とす
    local injected=() raw
    if [[ -n "${DIFF_REVIEW_GROUND_TRUTH:-}" ]]; then
        while IFS= read -r raw; do
            [[ -n "$raw" ]] || continue
            local abs="$raw"
            [[ "$abs" != /* ]] && abs="$root/$raw"
            if [[ -f "$abs" ]]; then
                injected+=("${abs#"$root"/}")
            else
                echo "WARN: DIFF_REVIEW_GROUND_TRUTH のパスが存在しない: $raw" >&2
            fi
        done <<<"$(printf '%s' "$DIFF_REVIEW_GROUND_TRUTH" | tr ':' '\n')"
    fi

    local boundary="$root/.claude/task-boundary.json"
    local has_boundary=0
    [[ -f "$boundary" ]] && has_boundary=1

    local confirmed candidates
    confirmed=$(emit_confirmed_paths "$root" ${targets[@]+"${targets[@]}"})
    if ((${#injected[@]})); then
        confirmed=$(printf '%s\n%s\n' "$confirmed" "$(printf '%s\n' "${injected[@]}")" | grep -v '^$' | sort -u)
    fi
    candidates=$(find_candidates "$root" "$confirmed")

    if [[ -z "$confirmed" ]] && [[ -z "$candidates" ]] && ((has_boundary == 0)); then
        return
    fi

    echo "== GROUND_TRUTH (レビューの判断基準。Read して仕様・テストケースと突合する) =="
    local t p
    for t in ${targets[@]+"${targets[@]}"}; do
        echo "対象: $t"
        for p in "docs/dev/$t/spec.md" "docs/dev/$t/basic-design.md" "docs/test/$t/test-case.md"; do
            if [[ -f "$root/$p" ]]; then
                echo "  $p"
            fi
        done
    done
    if ((${#injected[@]})); then
        echo "明示指定(DIFF_REVIEW_GROUND_TRUTH):"
        printf '  %s\n' "${injected[@]}"
    fi
    if [[ -n "$candidates" ]]; then
        local count
        count=$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')
        echo "候補(規定パス外。未確定。採否をユーザーに確認するまで判断基準に使わない): ${count}件"
        printf '%s\n' "$candidates" | head -n "$CANDIDATE_LIMIT" | sed 's/^/  /'
        if ((count > CANDIDATE_LIMIT)); then
            echo "  (残り $((count - CANDIDATE_LIMIT)) 件は省略。DIFF_REVIEW_GROUND_TRUTH で対象を明示すること)"
        fi
    fi
    if ((has_boundary == 1)); then
        echo "タスク境界ファイル: .claude/task-boundary.json"
        sed 's/^/  /' "$boundary"
    fi
    echo
}

# 変更ファイルに適用されるコーディング規約の列挙(collect_conventions.py へ委譲)。
# GROUND_TRUTH と異なり節は常に出す(`status: none` も reviewer への情報)。
# 変更ファイル集合 = 除外 pathspec 適用後の追加・変更ファイル(削除は除く)+ 未追跡ファイル。
# python3 が無い、またはスクリプトが失敗したときは manifest を止めず `status: unavailable` で続行する。
CONVENTIONS_HEADER="== CONVENTIONS (規約。レビューの第 1 基準。一致した規約は Read して照合する) =="
emit_conventions() {
    local root out
    root=$(git rev-parse --show-toplevel)
    if ! command -v python3 >/dev/null 2>&1; then
        echo "WARN: python3 が無いため CONVENTIONS 節を生成できない(status: unavailable)" >&2
        printf '%s\nstatus: unavailable\n\n' "$CONVENTIONS_HEADER"
        return
    fi
    if out=$({
        git diff --name-only --diff-filter=d "$BASE_SHA" -- . "${EXCLUDE_PATHSPEC[@]}"
        git ls-files --others --exclude-standard --full-name
    } | sort -u | python3 "$SCRIPT_DIR/collect_conventions.py" --root "$root"); then
        printf '%s\n\n' "$out"
    else
        echo "WARN: collect_conventions.py が失敗したため CONVENTIONS 節を生成できない(status: unavailable)" >&2
        printf '%s\nstatus: unavailable\n\n' "$CONVENTIONS_HEADER"
    fi
}

cmd_manifest() {
    resolve_base "${1:-}"
    local head_sha branch commits untracked
    head_sha=$(git rev-parse HEAD)
    branch=$(git symbolic-ref --quiet --short HEAD || echo "(detached)")
    commits=$(git log --reverse --format='%h %s' "$BASE_SHA..HEAD")
    untracked=$(git ls-files --others --exclude-standard)

    if [[ -z "$commits" && -z "$untracked" ]] && git diff --quiet HEAD; then
        echo "NO_CHANGES"
        return
    fi

    echo "== RANGE =="
    echo "base_ref=$BASE_REF"
    echo "base=$BASE_SHA"
    echo "head=$head_sha (branch: $branch)"
    echo

    emit_ground_truth
    emit_conventions

    echo "== COMMITS (base..HEAD, 古い順) =="
    if [[ -z "$commits" ]]; then
        echo "(なし)"
    else
        local sha subject
        while read -r sha _; do
            subject=$(git log -1 --format='%s' "$sha")
            echo "- $sha $subject"
            git show --numstat --format= "$sha" -- . "${EXCLUDE_PATHSPEC[@]}" | format_numstat | sed 's/^/  /'
        done <<<"$commits"
    fi
    echo

    echo "== WORKTREE (未コミット変更: staged + unstaged) =="
    local worktree_stat
    worktree_stat=$(git diff --numstat HEAD -- . "${EXCLUDE_PATHSPEC[@]}")
    if [[ -z "$worktree_stat" ]]; then
        echo "(なし)"
    else
        format_numstat <<<"$worktree_stat"
    fi
    echo

    echo "== UNTRACKED (未追跡ファイル: Read ツールで参照する) =="
    if [[ -z "$untracked" ]]; then
        echo "(なし)"
    else
        local f
        while IFS= read -r f; do
            echo "  $f ($(wc -l <"$f") lines)"
        done <<<"$untracked"
    fi
    echo

    echo "== EXCLUDED (lockfile・生成物: 統計のみ、全文は取得不可) =="
    local excluded_stat
    excluded_stat=$(git diff --numstat "$BASE_SHA" -- "${EXCLUDE_PATTERNS[@]}")
    if [[ -z "$excluded_stat" ]]; then
        echo "(なし)"
    else
        format_numstat <<<"$excluded_stat"
    fi
    echo

    local total untracked_lines=0
    total=$(git diff --numstat "$BASE_SHA" -- . "${EXCLUDE_PATHSPEC[@]}" | sum_numstat)
    if [[ -n "$untracked" ]]; then
        local f
        while IFS= read -r f; do
            untracked_lines=$((untracked_lines + $(wc -l <"$f")))
        done <<<"$untracked"
    fi
    echo "== SIZE =="
    echo "total_changed_lines=$total (除外分を除く) + untracked_lines=$untracked_lines"
    echo

    if ((total <= INLINE_THRESHOLD)); then
        echo "== FULL DIFF (total <= ${INLINE_THRESHOLD} のため同梱。未追跡ファイルは含まない) =="
        git diff "$BASE_SHA" -- . "${EXCLUDE_PATHSPEC[@]}"
    else
        echo "== FULL DIFF 省略 (total > ${INLINE_THRESHOLD}) =="
        echo "commit <sha> / worktree / cumulative [-- <path>...] で必要な単位のみ取得すること"
    fi
}

cmd_commit() {
    local sha="${1:-}"
    if [[ -z "$sha" ]]; then
        echo "ERROR: commit <sha> の形式で指定すること" >&2
        exit 1
    fi
    git show "$sha" -- . "${EXCLUDE_PATHSPEC[@]}"
}

cmd_worktree() {
    git diff HEAD -- . "${EXCLUDE_PATHSPEC[@]}"
    local untracked
    untracked=$(git ls-files --others --exclude-standard)
    if [[ -n "$untracked" ]]; then
        echo
        echo "== UNTRACKED (Read ツールで参照する) =="
        local f
        while IFS= read -r f; do
            echo "  $f"
        done <<<"$untracked"
    fi
}

cmd_cumulative() {
    local base_arg="" paths=()
    while (($#)); do
        case "$1" in
            --)
                shift
                paths=("$@")
                break
                ;;
            *)
                base_arg="$1"
                shift
                ;;
        esac
    done
    resolve_base "$base_arg"
    if ((${#paths[@]})); then
        git diff "$BASE_SHA" -- "${paths[@]}"
    else
        git diff "$BASE_SHA" -- . "${EXCLUDE_PATHSPEC[@]}"
    fi
}

sub="${1:-}"
if (($#)); then shift; fi
case "$sub" in
    manifest) cmd_manifest "$@" ;;
    commit) cmd_commit "$@" ;;
    worktree) cmd_worktree ;;
    cumulative) cmd_cumulative "$@" ;;
    *)
        usage >&2
        exit 1
        ;;
esac
