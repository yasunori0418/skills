"""PATH の pyright（strict）を pytest から実行し、型検査の失敗をテストの失敗にする。

pyright 本体は uv の dev 依存に入れない（PyPI 版は実行時に node を取りに行き nix sandbox で
動かない）。nix の pkgs.pyright を checks.pytest と devShell が供給する。無ければ skip ではなく
失敗させ、CI で型検査が黙って素通りしないようにする。
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_pyright_strict() -> None:
    pyright = shutil.which("pyright")
    assert pyright is not None, "pyright が PATH に無い（devShell / checks.pytest は nix の pkgs.pyright を供給する）"
    # --pythonpath: pyright は site-packages の探索に PATH の python を使う。pytest を持つ
    # この interpreter を明示しないと `import pytest` が reportMissingImports になる。
    proc = subprocess.run(
        [pyright, "--project", str(PROJECT_ROOT), "--pythonpath", sys.executable],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, f"pyright strict が失敗:\n{proc.stdout}\n{proc.stderr}"
