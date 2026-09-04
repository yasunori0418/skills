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
#     新しい workspace を作り、その root pane で claude を起動する。herdr CLI へは
#     常に --session（herdr_session_name）を明示し、起動元 pane と同じセッションへ
#     作る（env 依存の暗黙解決に任せると既定セッションへ流れ込む）
#   - tmux:  それ以外。detached な tmux セッションとして起動する
# PROJECT_SESSION_BACKEND で明示的に上書きもできる。
#
# herdr backend で作る単位（topology）は `launch --session <query>` フラグで切り替える
# （detect_topology。フラグ未指定なら PROJECT_SESSION_TOPOLOGY へフォールバック）:
#   - workspace（既定）: 起動元 pane と同じ session に workspace を足す
#   - session: プロジェクト専用の herdr session を detached で立て、その中で起動する。
#     子 pane には新 session のソケットが注入されるため、その session 内で
#     job-graph / lane-ops が完結する（親子が同じソケットを見る）
# フラグは query より前にのみ置ける。query 以降は claude への passthrough なので、
# そこを走査すると claude 側の同名フラグと衝突しうる。
#
# query は既定で ghq list への部分一致キーだが、`/...` `~...` `./...` `../...` の形なら
# ghq 解決を飛ばしてそのディレクトリを直接使う（ghq 管理外のリポジトリ用。is_path_query）。
# 裸の名前は ghq キーのままにする（ghq の repo 名とカレント配下のディレクトリ名が
# 衝突したとき、意図せずローカルを掴まないため）。
#
# 起動する claude は親セッションの子プロセスではなく独立したセッションなので、
# claude が子シェルへ注入する親セッション固有のマーカーは env -u で断ち切る
# （inherited_session_vars。放置すると transcript 保存が切られる等の不整合が起きる）。
# 断ち切る対象は claude の起動コマンドだけではない。multiplexer の server（herdr /
# tmux）は自分の environ を配下の**全 pane の shell へ継承させる**ので、server を
# 起こす呼び出しも env -u 越しにする（env_unset_prefix）。そうしないと root pane の
# claude は無事でも、ユーザーが後から開いた tab/pane で claude を立てたときに
# transcript 保存が切られる。
# 逆に pane の環境を決めるのは server の environ だけで、CLI クライアント側の環境は
# 伝播しない（実測で確認済み）。既存 server へ繋ぐだけの workspace create /
# pane run には env -u を付けない。
#
# 純関数（sanitize/resolve_matches/session_base_name/next_session_name/
# inject_remote_control/detect_backend/extract_topology_flag/detect_topology/
# herdr_session_name/backend_attach_hint/backend_required_tools/is_path_query/
# expand_path_query/inherited_session_vars/env_unset_prefix/subtract_ids）は
# 外部コマンド（ghq/tmux/herdr/claude）を
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

# extract_topology_flag <args...>
# 先頭に並んだ topology フラグを読み取り、NUL 区切りで
# 「topology」「残りの引数...」の順に出力する。
#   --session  -> session（プロジェクト専用 herdr session を立てる）
# フラグは **query より前**（サブコマンド直後）にのみ置ける。query 以降は claude への
# passthrough なので、そこを走査すると claude 側の同名フラグと衝突しうる。
# 空文字を返したら「フラグ指定なし」で、呼び出し側が環境変数へフォールバックする。
# 外部コマンドを呼ばないので単体テストできる。
extract_topology_flag() {
    local topology=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --session)
            topology="session"
            shift
            ;;
        *)
            break
            ;;
        esac
    done
    printf '%s\0' "$topology" "$@"
}

# detect_topology [override]
# herdr backend で作る単位（workspace | session）を決める。
#   override（--session フラグ or PROJECT_SESSION_TOPOLOGY）が非空ならそれ、
#   未指定なら workspace。
# workspace: 起動元 pane と同じ session に workspace を足す（既定）。
# session:   プロジェクト専用の herdr session を detached で立て、その中で起動する。
#            その session 内で job-graph / lane-ops を完結させたいときに使う
#            （子 pane には新 session のソケットが注入されるため、session 内で
#            親子が同じソケットを見る）。
# tmux backend では無視される（tmux は常に detached セッション 1 つ）。
# 外部コマンドを呼ばないので単体テストできる。
detect_topology() {
    local override="${1:-}"
    printf '%s' "${override:-workspace}"
}

