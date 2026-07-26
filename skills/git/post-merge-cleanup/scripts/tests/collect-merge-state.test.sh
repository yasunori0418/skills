#!/usr/bin/env bash
# collect-merge-state.sh の検証。
# gh は実ネットワークを叩くため、PATH 先頭に置いた stub で固定応答に差し替える。
# 検証対象は「どの候補を deletable から外すか」の判定ロジック:
#   - dirty / ahead>0 / is_main / is_current は deletable=false + 理由付き
#   - clean かつ ahead=0 の worktree は deletable=true
#   - MERGED でない PR は候補に入れず not_merged に出す
#   - worktree もローカルブランチも無いブランチは候補にしない
#   - tracking issue は自動クローズ語（Closes/Fixes/Resolves）付きを除外する
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COLLECT="$SCRIPT_DIR/../collect-merge-state.sh"

# 依存が欠けたまま走ると「何も出力せず exit 0」＝素通りになるため、先に確かめて
# 明示的にスキップを宣言する（沈黙は CI 上で検知できない）。
for dep in jq git mktemp chmod; do
    command -v "$dep" >/dev/null 2>&1 || {
        echo "SKIP: $(basename "$0") — $dep が無い環境のためスキップ"
        exit 0
    }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
contains() { # label haystack needle
    case "$2" in
        *"$3"*) echo "PASS: $(basename "$0")[$1] contains '$3'" ;;
        *)
            echo "FAIL: $(basename "$0")[$1] missing '$3'"
            fail=1
            ;;
    esac
}

# --- stub: gh / wt / tmux ----------------------------------------------------
# 実バイナリを呼ばせないよう PATH を差し替える。jq/git/bash は実物を使う。
stub="$TMP/bin"
mkdir -p "$stub"

# stub の shebang は実行中の bash の絶対パスを使う。`#!/usr/bin/env bash` だと
# /usr/bin/env を持たない Nix sandbox で exit 126 になり、テストが黙って死ぬ。
# （checked-in ファイルは patchShebangs が直すが、実行時生成の stub は直されない）
BASH_ABS=$(command -v bash)

cat >"$stub/gh" <<EOF
#!$BASH_ABS
EOF
cat >>"$stub/gh" <<'EOF'
# gh pr list --state merged ... -> PR_LIST_JSON
# gh pr list --state open --base ... -> 空（stacked 子なし）
# gh pr view N ... -> PR_VIEW_JSON から該当を返す
set -euo pipefail
args="$*"
case "$args" in
  *"--state open"*) echo '[]' ;;
  *"--state merged"*) printf '%s' "${PR_LIST_JSON:-[]}" ;;
  *"pr list --head"*)
      head=$(printf '%s\n' "$@" | awk '/^--head$/{getline; print}')
      printf '%s' "${PR_LIST_JSON:-[]}" | jq --arg h "$head" '[.[] | select(.headRefName == $h)]' ;;
  *"pr view"*)
      n=$(printf '%s\n' "$@" | awk 'p{print;exit} /^view$/{p=1}')
      printf '%s' "${PR_ALL_JSON:-${PR_LIST_JSON:-[]}}" | jq --argjson n "$n" '.[] | select(.number == $n)' ;;
  *) echo '[]' ;;
esac
EOF

cat >"$stub/wt" <<EOF
#!$BASH_ABS
EOF
cat >>"$stub/wt" <<'EOF'
set -euo pipefail
case "$*" in
  *"list"*) printf '%s' "${WT_LIST_JSON:-[]}" ;;
  *) exit 0 ;;
esac
EOF

