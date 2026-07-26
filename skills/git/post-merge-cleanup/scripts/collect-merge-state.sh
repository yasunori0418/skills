#!/usr/bin/env bash
#
# collect-merge-state.sh — マージ済み PR に対応するローカルの後片付け候補を
# JSON で列挙する。read-only（参照・working tree・リモートを一切変更しない）。
#
# Usage:
#   collect-merge-state.sh [PR番号|ブランチ名]...
#     引数あり: 指定された PR / ブランチだけを候補にする
#     引数なし: merged PR 直近 30 件と、ローカルの worktree / ブランチの積集合
#
# 判定方針:
#   マージ済みかどうかの真実源は GitHub の PR state（MERGED）。
#   ローカルの patch-id 比較は行わない — rebase-merge で sha が変わるため
#   `git branch --merged` は当てにならず、実際の削除可否は wt remove が
#   tree 一致（"tree matches main"）で機械判定する。本スクリプトは
#   「どれが対象か」と「安全に消せるか」だけを確定させる。
#
# 削除候補から外す条件（deletable=false）:
#   - dirty        : 未コミット変更あり（wt remove 自体も拒否する）
#   - ahead > 0    : マージ後の追加コミットあり。wt remove は worktree を消して
#                    しまうが、それは次の PR になる予定の作業である可能性が高い。
#                    gitignored なファイル（.env / .direnv / ビルド成果物）は
#                    worktree ごと消えると復旧できないため、候補から外す。
#   - is_main      : main worktree は対象外
#   - is_current   : 実行中セッションが居る worktree は自分の足元を消させない
set -euo pipefail

MERGED_PR_LIMIT=30

for cmd in gh jq git; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: $cmd が必要です" >&2
        exit 1
    }
done

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "ERROR: git リポジトリ内で実行してください" >&2
    exit 1
}

have_wt=false
command -v wt >/dev/null 2>&1 && have_wt=true
have_tmux=false
command -v tmux >/dev/null 2>&1 && have_tmux=true

