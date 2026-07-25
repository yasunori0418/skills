#!/usr/bin/env bash
# task-boundary/main.sh — PreToolUse hook（matcher: Edit|Write|NotebookEdit）。
# 書き込み対象パスから親へ遡って境界ファイル .claude/task-boundary.json を探し、
# 宣言された allow glob の外への書き込みを deny する（スコープドリフト防止）。
#
# fail-open 設計（git-guard の fail-closed と逆向き / spec REQ-10・NFR-04・AC-09）:
#   境界ファイルが見つからなければ即 exit 0。プロセスに則らない通常セッションでは
#   一切発火しない（成果物が無いリポジトリでの誤作動ゼロ）。
#
# 境界ファイル書式（公開契約。生成者は parallel-worktree に限定されない）:
#   {"task_id":"B2","branch":"feat-client-retry","allow":["src/client/**","tests/client/**"]}
#
# 既知の抜け穴: Bash 経由の書き込み（`sh -c 'echo x > file'` 等）は matcher の
# 対象外なのでブロックされない。決定論での確実なパースが不可能なため許容済みの
# 残余リスク（spec スコープ外）。本 hook は「勢いによるドリフト」を止める
# ガードレールであり、敵対的エージェントに対するセキュリティ境界ではない
# （git-guard と同格）。
set -euo pipefail

BOUNDARY_REL=".claude/task-boundary.json"

deny() { # reason
    jq -cn --arg r "$1" \
        '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
    exit 0
}

input=$(cat)

# 対象パスの取得: Edit/Write は file_path、NotebookEdit は notebook_path。
target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
# パスが取れない（未知の入力形状・別ツール）ときは安全側で通す（fail-open）。
[ -n "$target" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

# --- パス正規化 ------------------------------------------------------------
# 相対パスは cwd 起点で絶対化し、`.` / `..` を字句的に畳む。
# realpath -m / --relative-to（GNU 拡張）には依存しない: 対象ファイルは Write の
# 時点では未作成であることが多く、また macOS の BSD realpath には -m が無いため。
normalize() { # abs-or-rel-path -> absolute lexical path
    local p="$1" out="" seg
    case "$p" in
        /*) ;;
        *) p="${cwd:-$PWD}/$p" ;;
    esac
    local IFS='/'
    # shellcheck disable=SC2086
    for seg in $p; do
        case "$seg" in
            '' | '.') ;;
            '..') out="${out%/*}" ;;
            *) out="$out/$seg" ;;
        esac
    done
    printf '%s' "${out:-/}"
}

# 存在するディレクトリ部分だけ物理パス（symlink 解決済み）へ寄せる。
# 境界ファイルの探索も対象パスの相対化も同じ物理名前空間の上で行うため、
# symlink 経由でアクセスされても境界判定が一貫する。
# 末尾の未作成部分（Write 対象のファイル名など）は字句のまま残す。
physical() { # absolute lexical path -> physical path
    local p="$1" tail="" head="$1" resolved
    while [ "$head" != "/" ] && [ -n "$head" ]; do
        if [ -d "$head" ]; then
            resolved=$(cd -P "$head" 2>/dev/null && pwd -P) || resolved="$head"
            printf '%s' "${resolved%/}$tail"
            return 0
        fi
        tail="/${head##*/}$tail"
        head="${head%/*}"
    done
    printf '%s' "$p"
}

abs=$(physical "$(normalize "$target")")

# --- 境界ファイルの探索（対象パスから root まで遡る） ----------------------
boundary=""
root=""
dir="${abs%/*}"
[ -n "$dir" ] || dir="/"
while :; do
    if [ -f "$dir/$BOUNDARY_REL" ]; then
        boundary="$dir/$BOUNDARY_REL"
        root="$dir"
        break
    fi
    [ "$dir" = "/" ] && break
    dir="${dir%/*}"
    [ -n "$dir" ] || dir="/"
done

# 境界ファイル無し -> 沈黙（fail-open。AC-09）
[ -n "$boundary" ] || exit 0

# --- 境界ファイルの読み取り ------------------------------------------------
# JSON が壊れている場合は deny（自己説明メッセージ付き）。
# 壊れた境界で黙って全通しにするとドリフト防止という目的そのものが失われ、
# かつ「境界を宣言したつもりで効いていない」状態に気づけないため、
# ここだけは fail-closed に倒す（利用者は境界ファイルを直せば即復帰できる）。
if ! meta=$(jq -er '[(.task_id // "(未宣言)"), (.branch // "(未宣言)")] | @tsv' "$boundary" 2>/dev/null); then
    deny "🚫 タスク境界ファイルが読めない（JSON 構文エラー、または内容が JSON オブジェクトでない）。
境界ファイル: $boundary
書き込み対象: $abs

このリポジトリはタスク境界による書き込み制限が有効な作業ツリーだが、境界ファイル自体が壊れているため許可範囲を判定できない。壊れた境界を黙って全通しにするとタスク境界の意味が失われるため、安全側でブロックした。