# herdr_session_name [env_value]
# herdr CLI へ渡す --session の値を決める。
#   env_value（HERDR_SESSION）が非空ならそれ、空・未設定なら default。
# herdr CLI は HERDR_SESSION / HERDR_SOCKET_PATH が生きていれば現在のセッションへ
# 解決するが、env が失われると既定セッションへ落ちる。project-session は起動した
# pane と同じセッションに workspace を作るのが正しいので、CLI 呼び出しでは常に
# --session を明示してこの暗黙解決に依存しない。`herdr --session ""` は
# `session name cannot be empty` で拒否されるため、空は default へ畳む。
# 外部コマンドを呼ばないので単体テストできる。
herdr_session_name() {
    local env_value="${1:-}"
    printf '%s' "${env_value:-default}"
}

# inherited_session_vars
# 新セッションへ引き継いではいけない親セッション固有の環境変数を 1 行 1 件で返す。
#
# claude は Bash ツールで子シェルを spawn するとき、自分の身元を示すマーカーを
# その子シェルへ注入する（claude プロセス本体の environ には無く、子シェルにだけ現れる）。
# 本スキルはその子シェルから**独立した長寿命の claude セッション**を起動するため、
# 放置すると新セッションが親の子プロセスだと誤認し、
#   - transcript 保存が切られる（CLAUDE_CODE_CHILD_SESSION）
#   - 親宛のメッセージ経路を掴む（CLAUDE_CODE_MESSAGING_*）
#   - 親のセッション ID を名乗る（CLAUDE_CODE_*SESSION_ID）
# といった不整合が起きる。起動時に env -u で明示的に断ち切る。
#
# GIT_EDITOR は prefix が付かないが同じ経路で注入される。claude 自身が git commit を
# 実行したときエディタが開いてハングしないよう `true`（no-op）が入るもので、これを
# 引き継ぐと人が使う shell でも `git commit` がエディタを開かず空メッセージで進む。
# 落とすと git は core.editor / VISUAL / EDITOR へフォールバックし、shell 由来の
# 設定が効く。
#
# ユーザー設定由来のもの（CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY 等）や実行ファイル解決に
# 使う CLAUDE_CODE_EXECPATH は引き継ぐので、ここには挙げない。
# 外部コマンドを呼ばないので単体テストできる。
inherited_session_vars() {
    printf '%s\n' \
        CLAUDE_CODE_CHILD_SESSION \
        CLAUDE_CODE_SESSION_ID \
        CLAUDE_CODE_BRIDGE_SESSION_ID \
        CLAUDE_CODE_MESSAGING_SOCKET \
        CLAUDE_CODE_MESSAGING_TOKEN \
        CLAUDE_CODE_ENTRYPOINT \
        GIT_EDITOR
}

# env_unset_prefix
# inherited_session_vars を `env -u <var> ...` の引数列に展開して 1 行 1 件で返す。
# コマンドの先頭へ置くと、その子孫プロセス全体から親セッションのマーカーが消える。
# 外部コマンドを呼ばないので単体テストできる。
env_unset_prefix() {
    local var
    printf '%s\n' env
    while IFS= read -r var; do
        [ -n "$var" ] || continue
        printf '%s\n%s\n' -u "$var"
    done < <(inherited_session_vars)
}

# subtract_ids <keep-id>
# stdin の ID 一覧（1 行 1 件）から keep-id を除いたものを返す。
# 新しい herdr session を立てたとき、server が起動時に自動生成する既定 workspace
# （cwd=$HOME・ラベル `~`）を特定するのに使う。ID は決め打ちせず「起動直後に在った
# もののうち、自分が作った workspace ではないもの」として差分で求める。
# 外部コマンドを呼ばないので単体テストできる。
subtract_ids() {
    local keep="$1" id
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        [ "$id" = "$keep" ] && continue
        printf '%s\n' "$id"
    done
}

# sanitize <name>
# セッション名・ラベル向けに [^A-Za-z0-9_-]+ を - に置換し前後の - を除去する。
# 空になったら session を返す。
sanitize() {
    local name="$1" out
    out=$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9_-]+/-/g; s/^-+//; s/-+$//')
    printf '%s' "${out:-session}"
}

