#!/usr/bin/env bash
# pr-visualize.sh をハーメティックに検証する（ネットワーク・実 gh・実 mmdc なし）。
#
# 仕組み: PATH の先頭へ偽 gh を置き、用意した JSON を jq で整形して返させる（gh の --jq を
# jq -r で代用する）。呼び出しは $FAKE_GH_LOG に記録し、投稿本文は $FAKE_GH_DIR/posted.md へ
# 写す。head の取得は url.insteadOf でローカルの bare リポジトリへ向ける。
#
# 検証内容:
#   - parse          URL / #N / pr:N / N / GHE の URL / 解釈できない入力
#   - preflight      remote 一致 -> mode: full（https / scp 形式 / ssh:// 形式）、不一致 -> degraded、
#                    lockfile の excluded 表示、mmdc の有無
#   - stack          スタックの並びと現在の段、各段の変更ファイル、図（現在の段だけ強調・記号は文字参照）、
#                    スタックでない PR、スタックの情報を取得できない GitHub
#   - diff           lockfile の差分本文を落としてファイルへ退避、--out 必須
#   - fetch          refs/pull/N/head を ref を作らず取得し head/base の sha を出す、degraded は拒否
#   - mermaid-check  mmdc なし -> UNVERIFIED(exit 0)、全通過 -> OK、構文エラー -> FAIL(exit 1)と行番号、
#                    ログなしの失敗でも残りの図を検証する、図の文言では誤判定しない、図なし -> NO DIAGRAMS
#   - comment        dry-run は投稿しない（--out で投稿される本文を書き出す）、新規は POST、目印付きの自分のコメントがあれば PATCH、
#                    最初の図と同じ節の図は開いたまま、以降の節の図を <details> に畳む、承認後に本文が変われば拒否、
#                    上限超過は拒否（バイト数ではなく文字数で数える）、degraded は拒否
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PRV="$SCRIPT_DIR/../pr-visualize.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 実環境の git 設定に左右されないよう隔離する
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/xdg" GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
: >"$GIT_CONFIG_GLOBAL"

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
lacks() { # label haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "FAIL: $(basename "$0")[$1] unexpectedly contains '$3'"
        fail=1
    else
        echo "PASS: $(basename "$0")[$1] lacks '$3'"
    fi
}
run() { # 標準出力と標準エラーをまとめて OUT へ、終了コードを RC へ
    OUT=$(bash "$PRV" "$@" 2>&1)
    RC=$?
}
cg() { git -c user.name=t -c user.email=t@t "$@"; }

