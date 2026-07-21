#!/usr/bin/env bash
# gh-fetch.sh — 非対話セッション向けの git fetch / pull。SSH 優先・gh フォールバック。
# gh-push の取り込み（incoming）版。
#
# 経路の選び方（決定論）:
#   - remote が SSH URL で、`ssh -o BatchMode=yes` による非対話 SSH 認証が実際に
#     通るなら、素の git fetch を SSH で実行する。判定は agent の鍵有無ではなく、
#     BatchMode=yes での ls-remote が成功するかで直接テストする（agent の鍵・
#     パスフレーズ無しのディスク鍵・macOS キーチェーン鍵を区別せず「非対話で
#     通るか」を確かめられる。BatchMode=yes なのでパスフレーズ入力待ちには入らない）。
#   - SSH 認証テストが失敗した場合、または remote が非SSH（HTTPS）の場合は、
#     通信認証を gh の credential helper に肩代わりさせて HTTPS で実行する。
#     remote が SSH URL でも URL を HTTPS に変換して取得元に使うので origin は変えない。
#
# 使い方:
#   gh-fetch.sh preflight [branch]                 取り込み対象を収集して提示用に出力（何もしない）
#   gh-fetch.sh fetch     [branch]                 fetch のみ（remote-tracking ref を更新。作業ツリーは不変）
#   gh-fetch.sh pull      [branch] [strategy]      fetch して作業ブランチへ統合する
#       strategy: --ff-only（既定 / 安全）| --merge | --rebase
#
# branch 省略時は現在のブランチ。fetch は常に安全（作業ツリーを触らない）。
# pull は作業ツリーを書き換えるため、未コミット変更があると実行しない。
set -euo pipefail

# 既存の credential.helper 一覧を空でリセットしてから gh ヘルパーだけを使う。
# cache / oauth など他ヘルパーの介入・キャッシュ汚染を避ける。
CRED_RESET=(-c credential.helper= -c credential.helper='!gh auth git-credential')

# SSH 経路で使う共通オプション（判定 ls-remote と fetch 本体の両方でこの値を使う）。
#   BatchMode=yes            … パスフレーズ/パスワードのプロンプトに落ちず即失敗させる（非対話の担保）。
#   ConnectTimeout=5         … 接続段階のハングを 5 秒で打ち切る。
#   StrictHostKeyChecking=accept-new … known_hosts 未登録でも確認プロンプトに落ちず自動受理して進む
#                                       （CI 等 known_hosts が空の環境でも SSH 判定が通る）。
SSH_CMD='ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new'

# 判定 ls-remote 限定の全体タイムアウト（fetch 本体はデータ転送があるので包まない）。
# timeout / gtimeout があればそれで包み、無ければ SSH の ConnectTimeout に委ねる。
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout 10)
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(gtimeout 10)
else
    TIMEOUT_CMD=()
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- 非対話 SSH 認証テスト結果のメモ化 ---------------------------------------
# SSH 認証が「非対話で通るか」は host 単位で決まり、リポジトリ/ブランチに依存しない。
# セッション内で一度成功したら、以降は実 ls-remote を打たずにその結果を再利用する
# （preflight → fetch/pull、複数回取り込みの各回で往復コストを消せる）。gh-push と同一方針。
#
#   キー粒度 : host 単位（同一 host の別リポジトリでも再利用）
#   保存先   : /tmp/gh-ssh-authcache.<session_id>.<host>（セッション毎に独立。gh-push と共有）
#   TTL      : 30 分（ssh-agent ロック・鍵失効・キーチェーンロック等の状態変化に追従）
#   対象     : 成功（ssh_ok=1）のみ。失敗は記録せず毎回テストする。
# $CLAUDE_SESSION_ID が無ければメモ化しない（＝従来どおり毎回テスト）。
SSH_AUTH_TTL=1800   # 秒（30 分）

ssh_cache_file() {
    [ -n "${CLAUDE_SESSION_ID:-}" ] || return 1
    local safe_host="${1//[^A-Za-z0-9._-]/_}"
    printf '/tmp/gh-ssh-authcache.%s.%s\n' "$CLAUDE_SESSION_ID" "$safe_host"
}

