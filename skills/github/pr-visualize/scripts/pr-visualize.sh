#!/usr/bin/env bash
# pr-visualize.sh — PR を図解するための素材収集・図の検証・コメント投稿を決定論で行う。
#
# 差分の読解と図・解説の執筆はスキル本体（SKILL.md）の仕事。このスクリプトは
# 毎回同じ手順になる部分——PR の特定、メタ情報と差分の取得、head の取得、mermaid の
# 構文検証、PR コメントの新規投稿/上書き——だけを担う。
#
# 使い方:
#   pr-visualize.sh parse         <url|#PR|pr:PR|PR>            解決結果(host/repo/pr)のみ出力
#   pr-visualize.sh preflight     [url|#PR|pr:PR|PR]            PR のメタ情報・本文・コミット・変更ファイル・動作モード
#   pr-visualize.sh stack         [url|#PR|pr:PR|PR]            スタックの並び・各段の変更ファイル・スタックの図
#   pr-visualize.sh diff          [url|#PR|pr:PR|PR] --out <file>   差分をファイルへ退避（lockfile・生成物は除く）
#   pr-visualize.sh fetch         [url|#PR|pr:PR|PR]            PR の head を取得（作業ツリー・ブランチ・ref は変えない）
#   pr-visualize.sh mermaid-check <markdown>                    ```mermaid ブロックを mmdc で描画して構文検証
#   pr-visualize.sh comment       [url|#PR|pr:PR|PR] --from <markdown> (--dry-run [--out <file>] | --expect <hash>)
#                                                               図を折りたたんだ本文を PR コメントへ新規投稿/上書き
#                                                               （--dry-run --out で投稿される本文そのものを書き出す）
#
# 受理する入力:
#   https://HOST/OWNER/REPO/pull/PRNUM[/...]
#   #PRNUM / pr:PRNUM / PRNUM … repo は cwd から gh が解決
#   (空)                       … 現在ブランチの PR
#
# スタック:
#   GitHub のスタック機能に登録された PR だけを検出する（マージ後も取得できる）。
#   登録されていない PR は単独の PR として扱う。
#
# 動作モード:
#   full     … PR のリポジトリが cwd の remote と一致。head を取得でき、差分の外（呼び出し元）を読める
#   degraded … 一致しない。差分とメタ情報だけ。fetch と comment は拒否する
#
# 環境変数:
#   PR_VISUALIZE_MMDC       mmdc の実行ファイル（既定: PATH の mmdc）
#   PR_VISUALIZE_MMDC_ARGS  mmdc へ追加で渡す引数（例: "-p puppeteer.json"）
#
# コードの修正は一切行わない。外部へ書き込むのは comment（--dry-run なし）だけ。
# GitHub(github.com / GitHub Enterprise)専用。
set -euo pipefail

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

MARKER='<!-- pr-visualize -->'
COMMENT_LIMIT=65536 # GitHub の issue comment 本文の上限（文字数）

# lockfile・生成物: 差分本文は読んでも図にならないので、統計だけ残して本文は落とす
EXCLUDE_RE='(\.lock|\.lockfile|package-lock\.json|pnpm-lock\.yaml|go\.sum|\.min\.js|\.min\.css)$'

HOST=""
REPO=""
PR=""

