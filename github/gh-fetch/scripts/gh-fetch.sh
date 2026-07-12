#!/usr/bin/env bash
# gh-fetch.sh — 非対話セッション向けの git fetch / pull。SSH 優先・gh フォールバック。
# gh-push の取り込み（incoming）版。
#
# 経路の選び方（決定論）:
#   - remote が SSH URL かつ ssh-agent に鍵ロード済み（`ssh-add -l` が exit 0）なら、
#     素の git fetch を SSH で実行する。鍵が agent に載っているので署名は非対話で
#     完結し、パスフレーズ入力（= 標準入力）待ちに入らない。GIT_SSH_COMMAND に
#     BatchMode=yes を強制し、万一の鍵未ロード時も即失敗させる。
#   - SSH fetch が失敗した場合、または SSH が使えない（HTTPS remote / agent に鍵なし）
#     場合は、通信認証を gh の credential helper に肩代わりさせて HTTPS で実行する。
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

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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

# ssh-agent に鍵がロード済みか（= 非対話でも SSH 署名できる）を決定論的に判定。
# `ssh-add -l` の exit — 0: 鍵あり / 1: agent は生きているが鍵なし / 2: agent へ接続不能。
# 鍵が載っていれば SSH fetch はパスフレーズを問われず通る。この一覧照会自体に
# パスフレーズ入力の余地は無いので、タイムアウト待ちも発生しない。
ssh_agent_has_key() {
    ssh-add -l >/dev/null 2>&1
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
#   remote が SSH URL かつ ssh-agent に鍵ロード済みなら SSH を優先し、
#   素の git fetch を試す。失敗時のみ gh(HTTPS) 経路へフォールバックする。
#   それ以外（HTTPS remote / agent に鍵なし）は最初から gh 経路。
ssh_ok=0
gh_route_reason=""
if is_ssh_url "$url"; then
    if ssh_agent_has_key; then
        ssh_ok=1
    else
        gh_route_reason="ssh-agent に鍵なし/接続不能"
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
    die "SSH 署名不可（ssh-agent に鍵なし/remote が非SSH）で、gh も見つかりません。GitHub CLI を導入するか ssh-add で鍵をロードしてください"
fi

local_tip="$(git rev-parse HEAD)"
tracking_ref="refs/remotes/$remote/$branch"

# リモート側 tip を ls-remote で取得。auth/URL の早期検証も兼ねる。
# SSH 経路なら SSH URL で直接引き、引けなければ gh トークン経由の HTTPS で
# フォールバックする（public は gh 未認証でも HTTPS 変換だけで引ける）。
remote_tip=""
if [ "$ssh_ok" = 1 ]; then
    remote_tip="$(GIT_SSH_COMMAND='ssh -o BatchMode=yes' git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')" || true
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
# BatchMode=yes で万一の鍵未ロード時もパスフレーズ入力待ちに入らせず即失敗させる。
# used_route に実際に成功した経路（ssh / gh）を残す。
used_route=""
do_fetch() {
    used_route=""
    local rc=1
    if [ "$ssh_ok" = 1 ]; then
        set +e
        GIT_SSH_COMMAND='ssh -o BatchMode=yes' git fetch "$url" "+refs/heads/$branch:$tracking_ref"
        rc=$?
        set -e
        if [ "$rc" = 0 ]; then used_route="ssh"; return 0; fi
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
            echo "route:      SSH（ssh-agent に鍵ロード済み → 素の git fetch を優先。失敗時 gh へフォールバック）"
        else
            echo "route:      gh(HTTPS)（$gh_route_reason のため）"
        fi
        echo
        echo "=== AUTH ==="
        if [ "$ssh_ok" = 1 ]; then
            echo "  ssh-agent: 鍵ロード済み（SSH 署名可）"
        elif ssh-add -l >/dev/null 2>&1; then
            echo "  ssh-agent: 鍵ロード済み（ただし remote が非SSH のため未使用）"
        else
            echo "  ssh-agent: 鍵なし/agent 接続不能"
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