# TTL 内の成功キャッシュがあれば 0 を返す（SSH 認証済みとみなす）。
ssh_cache_valid() {
    local f; f="$(ssh_cache_file "$1")" || return 1
    [ -f "$f" ] || return 1
    local saved now
    saved="$(cat "$f" 2>/dev/null)" || return 1
    case "$saved" in ''|*[!0-9]*) return 1 ;; esac   # 数値でなければ無効
    now="$(date +%s)"
    [ $((now - saved)) -lt "$SSH_AUTH_TTL" ]
}

# SSH 認証成功をエポック秒で記録する（stat の OS 差異を避け自前で時刻を持つ）。
ssh_cache_store() {
    local f; f="$(ssh_cache_file "$1")" || return 0
    date +%s >"$f" 2>/dev/null || true
}

# remote URL → "https_url<TAB>host" に正規化。
to_https() {
    local url="$1" host path rest
    case "$url" in
        https://*)
            rest="${url#https://}"
            rest="${rest#*@}"                 # 埋め込み認証情報があれば落とす
            host="${rest%%/*}"
            printf 'https://%s\t%s\n' "$rest" "$host"
            ;;
        ssh://*)
            rest="${url#ssh://}"
            rest="${rest#*@}"                 # user@ を落とす
            host="${rest%%/*}"
            host="${host%%:*}"                # :port を落とす
            path="${rest#*/}"
            printf 'https://%s/%s\t%s\n' "$host" "$path" "$host"
            ;;
        *@*:*)
            host="${url%%:*}"; host="${host#*@}"   # scp 形式 git@host:owner/repo.git
            path="${url#*:}"
            printf 'https://%s/%s\t%s\n' "$host" "$path" "$host"
            ;;
        *)
            die "未対応の remote URL です: $url"
            ;;
    esac
}

# remote URL が SSH 形式（ssh:// もしくは scp 形式 git@host:path）か。
is_ssh_url() {
    case "$1" in
        ssh://*) return 0 ;;
        https://*) return 1 ;;
        *@*:*)   return 0 ;;
        *)       return 1 ;;
    esac
}

# SSH で全 head を非対話で引く。exit 0 なら「非対話 SSH 認証が通る」ことの
# 直接の証拠。agent の鍵・パスフレーズ無しのディスク鍵・キーチェーン鍵を区別せず
# 判定できる。出力（全 refs/heads）を stdout に返し、$branch の tip 抽出は呼び出し側で行う
# （認証成功だがブランチ未作成なら tip は空になるが、それは exit 0 の「認証OK」と両立する）。
# パイプで awk に食わせると認証失敗の exit code が握り潰されるため、ここでは
# git の生の exit code をそのまま返す。
ssh_ls_remote() {
    "${TIMEOUT_CMD[@]}" env GIT_SSH_COMMAND="$SSH_CMD" \
        git ls-remote "$url" "refs/heads/*" 2>/dev/null
}

cmd="${1:-preflight}"; shift || true
strategy="--ff-only"; branch=""
for a in "$@"; do
    case "$a" in
        --ff-only|--merge|--rebase) strategy="$a" ;;
        -*) die "不明なオプション: $a" ;;
        *)  branch="$a" ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "git リポジトリ内ではありません"

[ -n "$branch" ] || branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" != "HEAD" ] || die "detached HEAD です。取り込み先ブランチ名を引数で指定してください"

remote="$(git config "branch.$branch.remote" 2>/dev/null || echo origin)"
url="$(git remote get-url "$remote" 2>/dev/null || true)"
[ -n "$url" ] || die "remote '$remote' が見つかりません"

IFS=$'\t' read -r https host < <(to_https "$url")