# 入力を HOST/REPO/PR に正規化する。URL 以外は REPO を空のままにし、gh に cwd の remote を解決させる。
parse_input() {
    local in="${1:-}"
    [ -n "$in" ] || return 0
    case "$in" in
        http*://*)
            local rest path owner repo
            rest="${in#*://}"
            HOST="${rest%%/*}"
            path="${rest#*/}"
            path="${path%%\?*}"
            path="${path%%\#*}"
            owner="${path%%/*}"
            path="${path#*/}"
            repo="${path%%/*}"
            path="${path#*/}"
            [ -n "$owner" ] && [ -n "$repo" ] || die "URL から OWNER/REPO を取れません: $in"
            REPO="$owner/$repo"
            case "/$path/" in
                /pull/[0-9]*)
                    PR="${path#pull/}"
                    PR="${PR%%/*}"
                    ;;
                *) die "URL から pull request を特定できません: $in" ;;
            esac
            ;;
        \#[0-9]*) PR="${in#\#}" ;;
        pr:[0-9]*) PR="${in#pr:}" ;;
        [0-9]*) PR="$in" ;;
        *) die "入力を解釈できません: ${in}（PR の URL / #PR / pr:PR / 空 のいずれか）" ;;
    esac
    case "$PR" in
        '' | *[!0-9]*) die "PR 番号を解釈できません: $in" ;;
    esac
}

# remote URL を host/owner/repo（小文字）へ正規化する。解釈できない形式は空を返す。
normalize_remote() {
    local url="$1" host path
    url="${url%/}"
    url="${url%.git}"
    case "$url" in
        *://*)
            url="${url#*://}"
            url="${url#*@}"
            host="${url%%/*}"
            host="${host%%:*}" # ssh://git@host:22/owner/repo のポートを落とす
            path="${url#*/}"
            ;;
        *@*:*)
            url="${url#*@}"
            host="${url%%:*}"
            path="${url#*:}"
            ;;
        *) return 0 ;;
    esac
    printf '%s/%s' "$host" "$path" | tr '[:upper:]' '[:lower:]'
}

# PR のリポジトリ（HOST/REPO）に一致する cwd の remote 名を返す。無ければ空。
# url.insteadOf の書き換え前の URL で照合するため、remote get-url ではなく設定値を読む。
match_remote() {
    git rev-parse --git-dir >/dev/null 2>&1 || return 0
    local want key url name
    want="$(printf '%s/%s' "$HOST" "$REPO" | tr '[:upper:]' '[:lower:]')"
    while read -r key url; do
        [ -n "$key" ] || continue
        if [ "$(normalize_remote "$url")" = "$want" ]; then
            name="${key#remote.}"
            printf '%s' "${name%.url}"
            return 0
        fi
    done < <(git config --get-regexp '^remote\..*\.url$' 2>/dev/null || true)
}

BASE_REF=""
BASE_OID=""
HEAD_REF=""
HEAD_OID=""
PR_URL=""
RARGS=()

# PR を gh で特定し、HOST/REPO/PR と base/head を確定する。以降の gh 呼び出しは -R で固定する。
resolve_pr() {
    local args=() line
    [ -n "$PR" ] && args+=("$PR")
    [ -n "$REPO" ] && args+=(-R "$HOST/$REPO")
    if [ -z "$REPO" ]; then
        git rev-parse --git-dir >/dev/null 2>&1 ||
            die "git リポジトリ外では PR の URL を指定してください。"
    fi
    line="$(gh pr view ${args[@]+"${args[@]}"} \
        --json number,url,baseRefName,baseRefOid,headRefName,headRefOid \
        --jq '[.number, .url, .baseRefName, .baseRefOid, .headRefName, .headRefOid] | @tsv')" ||
        die "PR を取得できません（gh auth status・PR 番号・現在ブランチに PR があるかを確認）"
    IFS=$'\t' read -r PR PR_URL BASE_REF BASE_OID HEAD_REF HEAD_OID <<<"$line"
    [ -n "$PR_URL" ] || die "PR の URL を取得できませんでした"
    local rest="${PR_URL#*://}"
    HOST="${rest%%/*}"
    rest="${rest#*/}"
    REPO="$(printf '%s' "$rest" | cut -d/ -f1-2)"
    RARGS=(-R "$HOST/$REPO")
}

STACK_QUERY='query($o: String!, $n: String!, $p: Int!) {
  repository(owner: $o, name: $n) {
    pullRequest(number: $p) {
      stackEntry { position }
      stack {
        size
        baseRefName
        entries(first: 50) {
          nodes {
            position
            pullRequest {
              number state title headRefName additions deletions changedFiles
              files(first: 100) { nodes { path additions deletions } }
            }
          }
        }
      }
    }
  }
}'

