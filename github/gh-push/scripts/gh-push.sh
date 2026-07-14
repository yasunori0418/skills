#!/usr/bin/env bash
# gh-push.sh — 非対話セッション向けの git push。SSH 優先・gh フォールバック。
#
# 経路の選び方（決定論）:
#   - remote が SSH URL で、`ssh -o BatchMode=yes` による非対話 SSH 認証が実際に
#     通るなら、素の git push を SSH で実行する。判定は agent の鍵有無ではなく、
#     BatchMode=yes での ls-remote が成功するかで直接テストする（agent の鍵・
#     パスフレーズ無しのディスク鍵・macOS キーチェーン鍵を区別せず「非対話で
#     通るか」を確かめられる。BatchMode=yes なのでパスフレーズ入力待ちには入らない）。
#   - SSH 認証テストが失敗した場合、または remote が非SSH（HTTPS）の場合は、
#     push 認証を gh の credential helper に肩代わりさせて HTTPS で実行する。
#     remote が SSH URL でも URL を HTTPS に変換して push 先に使うので origin は変えない。
#
# 「SSH で push できるか」を実 SSH 認証テストで決定論的に判定するため、
# 非対話 SSH が通る環境では余計なトークン経由を避けて素の push が通る。
#
# 使い方:
#   gh-push.sh preflight [branch]                            push 対象を収集して提示用に出力（push しない）
#   gh-push.sh push      [branch] [--force] [--expect=<sha>] 実際に push する
#
# branch 省略時は現在のブランチ。force は push が non-fast-forward で
# 弾かれたときに、明示確認の上でのみ付ける。
#
# --force は --force-with-lease=<branch>:<sha> の明示 lease で実行される。
# URL 直 push では remote-tracking ref が参照されず、引数なしの
# --force-with-lease は常に "stale info" で拒否されるため（検証済み）。
# lease 値は --expect=<sha> があればそれ、無ければ push 直前に ls-remote で
# 見えたリモート tip。呼び出し元（rebase-flow 等）が安全確認済みの tip を
# 持っている場合は --expect で渡すこと — 確認時点以降の他者 push を確実に
# 検出して拒否できる。
set -euo pipefail

# 既存の credential.helper 一覧を空でリセットしてから gh ヘルパーだけを使う。
# cache / oauth など他ヘルパーの介入・キャッシュ汚染を避ける。
CRED_RESET=(-c credential.helper= -c credential.helper='!gh auth git-credential')

# SSH 経路で使う共通オプション（判定 ls-remote と push 本体の両方でこの値を使う）。
#   BatchMode=yes            … パスフレーズ/パスワードのプロンプトに落ちず即失敗させる（非対話の担保）。
#   ConnectTimeout=5         … 接続段階のハングを 5 秒で打ち切る。
#   StrictHostKeyChecking=accept-new … known_hosts 未登録でも確認プロンプトに落ちず自動受理して進む
#                                       （CI 等 known_hosts が空の環境でも SSH 判定が通る）。
SSH_CMD='ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new'

# 判定 ls-remote 限定の全体タイムアウト（push 本体はデータ転送があるので包まない）。
# timeout / gtimeout があればそれで包み、無ければ SSH の ConnectTimeout に委ねる。
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(timeout 10)
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD=(gtimeout 10)
else
    TIMEOUT_CMD=()
fi

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
force=0; branch=""; expect=""
for a in "$@"; do
    case "$a" in
        --force|--force-with-lease) force=1 ;;
        --expect=*) expect="${a#--expect=}" ;;
        -*) die "不明なオプション: $a" ;;
        *)  branch="$a" ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || die "git リポジトリ内ではありません"

[ -n "$branch" ] || branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" != "HEAD" ] || die "detached HEAD です。push 先ブランチ名を引数で指定してください"

remote="$(git config "branch.$branch.remote" 2>/dev/null || echo origin)"
url="$(git remote get-url "$remote" 2>/dev/null || true)"
[ -n "$url" ] || die "remote '$remote' が見つかりません"

IFS=$'\t' read -r https host < <(to_https "$url")

