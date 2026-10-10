#!/usr/bin/env bash
# collect-merge-state.sh の検証。
# gh は実ネットワークを叩くため、PATH 先頭に置いた stub で固定応答に差し替える。
# 検証対象は「どの候補を deletable から外すか」の判定ロジック:
#   - dirty / ahead>0 / is_main / is_current は deletable=false + 理由付き
#   - clean かつ ahead=0 の worktree は deletable=true
#   - MERGED でない PR は候補に入れず not_merged に出す
#   - worktree もローカルブランチも無いブランチは候補にしない
#   - tracking issue は自動クローズ語（Closes/Fixes/Resolves）付きを除外する
#   - PR 本文の合計が 1 引数の上限（128KiB）を超えても落ちない
#   - herdr の pane が cwd / foreground_cwd に持つ worktree は deletable=false + 理由付き
#     （agent_status を問わない / パス境界で突合 / HERDR_ENV が無ければ判定を省く）
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COLLECT="$SCRIPT_DIR/../collect-merge-state.sh"

# 依存が欠けたまま走ると「何も出力せず exit 0」＝素通りになるため、先に確かめて
# 明示的にスキップを宣言する（沈黙は CI 上で検知できない）。
for dep in jq git; do
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

# --- stub: gh / wt / tmux / herdr ---------------------------------------------
# 実バイナリを呼ばせないよう PATH を差し替える。jq/git/bash は実物を使う。
stub="$TMP/bin"
mkdir -p "$stub"

# stub の shebang は実行中の bash の絶対パスで書く。checked-in の *.sh は
# patchShebangs が nix store の bash へ書き換えてくれるが、ここで実行時に
# 生成する stub は対象外で、Nix sandbox には /usr/bin/env が無いため
# `#!/usr/bin/env bash` のままだと exit 126 になる。
stub_bash=$(command -v bash)

cat >"$stub/gh" <<EOF
#!$stub_bash
EOF
cat >>"$stub/gh" <<'EOF'
# gh pr list --state merged ... -> PR_LIST_JSON
# gh pr list --state open --base ... -> 空（stacked 子なし）
# gh pr view N ... -> PR_VIEW_JSON から該当を返す
set -euo pipefail
args="$*"
case "$args" in
  *"--state open"*) echo '[]' ;;
  *"--state merged"*)
      # 大きな応答は環境変数に載らない（1 引数・1 環境変数の上限）のでファイルからも受ける
      if [ -n "${PR_LIST_FILE:-}" ]; then cat "$PR_LIST_FILE"; else printf '%s' "${PR_LIST_JSON:-[]}"; fi ;;
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
#!$stub_bash
EOF
cat >>"$stub/wt" <<'EOF'
set -euo pipefail
case "$*" in
  *"list"*) printf '%s' "${WT_LIST_JSON:-[]}" ;;
  *) exit 0 ;;
esac
EOF

cat >"$stub/tmux" <<EOF
#!$stub_bash
EOF
cat >>"$stub/tmux" <<'EOF'
set -euo pipefail
case "$1" in
  ls) printf '%s\n' ${TMUX_SESSIONS:-} ;;
  list-panes) printf '%s\n' "${TMUX_PANE_CMD:-zsh}" ;;
  *) exit 0 ;;
