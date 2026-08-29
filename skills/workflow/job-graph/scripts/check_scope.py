#!/usr/bin/env python3
"""job-graph 計画突合（決定論 CLI）。PR またはローカル diff の変更を計画の期待と機械比較する。

ワーカーは PR 作成前に `--base <base>` で自分の worktree を、親は PR 報告を受けたら
`--pr <番号>` で PR の変更を突合する。判定はどちらも同じ純粋関数（judge）で行う:

- 期待ファイル一覧（--expected-file、繰り返し可）に無いファイルが 1 つでも変更されていれば FAIL
- 変更行数（追加 + 削除）が 規模目安（--expected-scale）× SCALE_FACTOR を超えれば FAIL
- 期待が両方とも無ければ SKIP（判定不能。親が手で確認する）
- `tmp_claude/**` 配下は突合から除外する（一時出力先。境界宣言でも自動許可される）

出力は `=== CHANGED ===` / `=== UNEXPECTED ===` / `=== SCALE ===` と末尾の `VERDICT: PASS|FAIL|SKIP`。
終了コード: PASS/SKIP = 0、FAIL = 1、収集失敗（gh/git の実行エラー）= 2。

使い方:
    python3 check_scope.py --pr 42 --expected-file src/a.py --expected-file tests/test_a.py --expected-scale 120
    python3 check_scope.py --base main -C <worktree> --expected-file src/a.py --expected-scale 120

依存は stdlib のみ。判定は AI の見積り（expected_scale）を補助に使うが、主判定はファイル一覧。

設計: 純粋関数（parse_args / parse_numstat / parse_pr_json / judge / render / exit_code）は
副作用を持たせない。gh / git の実行は collect_pr / collect_local に閉じる。
"""
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
from dataclasses import dataclass
from enum import Enum
from typing import Union

# 規模目安に対する許容倍率。目安は AI の見積りなので、ちょうど倍までを許容する（閾値は 1 か所）。
SCALE_FACTOR = 2

# 突合から除外するパス接頭辞（一時出力先。境界宣言でも自動で許可される）。
EXCLUDED_PREFIXES = ("tmp_claude/",)


class ScopeError(Exception):
    """gh / git による変更の収集に失敗した場合。"""


class Verdict(Enum):
    PASS = "PASS"
    FAIL = "FAIL"
    SKIP = "SKIP"


@dataclass(frozen=True)
class FileChange:
    path: str
    additions: int
    deletions: int


@dataclass(frozen=True)
class Expectation:
    """計画から起こした期待。files が空 = ファイル照合なし、scale が 0 = 規模照合なし。"""

    files: tuple[str, ...] = ()
    scale: int = 0


@dataclass(frozen=True)
class ScopeResult:
    verdict: Verdict
    changed: tuple[FileChange, ...]
    unexpected: tuple[str, ...]
    total_lines: int
    scale_limit: int  # 0 = 規模照合なし
    reasons: tuple[str, ...]
    warnings: tuple[str, ...]


@dataclass(frozen=True)
class PrSource:
    number: int


@dataclass(frozen=True)
class BaseSource:
    ref: str


Source = Union[PrSource, BaseSource]


@dataclass(frozen=True)
class Options:
    source: Source
    worktree: str
    expectation: Expectation


@dataclass(frozen=True)
class Collected:
    """収集アダプタの戻り。変更一覧と、収集時に気付いた注意（件数不一致など）。"""

    changes: tuple[FileChange, ...]
    warnings: tuple[str, ...] = ()


# ============================================================
# 純粋関数
# ============================================================


def parse_numstat(text: str) -> tuple[FileChange, ...]:
    """`git diff --numstat` の出力 -> FileChange 列。バイナリ（`-`）は 0 行扱い。"""
    changes: list[FileChange] = []
    for line in text.splitlines():
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        adds, dels, path = parts
        changes.append(
            FileChange(
                path=path.strip(),
                additions=0 if adds == "-" else int(adds),
                deletions=0 if dels == "-" else int(dels),
            )
        )
    return tuple(changes)


def parse_pr_json(raw: object) -> Collected:
    """`gh pr view --json additions,deletions,changedFiles,files` の JSON -> Collected。

    files が changedFiles より少なければ（API の件数上限など）警告を付ける。
    """
    if not isinstance(raw, dict):
        raise ScopeError("gh pr view の応答がオブジェクトではない")
    files_raw = raw.get("files")
    if not isinstance(files_raw, list):
        raise ScopeError("gh pr view の応答に files 配列が無い")
    changes: list[FileChange] = []
    for f in files_raw:
        if not isinstance(f, dict) or not isinstance(f.get("path"), str):
            raise ScopeError(f"files の要素が不正: {f!r}")
        changes.append(
            FileChange(
                path=f["path"],
                additions=int(f.get("additions", 0) or 0),
                deletions=int(f.get("deletions", 0) or 0),
            )
        )
    warnings: list[str] = []
    changed_files = raw.get("changedFiles")
    if isinstance(changed_files, int) and changed_files > len(changes):
        warnings.append(
            f"PR の変更ファイル数 {changed_files} に対し files は {len(changes)} 件しか取得できていない"
            "（gh の件数上限の可能性。未取得分は突合に掛からない）"
        )
    return Collected(changes=tuple(changes), warnings=tuple(warnings))


def is_excluded(path: str) -> bool:
    return any(path.startswith(p) for p in EXCLUDED_PREFIXES)


