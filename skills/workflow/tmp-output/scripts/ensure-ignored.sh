#!/usr/bin/env bash
# tmp-output: 一時出力先 tmp-agents/ が git に ignore されていることを保証する(冪等)
#
# usage:
#   ensure-ignored.sh [<dir>]    <dir>(既定: カレント)を含むリポジトリのルートで判定する
#
# stdout(1 行):
#   already-ignored                .gitignore / info/exclude / 全体設定のいずれかで ignore 済み
#   added: <info/exclude のパス>   未 ignore だったので info/exclude へ追記した
#   skip: not a git repository     git リポジトリ外(何もしない)
# 追記後も ignore にならない(.gitignore の否定パターン等)ときは stderr に理由を出し exit 1。
#
# 判定は git check-ignore に委ね、全体設定のファイルを直接読まない(core.excludesFile の
# 有無で参照先が変わり、プロジェクトの .gitignore で ignore 済みの場合も拾えないため)。
# 追記先は info/exclude のみで、.gitignore は編集しない(コミット対象を汚さない)。
set -euo pipefail

NAME=tmp-agents

cd "${1:-.}"
if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "skip: not a git repository"
    exit 0
fi
cd "$root"

# 一致したパターンを見て判定する。ディレクトリ限定のパターン(tmp-agents/)は、
# 実ディレクトリがあるときだけ一致し、未作成時や worktree 作成フックが tmp-agents を
# symlink にしたときは一致しない。判定を実体の有無に左右させないため、
# ディレクトリ限定での一致は「ignore 済み」とみなさず追記する。
# --no-index: 誤って追跡済みでもパターンの一致だけで判定する
rc=0
match=$(git check-ignore -v --no-index "$NAME") || rc=$?
case $rc in
    0 | 1) ;;
    *)
        echo "error: git check-ignore failed (exit $rc)" >&2
        exit 1
        ;;
esac
# 出力形式: <source>:<linenum>:<pattern><TAB><pathname>。-v は否定パターン(!…)への
# 一致でも exit 0 を返すため、否定は ignore されていない扱いにする。
pattern=$(printf '%s' "${match%%$'\t'*}" | sed -E 's/^.*:[0-9]+://')
if [ "$rc" -eq 0 ] && [ "${pattern#!}" = "$pattern" ] && [ "${pattern%/}" = "$pattern" ]; then
    echo "already-ignored"
    exit 0
fi

# worktree でも共通の git ディレクトリの exclude を返すので、全 worktree に効く
ex=$(git rev-parse --path-format=absolute --git-path info/exclude)
if grep -qxF "$NAME" "$ex" 2>/dev/null; then
    # 追記済み(より優先度の高い .gitignore のディレクトリ限定パターンが先に一致しただけ)
    echo "already-ignored"
    exit 0
fi
mkdir -p "$(dirname "$ex")"
# 末尾改行の無い既存ファイルへ追記すると最終行と連結されるため補う
if [ -s "$ex" ] && [ -n "$(tail -c1 "$ex")" ]; then
    printf '\n' >>"$ex"
fi
# 末尾スラッシュなし: ディレクトリにも symlink にも一致させる
printf '%s\n' "$NAME" >>"$ex"

if ! git check-ignore -q --no-index "$NAME"; then
    echo "error: $NAME is still not ignored after adding it to $ex (negated by a .gitignore pattern?)" >&2
    exit 1
fi
echo "added: $ex"