対処: ユーザーに報告し、境界ファイルを次の書式へ修復してもらうこと（AI が勝手に書き換えてはならない）。
  {\"task_id\": \"<タスクID>\", \"branch\": \"<ブランチ名>\", \"allow\": [\"src/foo/**\", \"tests/foo/**\"]}"
fi
task_id=$(printf '%s' "$meta" | cut -f1)
branch=$(printf '%s' "$meta" | cut -f2)

if ! allow_list=$(jq -er '.allow | if type == "array" then .[] | select(type == "string") else error end' "$boundary" 2>/dev/null); then
    deny "🚫 タスク境界ファイルの allow が不正（文字列の配列でない、またはキーが無い）。
境界ファイル: $boundary
タスク: task_id=$task_id / branch=$branch
書き込み対象: $abs

許可範囲を判定できないため安全側でブロックした。

対処: ユーザーに報告し、境界ファイルの allow を glob の配列へ修復してもらうこと（AI が勝手に書き換えてはならない）。
  {\"task_id\": \"$task_id\", \"branch\": \"$branch\", \"allow\": [\"src/foo/**\", \"tests/foo/**\"]}"
fi

# --- 相対化 ----------------------------------------------------------------
# 境界ファイルのあるディレクトリ（= worktree ルート）からの相対パスに直す。
case "$abs" in
    "$root"/*) rel="${abs#"$root"/}" ;;
    *)
        # 遡って見つけた以上ここには来ないが、判定不能なら安全側でブロックする。
        deny "🚫 書き込み対象がタスク境界ルートの外にある（相対化不能）。
境界ファイル: $boundary
境界ルート: $root
書き込み対象: $abs"
        ;;
esac

# --- 自己解錠の封じ --------------------------------------------------------
# 境界ファイル自身への書き込みは、allow の内容によらず常に deny する
# （エージェントが allow を書き換えて自分で境界を広げるのを防ぐ）。
if [ "$rel" = "$BOUNDARY_REL" ]; then
    deny "🚫 タスク境界ファイル自身への書き込みは禁止（自己解錠の防止）。
境界ファイル: $boundary
タスク: task_id=$task_id / branch=$branch

このファイルは現在のタスクが触ってよい範囲を宣言するもので、AI が自分で書き換えて境界を広げることはできない。

境界を正当に広げる手順:
  1. なぜ現在の境界の外に手を入れる必要があるのかをユーザーへ説明する
  2. ユーザーが $boundary の allow を手で編集する（またはユーザーの明示的な指示のもとで編集する）
  3. 本来別タスク・別 PR で扱うべき変更なら、境界を広げず「見送り」として報告に残す"
fi

# --- glob 照合 -------------------------------------------------------------
# 実装方式: glob を ERE へ変換して grep -E で照合する。
#   - bash の `case` パターンは `**` と `*` を区別できず（extglob でも
#     ディレクトリ区切りをまたぐ意味論が無い）、`src/**` が `src/a/b.ts` に
#     一致しない／`src/*` が誤って一致する、といった取り違えが起きる
#   - `shopt -s globstar` は実ファイルの展開であり、未作成パス（Write 対象）に
#     使えない
#   - `git check-ignore` は git リポジトリと一時ファイルへの書き込みを要求し、
#     hook としては重く副作用がある
# よって「文字列 → 文字列」の純粋な照合になる ERE 変換を採る。
# 変換規則:
#   `**`  -> `.*`      （ディレクトリ区切りをまたぐ）
#   `*`   -> `[^/]*`   （単一階層内のみ）
#   `?`   -> `[^/]`
#   その他の ERE メタ文字はエスケープ
# また `src/client/**` のようにディレクトリを指す宣言は、
# ディレクトリ自身（`src/client`）にも一致させる（末尾 `/**` の `/` を任意にする）。
glob_to_ere() { # glob -> ERE (anchored by caller)
    local g="$1" out="" i=0 c n len=${#1}
    while [ "$i" -lt "$len" ]; do
        c="${g:i:1}"
        n="${g:i+1:1}"
        case "$c" in
            '*')
                if [ "$n" = '*' ]; then
                    out="$out.*"
                    i=$((i + 2))
                    continue
                fi
                out="${out}[^/]*"
                ;;
            '?') out="${out}[^/]" ;;
            [a-zA-Z0-9_/-]) out="$out$c" ;;
            *) out="$out\\$c" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

matches() { # rel-path glob
    local ere
    case "$2" in
        */'**')
            # `src/client/**` は `src/client` 自体にも一致させる
            ere="$(glob_to_ere "${2%/\*\*}")(/.*)?"
            ;;
        *) ere="$(glob_to_ere "$2")" ;;
    esac
    printf '%s' "$1" | grep -Eq "^${ere}$"
}

globs=()
while IFS= read -r g; do
    [ -n "$g" ] || continue
    globs+=("$g")
done <<< "$allow_list"

for g in "${globs[@]}"; do
    if matches "$rel" "$g"; then
        exit 0
    fi
done

# --- 境界外 -> deny --------------------------------------------------------
allow_display=""
for g in "${globs[@]}"; do
    allow_display="$allow_display
  - $g"
done
[ -n "$allow_display" ] || allow_display="
  （allow が空。何も書き込めない宣言になっている）"

deny "🚫 このパスへの書き込みは現在のタスク境界の外にある。
タスク: task_id=$task_id / branch=$branch
境界ファイル: $boundary
書き込み対象: $rel（境界ルート $root からの相対）
宣言されている許可範囲（allow glob）:$allow_display

このセッションは上記タスクの実装レーンであり、宣言された範囲の外を変更するとスコープドリフト（当初タスクの境界からの逸脱）になるためブロックした。

対処（いずれか）:
  1. 本来のタスク範囲内で目的を達成できないか見直す（多くの場合はこれで足りる）
  2. この変更が本当に現在のタスクに必要なら、理由をユーザーへ説明し、ユーザーが $boundary の allow を手で編集して境界を広げる（またはユーザーの明示的な指示のもとで編集する）。AI が自分で境界ファイルを書き換えることはできない
  3. 別タスク・別 PR で扱うべき変更なら、ここでは着手せず「見送り一覧（理由つき）」として最終報告に残す"
