#!/usr/bin/env bash
# Verifies validate-aggregator-bash.sh (review-aggregator の PreToolUse hook) と、その配線:
#   - スクリプト本体: 統合報告ファイル(basename が review-converge-round-<数字>.md)で、かつ
#                     書き込み先が worktree 内か scratchpad 配下(`..` の遡上は不可)への
#                     リダイレクトのみ許可。それ以外のリダイレクトと書き込み・ビルド系
#                     コマンド(tee / cp / mv / rm / go / cargo / npm / make / nix build) -> exit 2
#                     参照系・スキルのスクリプト(git diff / collect-diff.sh / run-python.sh) -> exit 0
#   - review-aggregator.md の frontmatter にある hook の command 文字列を抽出して実行:
#       (a) CLAUDE_PLUGIN_ROOT 未設定 + $HOME/.claude/skills に配置(nput 配置) -> 解決でき rm が exit 2
#       (b) CLAUDE_PLUGIN_ROOT 未設定 + $HOME が空(スクリプト不在)             -> exit 2 + not found
#       (c) CLAUDE_PLUGIN_ROOT=<repo>/skills/git(plugin 配置)                  -> 解決でき git diff が exit 0
#     不在時に exit 127(非ブロック扱い)で素通しになる退行を固定する。
# command の抽出は YAML として読む(uv も python3 も無い環境では配線テストだけ SKIP)。
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
HOOK="$SCRIPT_DIR/../validate-aggregator-bash.sh"
RUN_PY="$SCRIPT_DIR/../../../diff-review/scripts/run-python.sh" # uv → python3 の順に実行経路を選ぶ
AGENT_MD="$SCRIPT_DIR/../../agents/review-aggregator.md"
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd) # category root(skills/git)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
has() { # label haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "PASS: $(basename "$0")[$1] contains '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] missing '$3'"
        fail=1
    fi
}
# 判定の基準となる worktree はテスト内で用意する。ソースツリーが live な git
# チェックアウトである前提を置くと、checks.hooks の sandbox(.git を持たない
# cp -r コピー)で成立せず許可ケースが軒並み deny に倒れる。
WORKTREE="$WORK/repo"
mkdir -p "$WORKTREE/tmp_claude"
git init -q "$WORKTREE"

payload() { # command [cwd] -> hook 入力 JSON を $WORK/in.json に書く
    printf '{"tool_input": {"command": %s}, "cwd": %s}' \
        "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "${2:-$WORKTREE}" | jq -Rs .)" >| "$WORK/in.json"
}
hook_exit() { # command [cwd] -> スクリプト本体の exit code
    payload "$1" "${2:-}"
    "$HOOK" < "$WORK/in.json" > /dev/null 2>&1
    echo $?
}