# --- worktree 一覧 -----------------------------------------------------------
# wt list --format json（schema 1）を正とし、wt が無い環境では
# git worktree list --porcelain から同じ形へ落とす。
worktrees_json() {
    if [ "$have_wt" = true ]; then
        # schema 1 固定。将来 schema 2 が既定になっても形が変わらないよう明示する。
        wt list --format json --config-set list.json-schema=1 2>/dev/null |
            jq '[.[] | select(.kind == "worktree") | {
                branch: .branch,
                path: .path,
                dirty: (
                    (.working_tree.staged // false) or (.working_tree.modified // false)
                    or (.working_tree.untracked // false) or (.working_tree.renamed // false)
                    or (.working_tree.deleted // false)
                ),
                ahead: (.remote.ahead // 0),
                behind: (.remote.behind // 0),
                is_main: (.is_main // false),
                is_current: (.is_current // false)
            }]'
    else
        git worktree list --porcelain | awk '
            /^worktree /  { path = substr($0, 10) }
            /^branch /    { br = substr($0, 8); sub("^refs/heads/", "", br) }
            /^$/          { if (path != "") { printf "%s\t%s\n", path, br; path=""; br="" } }
            END           { if (path != "") printf "%s\t%s\n", path, br }
        ' | jq -R -s --arg cwd "$PWD" --arg main "$(git rev-parse --show-toplevel)" '
            [ split("\n")[] | select(length > 0) | split("\t") | {
                branch: (.[1] // ""), path: .[0],
                dirty: false, ahead: 0, behind: 0,
                is_main: (.[0] == $main), is_current: (.[0] == $cwd)
            } ]'
    fi
}

wts=$(worktrees_json)
if [ "$have_wt" != true ]; then
    # wt が無い環境では dirty/ahead を git で補う（wt list は既に持っている）
    seed="$wts"
    wts=$(
        while IFS=$'\t' read -r path branch; do
            [ -n "$path" ] || continue
            d=false
            [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ] && d=true
            a=0
            if [ -n "$branch" ] && git -C "$path" rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1; then
                a=$(git -C "$path" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
            fi
            jq -cn --arg p "$path" --argjson d "$d" --argjson a "$a" '{path:$p,dirty:$d,ahead:$a}'
        done < <(jq -r '.[] | [.path, .branch] | @tsv' <<<"$seed") |
            jq -s --argjson base "$seed" '
                . as $upd | $base | map(. as $w | ($upd[] | select(.path == $w.path)) as $u
                    | $w + {dirty: $u.dirty, ahead: $u.ahead})'
    )
fi

# --- 対象 PR の解決 ----------------------------------------------------------
# 引数は PR 番号（数字）とブランチ名を混在して受け取れる。
pr_fields='number,state,title,headRefName,baseRefName,mergedAt,url,body'

resolve_prs() {
    if [ $# -eq 0 ]; then
        gh pr list --state merged --limit "$MERGED_PR_LIMIT" --json "$pr_fields" 2>/dev/null || echo '[]'
        return
    fi
    local arg out='[]' one
    for arg in "$@"; do
        if [[ "$arg" =~ ^#?[0-9]+$ ]]; then
            one=$(gh pr view "${arg#\#}" --json "$pr_fields" 2>/dev/null || echo 'null')
        else
            one=$(gh pr list --head "$arg" --state all --limit 1 --json "$pr_fields" 2>/dev/null |
                jq '.[0] // null')
        fi
        [ "$one" = "null" ] && continue
        out=$(jq -c --argjson p "$one" '. + [$p]' <<<"$out")
    done
    printf '%s' "$out"
}

all_prs=$(resolve_prs "$@")
merged_prs=$(jq -c '[.[] | select(.state == "MERGED")]' <<<"$all_prs")
# 引数で指定されたが MERGED でない PR は「対象外」として明示報告する
not_merged=$(jq -c '[.[] | select(.state != "MERGED")
    | {number, state, headRefName, title}]' <<<"$all_prs")

# --- tmux セッション ---------------------------------------------------------
# セッション名は parallel-worktree が sanitize 済みブランチ名で揃えている。
# 対応付けは完全一致のみ（部分一致で無関係なセッションを巻き込まない）。
tmux_sessions='[]'
if [ "$have_tmux" = true ]; then
    tmux_sessions=$(tmux ls -F '#{session_name}' 2>/dev/null | jq -R -s '
        [ split("\n")[] | select(length > 0) ]' || echo '[]')
fi

# ブランチ名 -> tmux セッション名の sanitize は worktrunk と同じ規則
# （英数・ハイフン・アンダースコア以外を "-" に落とす）。
# bash の文字クラス置換で閉じる（tr への依存を避ける。理由は head と同じ）
sanitize() {
    local s="${1//[^a-zA-Z0-9_-]/-}"
    printf '%s' "$s"
}

# セッション内で claude が動いているかを見る。動いていれば「作業中」として
# 既定を「残す」に倒す（後片付けのつもりで実行中の作業を殺さないため）。
session_busy() {
    local s="$1"
    [ "$have_tmux" = true ] || {
        printf 'false'
        return
    }
    if tmux list-panes -t "$s" -F '#{pane_current_command}' 2>/dev/null |
        grep -qiE '^(claude|node)$'; then
        printf 'true'
    else
        printf 'false'
    fi
}

# --- 候補の組み立て ----------------------------------------------------------
candidates='[]'
while IFS=$'\t' read -r number branch url title; do
    [ -n "$branch" ] || continue

    # first(...) で jq 内に閉じる（外部 head に依存すると、coreutils を持たない
    # Nix sandbox 等で落ちる）
    w=$(jq -c --arg b "$branch" 'first(.[] | select(.branch == $b)) // empty' <<<"$wts")
    has_local_branch=false
    git show-ref --verify --quiet "refs/heads/$branch" && has_local_branch=true

    # worktree もローカルブランチも無ければ、片付けるものが無い
    if [ -z "$w" ] && [ "$has_local_branch" != true ]; then
        continue
    fi

    if [ -n "$w" ]; then
        wpath=$(jq -r '.path' <<<"$w")
        dirty=$(jq -r '.dirty' <<<"$w")
        ahead=$(jq -r '.ahead' <<<"$w")
        is_main=$(jq -r '.is_main' <<<"$w")
        is_current=$(jq -r '.is_current' <<<"$w")
    else
        wpath=""
        dirty=false
        ahead=0
        is_main=false
        is_current=false
        # worktree が無くてもブランチ単体で ahead を測る
        if git rev-parse --verify --quiet "$branch@{upstream}" >/dev/null 2>&1; then
            ahead=$(git rev-list --count "$branch@{upstream}..$branch" 2>/dev/null || echo 0)
        fi
    fi

    sess=""
    busy=false
    cand_sess=$(sanitize "$branch")
    if jq -e --arg s "$cand_sess" 'index($s)' <<<"$tmux_sessions" >/dev/null 2>&1; then
        sess="$cand_sess"
        busy=$(session_busy "$sess")
    fi

    reasons='[]'
    deletable=true
    [ "$dirty" = true ] && {
        reasons=$(jq -c '. + ["未コミット変更あり（wt remove も拒否する）"]' <<<"$reasons")
        deletable=false
    }
    [ "$ahead" -gt 0 ] 2>/dev/null && {
        reasons=$(jq -c --arg n "$ahead" '. + ["マージ後の追加コミット \($n) 件（未 push）"]' <<<"$reasons")
        deletable=false
    }
    [ "$is_main" = true ] && {
        reasons=$(jq -c '. + ["main worktree"]' <<<"$reasons")
        deletable=false
    }
    [ "$is_current" = true ] && {
        reasons=$(jq -c '. + ["このセッションの作業ディレクトリ"]' <<<"$reasons")
        deletable=false
    }

    candidates=$(jq -c \
        --argjson pr "$number" --arg branch "$branch" --arg url "$url" --arg title "$title" \
        --arg wpath "$wpath" --argjson dirty "$dirty" --argjson ahead "${ahead:-0}" \
        --arg sess "$sess" --argjson busy "$busy" \
        --argjson deletable "$deletable" --argjson reasons "$reasons" \
        '. + [{
            pr: $pr, title: $title, url: $url, branch: $branch,
            worktree_path: (if $wpath == "" then null else $wpath end),
            tmux_session: (if $sess == "" then null else $sess end),
            tmux_busy: $busy,
            dirty: $dirty, ahead: $ahead,
            deletable: $deletable, blocked_reasons: $reasons
        }]' <<<"$candidates")
done < <(jq -r '.[] | [.number, .headRefName, .url, .title] | @tsv' <<<"$merged_prs")

# --- 後続タスクの材料 --------------------------------------------------------
# stacked 子ブランチ: マージ済みブランチを base に持つ open PR。
stacked='[]'
while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    kids=$(gh pr list --state open --base "$branch" --limit 20 \
        --json number,title,headRefName,baseRefName 2>/dev/null || echo '[]')
    stacked=$(jq -c --argjson k "$kids" '. + $k' <<<"$stacked")
done < <(jq -r '.[].headRefName' <<<"$merged_prs")

# tracking issue: PR 本文中の #N 参照のうち、GitHub が自動クローズしないもの。
# Closes/Fixes/Resolves（および複数形・過去形）が直前に付く参照は GitHub 側で
# 閉じられるので除外し、"Part of #N" / "Refs #N" / 裸の #N だけを残す。
tracking_issues=$(jq -c '
    [ .[] | . as $pr
      | ($pr.body // "")
      | [ scan("(?i)(closes|closed|close|fixes|fixed|fix|resolves|resolved|resolve)?[[:space:]]*#([0-9]+)") ]
      | map(select(.[0] == null))
      | map({issue: (.[1] | tonumber), pr: $pr.number})
      | .[]
    ] | unique_by(.issue)' <<<"$merged_prs")

jq -n \
    --argjson merged_prs "$merged_prs" \
    --argjson not_merged "$not_merged" \
    --argjson candidates "$candidates" \
    --argjson stacked "$stacked" \
    --argjson tracking_issues "$tracking_issues" \
    --argjson have_wt "$have_wt" \
    --argjson have_tmux "$have_tmux" \
    '{
        merged_prs: [$merged_prs[] | {number, title, headRefName, url}],
        not_merged: $not_merged,
        candidates: $candidates,
        followups: { stacked_children: $stacked, tracking_issues: $tracking_issues },
        tooling: { wt: $have_wt, tmux: $have_tmux }
    }'
