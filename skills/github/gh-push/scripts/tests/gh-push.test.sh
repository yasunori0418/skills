#!/usr/bin/env bash
# gh-push.sh の SSH 経路をハーメティックに検証する（ネットワーク・実 SSH 鍵なし）。
#
# 仕組み: remote URL を ssh://git@fake-host/<bare repo の絶対パス> にし、PATH の
# 先頭へ偽 ssh を置く。git の ssh transport は
#   ssh <host> "git-upload-pack '<path>'"
# の形で起動するので、偽 ssh が末尾のコマンド文字列だけをローカル実行すれば
# ls-remote / push が実リポジトリ相手に成立する。BatchMode 等のオプションは
# 偽 ssh 側で読み捨てる。
#
# 検証内容:
#   - ブランチ 1 本のリポジトリ           -> preflight が exit 0 でセクションを出す
#   - ブランチ 3000 本のリポジトリ         -> exit 0（回帰: ls-remote 出力を早期 exit する
#     フィルタへパイプしていた頃は SIGPIPE で exit 141・出力ゼロになった）
#   - リモートに無いブランチ               -> state=new
#   - fast-forward                        -> 送るコミットが列挙される
#   - 履歴分岐 + force 無しの push         -> ERROR で停止
#   - 保護ブランチへの force               -> ERROR で停止
#   - --expect がリモート実測と不一致      -> ERROR で停止
#   - force push（作業ブランチ・lease 一致）-> 成功しリモート tip が進む
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GH_PUSH="$SCRIPT_DIR/../gh-push.sh"

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

# --- 偽 ssh: 最後の引数（リモートで実行されるコマンド）だけをローカルで実行する ---
# shebang は実行中の bash の絶対パスを焼き込む。テスト実行時に生成するファイルは
# nix の patchShebangs が通らないため、sandbox に無い /usr/bin/env は使えない。
mkdir -p "$WORK/bin"
{
    printf '#!%s\n' "$BASH"
    cat <<'EOF'
# 引数末尾が git-upload-pack / git-receive-pack のコマンド文字列。
# host より前の -o オプション等は読み捨てる。
# コマンド文字列はクォートを含むシェル構文なので -c で解釈させる。
cmd="${!#}"
exec "$BASH" -c "$cmd"
EOF
} >"$WORK/bin/ssh"
chmod +x "$WORK/bin/ssh"
PATH="$WORK/bin:$PATH"
export PATH

git_init() { # dir
    git -C "$1" config user.email "test@example.com"
    git -C "$1" config user.name "test"
    git -C "$1" config commit.gpgsign false
}

# bare リモート + それを ssh:// で参照する作業リポジトリを作る。
# 作業ブランチ名は $3（既定 feat）。
#
# $2 に本数を渡すとリモート側にその数だけダミーブランチを追加する。これは
# SIGPIPE 回帰（exit 141・出力ゼロ）を検出するための仕掛け: ls-remote は ref 名の
# 辞書順で出力するので、ダミー名を "zz/..." にして対象ブランチより後ろへ回すと、
# 対象行にマッチして早期 exit する抽出フィルタの下流が閉じた時点で上流に
# 数百KB の未書き込みデータが残り、パイプバッファ（64KB）を超えて
# SIGPIPE が確実に起きる。出力サイズだけでなく「未読データが残る配置」が要点。
new_pair() { # dir [extra_branches] [branch]
    local d="$1" extra="${2:-0}" br="${3:-feat}"
    mkdir -p "$d"
    git init --quiet --bare "$d/remote.git"
    git init --quiet --initial-branch=main "$d/work"
    git_init "$d/work"
    echo "base" >"$d/work/README.md"
    git -C "$d/work" add -A
    git -C "$d/work" commit --quiet -m "chore: init"
    git -C "$d/work" remote add origin "ssh://git@fake-host$d/remote.git"
    git -C "$d/work" push --quiet origin main
    git -C "$d/work" checkout --quiet -b "$br"
    if [ "$extra" -gt 0 ]; then
        # bare 側へ直接 ref を打つ（ネットワーク往復もコミット生成も不要）。
        local sha i
        sha="$(git -C "$d/work" rev-parse main)"
        {
            # 対象ブランチをリモートにも作る（tip 抽出でマッチさせる）。
            printf 'create refs/heads/%s %s\n' "$br" "$sha"
            for ((i = 0; i < extra; i++)); do
                printf 'create refs/heads/zz/%s-%04d %s\n' \
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$i" "$sha"
            done
        } | git -C "$d/remote.git" update-ref --stdin
    fi
}