# jq: スタックの並び。現在の段に * を付ける。
STACK_JQ_LIST='
.data.repository.pullRequest as $pr
| if $pr.stack == null then "size:     1 (スタックではない)"
  else
    $pr.stackEntry.position as $cur
    | ($pr.stack.entries.nodes | map(select(.pullRequest != null)) | sort_by(.position)) as $es
    | "size:     \($pr.stack.size)",
      "base:     \($pr.stack.baseRefName)",
      "position: \($cur) of \($pr.stack.size)",
      ($es[] | "\(.position)\(if .position == $cur then " *" else "  " end) #\(.pullRequest.number)\t\(.pullRequest.state)\t+\(.pullRequest.additions) -\(.pullRequest.deletions)\t\(.pullRequest.changedFiles) files\t\(.pullRequest.headRefName)\t\(.pullRequest.title)")
  end'

# jq: 各段の変更ファイルと、スタックの図。図の文は mermaid が解釈する記号を文字参照へ置き換える。
STACK_JQ_DETAIL='
def esc: gsub("(?<c>[#;\"<>])"; {"#": "#35;", ";": "#59;", "\"": "#quot;", "<": "#lt;", ">": "#gt;"}[.c]);
.data.repository.pullRequest as $pr
| if $pr.stack == null then empty
  else
    $pr.stackEntry.position as $cur
    | ($pr.stack.entries.nodes | map(select(.pullRequest != null)) | sort_by(.position)) as $es
    | "",
      "=== STACK FILES ===",
      ($es[] | "#\(.pullRequest.number) (\(.position) 段目):", (.pullRequest.files.nodes[] | "  +\(.additions) -\(.deletions)\t\(.path)")),
      "",
      "=== STACK MERMAID ===",
      "```mermaid",
      "flowchart BT",
      "    classDef current fill:#ffc40066,stroke:#d39e00,stroke-width:3px",
      "    classDef base stroke-dasharray: 4 3",
      "",
      "    base[\"\($pr.stack.baseRefName | esc)\"]:::base",
      ($es[] | "    p\(.position)[\"#35;\(.pullRequest.number) \(.pullRequest.title | esc)<br/>+\(.pullRequest.additions) -\(.pullRequest.deletions) / \(.pullRequest.changedFiles) files\"]\(if .position == $cur then ":::current" else "" end)"),
      "",
      "    base" + ($es | map(" --> p\(.position)") | join("")),
      "```"
  end'

# スタックの情報を出す。$1 = jq の式。取得できない GitHub（スタックの項目が無い版など）では 1 を返す。
stack_query() {
    gh api --hostname "$HOST" graphql -f query="$STACK_QUERY" \
        -f o="${REPO%%/*}" -f n="${REPO#*/}" -F p="$PR" --jq "$1" 2>/dev/null
}

print_stack_list() {
    stack_query "$STACK_JQ_LIST" ||
        echo "size:     unknown (この GitHub からスタックの情報を取得できない。単独の PR として扱う)"
}

mmdc_bin() {
    local bin="${PR_VISUALIZE_MMDC:-mmdc}"
    command -v "$bin" 2>/dev/null || true
}