# --- 偽 gh / 偽 mmdc ---
# shebang は実行中の bash の絶対パスを焼き込む（テスト時に生成するファイルには nix の
# patchShebangs が通らず、sandbox に /usr/bin/env が無いため）。
export FAKE_GH_DIR="$WORK/gh" FAKE_GH_LOG="$WORK/gh.log"
mkdir -p "$WORK/bin" "$FAKE_GH_DIR"
{
    printf '#!%s\n' "$BASH"
    cat <<'EOS'
echo "gh $*" >>"$FAKE_GH_LOG"
jqexpr="" method="GET" endpoint="" bodyfile="" prev=""
for a in "$@"; do
    case "$prev" in
        --jq) jqexpr="$a" ;;
        -X) method="$a" ;;
        -F) bodyfile="${a#body=@}" ;;
        --hostname | -R | --json) ;;
        *) case "$a" in repos/* | user | graphql) endpoint="$a" ;; esac ;;
    esac
    prev="$a"
done
out() { if [ -n "$jqexpr" ]; then jq -r "$jqexpr"; else cat; fi; }
case "$1 $2" in
    "pr view") out <"$FAKE_GH_DIR/pr.json" ;;
    "pr diff") cat "$FAKE_GH_DIR/pr.diff" ;;
    "api "*)
        case "$method $endpoint" in
            "GET user") echo '{"login":"me"}' | out ;;
            "GET graphql")
                [ -f "$FAKE_GH_DIR/stack.json" ] || exit 1 # スタックの項目が無い GitHub を模す
                out <"$FAKE_GH_DIR/stack.json"
                ;;
            "GET repos/"*"/comments") out <"$FAKE_GH_DIR/comments.json" ;;
            "POST repos/"* | "PATCH repos/"*)
                cp "$bodyfile" "$FAKE_GH_DIR/posted.md"
                echo '{"html_url":"https://github.com/o/r/pull/7#issuecomment-1"}' | out
                ;;
            *) echo "fake gh: unexpected api call: $*" >&2; exit 1 ;;
        esac
        ;;
    *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
EOS
} >"$WORK/bin/gh"
{
    printf '#!%s\n' "$BASH"
    cat <<'EOS'
in="" out="" prev=""
for a in "$@"; do
    case "$prev" in -i) in="$a" ;; -o) out="$a" ;; esac
    prev="$a"
done
if grep -q BROKEN "$in"; then
    echo "Error: Parse error on line 2:" >&2
    exit 1
fi
grep -q SILENT "$in" && exit 0 # 何も出力せず正常終了する失敗
echo "<svg/>" >"$out"
EOS
} >"$WORK/bin/mmdc"
chmod +x "$WORK/bin/gh" "$WORK/bin/mmdc"
export PATH="$WORK/bin:$PATH"
NO_MMDC="$WORK/no-such-dir/mmdc"

# --- リポジトリ: base(main) と PR の head。head は bare 側の refs/pull/7/head からしか辿れない ---
cg init -q -b main "$WORK/up"
mkdir -p "$WORK/up/src"
printf 'def foo(x):\n    return x\n' >"$WORK/up/src/foo.py"
cg -C "$WORK/up" add -A && cg -C "$WORK/up" commit -q -m base
BASE_SHA=$(git -C "$WORK/up" rev-parse HEAD)
cg -C "$WORK/up" switch -q -c feat/foo
printf 'def foo(x):\n    return x + 1\n' >"$WORK/up/src/foo.py"
cg -C "$WORK/up" commit -q -am change
HEAD_SHA=$(git -C "$WORK/up" rev-parse HEAD)
cg -C "$WORK/up" switch -q main
git clone -q --bare "$WORK/up" "$WORK/bare.git"
git -C "$WORK/bare.git" update-ref refs/pull/7/head "$HEAD_SHA"
git -C "$WORK/bare.git" update-ref -d refs/heads/feat/foo

new_clone() { # dir remote-url
    # file:// で transport を通す（パス指定の clone はオブジェクトを丸ごと写すため、
    # 「head は未取得」の前提が作れない）
    git clone -q "file://$WORK/bare.git" "$1"
    git -C "$1" remote set-url origin "$2"
    git -C "$1" config "url.file://$WORK/bare.git.insteadOf" "https://github.com/o/r.git"
}
new_clone "$WORK/work" "https://github.com/o/r.git"
new_clone "$WORK/other" "https://github.com/someone/else.git"

cat >"$FAKE_GH_DIR/pr.json" <<EOS
{"number":7,"url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":true,
 "author":{"login":"alice"},"title":"feat: foo を加算に変える","body":"本文の一行目\n二行目",
 "baseRefName":"main","baseRefOid":"$BASE_SHA","headRefName":"feat/foo","headRefOid":"$HEAD_SHA",
 "additions":3,"deletions":1,
 "files":[{"path":"src/foo.py","additions":1,"deletions":1},{"path":"uv.lock","additions":2,"deletions":0}],
 "commits":[{"oid":"$HEAD_SHA","messageHeadline":"change","messageBody":"理由の説明"}]}
EOS
cat >"$FAKE_GH_DIR/pr.diff" <<'EOS'
diff --git a/src/foo.py b/src/foo.py
--- a/src/foo.py
+++ b/src/foo.py
@@ -1,2 +1,2 @@
 def foo(x):
-    return x
+    return x + 1
diff --git a/uv.lock b/uv.lock
--- a/uv.lock
+++ b/uv.lock
@@ -0,0 +1,2 @@
+LOCKLINE1
+LOCKLINE2
EOS
echo '[]' >"$FAKE_GH_DIR/comments.json"

# --- parse ---
run parse "https://github.com/o/r/pull/12/files#diff-abc"
has "parse-url-repo" "$OUT" "repo:  o/r"
has "parse-url-pr" "$OUT" "pr:    12"
run parse "https://ghe.example.com/team/app/pull/3"
has "parse-ghe-host" "$OUT" "host:  ghe.example.com"
run parse "#45"
has "parse-hash" "$OUT" "pr:    45"
run parse "pr:46"
has "parse-prefix" "$OUT" "pr:    46"
run parse "47"
has "parse-number" "$OUT" "pr:    47"
run parse "https://github.com/o/r/actions/runs/1"
check "parse-non-pr-url-rc" 1 "$RC"
run parse "feat/foo"
check "parse-invalid-rc" 1 "$RC"

# --- preflight ---
cd "$WORK/work" || exit 1
run preflight "#7"
check "preflight-rc" 0 "$RC"
has "preflight-target" "$OUT" "state:  OPEN (draft)"
has "preflight-head" "$OUT" "head:   feat/foo ($HEAD_SHA)"
has "preflight-mode-full" "$OUT" "mode:   full"
has "preflight-remote" "$OUT" "remote: origin"
has "preflight-title" "$OUT" "feat: foo を加算に変える"
has "preflight-body" "$OUT" "二行目"
has "preflight-commit-body" "$OUT" "    理由の説明"
has "preflight-excluded" "$OUT" "uv.lock	(excluded"
lacks "preflight-not-excluded" "$OUT" "src/foo.py	(excluded"
has "preflight-total" "$OUT" "total: 2 files, +3 -1"
has "preflight-mmdc-found" "$OUT" "mmdc: $WORK/bin/mmdc"
PR_VISUALIZE_MMDC="$NO_MMDC" run preflight "#7"
has "preflight-mmdc-missing" "$OUT" "mmdc: (not found)"

git -C "$WORK/work" remote set-url origin "git@github.com:O/R.git"
run preflight
has "preflight-scp-remote-full" "$OUT" "mode:   full"
git -C "$WORK/work" remote set-url origin "ssh://git@github.com:22/o/r"
run preflight
has "preflight-ssh-remote-full" "$OUT" "mode:   full"
git -C "$WORK/work" remote set-url origin "https://github.com/o/r.git"

cd "$WORK/other" || exit 1
run preflight "https://github.com/o/r/pull/7"
check "preflight-degraded-rc" 0 "$RC"
has "preflight-degraded" "$OUT" "mode:   degraded"

# --- stack ---
cd "$WORK/work" || exit 1
run stack "#7"
check "stack-unknown-rc" 0 "$RC"
has "stack-unknown" "$OUT" "size:     unknown"
echo '{"data":{"repository":{"pullRequest":{"stackEntry":null,"stack":null}}}}' >"$FAKE_GH_DIR/stack.json"
run stack "#7"
has "stack-none" "$OUT" "size:     1 (スタックではない)"
lacks "stack-none-no-mermaid" "$OUT" "STACK MERMAID"
run preflight "#7"
has "preflight-stack-none" "$OUT" "size:     1 (スタックではない)"
cat >"$FAKE_GH_DIR/stack.json" <<'EOS'
{"data":{"repository":{"pullRequest":{"stackEntry":{"position":2},"stack":{"size":3,"baseRefName":"main",
 "entries":{"nodes":[
  {"position":3,"pullRequest":{"number":8,"state":"OPEN","title":"test: 検証を足す","headRefName":"test/c","additions":5,"deletions":0,"changedFiles":1,
   "files":{"nodes":[{"path":"tests/c_test.py","additions":5,"deletions":0}]}}},
  {"position":1,"pullRequest":{"number":6,"state":"MERGED","title":"feat: 土台 \"A\"; <B> #1","headRefName":"feat/a","additions":10,"deletions":2,"changedFiles":2,
   "files":{"nodes":[{"path":"src/a.py","additions":8,"deletions":2},{"path":"src/foo.py","additions":2,"deletions":0}]}}},
  {"position":2,"pullRequest":{"number":7,"state":"OPEN","title":"feat: foo を加算に変える","headRefName":"feat/foo","additions":3,"deletions":1,"changedFiles":1,
   "files":{"nodes":[{"path":"src/foo.py","additions":1,"deletions":1}]}}}
 ]}}}}}}
EOS
run stack "#7"
check "stack-rc" 0 "$RC"
has "stack-size" "$OUT" "size:     3"
has "stack-position" "$OUT" "position: 2 of 3"
has "stack-current-mark" "$OUT" "2 * #7	OPEN"
has "stack-other-unmarked" "$OUT" "1   #6	MERGED"
has "stack-files-header" "$OUT" "#6 (1 段目):"
has "stack-files-entry" "$OUT" "  +8 -2	src/a.py"
has "stack-mermaid-current" "$OUT" '+3 -1 / 1 files"]:::current'
has "stack-mermaid-chain" "$OUT" "    base --> p1 --> p2 --> p3"
has "stack-mermaid-escaped" "$OUT" 'p1["#35;6 feat: 土台 #quot;A#quot;#59; #lt;B#gt; #35;1<br/>'
check "stack-mermaid-one-current" 1 "$(printf '%s\n' "$OUT" | grep -c ':::current$')"
printf '%s\n' "$OUT" >"$WORK/stack.md"
run mermaid-check "$WORK/stack.md"
has "stack-mermaid-extractable" "$OUT" "RESULT: OK (1 diagrams)"
run preflight "#7"
has "preflight-stack-position" "$OUT" "position: 2 of 3"
lacks "preflight-stack-no-files" "$OUT" "STACK FILES"

# --- diff ---
cd "$WORK/work" || exit 1
run diff "#7"
check "diff-needs-out-rc" 1 "$RC"
run diff "#7" --out "$WORK/out/pr.diff"
check "diff-rc" 0 "$RC"
has "diff-excluded-list" "$OUT" "  uv.lock"
DIFF=$(cat "$WORK/out/pr.diff")
has "diff-keeps-code" "$DIFF" "+    return x + 1"
lacks "diff-drops-lock" "$DIFF" "LOCKLINE1"

# --- fetch ---
check "fetch-head-absent-before" "absent" "$(
    git -C "$WORK/work" cat-file -e "$HEAD_SHA^{commit}" 2>/dev/null && echo present || echo absent
)"
REFS_BEFORE=$(git -C "$WORK/work" for-each-ref | sort)
run fetch "#7"
check "fetch-rc" 0 "$RC"
has "fetch-head-sha" "$OUT" "head_sha: $HEAD_SHA"
has "fetch-base-sha" "$OUT" "base_sha: $BASE_SHA"
lacks "fetch-no-warning" "$OUT" "WARNING"
check "fetch-head-readable" "    return x + 1" "$(git -C "$WORK/work" show "$HEAD_SHA:src/foo.py" | tail -n 1)"
check "fetch-creates-no-ref" "$REFS_BEFORE" "$(git -C "$WORK/work" for-each-ref | sort)"
check "fetch-keeps-branch" "main" "$(git -C "$WORK/work" rev-parse --abbrev-ref HEAD)"
cd "$WORK/other" || exit 1
run fetch "https://github.com/o/r/pull/7"
check "fetch-degraded-rc" 1 "$RC"
has "fetch-degraded-msg" "$OUT" "degraded"

# --- mermaid-check ---
cd "$WORK/work" || exit 1
DOC="$WORK/doc.md"
cat >"$DOC" <<'EOS'
# PR #7: foo を加算に変える

概要の文章。

**図1: 俯瞰**

```mermaid
flowchart LR
    A --> B
```

## foo

**図2: foo のシーケンス**

```mermaid
sequenceDiagram
    A->>B: foo(x)
```

説明文。

```mermaid
sequenceDiagram
    C->>D: bar()
```

```python
print("mermaid ではない")
```
EOS
run mermaid-check "$DOC"
check "mermaid-ok-rc" 0 "$RC"
has "mermaid-ok" "$OUT" "RESULT: OK (3 diagrams)"
PR_VISUALIZE_MMDC="$NO_MMDC" run mermaid-check "$DOC"
check "mermaid-unverified-rc" 0 "$RC"
has "mermaid-unverified" "$OUT" "RESULT: UNVERIFIED (3 diagrams)"
sed 's/A->>B: foo(x)/A->>B: BROKEN/' "$DOC" >"$WORK/bad.md"
run mermaid-check "$WORK/bad.md"
check "mermaid-fail-rc" 1 "$RC"
has "mermaid-fail-block" "$OUT" "block 2 (line 16): FAIL"
has "mermaid-fail-log" "$OUT" "Parse error"
has "mermaid-fail-others-ok" "$OUT" "block 3 (line 23): OK"
has "mermaid-fail-result" "$OUT" "RESULT: FAIL (1 of 3 diagrams)"
# ログなしの失敗でも止まらず、残りの図を検証して RESULT を出す
sed 's/A->>B: foo(x)/A->>B: SILENT/' "$DOC" >"$WORK/silent.md"
run mermaid-check "$WORK/silent.md"
check "mermaid-silent-rc" 1 "$RC"
has "mermaid-silent-block" "$OUT" "block 2 (line 16): FAIL"
has "mermaid-silent-note" "$OUT" "mmdc がログを出さずに失敗した"
has "mermaid-silent-continues" "$OUT" "block 3 (line 23): OK"
has "mermaid-silent-result" "$OUT" "RESULT: FAIL (1 of 3 diagrams)"
# 図の文言に「Syntax error in text」を含んでも、描画できていれば通す
sed 's/A->>B: foo(x)/A->>B: Syntax error in text/' "$DOC" >"$WORK/phrase.md"
run mermaid-check "$WORK/phrase.md"
has "mermaid-phrase-ok" "$OUT" "RESULT: OK (3 diagrams)"
printf '# no diagrams\n' >"$WORK/plain.md"
run mermaid-check "$WORK/plain.md"
has "mermaid-none" "$OUT" "RESULT: NO DIAGRAMS"

# --- comment ---
: >"$FAKE_GH_LOG"
run comment "#7" --from "$DOC"
check "comment-needs-expect-rc" 1 "$RC"
run comment "#7" --from "$DOC" --dry-run
check "comment-dry-rc" 0 "$RC"
has "comment-dry-action" "$OUT" "action:    create"
has "comment-dry-result" "$OUT" "RESULT: DRY RUN"
run comment "#7" --from "$DOC" --dry-run --out "$WORK/out/preview.md"
has "comment-dry-preview-path" "$OUT" "preview:   $WORK/out/preview.md"
check "comment-dry-preview-marker" "<!-- pr-visualize -->" "$(head -n 1 "$WORK/out/preview.md")"
lacks "comment-dry-no-post" "$(cat "$FAKE_GH_LOG")" "-X POST"
HASH=$(printf '%s\n' "$OUT" | sed -n 's/^body_hash: //p')

run comment "#7" --from "$DOC" --expect "0000"
check "comment-stale-rc" 1 "$RC"
has "comment-stale-msg" "$OUT" "承認時から変わっている"
lacks "comment-stale-no-post" "$(cat "$FAKE_GH_LOG")" "-X POST"

run comment "#7" --from "$DOC" --expect "$HASH"
check "comment-post-rc" 0 "$RC"
has "comment-post-result" "$OUT" "RESULT: POSTED https://github.com/o/r/pull/7#issuecomment-1"
has "comment-post-call" "$(cat "$FAKE_GH_LOG")" "-X POST repos/o/r/issues/7/comments"
POSTED=$(cat "$FAKE_GH_DIR/posted.md")
check "comment-marker-first" "<!-- pr-visualize -->" "$(head -n 1 "$FAKE_GH_DIR/posted.md")"
has "comment-first-caption-open" "$POSTED" "**図1: 俯瞰**"
has "comment-second-folded" "$POSTED" "<summary>図2: foo のシーケンス</summary>"
lacks "comment-second-caption-moved" "$POSTED" "**図2: foo のシーケンス**"
has "comment-third-folded" "$POSTED" "<summary>diagram 3</summary>"
check "comment-details-count" 2 "$(grep -c '^<details>$' "$FAKE_GH_DIR/posted.md")"
check "comment-details-closed" 2 "$(grep -c '^</details>$' "$FAKE_GH_DIR/posted.md")"
has "comment-keeps-prose" "$POSTED" "説明文。"
has "comment-keeps-code" "$POSTED" 'print("mermaid ではない")'

# 最初の図と同じ節にある図はすべて開いたままにする（スタックの全体像と変更の全体像）
cat >"$WORK/two-overviews.md" <<'EOS'
# PR

## 全体像

**図1: スタックの全体像**

```mermaid
flowchart BT
    a --> b
```

**図2: 変更の全体像**

```mermaid
flowchart LR
    c --> d
```

```text
## これは見出しではない
```

## 変更の詳細

**図3: foo**

```mermaid
sequenceDiagram
    A->>B: foo()
```
EOS
run comment "#7" --from "$WORK/two-overviews.md" --dry-run --out "$WORK/out/two.md"
check "comment-two-open-rc" 0 "$RC"
TWO=$(cat "$WORK/out/two.md")
has "comment-two-open-first" "$TWO" "**図1: スタックの全体像**"
has "comment-two-open-second" "$TWO" "**図2: 変更の全体像**"
has "comment-two-fold-third" "$TWO" "<summary>図3: foo</summary>"
check "comment-two-details-count" 1 "$(grep -c '^<details>$' "$WORK/out/two.md")"

# 目印付きの自分のコメントだけを上書き対象にする（他人の目印付き・自分の目印なしは対象外）
cat >"$FAKE_GH_DIR/comments.json" <<'EOS'
[{"id":11,"user":{"login":"bob"},"body":"<!-- pr-visualize -->\nother"},
 {"id":22,"user":{"login":"me"},"body":"<!-- pr-visualize -->\nold"},
 {"id":33,"user":{"login":"me"},"body":"plain comment"}]
EOS
: >"$FAKE_GH_LOG"
run comment "#7" --from "$DOC" --dry-run
has "comment-update-action" "$OUT" "action:    update (既存コメント 22 を上書き)"
run comment "#7" --from "$DOC" --expect "$HASH"
check "comment-update-rc" 0 "$RC"
has "comment-update-call" "$(cat "$FAKE_GH_LOG")" "-X PATCH repos/o/r/issues/comments/22"
lacks "comment-update-no-post" "$(cat "$FAKE_GH_LOG")" "-X POST"

# 上限はバイト数ではなく文字数: 日本語 30000 字(9 万バイト)は通り、70000 字は拒否
echo '[]' >"$FAKE_GH_DIR/comments.json"
: >"$FAKE_GH_LOG"
awk 'BEGIN { for (i = 0; i < 30000; i++) printf "あ"; print "" }' >"$WORK/mid.md"
run comment "#7" --from "$WORK/mid.md" --dry-run
check "comment-multibyte-rc" 0 "$RC"
awk 'BEGIN { for (i = 0; i < 70000; i++) printf "あ"; print "" }' >"$WORK/big.md"
run comment "#7" --from "$WORK/big.md" --dry-run
check "comment-too-long-rc" 1 "$RC"
has "comment-too-long-msg" "$OUT" "上限 65536 を超える"

cd "$WORK/other" || exit 1
run comment "https://github.com/o/r/pull/7" --from "$DOC" --dry-run
check "comment-degraded-rc" 1 "$RC"
has "comment-degraded-msg" "$OUT" "degraded"
lacks "comment-degraded-no-post" "$(cat "$FAKE_GH_LOG")" "-X POST"

exit "$fail"
