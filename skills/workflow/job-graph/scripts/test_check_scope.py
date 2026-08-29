"""check_scope.py のユニットテスト。純粋関数（parse_* / judge / render / parse_args）を検証する。

gh / git の実行はしない（collect_* は実機確認に委ねる）。
"""
from __future__ import annotations

import pytest

import check_scope as cs


def fc(path, adds=1, dels=0):
    return cs.FileChange(path=path, additions=adds, deletions=dels)


# ------------------------------------------------------------
# judge
# ------------------------------------------------------------


def test_judge_pass_when_files_and_scale_within():
    changed = (fc("src/a.py", 30, 10), fc("tests/test_a.py", 20, 0))
    res = cs.judge(changed, cs.Expectation(files=("src/a.py", "tests/test_a.py"), scale=30))
    assert res == cs.ScopeResult(
        verdict=cs.Verdict.PASS,
        changed=changed,
        unexpected=(),
        total_lines=60,
        scale_limit=60,
        reasons=(),
        warnings=(),
    )


def test_judge_scale_exactly_double_passes_and_over_fails():
    changed = (fc("src/a.py", 40, 20),)  # 60 行
    ok = cs.judge(changed, cs.Expectation(files=("src/a.py",), scale=30))
    assert ok.verdict is cs.Verdict.PASS
    over = cs.judge((fc("src/a.py", 40, 21),), cs.Expectation(files=("src/a.py",), scale=30))
    assert over.verdict is cs.Verdict.FAIL
    assert over.total_lines == 61 and over.scale_limit == 60
    assert any("上限 60" in r for r in over.reasons)


def test_judge_unexpected_file_fails():
    changed = (fc("src/a.py"), fc("src/other.py"))
    res = cs.judge(changed, cs.Expectation(files=("src/a.py",)))
    assert res.verdict is cs.Verdict.FAIL
    assert res.unexpected == ("src/other.py",)
    assert res.scale_limit == 0  # 規模照合なし


def test_judge_excludes_tmp_claude():
    changed = (fc("src/a.py", 5, 0), fc("tmp_claude/x/pr-body.md", 500, 0))
    res = cs.judge(changed, cs.Expectation(files=("src/a.py",), scale=5))
    assert res.verdict is cs.Verdict.PASS
    assert res.changed == (fc("src/a.py", 5, 0),)
    assert res.total_lines == 5


def test_judge_skip_without_expectation():
    changed = (fc("src/a.py"),)
    res = cs.judge(changed, cs.Expectation())
    assert res == cs.ScopeResult(
        verdict=cs.Verdict.SKIP,
        changed=changed,
        unexpected=(),
        total_lines=1,
        scale_limit=0,
        reasons=("期待ファイル一覧も規模目安も無いため判定できない（親が手で確認する）",),
        warnings=(),
    )


def test_judge_scale_only():
    res = cs.judge((fc("anything.py", 10, 0),), cs.Expectation(scale=10))
    assert res.verdict is cs.Verdict.PASS
    assert res.unexpected == ()


def test_judge_carries_warnings():
    res = cs.judge((fc("a"),), cs.Expectation(files=("a",)), warnings=("w1",))
    assert res.warnings == ("w1",)
    assert res.verdict is cs.Verdict.PASS


# ------------------------------------------------------------
# parse_numstat / parse_pr_json
# ------------------------------------------------------------


def test_parse_numstat_handles_binary_and_blank():
    text = "10\t2\tsrc/a.py\n-\t-\timg/logo.png\n\n3\t0\tdocs/x.md\n"
    assert cs.parse_numstat(text) == (
        fc("src/a.py", 10, 2),
        fc("img/logo.png", 0, 0),
        fc("docs/x.md", 3, 0),
    )


def test_parse_pr_json_normalizes_and_warns_on_truncation():
    raw = {
        "additions": 12,
        "deletions": 3,
        "changedFiles": 3,
        "files": [
            {"path": "src/a.py", "additions": 10, "deletions": 3},
            {"path": "src/b.py", "additions": 2, "deletions": 0},
        ],
    }
    got = cs.parse_pr_json(raw)
    assert got.changes == (fc("src/a.py", 10, 3), fc("src/b.py", 2, 0))
    assert len(got.warnings) == 1 and "3 に対し files は 2 件" in got.warnings[0]


def test_parse_pr_json_no_warning_when_complete():
    raw = {"changedFiles": 1, "files": [{"path": "a", "additions": 1, "deletions": 0}]}
    assert cs.parse_pr_json(raw) == cs.Collected(changes=(fc("a", 1, 0),))


def test_parse_pr_json_rejects_bad_shape():
    with pytest.raises(cs.ScopeError):
        cs.parse_pr_json([])
    with pytest.raises(cs.ScopeError):
        cs.parse_pr_json({"files": "x"})


# ------------------------------------------------------------
# render / exit_code
# ------------------------------------------------------------


def test_render_sections_and_verdict_line():
    res = cs.judge((fc("src/a.py", 3, 1), fc("src/z.py", 1, 0)), cs.Expectation(files=("src/a.py",), scale=2))
    out = cs.render(res)
    assert "=== CHANGED" in out and "=== UNEXPECTED" in out and "=== SCALE" in out
    assert "  src/z.py" in out.split("=== UNEXPECTED")[1]
    assert "実測 5 行 / 目安 2 行 / 上限 4 行" in out
    assert out.splitlines()[-1] == "VERDICT: FAIL"
    assert cs.exit_code(res) == 1


def test_render_pass_and_skip_exit_zero():
    ok = cs.judge((fc("a"),), cs.Expectation(files=("a",)))
    assert cs.render(ok).endswith("VERDICT: PASS") and cs.exit_code(ok) == 0
    skip = cs.judge((fc("a"),), cs.Expectation())
    assert cs.render(skip).endswith("VERDICT: SKIP") and cs.exit_code(skip) == 0


def test_render_prints_warnings_first():
    res = cs.judge((fc("a"),), cs.Expectation(files=("a",)), warnings=("truncated",))
    assert cs.render(res).splitlines()[0] == "WARNING: truncated"


# ------------------------------------------------------------
# parse_args
# ------------------------------------------------------------


def test_parse_args_pr_source():
    opts = cs.parse_args(["check_scope.py", "--pr", "42", "--expected-file", "a", "--expected-file", "b", "--expected-scale", "10"])
    assert opts == cs.Options(
        source=cs.PrSource(42), worktree=".", expectation=cs.Expectation(files=("a", "b"), scale=10)
    )


def test_parse_args_base_source_with_worktree():
    opts = cs.parse_args(["check_scope.py", "--base", "main", "-C", "/wt"])
    assert opts == cs.Options(source=cs.BaseSource("main"), worktree="/wt", expectation=cs.Expectation())


def test_parse_args_pr_and_base_are_exclusive():
    with pytest.raises(SystemExit):
        cs.parse_args(["check_scope.py", "--pr", "1", "--base", "main"])
    with pytest.raises(SystemExit):
        cs.parse_args(["check_scope.py"])
    with pytest.raises(SystemExit):
        cs.parse_args(["check_scope.py", "--base", "main", "--expected-scale", "-1"])