def judge(changed: tuple[FileChange, ...], expectation: Expectation, warnings: tuple[str, ...] = ()) -> ScopeResult:
    """変更一覧 × 期待 -> ScopeResult（純粋）。"""
    considered = tuple(c for c in changed if not is_excluded(c.path))
    total = sum(c.additions + c.deletions for c in considered)
    scale_limit = expectation.scale * SCALE_FACTOR if expectation.scale > 0 else 0
    reasons: list[str] = []

    if not expectation.files and not expectation.scale:
        return ScopeResult(
            verdict=Verdict.SKIP,
            changed=considered,
            unexpected=(),
            total_lines=total,
            scale_limit=0,
            reasons=("期待ファイル一覧も規模目安も無いため判定できない（親が手で確認する）",),
            warnings=warnings,
        )

    unexpected: tuple[str, ...] = ()
    if expectation.files:
        allowed = set(expectation.files)
        unexpected = tuple(c.path for c in considered if c.path not in allowed)
        if unexpected:
            reasons.append(f"計画に無いファイルの変更: {len(unexpected)} 件")
    if scale_limit and total > scale_limit:
        reasons.append(f"変更行数 {total} が上限 {scale_limit}（目安 {expectation.scale} × {SCALE_FACTOR}）を超過")

    return ScopeResult(
        verdict=Verdict.FAIL if reasons else Verdict.PASS,
        changed=considered,
        unexpected=unexpected,
        total_lines=total,
        scale_limit=scale_limit,
        reasons=tuple(reasons),
        warnings=warnings,
    )


def render(result: ScopeResult) -> str:
    out: list[str] = []
    for w in result.warnings:
        out.append(f"WARNING: {w}")
    out.append("=== CHANGED (path adds dels; tmp_claude/ は除外済み) ===")
    if result.changed:
        for c in result.changed:
            out.append(f"  {c.path}\t+{c.additions}\t-{c.deletions}")
    else:
        out.append("  (なし)")
    out.append("=== UNEXPECTED (計画に無いファイル) ===")
    if result.unexpected:
        for p in result.unexpected:
            out.append(f"  {p}")
    else:
        out.append("  (なし)")
    out.append("=== SCALE ===")
    if result.scale_limit:
        scale = result.scale_limit // SCALE_FACTOR
        out.append(f"  実測 {result.total_lines} 行 / 目安 {scale} 行 / 上限 {result.scale_limit} 行")
    else:
        out.append(f"  実測 {result.total_lines} 行 / 目安なし（規模照合なし）")
    for r in result.reasons:
        out.append(f"REASON: {r}")
    out.append(f"VERDICT: {result.verdict.value}")
    return "\n".join(out)


def exit_code(result: ScopeResult) -> int:
    return 1 if result.verdict is Verdict.FAIL else 0


def parse_args(argv: list[str]) -> Options:
    parser = argparse.ArgumentParser(
        prog="check_scope.py",
        description="PR またはローカル diff の変更を計画の期待（ファイル一覧・規模目安）と突合する",
    )
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--pr", type=int, metavar="N", help="突合する PR 番号（gh pr view で収集）")
    src.add_argument("--base", metavar="REF", help="ローカル diff の base（git diff --numstat <REF>...HEAD）")
    parser.add_argument("-C", dest="worktree", default=".", metavar="DIR", help="git / gh を実行する worktree")
    parser.add_argument(
        "--expected-file",
        action="append",
        default=[],
        metavar="PATH",
        help="計画に書かれた変更ファイル（リポジトリルート相対。繰り返し可。glob 不可）",
    )
    parser.add_argument(
        "--expected-scale",
        type=int,
        default=0,
        metavar="N",
        help=f"計画の規模目安（追加 + 削除の行数）。実測が N × {SCALE_FACTOR} を超えると FAIL。0 = 照合なし",
    )
    ns = parser.parse_args(argv[1:])
    if ns.expected_scale < 0:
        parser.error("--expected-scale は非負整数")
    source: Source = PrSource(ns.pr) if ns.pr is not None else BaseSource(ns.base)
    return Options(
        source=source,
        worktree=ns.worktree,
        expectation=Expectation(
            files=tuple(p.strip() for p in ns.expected_file if p.strip()),
            scale=ns.expected_scale,
        ),
    )


# ============================================================
# 副作用（gh / git の実行）
# ============================================================


def _run(cmd: list[str], cwd: str) -> str:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise ScopeError(f"{shlex.join(cmd)} が失敗: {proc.stderr.strip()}")
    return proc.stdout


def collect_pr(number: int, worktree: str) -> Collected:
    raw = _run(["gh", "pr", "view", str(number), "--json", "additions,deletions,changedFiles,files"], worktree)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ScopeError(f"gh pr view の応答が不正な JSON: {e}") from e
    return parse_pr_json(data)


def collect_local(base: str, worktree: str) -> Collected:
    text = _run(["git", "diff", "--numstat", f"{base}...HEAD"], worktree)
    return Collected(changes=parse_numstat(text))


def collect(opts: Options) -> Collected:
    if isinstance(opts.source, PrSource):
        return collect_pr(opts.source.number, opts.worktree)
    return collect_local(opts.source.ref, opts.worktree)


def main(argv: list[str]) -> int:
    opts = parse_args(argv)
    try:
        collected = collect(opts)
    except ScopeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    result = judge(collected.changes, opts.expectation, collected.warnings)
    print(render(result))
    return exit_code(result)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