# 図を折りたたんだコメント本文を組み立てる。最初の図と同じ節（## の見出し単位）にある図は
# 開いたままにし、以降の節の図は <details> に入れる。全体像の節に図が複数あっても（スタックの
# 全体像と変更の全体像）すべて開いたままになる。図の直前にある太字だけの行（**図: …**）を
# 見出し（summary）に使う。
compose_comment() { # $1 = 正本の markdown
    printf '%s\n' "$MARKER"
    awk '
        function flush() {
            if (held != "") { printf "%s", held; held = "" }
            cap = ""
        }
        {
            if (inblk) {
                print
                if ($0 ~ /^[ \t]*```[ \t]*$/) {
                    inblk = 0
                    if (fold) { print ""; print "</details>" }
                }
                next
            }
            if (incode) {
                print
                if ($0 ~ /^[ \t]*```[ \t]*$/) incode = 0
                next
            }
            if ($0 ~ /^[ \t]*```mermaid[ \t]*$/) {
                n++; inblk = 1
                if (n == 1) opensec = sec
                fold = (sec != opensec)
                if (fold) {
                    s = (cap != "") ? cap : "diagram " n
                    held = ""; cap = ""
                    print "<details>"
                    print "<summary>" s "</summary>"
                    print ""
                } else {
                    flush()
                }
                print
                next
            }
            if ($0 ~ /^[ \t]*```/) { flush(); incode = 1; print; next }
            if ($0 ~ /^## /) sec++
            if ($0 ~ /^\*\*.+\*\*[ \t]*$/) {
                flush()
                cap = $0
                sub(/^\*\*/, "", cap)
                sub(/\*\*[ \t]*$/, "", cap)
                held = $0 "\n"
                next
            }
            if ($0 ~ /^[ \t]*$/ && held != "") { held = held $0 "\n"; next }
            flush()
            print
        }
        END { flush() }
    ' "$1"
}

# UTF-8 の文字数（ロケール非依存）: 継続バイト(0x80-0xBF)を除いたバイト数 = コードポイント数。
count_chars() {
    LC_ALL=C tr -d '\200-\277' <"$1" | wc -c | tr -d ' '
}

cmd="${1:-preflight}"
shift || true
input=""
OUT=""
FROM=""
EXPECT=""
DRY_RUN=0
want=""
for a in "$@"; do
    if [ -n "$want" ]; then
        case "$want" in
            out) OUT="$a" ;;
            from) FROM="$a" ;;
            expect) EXPECT="$a" ;;
        esac
        want=""
        continue
    fi
    case "$a" in
        --out) want=out ;;
        --from) want=from ;;
        --expect) want=expect ;;
        --dry-run) DRY_RUN=1 ;;
        -*) die "不明なオプション: $a" ;;
        *) input="$a" ;;
    esac
done
[ -z "$want" ] || die "--$want に値がありません"