# is_path_query <query>
# query を「ghq 解決を飛ばす直接パス指定」とみなすなら 0、ghq への部分一致キーなら 1。
# 直接パスとみなすのは次のいずれか:
#   /...   絶対パス
#   ~...   ホーム相対（~ 単体・~/... の形）
#   ./ ../ 明示的な相対パス
# `dotfiles` のような裸の名前は ghq キーのままにする（ghq 管理下の repo 名と
# カレント配下のディレクトリ名が衝突したとき、意図せずローカルを掴まないため）。
# 外部コマンドを呼ばないので単体テストできる。
is_path_query() {
    # SC2088: ここでの ~ は「展開させたい値」ではなく、query 文字列に現れる
    # リテラルの ~ とのパターンマッチ。展開は expand_path_query の責務。
    # shellcheck disable=SC2088
    case "${1:-}" in
    /* | '~' | '~/'* | ./* | ../*) return 0 ;;
    *) return 1 ;;
    esac
}

# expand_path_query <query>
# 直接パス指定の query を絶対パスへ正規化する（先頭 ~ を $HOME へ展開する）。
# ディレクトリの存在確認・シンボリックリンク解決は呼び出し側の責務。
# 外部コマンドを呼ばないので単体テストできる。
expand_path_query() {
    local query="${1:-}" home="${2:-$HOME}"
    # SC2088: query 内のリテラル ~ を検出・除去するための引用であって、
    # ここで shell に展開させたいわけではない（展開先は $home を明示的に使う）。
    # shellcheck disable=SC2088
    case "$query" in
    '~') printf '%s' "$home" ;;
    '~/'*) printf '%s/%s' "$home" "${query#'~/'}" ;;
    *) printf '%s' "$query" ;;
    esac
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

# backend_required_tools <backend> [needs_ghq]
# その backend で PATH に必要なコマンドを 1 行 1 件で返す。
# needs_ghq が 0（＝直接パス指定で ghq 解決を使わない）なら ghq を要求しない。
# 外部コマンドを呼ばないので単体テストできる。
backend_required_tools() {
    local backend="$1" needs_ghq="${2:-1}"
    case "$backend" in
    herdr) printf 'herdr\n' ;;
    *) printf 'tmux\n' ;;
    esac
    [ "$needs_ghq" = "0" ] || printf 'ghq\n'
    printf 'claude\n'
}

# backend_existing_names <backend> [topology]
# 名前衝突の判定対象を 1 行 1 件で返す。取得できない場合（サーバ未起動など）は
# 空扱いにする。衝突を見る先は作る単位によって変わる:
#   tmux                      -> 既存セッション名
#   herdr + topology=workspace -> 現在 session の workspace ラベル
#   herdr + topology=session   -> herdr の session 名（停止中も含む。同名 session を
#                                 作ると既存の状態に相乗りしてしまうため）
backend_existing_names() {
    local backend="$1" topology="${2:-workspace}"
    # 一覧取得でも server が暗黙起動されうる（tmux list-sessions / herdr の session
    # 解決）。そこで起きた server の environ は以後その session の全 pane へ継承されるので、
    # 読み取り系も env -u 越しに呼ぶ。
    local -a env_args=()
    mapfile -t env_args < <(env_unset_prefix)
    case "$backend" in
    herdr)
        if [ "$topology" = "session" ]; then
            "${env_args[@]}" herdr session list --json 2>/dev/null |
                jq -r '.sessions[]?.name // empty' 2>/dev/null || true
        else
            "${env_args[@]}" herdr --session "$(herdr_session_name "${HERDR_SESSION:-}")" \
                workspace list 2>/dev/null |
                jq -r '.result.workspaces[]?.label // empty' 2>/dev/null || true
        fi
        ;;
    *)
        "${env_args[@]}" tmux list-sessions -F '#{session_name}' 2>/dev/null || true
        ;;
    esac
}

# herdr_start_session <sess> [timeout_sec]
# 名前付き herdr session を detached の headless server として起動し、socket API が
# 応答するまで待つ。socket API 自体には server を起こす力が無く
# （`server_not_running` を返す）、`herdr session attach` は TUI に入る対話コマンドの
# ため、detached 起動は `herdr --session <name> server` を background に置く形をとる。
#
# server は自分の environ をその session の**全 pane の shell へ継承させる**ため、
# 親セッションのマーカーを持ったまま起動すると、後から開いた tab/pane で claude を
# 立てたときに transcript 保存が切られる。起動を env -u 越しにして根元で断ち切る。
herdr_start_session() {
    local sess="$1" timeout_sec="${2:-30}" waited=0
    local -a env_args=()
    mapfile -t env_args < <(env_unset_prefix)
    nohup "${env_args[@]}" herdr --session "$sess" server >/dev/null 2>&1 &
    disown 2>/dev/null || true
    while ! "${env_args[@]}" herdr --session "$sess" workspace list >/dev/null 2>&1; do
        if [ "$waited" -ge "$timeout_sec" ]; then
            printf 'error: herdr session %s が %s 秒以内に起動しません\n' \
                "$sess" "$timeout_sec" >&2
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# backend_launch <backend> <sess> <abs_path> <inner> [topology]
# claude を detached に起動する。inner は shell へ渡す単一コマンド文字列。
backend_launch() {
    local backend="$1" sess="$2" abs_path="$3" inner="$4" topology="${5:-workspace}"
    case "$backend" in
    herdr)
        local resp pane ws hsess started_session=0
        if [ "$topology" = "session" ]; then
            # プロジェクト専用の herdr session を detached で立て、その中に
            # workspace を作って起動する。子 pane には新 session のソケットが
            # 注入されるので、その session 内で job-graph / lane-ops が完結する。
            herdr_start_session "$sess" || return 1
            hsess="$sess"
            started_session=1
        else
            # プロジェクト用の新しい workspace を作り、その root pane で claude を
            # 起動する。workspace はリポジトリ単位の長寿命コンテナなので、別の
            # プロジェクトを開くときは現在の workspace に tab を足すのではなく
            # workspace を増やす。
            hsess=$(herdr_session_name "${HERDR_SESSION:-}")
        fi
        resp=$(herdr --session "$hsess" workspace create \
            --cwd "$abs_path" --label "$sess" --no-focus) || return 1
        pane=$(printf '%s' "$resp" | jq -r '.result.root_pane.pane_id')
        if [ -z "$pane" ] || [ "$pane" = "null" ]; then
            printf 'error: herdr workspace の root pane を取得できません\n' >&2
            return 1
        fi
        # pane の環境は server の environ が決めるので、この CLI 呼び出し自体を
        # env -u 越しにしても効果は無い（実測で確認済み。断ち切る先は server 起動側）。
        herdr --session "$hsess" pane run "$pane" "$inner"
        # 自分で立てた session に限り、server が起動時に作る既定 workspace
        # （cwd=$HOME・ラベル `~`）を畳む。プロジェクト専用の session を立てる
        # topology なので、attach したときプロジェクトと無関係なホーム直下の
        # workspace が同居しているのは意図に反する。閉じるのは claude を起こした
        # 後（workspace が 0 個になると server が終了しうるため）。
        # 既存 session へ相乗りする topology=workspace では、ユーザーが使っている
        # workspace を畳んでしまうので何もしない。
        if [ "$started_session" = "1" ]; then
            ws=$(printf '%s' "$resp" | jq -r '.result.workspace.workspace_id')
            if [ -n "$ws" ] && [ "$ws" != "null" ]; then
                local stale
                while IFS= read -r stale; do
                    [ -n "$stale" ] || continue
                    herdr --session "$hsess" workspace close "$stale" >/dev/null 2>&1 || true
                done < <(herdr --session "$hsess" workspace list 2>/dev/null |
                    jq -r '.result.workspaces[]?.workspace_id // empty' 2>/dev/null |
                    subtract_ids "$ws")
            fi
        fi
        ;;
    *)
        # tmux は server 未起動なら new-session が暗黙起動し、その environ が
        # 以後の全 pane へ継承される。herdr の server 起動と同じ理由で断ち切る。
        local -a env_args=()
        mapfile -t env_args < <(env_unset_prefix)
        "${env_args[@]}" tmux new-session -d -s "$sess" -c "$abs_path" "$inner"
        ;;
    esac
}

# backend_attach_hint <backend> <sess> [topology]
# 起動したセッションへ合流する方法を 1 行で返す。detached で立てた herdr session は
# ユーザーが attach するまで画面に現れないので、コマンドをそのまま案内する
# （現在の TUI は奪わない）。外部コマンドを呼ばないので単体テストできる。
backend_attach_hint() {
    local backend="$1" sess="$2" topology="${3:-workspace}"
    case "$backend" in
    herdr)
        if [ "$topology" = "session" ]; then
            printf 'herdr session attach %s' "$sess"
        else
            printf 'herdr（workspace ラベル: %s）に切り替える' "$sess"
        fi
        ;;
    *) printf 'tmux attach -t %s' "$sess" ;;
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
# 直接パス指定（/... ~... ./... ../...）は ghq を引かず、存在すれば絶対パスを 1 行返す
# （launch 側と判定を揃える。存在しなければ not found 扱いで exit 3）。
cmd_resolve() {
    local query="$1" list matches count
    if is_path_query "$query"; then
        local abs_path
        abs_path=$(expand_path_query "$query")
        if [ -d "$abs_path" ]; then
            (cd "$abs_path" && pwd)
            return 0
        fi
        printf 'error: ディレクトリが存在しません: %s\n' "$abs_path" >&2
        return 3
    fi
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

# cmd_launch [--session] <query> [claude引数...] — 本体。
cmd_launch() {
    # 0. topology フラグを query より前から抜き取る（query 以降は claude への
    #    passthrough なので走査しない）。フラグ未指定なら環境変数へフォールバックする。
    local -a rest=()
    local flag_topology=""
    mapfile -d '' rest < <(extract_topology_flag "$@")
    flag_topology="${rest[0]}"
    rest=("${rest[@]:1}")
    if [ "${#rest[@]}" -eq 0 ]; then
        printf 'usage: launch.sh launch [--session] <query> [claude引数...]\n' >&2
        return 1
    fi

    local query="${rest[0]}"
    local -a claude_args=("${rest[@]:1}")

    # 1. backend / topology 判定 + 必須コマンドの存在確認（欠落は名指しでエラー）。
    #    直接パス指定のときは ghq 解決を使わないので ghq を要求しない。
    local backend topology needs_ghq=1
    backend=$(detect_backend "${HERDR_ENV:-}" "${PROJECT_SESSION_BACKEND:-}")
    topology=$(detect_topology "${flag_topology:-${PROJECT_SESSION_TOPOLOGY:-}}")
    is_path_query "$query" && needs_ghq=0
    local tool missing=0
    while IFS= read -r tool; do
        [ -n "$tool" ] || continue
        if ! command -v "$tool" >/dev/null 2>&1; then
            # shellcheck disable=SC2016
            printf 'error: `%s` が見つかりません（PATH に必要 / backend=%s）\n' \
                "$tool" "$backend" >&2
            missing=1
        fi
    done < <(backend_required_tools "$backend" "$needs_ghq")
    [ "$missing" -eq 0 ] || return 1

    # 2-3. パス指定なら ghq 解決を飛ばし、そのディレクトリを直接使う。
    #      それ以外は resolve と同じ解決（一意でなければ同じ出力・exit code で中断）。
    local list relpath abs_path base
    if is_path_query "$query"; then
        abs_path=$(expand_path_query "$query")
        if [ ! -d "$abs_path" ]; then
            printf 'error: ディレクトリが存在しません: %s\n' "$abs_path" >&2
            return 1
        fi
        # 表示用の relpath は絶対パスそのもの。セッション名は basename から作る
        # （ghq の owner/repo 重複規則は効かないので basename 一択）。
        abs_path=$(cd "$abs_path" && pwd)
        relpath="$abs_path"
        base=$(sanitize "${abs_path##*/}")
    else
        local matches count
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

        abs_path="$(ghq root)/$relpath"
        if [ ! -d "$abs_path" ]; then
            printf 'error: ディレクトリが存在しません: %s\n' "$abs_path" >&2
            return 1
        fi
        base=$(printf '%s\n' "$list" | session_base_name "$relpath")
    fi

    # 4. セッション名決定（既存一覧は backend から。取得不能時は空扱い）。
    local existing sess
    existing=$(backend_existing_names "$backend" "$topology")
    sess=$(printf '%s\n' "$existing" | next_session_name "$base")

    # 5. inject_remote_control で claude 引数を確定（NUL 区切りで受け取る）。
    local -a final_args=()
    if [ "${#claude_args[@]}" -gt 0 ]; then
        mapfile -d '' final_args < <(inject_remote_control "$sess" "${claude_args[@]}")
    fi

    # 6. 起動。shell-command は単一文字列で渡す。クォートは printf '%q ' で機械生成。
    #    親セッション固有のマーカーは env -u で断ち切る（inherited_session_vars 参照）。
    local inner
    local -a env_args=()
    mapfile -t env_args < <(env_unset_prefix)
    inner=$(printf '%q ' "${env_args[@]}" claude "${final_args[@]}")
    backend_launch "$backend" "$sess" "$abs_path" "$inner" "$topology" || return 1

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
    if [ "$backend" = herdr ]; then
        printf 'TOPOLOGY: %s\n' "$topology"
    fi
    printf 'PROJECT: %s\n' "$relpath"
    printf 'PATH: %s\n' "$abs_path"
    printf 'BRANCH: %s\n' "$branch"
    printf 'DIRTY: %s\n' "$dirty"
    printf 'CLAUDE_ARGS: %s\n' "$args_report"
    printf 'ATTACH: %s\n' "$(backend_attach_hint "$backend" "$sess" "$topology")"
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
            printf 'usage: launch.sh launch [--session] <query> [claude引数...]\n' >&2
            return 1
        }
        cmd_launch "$@"
        ;;
    *)
        printf 'usage: launch.sh {list|resolve <query>|launch [--session] <query> [claude引数...]}\n' >&2
        return 1
        ;;
    esac
}

# source ガード: 直接実行時のみ main を呼ぶ。テストは source して純関数だけを検証する。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