commit_on() { # dir msg
    echo "$2" >>"$1/README.md"
    git -C "$1" add -A
    git -C "$1" commit --quiet -m "$2"
}

# 出力を $OUT、終了コードを $RC に入れる（コマンド置換ではサブシェルの $? が
# 親へ伝わらないため、戻り値ではなくグローバル変数で受け渡す）。
OUT=""
RC=0
run() { # dir args...
    local d="$1"
    shift
    OUT="$(cd "$d" && bash "$GH_PUSH" "$@" 2>&1)"
    RC=$?
}

# --- ブランチ 1 本: 通常動作 ---
D="$WORK/small" && new_pair "$D"
commit_on "$D/work" "feat: a"
run "$D/work" preflight
check "small-exit" 0 "$RC"
has "small-route" "$OUT" "route:      SSH"
has "small-auth" "$OUT" "SSH 認証テスト: 成功"
has "small-state-new" "$OUT" "remote state: new"

# --- ブランチ 3000 本: 回帰（旧実装はここで exit 141・出力ゼロ） ---
# 対象ブランチ名を "aaa-target" にして ls-remote 出力の先頭側へ置き、ダミー
# "zz/..." を後ろへ回す（new_pair のコメント参照）。
D="$WORK/huge" && new_pair "$D" 3000 "aaa-target"
commit_on "$D/work" "feat: a"
run "$D/work" preflight
check "huge-exit" 0 "$RC"
has "huge-not-empty" "$OUT" "=== TARGET ==="
has "huge-route" "$OUT" "route:      SSH"
# リモート tip を正しく抽出できていること（SIGPIPE で空になっていない）。
has "huge-state" "$OUT" "remote state: fast-forward"

# --- fast-forward: 送るコミットが出る ---
D="$WORK/ff" && new_pair "$D"
commit_on "$D/work" "feat: first"
run "$D/work" push
check "ff-push-exit" 0 "$RC"
commit_on "$D/work" "feat: second"
run "$D/work" preflight
check "ff-exit" 0 "$RC"
has "ff-state" "$OUT" "remote state: fast-forward"
has "ff-commit" "$OUT" "feat: second"

# --- up-to-date ---
run "$D/work" push
run "$D/work" preflight
has "uptodate-state" "$OUT" "remote state: up-to-date"

# --- 履歴分岐: force 無しの push は停止 ---
D="$WORK/div" && new_pair "$D"
commit_on "$D/work" "feat: orig"
run "$D/work" push
ORIG_TIP="$(git -C "$D/work" rev-parse HEAD)"
git -C "$D/work" reset --quiet --hard HEAD~1
commit_on "$D/work" "feat: rewritten"
run "$D/work" preflight
has "div-state" "$OUT" "remote state: diverged"
run "$D/work" push
check "div-noforce-exit" 1 "$RC"
has "div-noforce-msg" "$OUT" "履歴が分岐しています"

# --- --expect がリモート実測と不一致: 停止 ---
run "$D/work" push --force --expect=0000000000000000000000000000000000000000
check "expect-mismatch-exit" 1 "$RC"
has "expect-mismatch-msg" "$OUT" "と不一致"

# --- force push（lease 一致）: 成功しリモートが進む ---
NEW_TIP="$(git -C "$D/work" rev-parse HEAD)"
run "$D/work" push --force --expect="$ORIG_TIP"
check "force-exit" 0 "$RC"
has "force-ok" "$OUT" "OK: [ssh]"
check "force-remote-tip" "$NEW_TIP" "$(git -C "$D/remote.git" rev-parse refs/heads/feat)"

# --- 保護ブランチへの force: 拒否 ---
D="$WORK/prot" && new_pair "$D"
git -C "$D/work" checkout --quiet main
commit_on "$D/work" "feat: on main"
run "$D/work" push main --force
check "protected-exit" 1 "$RC"
has "protected-msg" "$OUT" "保護ブランチ"

exit $fail
