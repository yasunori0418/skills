#!/usr/bin/env bash
# diff-review: Python スクリプトの実行経路を決定論で選ぶ(uv → python3 → 不在)。
#
#   uv があれば pyproject.toml の依存を解決した venv で実行する。venv はスキル外の
#   $HOME/.cache/uv-venvs/diff-review に置く(スキルディレクトリは nix store / plugin cache で
#   read-only になり得る)。uv が無ければ PATH の python3 で実行する(nix sandbox の checks では
#   withPackages で依存を揃えた python3 が来る)。どちらも無ければ exit 127。
#
#   DIFF_REVIEW_PYTHON にインタプリタを指定すると経路判定を省いてそれで実行する
#   (依存を自前で揃えた環境向け。テストが遅い偽インタプリタを差し込む用途にも使う)。
#
# usage: run-python.sh <script.py> [args...]
set -euo pipefail
SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ -n "${DIFF_REVIEW_PYTHON:-}" ]]; then
    exec "$DIFF_REVIEW_PYTHON" "$@"
elif command -v uv >/dev/null 2>&1; then
    export UV_PROJECT_ENVIRONMENT="${UV_PROJECT_ENVIRONMENT:-$HOME/.cache/uv-venvs/diff-review}"
    exec uv run -q --project "$SKILL_DIR" python "$@"
elif command -v python3 >/dev/null 2>&1; then
    exec python3 "$@"
else
    echo "ERROR: uv も python3 も無いため Python スクリプトを実行できない" >&2
    exit 127
fi
