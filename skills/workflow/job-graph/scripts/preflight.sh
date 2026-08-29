#!/usr/bin/env bash
# job-graph の事前確認（read-only）。
# herdr/wt/gh/jq の有無、HERDR_ENV、既定ブランチ、未コミット変更、
# 既存 worktree/ブランチ名を決定論的に収集する。worktree 生成やエージェント起動の
# 前に必ず実行し、出力の WARNING を解消してから進む。状態を変える操作は一切行わない。
set -u

section() { printf '\n=== %s ===\n' "$1"; }

section "HERDR"
if [ "${HERDR_ENV:-}" = 1 ]; then
    echo "HERDR_ENV=1: herdr 管理下の pane で実行中"
else
    echo "WARNING: HERDR_ENV が 1 でない。herdr 管理下の pane で実行すること（job-graph は herdr 前提）"
fi
# レーンを作る先の session。COMMANDS はこの値を --session に固定して起動する。
# 意図した session（親 pane と同じ）かどうかを起動前に目視で確認する。
printf 'session: %s' "${HERDR_SESSION:-default}"
if [ -z "${HERDR_SESSION:-}" ]; then
    printf '  WARNING: HERDR_SESSION が空。既定 session にレーンを作る'
fi
printf '\n'

section "TOOLS"
for t in herdr wt gh jq git; do
    if command -v "$t" >/dev/null 2>&1; then
        ver=$("$t" --version 2>/dev/null | head -1)
        printf '%-6s installed: yes  %s\n' "$t" "$ver"
    else
        printf '%-6s installed: no   WARNING: %s が無い\n' "$t" "$t"
    fi
done
if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
        echo "gh auth: ok"
    else
        echo "gh auth: NONE  WARNING: gh 未認証。PR 作成前に gh auth login が必要"
    fi
fi

section "REPO"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "WARNING: git リポジトリ外。リポジトリ内で実行すること"
    exit 0
fi
echo "current branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
# 既定ブランチ（origin/HEAD → 無ければ main/master/develop を推測）
def=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
if [ -z "${def:-}" ]; then
    for c in main master develop; do
        git show-ref --verify --quiet "refs/heads/$c" && def="$c" && break
    done
fi
echo "default branch: ${def:-（特定できず。default_base を明示すること）}"
# develop が別に存在すれば候補として併記（stack の base 指定に使うことがある）
if git show-ref --verify --quiet refs/heads/develop && [ "${def:-}" != "develop" ]; then
    echo "candidate base: develop （git-flow 系。base に使うなら明示）"
fi

section "DIRTY (未コミット変更)"
dirty=$(git status --porcelain 2>/dev/null)
if [ -n "$dirty" ]; then
    echo "WARNING: プライマリ worktree に未コミット変更あり。"
    echo "  新しい worktree は base ブランチから切られるためこれらは引き継がれない。"
    echo "  先に commit / stash で捌くか、対象 worktree で作業すること。"
    echo "$dirty"
else
    echo "clean"
fi

section "PERMISSIONS (permissions.ask の git 系ルール)"
# レーン（非対話 pane の claude）では permissions.ask の承認プロンプトが誰にも届かず
# 自動 deny される。git reset / rebase / push が ask に載っていると、ワーカーの restack や
# push がそこで止まる。該当ルールを列挙して、親の代行（restack.md）を事前に決めておく。
# 設定ファイルが無い・jq が失敗した場合は沈黙する（read-only・fail-open）。
ask_hits=""
for cfg in "$HOME/.claude/settings.json" ".claude/settings.json"; do
    [ -f "$cfg" ] || continue
    hits=$(jq -r '.permissions.ask // [] | .[] | select(test("git (reset|rebase|push)"))' "$cfg" 2>/dev/null)
    if [ -n "$hits" ]; then
        ask_hits=1
        printf '%s:\n' "$cfg"
        printf '%s\n' "$hits" | sed 's/^/  /'
    fi
done
if [ -n "$ask_hits" ]; then
    echo "WARNING: 上記は permissions.ask のためレーン（非対話 pane）では承認プロンプトが誰にも届かず自動 deny される。"
    echo "  レーンで止まったら親が代行する: reset は親が git -C <worktree>（references/restack.md の役割分担）、push は lane-ops の代行 push。"
else
    echo "git reset/rebase/push を ask にしているルールなし"
fi

section "EXISTING WORKTREES"
git worktree list 2>/dev/null || echo "(なし)"

section "EXISTING BRANCHES (名前衝突チェック用)"
# 提案するブランチ名がここに既出なら別名にする
git branch --format='%(refname:short)' 2>/dev/null
echo "--- remote ---"
git branch -r --format='%(refname:short)' 2>/dev/null | grep -v 'HEAD' || true