# fetch 経路の決定（決定論、gh-push と同一方針）:
#   remote が SSH URL なら、まず BatchMode=yes での ls-remote を打って
#   「非対話 SSH 認証が通るか」を実テストする。通ればその経路を採り、出力を
#   リモート tip 取得にも流用する（往復増加ゼロ）。テストが失敗、または remote が
#   非SSH（HTTPS）なら gh(HTTPS) 経路へ。判定は agent の鍵有無に依存しない
#   （パスフレーズ無しのディスク鍵・macOS キーチェーン鍵でも非対話で通れば SSH を選ぶ）。
ssh_ok=0
ssh_cached=0        # キャッシュ由来で ssh_ok を立てたか（tip は別途取得が要る）
gh_route_reason=""
remote_tip=""
if is_ssh_url "$url"; then
    if ssh_cache_valid "$host"; then
        # セッション内で SSH 認証成功済み。実 ls-remote を省き経路を確定する。
        # このパスでは tip を得ていないので、後段の tip 取得で別途引く。
        ssh_ok=1
        ssh_cached=1
    else
        # 1 回の ls-remote で「認証が通るか（exit code）」と「$branch の tip」を同時に得る。
        ssh_heads=""
        if ssh_heads="$(ssh_ls_remote)"; then
            ssh_ok=1
            ssh_cache_store "$host"
            remote_tip="$(printf '%s\n' "$ssh_heads" | awk -v r="refs/heads/$branch" '$2==r{print $1; exit}')"
        else
            gh_route_reason="非対話 SSH 認証テストに失敗"
        fi
    fi
else
    gh_route_reason="remote が非SSH（HTTPS）"
fi

gh_present=0
if command -v gh >/dev/null 2>&1; then gh_present=1; fi
gh_auth=0
if [ "$gh_present" = 1 ] && gh auth status --hostname "$host" >/dev/null 2>&1; then
    gh_auth=1
fi

# gh 経路が唯一の手段（SSH 不可）なのに gh が使えないなら、ここで止める。
# ただし public リポジトリは HTTPS 変換のみで通るため、gh 未認証でも fetch は
# 試せる。fetch 実行時に到達可否が確定するので、ここでは硬く止めない。
if [ "$ssh_ok" != 1 ] && [ "$gh_present" != 1 ]; then
    die "非対話 SSH 認証不可（テスト失敗/remote が非SSH）で、gh も見つかりません。GitHub CLI を導入するか SSH 鍵を使える状態にしてください"
fi

local_tip="$(git rev-parse HEAD)"
tracking_ref="refs/remotes/$remote/$branch"

# リモート側 tip の取得。SSH 経路を実テストしたときは経路判定の ls-remote 出力から
# 既に $remote_tip を得ている（往復増加ゼロ）。tip が未取得のケースは 2 つ:
#   1. SSH 認証キャッシュヒット（ssh_ok=1 だが判定 ls-remote を省いた）→ SSH で 1 ブランチ分だけ引く。
#      ここで SSH が失敗したらキャッシュを破棄し gh 経路へ落とす（鍵失効などへの追従）。
#   2. gh(HTTPS) 経路 → gh トークン経由で引く（public は gh 未認証でも HTTPS 変換だけで引ける）。
if [ -z "$remote_tip" ] && [ "$ssh_cached" = 1 ]; then
    # awk へ直接パイプすると ls-remote の exit code を握り潰すため、生出力を変数に受けてから抽出する。
    if ssh_one="$(GIT_SSH_COMMAND="$SSH_CMD" "${TIMEOUT_CMD[@]}" git ls-remote "$url" "refs/heads/$branch" 2>/dev/null)"; then
        remote_tip="$(printf '%s\n' "$ssh_one" | awk 'NR==1{print $1}')"
    else
        # キャッシュは有効だったが今回 SSH が通らなかった。gh 経路へ降格する。
        ssh_ok=0; ssh_cached=0
        gh_route_reason="キャッシュ済み SSH 認証が今回失敗（鍵失効等）"
        f="$(ssh_cache_file "$host")" && rm -f "$f" 2>/dev/null || true
    fi
fi
if [ -z "$remote_tip" ]; then
    remote_tip="$(git "${CRED_RESET[@]}" ls-remote "$https" "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')" || true
fi