esac
EOF
# herdr agent list -> HERDR_AGENTS_JSON を .result.agents に包んで返す。
# HERDR_FAIL=1 なら失敗（サーバ不在などの再現）。
cat >"$stub/herdr" <<EOF
#!$stub_bash
EOF
cat >>"$stub/herdr" <<'EOF'
set -euo pipefail
[ "${HERDR_FAIL:-}" = 1 ] && exit 1
case "$*" in
  "agent list") printf '{"id":"cli:agent:list","result":{"agents":%s,"type":"agent_list"}}' "${HERDR_AGENTS_JSON:-[]}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$stub"/*

# 実行元の環境（herdr 管理下の pane）を持ち込まない。herdr の判定は 13 以降で明示的に有効化する。
unset HERDR_ENV

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

# --- 12. 引数なし: PR 本文の合計が 128KiB を超えても落ちない -------------------
# 回帰: 最後の jq へ merged_prs を --argjson で渡していた頃は "Argument list too long" で落ちた
export PR_LIST_FILE="$TMP/large-prs.json"
jq -n '[range(1; 31) | {number: ., state: "MERGED", title: "t\(.)",
    headRefName: (if . == 1 then "feat-clean" else "gone-\(.)" end), baseRefName: "main",
    url: "u\(.)", body: ("x" * 8192)}]' >"$PR_LIST_FILE"
out7=$(collect)
check "large-bodies-merged-count" "30" "$(jq '.merged_prs | length' <<<"$out7")"
check "large-bodies-candidate" "feat-clean" "$(jq -r '.candidates[0].branch' <<<"$out7")"
unset PR_LIST_FILE

# --- 13. herdr: pane の cwd が worktree と一致 -> 保護（status は問わない）----------
# 回帰: 2026-10-10 に herdr pane で claude が使用中の worktree が deletable=true と判定された
export HERDR_ENV=1
export HERDR_AGENTS_JSON='[{"pane_id":"w2X:p3","agent":"claude","agent_status":"idle",
  "cwd":"/tmp/wt.clean","foreground_cwd":"/tmp/wt.clean"}]'
out8=$(collect 1)
check "herdr-tooling" "true" "$(jq -r '.tooling.herdr' <<<"$out8")"
check "herdr-blocked" "false" "$(jq -r '.candidates[0].deletable' <<<"$out8")"
contains "herdr-reason" "$(jq -r '.candidates[0].blocked_reasons | join("/")' <<<"$out8")" \
    "herdr pane w2X:p3 で claude 稼働中（idle）"
check "herdr-panes" '[{"pane_id":"w2X:p3","agent":"claude","agent_status":"idle"}]' \
    "$(jq -c '.candidates[0].herdr_panes' <<<"$out8")"

# --- 14. herdr: パス境界で突合（配下は一致、同じ接頭辞の別ディレクトリは不一致）------
export HERDR_AGENTS_JSON='[
 {"pane_id":"w1:p1","agent":"claude","agent_status":"working",
  "cwd":"/tmp/wt.clean-extra","foreground_cwd":"/tmp/wt.clean-extra"},
 {"pane_id":"w1:p2","agent":"codex","agent_status":"working",
  "cwd":"/tmp/wt.clean/sub/dir","foreground_cwd":"/tmp/wt.clean/sub/dir"}]'
out9=$(collect 1)
check "herdr-boundary-panes" '["w1:p2"]' "$(jq -c '[.candidates[0].herdr_panes[].pane_id]' <<<"$out9")"
check "herdr-boundary-blocked" "false" "$(jq -r '.candidates[0].deletable' <<<"$out9")"

# --- 15. herdr: foreground_cwd だけが配下でも保護（cwd は別の場所）-------------------
export HERDR_AGENTS_JSON='[{"pane_id":"w1:p9","agent":"claude","agent_status":"working",
  "cwd":"/somewhere/else","foreground_cwd":"/tmp/wt.clean/"}]'
out10=$(collect 1)
check "herdr-foreground-blocked" "false" "$(jq -r '.candidates[0].deletable' <<<"$out10")"
check "herdr-foreground-panes" '["w1:p9"]' "$(jq -c '[.candidates[0].herdr_panes[].pane_id]' <<<"$out10")"

# --- 16. herdr: 一致する pane が無ければ削除可のまま --------------------------------
export HERDR_AGENTS_JSON='[{"pane_id":"w1:p1","agent":"claude","agent_status":"working",
  "cwd":"/tmp/other","foreground_cwd":"/tmp/other"}]'
out11=$(collect 1)
check "herdr-nomatch-deletable" "true" "$(jq -r '.candidates[0].deletable' <<<"$out11")"
check "herdr-nomatch-panes" "[]" "$(jq -c '.candidates[0].herdr_panes' <<<"$out11")"

# --- 17. HERDR_ENV が無ければ判定を省く（素通し・tooling.herdr=false）----------------
export HERDR_AGENTS_JSON='[{"pane_id":"w2X:p3","agent":"claude","agent_status":"working",
  "cwd":"/tmp/wt.clean","foreground_cwd":"/tmp/wt.clean"}]'
unset HERDR_ENV
out12=$(collect 1)
check "herdr-noenv-tooling" "false" "$(jq -r '.tooling.herdr' <<<"$out12")"
check "herdr-noenv-deletable" "true" "$(jq -r '.candidates[0].deletable' <<<"$out12")"

# --- 18. herdr agent list が失敗しても落ちず、判定していないことを示す ----------------
export HERDR_ENV=1 HERDR_FAIL=1
out13=$(collect 1)
check "herdr-fail-tooling" "false" "$(jq -r '.tooling.herdr' <<<"$out13")"
check "herdr-fail-deletable" "true" "$(jq -r '.candidates[0].deletable' <<<"$out13")"
unset HERDR_ENV HERDR_FAIL HERDR_AGENTS_JSON

exit "$fail"