# push 経路の決定（決定論）:
#   remote が SSH URL なら、まず BatchMode=yes での ls-remote を打って
#   「非対話 SSH 認証が通るか」を実テストする。通ればその経路を採り、出力を
#   リモート tip 取得にも流用する（往復増加ゼロ）。テストが失敗、または remote が
#   非SSH（HTTPS）なら gh(HTTPS) 経路へ。判定は agent の鍵有無に依存しない
#   （パスフレーズ無しのディスク鍵・macOS キーチェーン鍵でも非対話で通れば SSH を選ぶ）。
# BatchMode=yes を強制するため、SSH がパスフレーズ入力待ちに落ちる余地は無い。
ssh_ok=0
gh_route_reason=""
remote_tip=""
if is_ssh_url "$url"; then
    # 1 回の ls-remote で「認証が通るか（exit code）」と「$branch の tip」を同時に得る。
    ssh_heads=""
    if ssh_heads="$(ssh_ls_remote)"; then
        ssh_ok=1
        remote_tip="$(printf '%s\n' "$ssh_heads" | awk -v r="refs/heads/$branch" '$2==r{print $1; exit}')"
    else
        gh_route_reason="非対話 SSH 認証テストに失敗"
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
if [ "$ssh_ok" != 1 ] && [ "$gh_auth" != 1 ]; then
    if [ "$gh_present" != 1 ]; then
        die "非対話 SSH 認証不可（テスト失敗/remote が非SSH）で、gh も見つかりません。GitHub CLI を導入するか SSH 鍵を使える状態にしてください"
    fi
    die "非対話 SSH 認証不可（テスト失敗/remote が非SSH）で、gh が host '$host' で未認証です。'gh auth login --hostname $host' を実行するか、SSH 鍵を使える状態にしてください"
fi

