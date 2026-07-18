#!/usr/bin/env bash
# launch.sh — /project-session の決定論バックエンド。
#
# ghq 管理下のプロジェクトを 1 つ選び、そのディレクトリで（ブランチを変えず・
# worktree も作らず）claude を detached tmux セッションとして起動する。
# ghq 照合・セッション名決定・tmux 起動という機械的に確定できる処理を
# ここへ集約し、SKILL.md 側でロジックを二重管理しない。
#
# 純関数（sanitize/resolve_matches/session_base_name/next_session_name/
# inject_remote_control）は外部コマンド（ghq/tmux/claude）を呼ばず、入力は
# 引数と stdin のみ。これにより CI sandbox（jq/git のみ、ghq/tmux/claude 無し）で
# `source launch.sh` してテストできる。impure な処理は main とサブコマンドに閉じ、
# 末尾の source ガードで「直接実行時のみ main」を担保する。
set -euo pipefail

# sanitize <name>
# tmux セッション名向けに [^A-Za-z0-9_-]+ を - に置換し前後の - を除去する。
# 空になったら session を返す（parallel-worktree の sanitize と同じ規則）。
sanitize() {
    local name="$1" out
    out=$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9_-]+/-/g; s/^-+//; s/-+$//')
    printf '%s' "${out:-session}"
}

# resolve_matches <query>  (ghq list 全文を stdin から)
# 大文字小文字無視の部分一致で候補を列挙する。ただし basename（repo 名）が query と
# 大文字小文字無視で完全一致する候補がちょうど 1 件あれば、それを単独採用する
# （`foo` と `foo-bar` がある環境で `foo` が曖昧にならないための優先規則）。
# 候補を 1 行 1 件で stdout へ。
resolve_matches() {
    local query="$1" lower_query line lower_line base lower_base
    lower_query=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')

    local -a partial=() exact=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        lower_line=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
        case "$lower_line" in
        *"$lower_query"*)
            partial+=("$line")
            base=${line##*/}
            lower_base=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
            if [ "$lower_base" = "$lower_query" ]; then
                exact+=("$line")
            fi
            ;;
        esac
    done

    # basename 完全一致がちょうど 1 件なら、それを単独採用（曖昧化を避ける）。
    if [ "${#exact[@]}" -eq 1 ]; then
        printf '%s\n' "${exact[0]}"
        return 0
    fi

    local m
    for m in "${partial[@]}"; do
        printf '%s\n' "$m"
    done
}

# session_base_name <relpath>  (ghq list 全文を stdin から)
# relpath の basename が list 内で一意なら sanitize <repo>、重複していれば
# sanitize <owner>-<repo>（owner は basename の 1 つ上のパス要素）を返す。
session_base_name() {
    local relpath="$1" repo owner line count=0
    repo=${relpath##*/}
    owner=${relpath%/*}
    owner=${owner##*/}

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "${line##*/}" = "$repo" ]; then
            count=$((count + 1))
        fi
    done

    if [ "$count" -le 1 ]; then
        sanitize "$repo"
    else
        sanitize "$owner-$repo"
    fi
}

# next_session_name <base>  (既存セッション名一覧を stdin から、1 行 1 件)
# <base> が未使用ならそのまま。使用中なら <base>-2 から昇順で最初の空きを返す。
next_session_name() {
    local base="$1" line
    local -A used=()
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        used["$line"]=1
    done

    if [ -z "${used[$base]:-}" ]; then
        printf '%s' "$base"
        return 0
    fi

    local n=2
    while [ -n "${used[$base-$n]:-}" ]; do
        n=$((n + 1))
    done
    printf '%s' "$base-$n"
}

