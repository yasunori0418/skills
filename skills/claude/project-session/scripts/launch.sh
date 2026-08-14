#!/usr/bin/env bash
# launch.sh — /project-session の決定論バックエンド。
#
# ghq 管理下のプロジェクトを 1 つ選び、そのディレクトリで（ブランチを変えず・
# worktree も作らず）claude を detached セッションとして起動する。
# ghq 照合・セッション名決定・セッション起動という機械的に確定できる処理を
# ここへ集約し、SKILL.md 側でロジックを二重管理しない。
#
# マルチプレクサ backend は実行環境から自動判定する（detect_backend）:
#   - herdr: HERDR_ENV=1（herdr 管理下の pane から起動された）。プロジェクト用の
#     新しい workspace を作り、その root pane で claude を起動する
#   - tmux:  それ以外。detached な tmux セッションとして起動する
# PROJECT_SESSION_BACKEND で明示的に上書きもできる。
#
# 純関数（sanitize/resolve_matches/session_base_name/next_session_name/
# inject_remote_control/detect_backend）は外部コマンド（ghq/tmux/herdr/claude）を
# 呼ばず、入力は引数と stdin のみ。これにより CI sandbox（jq/git のみ、
# ghq/tmux/herdr/claude 無し）で
# `source launch.sh` してテストできる。impure な処理は main とサブコマンドに閉じ、
# 末尾の source ガードで「直接実行時のみ main」を担保する。
set -euo pipefail

# detect_backend [env_value] [override]
# 使用するマルチプレクサ backend 名（herdr | tmux）を決める。
#   override（PROJECT_SESSION_BACKEND）が非空ならそれを最優先で採用する。
#   env_value（HERDR_ENV）が 1 なら herdr、それ以外は tmux。
# 外部コマンドを呼ばないので単体テストできる。
detect_backend() {
    local env_value="${1:-}" override="${2:-}"
    if [ -n "$override" ]; then
        printf '%s' "$override"
        return 0
    fi
    if [ "$env_value" = "1" ]; then
        printf 'herdr'
    else
        printf 'tmux'
    fi
}

# sanitize <name>
# セッション名・ラベル向けに [^A-Za-z0-9_-]+ を - に置換し前後の - を除去する。
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

# ---- impure: backend 別の処理 ---------------------------------------------

# backend_required_tools <backend>
# その backend で PATH に必要なコマンドを 1 行 1 件で返す。
backend_required_tools() {
    case "$1" in
    herdr) printf 'herdr\nghq\nclaude\n' ;;
    *) printf 'tmux\nghq\nclaude\n' ;;
    esac
}

# backend_existing_names <backend>
# 既存セッション名（tmux）/ workspace ラベル（herdr）を 1 行 1 件で返す。
# 取得できない場合（サーバ未起動など）は空扱いにする。
backend_existing_names() {
    case "$1" in
    herdr)
        herdr workspace list 2>/dev/null |
            jq -r '.result.workspaces[]?.label // empty' 2>/dev/null || true
        ;;
    *)
        tmux list-sessions -F '#{session_name}' 2>/dev/null || true
        ;;
    esac
}

# backend_launch <backend> <sess> <abs_path> <inner>
# claude を detached に起動する。inner は shell へ渡す単一コマンド文字列。
backend_launch() {
    local backend="$1" sess="$2" abs_path="$3" inner="$4"
    case "$backend" in
    herdr)
        # プロジェクト用の新しい workspace を作り、その root pane で claude を
        # 起動する。workspace はリポジトリ単位の長寿命コンテナなので、別の
        # プロジェクトを開くときは現在の workspace に tab を足すのではなく
        # workspace を増やす。
        local resp pane
        resp=$(herdr workspace create \
            --cwd "$abs_path" --label "$sess" --no-focus) || return 1
        pane=$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id')
        if [ -z "$pane" ] || [ "$pane" = "null" ]; then
            printf 'error: herdr workspace の root pane を取得できません\n' >&2
            return 1
        fi
        herdr pane run "$pane" "$inner"
        ;;
    *)
        tmux new-session -d -s "$sess" -c "$abs_path" "$inner"
        ;;
    esac
}

# backend_attach_hint <backend> <sess>
# 起動したセッションへ合流する方法を 1 行で返す。
backend_attach_hint() {
    case "$1" in
    herdr) printf 'herdr（workspace ラベル: %s）に切り替える' "$2" ;;
    *) printf 'tmux attach -t %s' "$2" ;;
    esac
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

    # 1. backend 判定 + 必須コマンドの存在確認（欠落は名指しでエラー）。
    local backend
    backend=$(detect_backend "${HERDR_ENV:-}" "${PROJECT_SESSION_BACKEND:-}")
    local tool missing=0
    while IFS= read -r tool; do
        [ -n "$tool" ] || continue
        if ! command -v "$tool" >/dev/null 2>&1; then
            # shellcheck disable=SC2016
            printf 'error: `%s` が見つかりません（PATH に必要 / backend=%s）\n' \
                "$tool" "$backend" >&2
            missing=1
        fi
    done < <(backend_required_tools "$backend")
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

    # 4. セッション名決定（既存一覧は backend から。取得不能時は空扱い）。
    local base existing sess
    base=$(printf '%s\n' "$list" | session_base_name "$relpath")
    existing=$(backend_existing_names "$backend")
    sess=$(printf '%s\n' "$existing" | next_session_name "$base")

    # 5. inject_remote_control で claude 引数を確定（NUL 区切りで受け取る）。
    local -a final_args=()
    if [ "${#claude_args[@]}" -gt 0 ]; then
        mapfile -d '' final_args < <(inject_remote_control "$sess" "${claude_args[@]}")
    fi

    # 6. 起動。shell-command は単一文字列で渡す。クォートは printf '%q ' で機械生成。
    local inner
    inner=$(printf '%q ' claude "${final_args[@]}")
    backend_launch "$backend" "$sess" "$abs_path" "$inner" || return 1

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
    printf 'BACKEND: %s\n' "$backend"
    printf 'PROJECT: %s\n' "$relpath"
    printf 'PATH: %s\n' "$abs_path"
    printf 'BRANCH: %s\n' "$branch"
    printf 'DIRTY: %s\n' "$dirty"
    printf 'CLAUDE_ARGS: %s\n' "$args_report"
    printf 'ATTACH: %s\n' "$(backend_attach_hint "$backend" "$sess")"
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