# 取り込み方向の状態判定（push の逆向き）。
#   missing-remote … リモートにそのブランチが無い
#   up-to-date     … リモート tip をローカルが既に保持（content 上は最新）
#   behind         … ローカルがリモートの祖先＝FF で取り込める
#   diverged       … 双方に固有コミット。FF 不可（merge/rebase が要る）
#   fetchable      … リモート tip がローカル object DB に無く、fetch するまで分類不能
state="missing-remote"; incoming_range=""
if [ -n "$remote_tip" ]; then
    if [ "$remote_tip" = "$local_tip" ]; then
        state="up-to-date"
    elif git cat-file -e "${remote_tip}^{commit}" 2>/dev/null; then
        if git merge-base --is-ancestor "$remote_tip" "$local_tip" 2>/dev/null; then
            state="up-to-date"   # リモート tip を既に含む（ローカルが先行）
        elif git merge-base --is-ancestor "$local_tip" "$remote_tip" 2>/dev/null; then
            state="behind"; incoming_range="${local_tip}..${remote_tip}"
        else
            state="diverged"
        fi
    else
        state="fetchable"   # 新規コミットが未取得。fetch 後に FF/diverged を確定できる
    fi
fi

# 作業ツリーの汚れ（pull の安全性判定に使う）。
dirty=0
[ -z "$(git status --porcelain 2>/dev/null)" ] || dirty=1

# fetch 本体。SSH 経路を優先し、失敗したら gh(HTTPS) 経路へフォールバックする。
# 判定と同一の $SSH_CMD（BatchMode=yes 等）を使い、万一の非対話認証失敗時も
# パスフレーズ入力待ちに入らせず即失敗させる。fetch 本体はデータ転送があるため
# timeout では包まない（接続段階は ConnectTimeout に委ねる）。
# used_route に実際に成功した経路（ssh / gh）を残す。
used_route=""
do_fetch() {
    used_route=""
    local rc=1
    if [ "$ssh_ok" = 1 ]; then
        set +e
        GIT_SSH_COMMAND="$SSH_CMD" git fetch "$url" "+refs/heads/$branch:$tracking_ref"
        rc=$?
        set -e
        if [ "$rc" = 0 ]; then
            used_route="ssh"
            ssh_cache_store "$host"   # 実 fetch が通った＝最も強い成功証拠。TTL を延長。
            return 0
        fi
        f="$(ssh_cache_file "$host")" && rm -f "$f" 2>/dev/null || true   # SSH が通らなかったのでキャッシュ破棄
        echo "  SSH fetch に失敗 (exit $rc)。gh(HTTPS) 経路へフォールバックします..." >&2
    fi
    git "${CRED_RESET[@]}" fetch "$https" "+refs/heads/$branch:$tracking_ref"
    used_route="gh"
}

