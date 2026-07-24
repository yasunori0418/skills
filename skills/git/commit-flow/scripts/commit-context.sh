#!/usr/bin/env bash
#
# commit-context.sh — コミットメッセージ作成に必要な素材をまとめて出力する。
# read-only。git の状態を一切変更しない。
#
# コミット前の素材収集をモデルのアドリブ（git status / diff / log の手打ちや
# ファイル全文 Read）に任せると、staged / unstaged の取り違えや、diff に無い
# 既存行を「今回の変更」と誤認する事故が起きる。ここで確定させる。
#
# Usage:
#   commit-context.sh [max-diff-lines]
#     STAGED DIFF の最大行数（既定 600）。超過分は省略し、その旨を出力する。
#
# 出力は `=== SECTION ===` 区切りのプレーンテキスト。呼び出し側（スキル）が
# これを読んでコミットメッセージを組み立てる。
set -euo pipefail

max_diff_lines="${1:-600}"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: git リポジトリ内で実行してください" >&2
    exit 1
fi

git_dir=$(git rev-parse --git-dir)
has_head=yes
git rev-parse --verify --quiet HEAD >/dev/null || has_head=no

echo "=== REPO IDENTITY ==="
# 「どのリポジトリに対してコミットしようとしているか」の錨。会話に混ざった
# 別リポジトリの文脈をメッセージへ持ち込まないための確認用。
root=$(git rev-parse --show-toplevel 2>/dev/null || echo "?")
echo "worktree-root: $root"
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
echo "branch: $branch"
url=$(git remote get-url origin 2>/dev/null || git remote get-url "$(git remote | head -1)" 2>/dev/null || echo "")
if [ -n "$url" ]; then
    slug=$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://##; s#^[^@/]+@##; s#^[^:/]+[:/]##; s#\.git$##')
    echo "repo: $slug"
else
    echo "repo: (remote なし)"
fi
echo ""

echo "=== IN-PROGRESS OPERATION ==="
# merge / rebase / cherry-pick / revert / bisect 進行中の通常コミットは事故の元。
# 警告が出たら状況をユーザーに報告してから進める。
in_progress=no
[ -f "$git_dir/MERGE_HEAD" ] && { echo "WARNING: merge 進行中（MERGE_HEAD あり）"; in_progress=yes; }
{ [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; } && { echo "WARNING: rebase 進行中"; in_progress=yes; }
[ -f "$git_dir/CHERRY_PICK_HEAD" ] && { echo "WARNING: cherry-pick 進行中"; in_progress=yes; }
[ -f "$git_dir/REVERT_HEAD" ] && { echo "WARNING: revert 進行中"; in_progress=yes; }
[ -f "$git_dir/BISECT_LOG" ] && { echo "WARNING: bisect 進行中"; in_progress=yes; }
[ "$in_progress" = "no" ] && echo "(なし)"
echo ""

echo "=== STAGED FILES ==="
staged_names=$(git diff --cached --name-status 2>/dev/null || true)
if [ -z "$staged_names" ]; then
    echo "(ステージ済みの変更なし)"
    echo "→ コミット素材がありません。UNSTAGED / UNTRACKED を見て何をステージするか"
    echo "  決め（ユーザーの明示指示が無ければ候補を提示して確認）、ステージ後に"
    echo "  このスクリプトを再実行してからメッセージを書いてください。"
else
    echo "$staged_names"
    echo ""
    git diff --cached --stat 2>/dev/null | tail -1
fi
echo ""

echo "=== UNSTAGED / UNTRACKED ==="
# STAGED と物理的にセクションを分ける（staged/unstaged の取り違え防止）。
# ここに載っているものは今回のコミットには含まれない。
unstaged=$(git diff --name-status 2>/dev/null || true)
untracked=$(git ls-files --others --exclude-standard 2>/dev/null || true)
if [ -z "$unstaged" ] && [ -z "$untracked" ]; then
    echo "(なし)"
else
    if [ -n "$unstaged" ]; then
        echo "--- unstaged（変更あり・未ステージ）---"
        echo "$unstaged"
    fi
    if [ -n "$untracked" ]; then
        echo "--- untracked（未追跡）---"
        echo "$untracked"
    fi
fi
echo ""

echo "=== STAGED DIFF ==="
# コミットメッセージの唯一の素材。`+` 行だけが「追加」、`-` 行だけが「削除」。
# 無印のコンテキスト行は今回の変更ではない。
if [ -z "$staged_names" ]; then
    echo "(なし — ステージ後に再実行)"
else
    staged_diff=$(git diff --cached 2>/dev/null || true)
    total_lines=$(printf '%s\n' "$staged_diff" | wc -l | tr -d ' ')
    if [ "$total_lines" -gt "$max_diff_lines" ]; then
        printf '%s\n' "$staged_diff" | head -n "$max_diff_lines"
        echo ""
        echo "WARNING: diff が ${total_lines} 行あり、先頭 ${max_diff_lines} 行で省略しました。"
        echo "残りが必要なら範囲を絞って直接実行: git diff --cached -- <path>"
        echo "または上限を広げて再実行: commit-context.sh <max-diff-lines>"
    else
        printf '%s\n' "$staged_diff"
    fi
fi
echo ""

echo "=== RECENT COMMITS ==="
# リポジトリの type / scope 慣習の実例。書式をこれに揃える。
if [ "$has_head" = "yes" ]; then
    git log --oneline --no-decorate -10 2>/dev/null || true
else
    echo "(コミット履歴なし — 初回コミット)"
fi
echo ""

echo "=== SCOPE CANDIDATES ==="
# scope の機械抽出候補。上段: 直近履歴で実際に使われた scope（使用回数つき）。
# 下段: ステージ済みパスの構成要素。どちらも候補にすぎず、最終判断はモデル。
if [ "$has_head" = "yes" ]; then
    hist_scopes=$(git log --format=%s -30 2>/dev/null | sed -nE 's/^[a-z]+\(([^)]+)\)!?:.*$/\1/p' | sort | uniq -c | sort -rn || true)
    if [ -n "$hist_scopes" ]; then
        echo "--- 直近30コミットで使われた scope ---"
        echo "$hist_scopes"
    else
        echo "--- 直近30コミットで使われた scope ---"
        echo "(なし — scope 無し形式のリポジトリの可能性)"
    fi
else
    echo "--- 直近履歴 ---"
    echo "(コミット履歴なし)"
fi
if [ -n "$staged_names" ]; then
    echo "--- ステージ済みパスの構成要素 ---"
    printf '%s\n' "$staged_names" | awk '{print $NF}' | awk -F/ '{ if (NF>=2) print $1; if (NF>=3) print $2 }' | sort -u
fi
echo ""

echo "=== NOTE ==="
echo "- メッセージの素材は STAGED DIFF セクションのみ。ファイル全文の Read や記憶を根拠にしない。"
echo "- diff の \`+\` 行だけが「追加した」、\`-\` 行だけが「削除した」。無印行は変更内容として書かない。"