# force push は作業ブランチ限定。保護ブランチ（静的リスト + リモート既定ブランチ）は拒否。
if [ "$force" = 1 ]; then
    preason=""
    case "$branch" in
        main|master|develop|development|trunk|release|release/*|releases/*) preason="静的リスト" ;;
    esac
    if [ -z "$preason" ]; then
        def="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
        [ -n "$def" ] && [ "${def#refs/remotes/origin/}" = "$branch" ] && preason="origin/HEAD"
    fi
    if [ -z "$preason" ]; then
        slug="${https#https://"$host"/}"; slug="${slug%.git}"
        def="$(gh api "repos/$slug" --jq .default_branch 2>/dev/null || true)"
        [ -n "$def" ] && [ "$def" = "$branch" ] && preason="GitHub 既定ブランチ"
    fi
    [ -z "$preason" ] || die "保護ブランチ ($branch — $preason) への force push は禁止です。force は作業ブランチのみ"
fi

local_tip="$(git rev-parse HEAD)"

# リモート側 tip の取得。SSH 経路なら経路判定の ls-remote 出力から既に $remote_tip を
# 得ている（往復増加ゼロ）。SSH を使わない gh 経路で、かつ tip が未取得なら
# gh トークン経由の HTTPS ls-remote で引く（auth/URL の早期検証も兼ねる）。
if [ -z "$remote_tip" ] && [ "$ssh_ok" != 1 ] && [ "$gh_auth" = 1 ]; then
    remote_tip="$(git "${CRED_RESET[@]}" ls-remote "$https" "refs/heads/$branch" 2>/dev/null | awk 'NR==1{print $1}')" || true
fi

state="new"; need_force=0; range=""
if [ -n "$remote_tip" ]; then
    if [ "$remote_tip" = "$local_tip" ]; then
        state="up-to-date"
    elif git cat-file -e "${remote_tip}^{commit}" 2>/dev/null; then
        if git merge-base --is-ancestor "$remote_tip" "$local_tip" 2>/dev/null; then
            state="fast-forward"; range="${remote_tip}..${local_tip}"
        else
            state="diverged"; need_force=1
        fi
    else
        state="unknown"   # リモート tip がローカルに無く、FF 判定不能（push 時にサーバが検査）
    fi
fi

# force 時の lease 値を確定（ヘッダコメント参照）
lease=""
if [ "$force" = 1 ]; then
    lease="${expect:-$remote_tip}"
    [ -n "$lease" ] || die "リモート tip を特定できず lease を組めません（リモートにブランチが無いなら force は不要）"
    if [ -n "$expect" ] && [ -n "$remote_tip" ] && [ "$expect" != "$remote_tip" ]; then
        die "リモート tip ($remote_tip) が --expect ($expect) と不一致。確認後に他者の push があった可能性。停止します"
    fi
fi

fopt=""; [ "$force" = 1 ] && fopt=" --force-with-lease=$branch:$lease"
# 表示用 push コマンド（実行時の第一経路を反映）。
if [ "$ssh_ok" = 1 ]; then
    push_cmd="git push${fopt} $url $branch   # SSH 経路（失敗時に gh(HTTPS) へフォールバック）"
else
    push_cmd="git -c credential.helper= -c credential.helper='!gh auth git-credential' push${fopt} $https $branch"
fi

case "$cmd" in
    preflight)
        echo "=== TARGET ==="
        echo "remote:     $remote"
        echo "remote_url: $url"
        echo "push_url:   $https"
        echo "host:       $host"
        echo "branch:     $branch"
        if [ "$ssh_ok" = 1 ]; then
            echo "route:      SSH（非対話 SSH 認証テスト成功 → 素の git push を優先。失敗時 gh へフォールバック）"
        else
            echo "route:      gh(HTTPS)（$gh_route_reason のため）"
        fi
        echo
        echo "=== AUTH ==="
        if [ "$ssh_ok" = 1 ]; then
            echo "  SSH 認証テスト: 成功（BatchMode=yes で非対話通過）"
        elif is_ssh_url "$url"; then
            echo "  SSH 認証テスト: 失敗（非対話では通らず → gh 経路）"
        else
            echo "  SSH 認証テスト: 未実施（remote が非SSH）"
        fi
        if [ "$gh_auth" = 1 ]; then
            gh auth status --hostname "$host" 2>&1 | sed 's/^/  /'
        else
            echo "  gh: host '$host' で未認証（gh フォールバックは使えません）"
        fi
        echo
        echo "=== STATE ==="
        echo "local HEAD:   $(git log -1 --format='%h %s' "$local_tip")"
        echo "remote state: $state"
        case "$state" in
            up-to-date) echo "(push 不要: リモートと一致)" ;;
            new)        echo "commits to push (新規ブランチ, 直近5件):"
                git log -5 --format='  %h %s' "$local_tip" ;;
            fast-forward)
                echo "commits to push:"
                git log --format='  %h %s' "$range" ;;
            diverged)   echo "  リモートと履歴が分岐。通常 push は弾かれます。"
                echo "  整合させる（fetch + rebase/merge）か、意図的な上書きなら --force が必要。" ;;
            unknown)    echo "  リモート tip ($remote_tip) がローカルに無く push 範囲を厳密判定できません。"
                echo "  非 fast-forward ならサーバが push を拒否します（安全）。直近5件:"
                git log -5 --format='  %h %s' "$local_tip" ;;
        esac
        echo
        echo "=== PUSH COMMAND ==="
        echo "$push_cmd"
        echo
        echo "=== WARNINGS ==="
        if [ "$need_force" = 1 ]; then
            echo "WARNING: 履歴分岐を検出。--force 無しの push は失敗します。ユーザー確認なしに force しないこと。"
        elif [ "$state" = "up-to-date" ]; then
            echo "WARNING: push する差分がありません。"
        else
            echo "(none)"
        fi
        ;;

    push)
        [ "$state" != "up-to-date" ] || { echo "push 不要: リモートと一致しています。"; exit 0; }
        if [ "$need_force" = 1 ] && [ "$force" != 1 ]; then
            die "履歴が分岐しています。--force_with_lease を意図する場合のみ push ... --force を再実行してください（要ユーザー確認）"
        fi

        # SSH 経路の素の push。判定と同一の $SSH_CMD（BatchMode=yes 等）を使い、
        # 万一の非対話認証失敗時もパスフレーズ入力待ちに入らせず即失敗させる（非対話の担保）。
        # push 本体はデータ転送があるため timeout では包まない（接続段階は ConnectTimeout に委ねる）。
        # 成功時 git が remote-tracking ref を正しく更新するため手動整合は不要。
        do_push_ssh() {
            if [ "$force" = 1 ]; then
                GIT_SSH_COMMAND="$SSH_CMD" git push "--force-with-lease=$branch:$lease" "$url" "$branch"
            else
                GIT_SSH_COMMAND="$SSH_CMD" git push "$url" "$branch"
            fi
        }
        # gh(HTTPS) 経路の push。URL 直 push なので後段で remote-tracking ref を手で進める。
        do_push_gh() {
            if [ "$force" = 1 ]; then
                git "${CRED_RESET[@]}" push "--force-with-lease=$branch:$lease" "$https" "$branch"
            else
                git "${CRED_RESET[@]}" push "$https" "$branch"
            fi
        }

        used_route=""
        rc=1
        if [ "$ssh_ok" = 1 ]; then
            echo "→ SSH 経路で push を試行..."
            set +e; do_push_ssh; rc=$?; set -e
            if [ "$rc" = 0 ]; then
                used_route="ssh"
            elif [ "$gh_auth" = 1 ]; then
                echo "  SSH push に失敗 (exit $rc)。gh(HTTPS) 経路へフォールバックします..." >&2
                set +e; do_push_gh; rc=$?; set -e
                [ "$rc" = 0 ] && used_route="gh"
            fi
        else
            set +e; do_push_gh; rc=$?; set -e
            [ "$rc" = 0 ] && used_route="gh"
        fi

        [ "$rc" = 0 ] || die "push に失敗しました (exit $rc)"

        # gh(URL 直) 経路では remote-tracking ref が更新されないため手で進める。
        # SSH 経路では git が更新済みなので不要。
        if [ "$used_route" = "gh" ]; then
            git update-ref "refs/remotes/$remote/$branch" "$local_tip" 2>/dev/null || true
        fi
        target="$([ "$used_route" = "ssh" ] && echo "$url" || echo "$https")"
        echo "OK: [$used_route] $target $branch を更新しました ($(git log -1 --format='%h %s' "$local_tip"))"
        ;;

    *)
        die "未知のサブコマンド: $cmd （preflight | push）"
        ;;
esac
