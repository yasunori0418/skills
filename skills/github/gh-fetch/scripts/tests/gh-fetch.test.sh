#!/usr/bin/env bash
# gh-fetch.sh の SSH 経路をハーメティックに検証する（ネットワーク・実 SSH 鍵なし）。
#
# 仕組み: remote URL を ssh://git@fake-host/<bare repo の絶対パス> にし、PATH の
# 先頭へ偽 ssh を置く。git の ssh transport は
#   ssh <host> "git-upload-pack '<path>'"
# の形で起動するので、偽 ssh が末尾のコマンド文字列だけをローカル実行すれば
# ls-remote / fetch が実リポジトリ相手に成立する。BatchMode 等のオプションは
# 偽 ssh 側で読み捨てる。
#
# 検証内容:
#   - ブランチ 1 本のリポジトリ     -> preflight が exit 0 でセクションを出す
#   - ブランチ 3000 本のリポジトリ   -> exit 0（回帰: ls-remote 出力を早期 exit する
#     フィルタへパイプしていた頃は SIGPIPE で exit 141・出力ゼロになった）
#   - リモートが先行               -> behind と判定し fetch/pull で取り込める
#   - 履歴分岐 + --ff-only の pull  -> ERROR で停止
#   - dirty な作業ツリーでの pull   -> ERROR で停止（fetch は可）
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GH_FETCH="$SCRIPT_DIR/../gh-fetch.sh"

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

# bare リモート + それを ssh:// で参照する作業リポジトリ 2 つ（work / other）を作る。
# other は「他者の push」を模してリモートを進めるために使う。作業ブランチ名は $3（既定 feat）。
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
    git -C "$d/work" push --quiet origin "$br"
    if [ "$extra" -gt 0 ]; then
        # bare 側へ直接 ref を打つ（ネットワーク往復もコミット生成も不要）。
        local sha i
        sha="$(git -C "$d/work" rev-parse main)"
        for ((i = 0; i < extra; i++)); do
            printf 'create refs/heads/zz/%s-%04d %s\n' \
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$i" "$sha"
        done | git -C "$d/remote.git" update-ref --stdin
    fi
}

commit_on() { # dir msg
    echo "$2" >>"$1/README.md"
    git -C "$1" add -A
    git -C "$1" commit --quiet -m "$2"
}

# 別クローン経由でリモートを 1 コミット進める（他者の push を模す）。
advance_remote() { # dir branch msg
    local d="$1" br="$2" msg="$3"
    if [ ! -d "$d/other" ]; then
        git clone --quiet "$d/remote.git" "$d/other"
        git_init "$d/other"
    fi
    git -C "$d/other" checkout --quiet "$br"
    git -C "$d/other" pull --quiet --ff-only origin "$br"
    commit_on "$d/other" "$msg"
    git -C "$d/other" push --quiet origin "$br"
}

# 出力を $OUT、終了コードを $RC に入れる（コマンド置換ではサブシェルの $? が
# 親へ伝わらないため、戻り値ではなくグローバル変数で受け渡す）。
OUT=""
RC=0
run() { # dir args...
    local d="$1"
    shift
    OUT="$(cd "$d" && bash "$GH_FETCH" "$@" 2>&1)"
    RC=$?
}

# --- ブランチ 1 本: 通常動作 ---
D="$WORK/small" && new_pair "$D"
run "$D/work" preflight
check "small-exit" 0 "$RC"
has "small-route" "$OUT" "route:      SSH"
has "small-auth" "$OUT" "SSH 認証テスト: 成功"
has "small-uptodate" "$OUT" "incoming:     up-to-date"

# --- ブランチ 3000 本: 回帰（旧実装はここで exit 141・出力ゼロ） ---
# 対象ブランチ名を "aaa-target" にして ls-remote 出力の先頭側へ置き、ダミー
# "zz/..." を後ろへ回す（new_pair のコメント参照）。
D="$WORK/huge" && new_pair "$D" 3000 "aaa-target"
run "$D/work" preflight
check "huge-exit" 0 "$RC"
has "huge-not-empty" "$OUT" "=== TARGET ==="
has "huge-route" "$OUT" "route:      SSH"
# リモート tip を正しく抽出できていること（SIGPIPE で空になっていない）。
has "huge-tip" "$OUT" "remote tip:   $(git -C "$D/work" rev-parse HEAD)"

# --- リモートが先行: behind → fetch → pull で取り込める ---
D="$WORK/behind" && new_pair "$D"
advance_remote "$D" feat "feat: from other"
run "$D/work" preflight
check "behind-exit" 0 "$RC"
# リモートの新コミットはローカル object DB に無いので fetchable（fetch 後に FF 確定）。
has "behind-state" "$OUT" "incoming:     fetchable"
run "$D/work" fetch
check "fetch-exit" 0 "$RC"
has "fetch-ok" "$OUT" "OK: [ssh]"
run "$D/work" pull
check "pull-exit" 0 "$RC"
check "pull-merged" "feat: from other" "$(git -C "$D/work" log -1 --format=%s)"

# --- 履歴分岐 + --ff-only: 停止 ---
D="$WORK/div" && new_pair "$D"
advance_remote "$D" feat "feat: from other"
commit_on "$D/work" "feat: local only"
run "$D/work" pull
check "div-ffonly-exit" 1 "$RC"
has "div-ffonly-msg" "$OUT" "fast-forward できません"

# --- dirty な作業ツリー: pull は停止、fetch は通る ---
D="$WORK/dirty" && new_pair "$D"
advance_remote "$D" feat "feat: from other"
echo "uncommitted" >>"$D/work/README.md"
run "$D/work" pull
check "dirty-pull-exit" 1 "$RC"
has "dirty-pull-msg" "$OUT" "未コミット変更があります"
run "$D/work" fetch
check "dirty-fetch-exit" 0 "$RC"
has "dirty-fetch-ok" "$OUT" "OK: [ssh]"

exit $fail