# inject_remote_control <sess> <args...>
# 引数列を走査し、最初の値なし --remote-control（末尾、または次トークンが -
# 始まり）の直後に <sess> を挿入する。ユーザーが値を書いた場合（次トークンが
# - 始まりでない）は触らない。最初の 1 個のみ処理。結果は NUL 区切りで stdout へ
# （プロンプト引数は空白・改行を含み得るため）。
inject_remote_control() {
    local sess="$1"
    shift
    local -a args=("$@")
    local -a out=()
    local i injected=0 n=${#args[@]}

    for ((i = 0; i < n; i++)); do
        local cur="${args[i]}"
        out+=("$cur")
        if [ "$injected" -eq 0 ] && [ "$cur" = "--remote-control" ]; then
            if [ $((i + 1)) -ge "$n" ]; then
                # 末尾の値なし --remote-control -> セッション名を注入。
                out+=("$sess")
                injected=1
            else
                local nxt="${args[i + 1]}"
                if [ "${nxt:0:1}" = "-" ]; then
                    # 次トークンがフラグ -> 値なしとみなして注入。
                    out+=("$sess")
                    injected=1
                fi
            fi
        fi
    done

    printf '%s\0' "${out[@]}"
}

# ---- impure: サブコマンド / main ------------------------------------------

# cmd_list — ghq list をそのまま 1 行 1 件で出力（引数省略時の一覧提示用）。
cmd_list() {
    ghq list
}

# cmd_resolve <query> — resolve_matches の結果で分岐する。
#   一意: stdout に relpath 1 行、exit 0
#   複数: stdout に候補一覧、stderr に ambiguous、exit 2
#   0 件: stdout に全一覧、stderr に not found、exit 3
cmd_resolve() {
    local query="$1" list matches count
    list=$(ghq list)
    matches=$(printf '%s\n' "$list" | resolve_matches "$query")

    if [ -z "$matches" ]; then
        count=0
    else
        count=$(printf '%s\n' "$matches" | grep -c '^')
    fi

    if [ "$count" -eq 1 ]; then
        printf '%s\n' "$matches"
        return 0
    elif [ "$count" -ge 2 ]; then
        printf '%s\n' "$matches"
        printf 'ambiguous\n' >&2
        return 2
    else
        printf '%s\n' "$list"
        printf 'not found\n' >&2
        return 3
    fi
}

# cmd_launch <query> [claude引数...] — 本体。
cmd_launch() {
    local query="$1"
    shift
    local -a claude_args=("$@")

    # 1. 必須コマンドの存在確認（欠落は名指しでエラー）。
    local tool missing=0
    for tool in tmux ghq claude; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            printf 'error: `%s` が見つかりません（PATH に必要）\n' "$tool" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || return 1

    # 2. resolve と同じ解決。一意でなければ resolve と同じ出力・exit code で中断。
    local list matches count relpath
    list=$(ghq list)
    matches=$(printf '%s\n' "$list" | resolve_matches "$query")
    if [ -z "$matches" ]; then
        count=0
    else
        count=$(printf '%s\n' "$matches" | grep -c '^')
    fi
    if [ "$count" -ge 2 ]; then
        printf '%s\n' "$matches"
        printf 'ambiguous\n' >&2
        return 2
    elif [ "$count" -eq 0 ]; then
        printf '%s\n' "$list"
        printf 'not found\n' >&2
        return 3
    fi
    relpath=$(printf '%s\n' "$matches" | head -n1)

    # 3. 実パス = $(ghq root)/<relpath>。存在確認。
    local abs_path
    abs_path="$(ghq root)/$relpath"
    if [ ! -d "$abs_path" ]; then
        printf 'error: ディレクトリが存在しません: %s\n' "$abs_path" >&2
        return 1
    fi

    # 4. セッション名決定（既存一覧は tmux から。サーバ未起動は空扱い）。
    local base existing sess
    base=$(printf '%s\n' "$list" | session_base_name "$relpath")
    existing=$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
    sess=$(printf '%s\n' "$existing" | next_session_name "$base")

    # 5. inject_remote_control で claude 引数を確定（NUL 区切りで受け取る）。
    local -a final_args=()
    if [ "${#claude_args[@]}" -gt 0 ]; then
        mapfile -d '' final_args < <(inject_remote_control "$sess" "${claude_args[@]}")
    fi

    # 6. tmux 起動。shell-command は単一文字列で渡す。クォートは printf '%q ' で機械生成。
    local inner
    inner=$(printf '%q ' claude "${final_args[@]}")
    tmux new-session -d -s "$sess" -c "$abs_path" "$inner"

    # 7. 結果報告（AI はこれをそのまま報告素材にする）。
    local branch dirty_count dirty args_report
    branch=$(git -C "$abs_path" branch --show-current 2>/dev/null || true)
    [ -n "$branch" ] || branch="(detached)"
    dirty_count=$(git -C "$abs_path" status --porcelain 2>/dev/null | grep -c '^' || true)
    if [ "${dirty_count:-0}" -eq 0 ]; then
        dirty="clean"
    else
        dirty="$dirty_count files"
    fi
    if [ "${#final_args[@]}" -eq 0 ]; then
        args_report="(無し)"
    else
        args_report=$(printf '%q ' "${final_args[@]}")
        args_report=${args_report% }
    fi

    printf 'SESSION: %s\n' "$sess"
    printf 'PROJECT: %s\n' "$relpath"
    printf 'PATH: %s\n' "$abs_path"
    printf 'BRANCH: %s\n' "$branch"
    printf 'DIRTY: %s\n' "$dirty"
    printf 'CLAUDE_ARGS: %s\n' "$args_report"
    printf 'ATTACH: tmux attach -t %s\n' "$sess"
}

main() {
    local sub="${1:-}"
    case "$sub" in
    list)
        cmd_list
        ;;
    resolve)
        shift
        [ "$#" -ge 1 ] || {
            printf 'usage: launch.sh resolve <query>\n' >&2
            return 1
        }
        cmd_resolve "$1"
        ;;
    launch)
        shift
        [ "$#" -ge 1 ] || {
            printf 'usage: launch.sh launch <query> [claude引数...]\n' >&2
            return 1
        }
        cmd_launch "$@"
        ;;
    *)
        printf 'usage: launch.sh {list|resolve <query>|launch <query> [claude引数...]}\n' >&2
        return 1
        ;;
    esac
}

# source ガード: 直接実行時のみ main を呼ぶ。テストは source して純関数だけを検証する。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