# --- (1) 統合報告ファイルへのリダイレクトは許可 ---
# 出力先は basename 一致に加えて worktree / scratchpad 配下であることを要求する
check "report-redirect-allowed" "0" "$(hook_exit "cat body.md > $WORKTREE/tmp_claude/review-converge-round-1.md")"
check "report-append-allowed" "0" "$(hook_exit "echo done >> $WORKTREE/tmp_claude/review-converge-round-12.md")"
# 相対パスは hook 入力の cwd 基準で解決される(cwd が worktree 内なので許可)
check "report-relative-allowed" "0" "$(hook_exit 'printf x >| review-converge-round-3.md')"
# 実運用形: heredoc で本文を書き出す。本文に拒否語の行・markdown の引用行・バッククォートを
# 含めても、データはコマンドとして読まれない(唯一の書き出し経路を塞ぐ退行の固定)
check "report-heredoc-body-allowed" "0" "$(hook_exit "cat > $WORKTREE/tmp_claude/review-converge-round-1.md <<EOF
## レビュー結果
- rm -rf の確認ダイアログがレーンを止める
- make test / nix build は実測検証なので行わない
> 引用行の markdown
\`cp a b\` のようなコマンド引用
EOF")"
check "report-heredoc-quoted-delim-allowed" "0" "$(hook_exit "cat > $WORKTREE/tmp_claude/review-converge-round-2.md <<'EOF'
- nix build の成果物を作らない
EOF")"
# 引用符付き・変数展開の出力先は静的に解決できないので拒否側(安全側)に倒す
check "report-quoted-blocked" "2" "$(hook_exit "cat body.md > \"$WORKTREE/tmp_claude/review-converge-round-1.md\"")"
check "report-variable-blocked" "2" "$(hook_exit 'cat body.md > "$REPORT"')"
# 許可先と拒否先が 1 コマンドに混在するとき、最初の 1 件で打ち切らず全件検査する
check "mixed-redirect-blocked" "2" "$(hook_exit "cat a >| $WORKTREE/tmp_claude/review-converge-round-1.md; echo b > out.txt")"
# basename が一致しても書き込み先が worktree / scratchpad の外なら不可
check "report-in-worktree-allowed" "0" "$(hook_exit "cat a >| $WORKTREE/tmp_claude/review-converge-round-1.md")"
check "report-outside-worktree-blocked" "2" "$(hook_exit 'cat a >| /tmp/evil/review-converge-round-1.md')"
check "report-traversal-blocked" "2" "$(hook_exit 'cat a >| ../../review-converge-round-1.md')"
check "report-abs-traversal-blocked" "2" "$(hook_exit "cat a >| $WORKTREE/../review-converge-round-1.md")"
payload 'cat a >| /tmp/evil/review-converge-round-1.md'
ERR=$("$HOOK" < "$WORK/in.json" 2>&1 > /dev/null)
has "blocked-reason-outside" "$ERR" "worktree"

# scratchpad 配下は worktree 外でも許可する(統合報告の規定の出力先)
SCRATCH="$WORK/scratch"
mkdir -p "$SCRATCH"
payload "cat a >| $SCRATCH/review-converge-round-1.md"
CLAUDE_SCRATCHPAD_DIR="$SCRATCH" "$HOOK" < "$WORK/in.json" > /dev/null 2>&1
check "report-in-scratchpad-allowed" "0" "$?"
# 同じパスでも scratchpad の指定が無ければ worktree 外として拒否する
check "report-scratchpad-unset-blocked" "2" "$(hook_exit "cat a >| $SCRATCH/review-converge-round-1.md")"

# 実運用の経路: worktree 内の tmp_claude が primary リポジトリへの symlink でも許可する
# (worktree では symlink で配置される。前方一致は字句同士で行い symlink を
#  辿らないため、実体が worktree 外にあっても許可される)
PRIMARY="$WORK/primary-tmp"
mkdir -p "$PRIMARY"
LINKED="$WORK/repo-linked"
git init -q "$LINKED"
ln -s "$PRIMARY" "$LINKED/tmp_claude"
check "report-symlinked-tmp-claude-allowed" "0" \
    "$(hook_exit "cat a >| $LINKED/tmp_claude/review-converge-round-1.md" "$LINKED")"

# worktree root より上に symlink がある配置(git rev-parse は実体を返す)でも許可する
ABOVE="$WORK/above"
mkdir -p "$ABOVE/real"
ln -s "$ABOVE/real" "$ABOVE/link"
git init -q "$ABOVE/real/repo"
# tmp_claude は作らない。hook はコマンド実行前に走るので出力先は未作成であり、
# 先に作ると実在を前提にした解決でも通ってしまい退行を検知できない
check "report-symlink-above-root-allowed" "0" \
    "$(hook_exit "cat a >| $ABOVE/link/repo/tmp_claude/review-converge-round-1.md" "$ABOVE/link/repo")"

# above-root symlink と worktree 内 tmp_claude の外向き symlink が同時に成立する配置
BOTH="$WORK/both"
mkdir -p "$BOTH/real" "$BOTH/outside"
ln -s "$BOTH/real" "$BOTH/link"
git init -q "$BOTH/real/repo"
ln -s "$BOTH/outside" "$BOTH/real/repo/tmp_claude"
check "report-symlink-both-directions-allowed" "0" \
    "$(hook_exit "cat a >| $BOTH/link/repo/tmp_claude/review-converge-round-1.md" "$BOTH/link/repo")"

# git リポジトリ外で走ったときは worktree を解決できず、安全側で拒否する
check "report-outside-git-blocked" "2" "$(hook_exit "cat a >| $WORK/review-converge-round-1.md" "$WORK")"

# 引用無しの変数展開も静的に解決できないので拒否する(引用付きとは通過経路が別)
check "report-unquoted-variable-blocked" "2" "$(hook_exit 'cat body.md > $DIR/review-converge-round-1.md')"

# heredoc 演算子がリダイレクトより前に来る語順でも同じく許可される
check "report-heredoc-first-allowed" "0" "$(hook_exit "cat <<EOF > $WORKTREE/tmp_claude/review-converge-round-4.md
- rm や nix build の説明を含む本文
EOF")"

# --- (2) それ以外のリダイレクトと書き込み・ビルド系コマンドは拒否 ---
check "other-redirect-blocked" "2" "$(hook_exit 'git diff > out.txt')"
check "report-no-number-blocked" "2" "$(hook_exit 'echo x > review-converge-round-.md')"
check "report-wrongname-blocked" "2" "$(hook_exit 'echo x > review-converge-round-1.txt')"
check "tee-blocked" "2" "$(hook_exit 'cat a | tee b')"
check "cp-blocked" "2" "$(hook_exit 'cp a b')"
check "mv-blocked" "2" "$(hook_exit 'mv a b')"
check "rm-blocked" "2" "$(hook_exit 'rm -rf x')"
check "go-blocked" "2" "$(hook_exit 'go test ./...')"
check "cargo-blocked" "2" "$(hook_exit 'cargo build')"
check "npm-blocked" "2" "$(hook_exit 'npm run build')"
check "make-blocked" "2" "$(hook_exit 'make test')"
check "nix-build-blocked" "2" "$(hook_exit 'nix build .#foo')"
check "chained-rm-blocked" "2" "$(hook_exit 'git status && rm x')"

payload 'rm x'
ERR=$("$HOOK" < "$WORK/in.json" 2>&1 > /dev/null)
has "blocked-reason-command" "$ERR" "Blocked"
has "blocked-reason-rm" "$ERR" "rm"

payload 'git diff > out.txt'
ERR=$("$HOOK" < "$WORK/in.json" 2>&1 > /dev/null)
has "blocked-reason-redirect" "$ERR" "Blocked"
has "blocked-reason-redirect-target" "$ERR" "out.txt"

payload 'nix build .#foo'
ERR=$("$HOOK" < "$WORK/in.json" 2>&1 > /dev/null)
has "blocked-reason-nix" "$ERR" "Blocked"
has "blocked-reason-nix-build" "$ERR" "nix build"

# 検索パターン内の > はリダイレクトではない(引用の中身をコマンドと読まない)
check "quoted-pattern-allowed" "0" "$(hook_exit 'rg -n "a>b" src')"

# --- (3) 参照系・スキルのスクリプトは許可 ---
check "git-diff-allowed" "0" "$(hook_exit 'git diff HEAD~1')"
check "collect-diff-allowed" "0" "$(hook_exit "$PLUGIN_ROOT/diff-review/scripts/collect-diff.sh manifest")"
check "run-python-allowed" "0" "$(hook_exit "$PLUGIN_ROOT/diff-review/scripts/run-python.sh collect_conventions.py")"
check "stderr-devnull-allowed" "0" "$(hook_exit 'git log -1 2>/dev/null')"
check "nix-flake-check-allowed" "0" "$(hook_exit 'nix flake check')"

# --- frontmatter の command(配線) ---
if ! command -v uv > /dev/null 2>&1 && ! command -v python3 > /dev/null 2>&1; then
    echo "SKIP: $(basename "$0")[wiring] uv も python3 も無い環境のためスキップ"
    [ "$fail" -eq 0 ]
    exit
fi

CMD=$("$RUN_PY" -c '
import sys, frontmatter
hooks = frontmatter.load(sys.argv[1])["hooks"]["PreToolUse"]
print(next(h["command"] for m in hooks if m["matcher"] == "Bash" for h in m["hooks"]))
' "$AGENT_MD")
has "command-extracted" "$CMD" "validate-aggregator-bash.sh"

# プレースホルダ置換に依存しない書き方であること(plugin 無効の配置では置換されず未設定のまま走る)
case "$CMD" in
    *'${CLAUDE_PLUGIN_ROOT}'*) check "no-placeholder-literal" "absent" "present" ;;
    *) check "no-placeholder-literal" "absent" "absent" ;;
esac

wired() { # label expected-exit command [env 代入...] -> exit code を検査し stderr を WIRED_ERR に残す
    local label="$1" expected="$2" cmd="$3"
    shift 3
    payload "$cmd"
    WIRED_ERR=$(env -u CLAUDE_PLUGIN_ROOT "$@" sh -c "$CMD" < "$WORK/in.json" 2>&1 > /dev/null)
    check "$label" "$expected" "$?"
}

# (a) nput 配置: $HOME/.claude/skills/review-converge/scripts/ にスクリプトがある
HOME_OK="$WORK/home-ok"
mkdir -p "$HOME_OK/.claude/skills/review-converge/scripts"
cp "$HOOK" "$HOME_OK/.claude/skills/review-converge/scripts/"
wired "home-resolves-rm" "2" 'rm x' HOME="$HOME_OK"
has "home-resolves-reason" "$WIRED_ERR" "Blocked"
wired "home-resolves-git-diff" "0" 'git diff' HOME="$HOME_OK"

# (b) スクリプト不在: 127 で素通しにせず exit 2 で倒れる
HOME_EMPTY="$WORK/home-empty"
mkdir -p "$HOME_EMPTY"
wired "missing-blocks" "2" 'git diff' HOME="$HOME_EMPTY"
has "missing-reason" "$WIRED_ERR" "not found"

# (c) plugin 配置: CLAUDE_PLUGIN_ROOT(category root)が優先して解決される
wired "plugin-root-git-diff" "0" 'git diff' HOME="$HOME_EMPTY" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
wired "plugin-root-rm" "2" 'rm x' HOME="$HOME_EMPTY" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

[ "$fail" -eq 0 ]