case "$cmd" in
    preflight)
        echo "=== TARGET ==="
        echo "remote:     $remote"
        echo "remote_url: $url"
        echo "fetch_url:  $https"
        echo "host:       $host"
        echo "branch:     $branch"
        if [ "$ssh_ok" = 1 ]; then
            echo "route:      SSH（非対話 SSH 認証テスト成功 → 素の git fetch を優先。失敗時 gh へフォールバック）"
        else
            echo "route:      gh(HTTPS)（$gh_route_reason のため）"
        fi
        echo
        echo "=== AUTH ==="
        if [ "$ssh_ok" = 1 ] && [ "$ssh_cached" = 1 ]; then
            echo "  SSH 認証テスト: 成功（セッション内キャッシュ再利用 — ls-remote 省略）"
        elif [ "$ssh_ok" = 1 ]; then
            echo "  SSH 認証テスト: 成功（BatchMode=yes で非対話通過）"
        elif is_ssh_url "$url"; then
            echo "  SSH 認証テスト: 失敗（非対話では通らず → gh 経路）"
        else
            echo "  SSH 認証テスト: 未実施（remote が非SSH）"
        fi
        if [ "$gh_auth" = 1 ]; then
            gh auth status --hostname "$host" 2>&1 | sed 's/^/  /'
        else
            echo "  gh: host '$host' で未認証（gh フォールバックは public リポジトリのみ通る）"
        fi
        echo
        echo "=== STATE ==="
        echo "local HEAD:   $(git log -1 --format='%h %s' "$local_tip")"
        echo "remote tip:   ${remote_tip:-(なし)}"
        echo "incoming:     $state"
        case "$state" in
            missing-remote) echo "  リモートにブランチ '$branch' がありません。fetch するものがありません。" ;;
            up-to-date)     echo "  取り込み不要: リモート tip を既に保持しています。" ;;
            behind)         echo "  fast-forward で取り込めます。取り込まれるコミット:"
                git log --format='  %h %s' "$incoming_range" ;;
            diverged)       echo "  履歴が分岐。FF 不可 — pull には --merge / --rebase が要ります。" ;;
            fetchable)      echo "  新規コミット (remote tip ${remote_tip}) が未取得。fetch するまで件数は不明。" ;;
        esac
        echo
        echo "=== WORKTREE ==="
        if [ "$dirty" = 1 ]; then
            echo "  未コミット変更あり。pull は実行しません（fetch は可）。"
        else
            echo "  clean。pull 実行可。"
        fi
        echo
        echo "=== WARNINGS ==="
        if [ "$state" = "diverged" ]; then
            echo "WARNING: 履歴分岐。pull するなら --merge か --rebase を明示し、ユーザー確認を取ること。"
        elif [ "$state" = "up-to-date" ]; then
            echo "WARNING: 取り込む差分がありません。"
        elif [ "$dirty" = 1 ] && [ "$state" != "missing-remote" ]; then
            echo "WARNING: 作業ツリーが dirty。pull 前に commit / stash が必要。"
        else
            echo "(none)"
        fi
        ;;

    fetch)
        [ "$state" != "missing-remote" ] || die "リモートにブランチ '$branch' がありません。"
        do_fetch
        echo
        if git rev-parse --verify -q "$tracking_ref" >/dev/null; then
            n="$(git rev-list --count "HEAD..$tracking_ref" 2>/dev/null || echo 0)"
            if [ "$n" -gt 0 ]; then
                echo "OK: [$used_route] fetch 完了。未取り込みコミット $n 件（$tracking_ref）:"
                git log --format='  %h %s' "HEAD..$tracking_ref"
                echo "（取り込むには: gh-fetch.sh pull $branch [--merge|--rebase]）"
            else
                echo "OK: [$used_route] fetch 完了。取り込む差分はありません。"
            fi
        else
            echo "OK: [$used_route] fetch 完了。"
        fi
        ;;

    pull)
        [ "$state" != "missing-remote" ] || die "リモートにブランチ '$branch' がありません。"
        if [ "$dirty" = 1 ]; then
            die "作業ツリーに未コミット変更があります。pull 前に commit か stash してください（fetch のみなら可）。"
        fi

        do_fetch
        echo

        # fetch 後の最新状態で再分類（fetchable だった場合に確定する）。
        new_remote="$(git rev-parse --verify -q "$tracking_ref" || echo "")"
        [ -n "$new_remote" ] || die "fetch 後に $tracking_ref を解決できませんでした。"
        if [ "$new_remote" = "$local_tip" ] || git merge-base --is-ancestor "$new_remote" "$local_tip" 2>/dev/null; then
            echo "取り込み不要: 既に最新です。"; exit 0
        fi
        can_ff=0
        git merge-base --is-ancestor "$local_tip" "$new_remote" 2>/dev/null && can_ff=1

        if [ "$strategy" = "--ff-only" ] && [ "$can_ff" != 1 ]; then
            die "履歴が分岐しており fast-forward できません。意図を確認の上 'pull $branch --merge' か 'pull $branch --rebase' を再実行してください（要ユーザー確認）。"
        fi

        set +e
        case "$strategy" in
            --ff-only) git merge --ff-only "$tracking_ref" ;;
            --merge)   git merge --no-edit "$tracking_ref" ;;
            --rebase)  git rebase "$tracking_ref" ;;
        esac
        rc=$?
        set -e

        if [ "$rc" != 0 ]; then
            conflicts="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
            echo
            if [ -n "$conflicts" ]; then
                echo "CONFLICT: 統合中にコンフリクトが発生しました。対象ファイル:" >&2
                printf '  %s\n' $conflicts >&2
                [ "$strategy" = "--rebase" ] \
                    && echo "  解決して 'git rebase --continue'、中止は 'git rebase --abort'。" >&2 \
                    || echo "  解決して 'git commit'、中止は 'git merge --abort'。" >&2
            fi
            die "$strategy による統合に失敗しました (exit $rc)。作業ツリーは統合途中の状態です。"
        fi

        echo "OK: $strategy で取り込み完了 → $(git log -1 --format='%h %s' HEAD)"
        ;;

    *)
        die "未知のサブコマンド: $cmd （preflight | fetch | pull）"
        ;;
esac