case "$cmd" in
    parse)
        [ -n "$input" ] || die "parse には入力が必要です"
        parse_input "$input"
        echo "=== RESOLVED ==="
        echo "host:  ${HOST:-(cwd remote)}"
        echo "repo:  ${REPO:-(cwd remote)}"
        echo "pr:    ${PR}"
        ;;

    preflight)
        command -v gh >/dev/null 2>&1 || die "gh が見つかりません。GitHub CLI を導入してください"
        parse_input "$input"
        resolve_pr
        remote="$(match_remote)"
        echo "=== TARGET ==="
        gh pr view "$PR" "${RARGS[@]}" \
            --json number,url,state,isDraft,author,baseRefName,baseRefOid,headRefName,headRefOid \
            --jq '"pr:     #\(.number)\nurl:    \(.url)\nstate:  \(.state)\(if .isDraft then " (draft)" else "" end)\nauthor: \(.author.login)\nbase:   \(.baseRefName) (\(.baseRefOid))\nhead:   \(.headRefName) (\(.headRefOid))"'
        echo
        echo "=== MODE ==="
        if [ -n "$remote" ]; then
            echo "mode:   full"
            echo "remote: $remote"
        else
            echo "mode:   degraded"
            echo "reason: PR のリポジトリ ($HOST/$REPO) が作業ディレクトリの remote と一致しない"
            echo "effect: 参照箇所起点の図を省く / fetch と comment は実行できない"
        fi
        echo
        echo "=== STACK ==="
        print_stack_list
        echo
        echo "=== TITLE ==="
        gh pr view "$PR" "${RARGS[@]}" --json title --jq '.title'
        echo
        echo "=== BODY ==="
        gh pr view "$PR" "${RARGS[@]}" --json body --jq '.body'
        echo
        echo "=== COMMITS ==="
        gh pr view "$PR" "${RARGS[@]}" --json commits \
            --jq '.commits[] | "\(.oid[0:7]) \(.messageHeadline)" + (if (.messageBody // "") != "" then "\n" + (.messageBody | split("\n") | map("    " + .) | join("\n")) else "" end)'
        echo
        echo "=== FILES ==="
        # jq の文字列リテラルへ埋め込むため、正規表現のバックスラッシュを二重にする
        gh pr view "$PR" "${RARGS[@]}" --json files \
            --jq ".files[] | \"+\(.additions) -\(.deletions)\t\(.path)\" + (if (.path | test(\"${EXCLUDE_RE//\\/\\\\}\")) then \"\t(excluded: 差分本文は退避しない)\" else \"\" end)"
        gh pr view "$PR" "${RARGS[@]}" --json files,additions,deletions \
            --jq '"total: \(.files | length) files, +\(.additions) -\(.deletions)"'
        echo
        echo "=== TOOLS ==="
        mm="$(mmdc_bin)"
        if [ -n "$mm" ]; then
            echo "mmdc: $mm"
        else
            echo "mmdc: (not found) 図は構文検証できず「未検証」になる"
        fi
        ;;

    stack)
        command -v gh >/dev/null 2>&1 || die "gh が見つかりません。GitHub CLI を導入してください"
        parse_input "$input"
        resolve_pr
        echo "=== STACK ==="
        print_stack_list
        stack_query "$STACK_JQ_DETAIL" || true
        ;;

    diff)
        command -v gh >/dev/null 2>&1 || die "gh が見つかりません。GitHub CLI を導入してください"
        [ -n "$OUT" ] || die "diff には --out <file> が必要です（差分は標準出力へ流さずファイルへ退避する）"
        parse_input "$input"
        resolve_pr
        raw="$(mktemp)"
        trap 'rm -f "$raw" "$raw.excluded"' EXIT
        gh pr diff "$PR" "${RARGS[@]}" >"$raw" || die "差分を取得できません"
        mkdir -p "$(dirname "$OUT")"
        # 正規表現は環境変数で渡す（awk の -v はバックスラッシュを解釈して警告を出すため）
        EXCLUDE_RE="$EXCLUDE_RE" awk -v ex="$raw.excluded" '
            BEGIN { re = ENVIRON["EXCLUDE_RE"] }
            /^diff --git / {
                path = $0
                sub(/^.* b\//, "", path)
                skip = (path ~ re)
                if (skip) print path > ex
            }
            !skip { print }
        ' "$raw" >"$OUT"
        echo "=== DIFF ==="
        echo "pr:    #$PR ($HOST/$REPO)"
        echo "out:   $OUT"
        echo "lines: $(wc -l <"$OUT" | tr -d ' ')"
        echo
        echo "=== EXCLUDED ==="
        if [ -s "$raw.excluded" ]; then
            sed 's/^/  /' "$raw.excluded"
        else
            echo "  (none)"
        fi
        ;;

    fetch)
        command -v gh >/dev/null 2>&1 || die "gh が見つかりません。GitHub CLI を導入してください"
        parse_input "$input"
        resolve_pr
        remote="$(match_remote)"
        [ -n "$remote" ] ||
            die "degraded: PR のリポジトリ ($HOST/$REPO) が作業ディレクトリの remote と一致しないため head を取得しない"
        https_url="https://$HOST/$REPO.git"
        # ref を作らず FETCH_HEAD だけを更新する（ブランチ・作業ツリー・ref を汚さない）。
        # 非対話で SSH 認証が通らない環境では、gh のトークンを使う HTTPS 取得へ切り替える。
        fetch_obj() { # $1 = 取得対象（ref か sha）
            git fetch --quiet --no-tags "$remote" "$1" 2>/dev/null ||
                git -c credential.helper= -c credential.helper='!gh auth git-credential' \
                    fetch --quiet --no-tags "$https_url" "$1"
        }
        fetch_obj "refs/pull/$PR/head" || die "refs/pull/$PR/head を取得できません"
        # FETCH_HEAD は並行する別の fetch に上書きされうる。PR の head が手元に届いていれば
        # そちらを使い、届いていない（取得までに PR が更新された）ときだけ FETCH_HEAD を読む。
        if git cat-file -e "$HEAD_OID^{commit}" 2>/dev/null; then
            head_sha="$HEAD_OID"
        else
            head_sha="$(git rev-parse FETCH_HEAD)"
        fi
        if ! git cat-file -e "$BASE_OID^{commit}" 2>/dev/null; then
            fetch_obj "$BASE_OID" || die "base ($BASE_OID) を取得できません"
        fi
        base_sha="$(git merge-base "$head_sha" "$BASE_OID")" ||
            die "head と base の merge-base を求められません"
        echo "=== FETCHED ==="
        echo "remote:   $remote"
        echo "head_sha: $head_sha"
        echo "base_sha: $base_sha   (head と base ブランチの merge-base = 変更前の状態)"
        if [ "$head_sha" != "$HEAD_OID" ]; then
            echo "WARNING: 取得した head ($head_sha) が PR の headRefOid ($HEAD_OID) と異なる。preflight と diff を取り直すこと"
        fi
        echo
        echo "=== HOW TO READ ==="
        echo "変更後のファイル:   git show $head_sha:<path>"
        echo "変更前のファイル:   git show $base_sha:<path>"
        echo "参照箇所の検索:     git grep -n -w -e '<関数名>' $head_sha -- [<path>...]"
        echo "ファイル単位の差分: git diff $base_sha $head_sha -- <path>"
        ;;

    mermaid-check)
        file="$input"
        [ -n "$file" ] && [ -f "$file" ] || die "mermaid-check には markdown ファイルを指定してください"
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        awk -v dir="$tmp" '
            !inblk && /^[ \t]*```mermaid[ \t]*$/ { n++; inblk = 1; print n "\t" NR > (dir "/index"); next }
            inblk && /^[ \t]*```[ \t]*$/ { inblk = 0; next }
            inblk { print > (dir "/block-" n ".mmd") }
        ' "$file"
        echo "=== MERMAID CHECK ==="
        if [ ! -s "$tmp/index" ]; then
            echo "RESULT: NO DIAGRAMS"
            exit 0
        fi
        total="$(wc -l <"$tmp/index" | tr -d ' ')"
        mm="$(mmdc_bin)"
        if [ -z "$mm" ]; then
            while IFS=$'\t' read -r n line; do echo "block $n (line $line): UNVERIFIED"; done <"$tmp/index"
            echo "RESULT: UNVERIFIED ($total diagrams) mmdc が見つからないため構文検証していない"
            exit 0
        fi
        failed=0
        read -r -a extra <<<"${PR_VISUALIZE_MMDC_ARGS:-}"
        while IFS=$'\t' read -r n line; do
            src="$tmp/block-$n.mmd"
            [ -f "$src" ] || : >"$src"
            # 終了コードに加え、SVG が実際に出たかも見る（何も出さずに exit 0 で終わる失敗を拾う）。
            # SVG の中身は見ない: 図の文言に左右され、正しい図を誤って落とすため。
            if "$mm" -q ${extra[@]+"${extra[@]}"} -i "$src" -o "$tmp/block-$n.svg" >"$tmp/log-$n" 2>&1 &&
                [ -s "$tmp/block-$n.svg" ]; then
                echo "block $n (line $line): OK"
            else
                failed=$((failed + 1))
                echo "block $n (line $line): FAIL"
                if grep -q '[^[:space:]]' "$tmp/log-$n"; then
                    # ログが空・head の打ち切りでもスクリプトを止めず、残りの図の検証を続ける
                    { grep -v '^[[:space:]]*$' "$tmp/log-$n" | head -n 12 | sed 's/^/    /'; } || true
                else
                    echo "    (mmdc がログを出さずに失敗した)"
                fi
            fi
        done <"$tmp/index"
        if [ "$failed" -gt 0 ]; then
            echo "RESULT: FAIL ($failed of $total diagrams)"
            exit 1
        fi
        echo "RESULT: OK ($total diagrams)"
        ;;

    comment)
        command -v gh >/dev/null 2>&1 || die "gh が見つかりません。GitHub CLI を導入してください"
        [ -n "$FROM" ] && [ -f "$FROM" ] || die "comment には --from <markdown> が必要です"
        if [ "$DRY_RUN" -eq 0 ] && [ -z "$EXPECT" ]; then
            die "投稿には --expect <hash> が必要です（先に --dry-run を実行し、表示された body_hash を承認後に渡す）"
        fi
        parse_input "$input"
        resolve_pr
        remote="$(match_remote)"
        [ -n "$remote" ] ||
            die "degraded: PR のリポジトリ ($HOST/$REPO) が作業ディレクトリの remote と一致しないため投稿しない（図が欠けた解説を投稿しない）"
        body="$(mktemp)"
        trap 'rm -f "$body"' EXIT
        compose_comment "$FROM" >"$body"
        chars="$(count_chars "$body")"
        [ "$chars" -le "$COMMENT_LIMIT" ] ||
            die "コメント本文が ${chars} 文字で上限 ${COMMENT_LIMIT} を超えるため投稿しない（分割投稿はしない。正本はそのまま残る）"
        body_hash="$(git hash-object "$body")"
        me="$(gh api --hostname "$HOST" user --jq '.login')" || die "gh のログインユーザーを取得できません"
        case "$me" in
            '' | *[!A-Za-z0-9_.\[\]-]*) die "ログイン名を解釈できません: $me" ;;
        esac
        # 目印で始まる自分のコメントのうち最後の 1 件を上書き対象にする
        existing="$(gh api --hostname "$HOST" --paginate "repos/$REPO/issues/$PR/comments" \
            --jq ".[] | select(.user.login == \"$me\") | select(.body | startswith(\"$MARKER\")) | .id" | tail -n 1)" ||
            die "既存コメントを取得できません"
        echo "=== COMMENT ==="
        echo "pr:        #$PR ($HOST/$REPO)"
        echo "as:        $me"
        echo "chars:     $chars / $COMMENT_LIMIT"
        echo "body_hash: $body_hash"
        if [ -n "$existing" ]; then
            echo "action:    update (既存コメント $existing を上書き)"
        else
            echo "action:    create (新規コメント)"
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            if [ -n "$OUT" ]; then
                mkdir -p "$(dirname "$OUT")"
                cp "$body" "$OUT"
                echo "preview:   $OUT"
            fi
            echo "RESULT: DRY RUN (投稿していない)"
            exit 0
        fi
        [ "$EXPECT" = "$body_hash" ] ||
            die "本文が承認時から変わっている (expect=$EXPECT, actual=$body_hash)。--dry-run からやり直して再承認を得ること"
        if [ -n "$existing" ]; then
            url="$(gh api --hostname "$HOST" -X PATCH "repos/$REPO/issues/comments/$existing" \
                -F "body=@$body" --jq '.html_url')" || die "コメントの更新に失敗しました"
        else
            url="$(gh api --hostname "$HOST" -X POST "repos/$REPO/issues/$PR/comments" \
                -F "body=@$body" --jq '.html_url')" || die "コメントの投稿に失敗しました"
        fi
        echo "RESULT: POSTED $url"
        ;;

    *)
        die "未知のサブコマンド: $cmd （parse | preflight | stack | diff | fetch | mermaid-check | comment）"
        ;;
esac