cat >"$stub/tmux" <<EOF
#!$BASH_ABS
EOF
cat >>"$stub/tmux" <<'EOF'
set -euo pipefail
case "$1" in
  ls) printf '%s\n' ${TMUX_SESSIONS:-} ;;
  list-panes) printf '%s\n' "${TMUX_PANE_CMD:-zsh}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$stub"/*

# --- fixture repo ------------------------------------------------------------
repo="$TMP/repo"
git init -q -b main "$repo"
git -C "$repo" config user.email t@e.x
git -C "$repo" config user.name t
echo base >"$repo/a.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm base
# 候補判定に使うローカルブランチ群
for b in feat-clean feat-dirty feat-ahead feat-current; do
    git -C "$repo" branch "$b"
done

collect() { # -> JSON。スクリプトが落ちたら黙って空を返さず、その場で落とす。
    local out rc
    out=$(
        cd "$repo"
        PATH="$stub:$PATH" bash "$COLLECT" "$@" 2>&1
    ) && rc=0 || rc=$?
    if [ "$rc" -ne 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$out"; then
        echo "FAIL: $(basename "$0")[collect] スクリプトが失敗しました (exit=$rc)" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    printf '%s' "$out"
}

# 共通の PR 応答: 4 本 MERGED + 1 本 OPEN
export PR_LIST_JSON='[
 {"number":1,"state":"MERGED","title":"clean","headRefName":"feat-clean",
  "baseRefName":"main","url":"u1","body":"Part of #100"},
 {"number":2,"state":"MERGED","title":"dirty","headRefName":"feat-dirty",
  "baseRefName":"main","url":"u2","body":"Closes #200"},
 {"number":3,"state":"MERGED","title":"ahead","headRefName":"feat-ahead",
  "baseRefName":"main","url":"u3","body":"no refs"},
 {"number":4,"state":"MERGED","title":"cur","headRefName":"feat-current",
  "baseRefName":"main","url":"u4","body":"Refs #300"},
 {"number":5,"state":"MERGED","title":"gone","headRefName":"feat-no-local",
  "baseRefName":"main","url":"u5","body":""}]'

export WT_LIST_JSON='[
 {"kind":"worktree","branch":"main","path":"MAINPATH","is_main":true,"is_current":false,
  "working_tree":{},"remote":{"ahead":0,"behind":0}},
 {"kind":"worktree","branch":"feat-clean","path":"/tmp/wt.clean","is_main":false,"is_current":false,
  "working_tree":{"staged":false,"modified":false,"untracked":false},"remote":{"ahead":0,"behind":0}},
 {"kind":"worktree","branch":"feat-dirty","path":"/tmp/wt.dirty","is_main":false,"is_current":false,
  "working_tree":{"modified":true},"remote":{"ahead":0,"behind":0}},
 {"kind":"worktree","branch":"feat-ahead","path":"/tmp/wt.ahead","is_main":false,"is_current":false,
  "working_tree":{},"remote":{"ahead":2,"behind":0}},
 {"kind":"worktree","branch":"feat-current","path":"/tmp/wt.cur","is_main":false,"is_current":true,
  "working_tree":{},"remote":{"ahead":0,"behind":0}}]'

out=$(collect)
d() { jq -r --arg b "$1" '.candidates[] | select(.branch == $b) | .deletable' <<<"$out"; }
r() { jq -r --arg b "$1" '.candidates[] | select(.branch == $b) | .blocked_reasons | join("/")' <<<"$out"; }

# --- 1. clean かつ ahead=0 -> 削除可 ------------------------------------------
check "clean-deletable" "true" "$(d feat-clean)"

# --- 2. dirty -> 保護 ---------------------------------------------------------
check "dirty-blocked" "false" "$(d feat-dirty)"
contains "dirty-reason" "$(r feat-dirty)" "未コミット変更"

# --- 3. ahead>0（マージ後の追加コミット）-> 保護 ------------------------------
check "ahead-blocked" "false" "$(d feat-ahead)"
contains "ahead-reason" "$(r feat-ahead)" "追加コミット 2 件"

# --- 4. is_current（自セッションの作業ディレクトリ）-> 保護 -------------------
check "current-blocked" "false" "$(d feat-current)"
contains "current-reason" "$(r feat-current)" "このセッションの作業ディレクトリ"

# --- 5. main は候補にすら入らない（PR が無いため）-----------------------------
check "main-absent" "" "$(jq -r '.candidates[] | select(.branch == "main") | .branch' <<<"$out")"

# --- 6. worktree もローカルブランチも無いブランチは候補外 ---------------------
check "no-local-absent" "" "$(jq -r '.candidates[] | select(.branch == "feat-no-local") | .branch' <<<"$out")"

# --- 7. tracking issue: 自動クローズ語つきを除外 ------------------------------
issues=$(jq -c '[.followups.tracking_issues[].issue] | sort' <<<"$out")
check "tracking-issues" "[100,300]" "$issues"

# --- 8. MERGED でない PR は not_merged に出て候補にならない -------------------
export PR_ALL_JSON='[{"number":9,"state":"OPEN","title":"open one",
 "headRefName":"feat-clean","baseRefName":"main","url":"u9","body":""}]'
out2=$(collect 9)
check "open-not-candidate" "0" "$(jq '.candidates | length' <<<"$out2")"
check "open-in-not-merged" "OPEN" "$(jq -r '.not_merged[0].state' <<<"$out2")"

# --- 9. 引数指定で対象を絞れる（PR 1 のみ）-----------------------------------
unset PR_ALL_JSON
out3=$(collect 1)
check "arg-scoped-count" "1" "$(jq '.candidates | length' <<<"$out3")"
check "arg-scoped-branch" "feat-clean" "$(jq -r '.candidates[0].branch' <<<"$out3")"

# --- 10. tmux: 完全一致のセッションだけ紐づく ---------------------------------
export TMUX_SESSIONS='feat-clean feat-clean-extra'
out4=$(collect 1)
check "tmux-exact" "feat-clean" "$(jq -r '.candidates[0].tmux_session' <<<"$out4")"

# --- 11. tmux: claude 稼働中は busy=true（既定「残す」の材料）----------------
export TMUX_PANE_CMD='claude'
out5=$(collect 1)
check "tmux-busy" "true" "$(jq -r '.candidates[0].tmux_busy' <<<"$out5")"
export TMUX_PANE_CMD='zsh'
out6=$(collect 1)
check "tmux-idle" "false" "$(jq -r '.candidates[0].tmux_busy' <<<"$out6")"

exit "$fail"
