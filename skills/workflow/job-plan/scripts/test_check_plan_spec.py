from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

import check_plan_spec as cps

SCRIPT = Path(__file__).resolve().parent / "check_plan_spec.py"


PLAN_OK = """# 計画: demo

## 1. 目的・背景

REQ-01 と REQ-02 を満たす。

## 2. タスク一覧と依存グラフ

| id | 概要 | branch | 依存 |
| --- | --- | --- | --- |
| A | ロガー整理 | refactor-logger | なし |
| B1 | 設定追加 | feat-config-retry | なし |
| B2 | クライアント実装 | feat-client-retry | B1 |

## 3. タスク詳細

### A: ロガー整理
- branch: `refactor-logger`
- 依存: なし
- 対応要求: REQ-01
- 完了条件: 既存テストが全て通る
- 変更対象:
  ```
  pkg/logger/logger.go
  pkg/logger/logger_test.go
  ```
- 規模目安: 120 行
- 境界:
  ```
  pkg/logger/**
  ```
- コミット計画:
  1. `refactor(logger): インターフェースを整理する`

### B1: 設定追加
- branch: `feat-config-retry`
- 依存: なし
- 対応要求: REQ-02
- 完了条件: 設定の読み込みテストが通る
- 変更対象:
  ```
  internal/config/retry.go
  tests/config/retry_test.go
  ```
- 規模目安: 80 行
- 境界:
  ```
  internal/config/**
  tests/config/**
  ```
- コミット計画:
  1. `feat(config): リトライ設定を追加する`

### B2: クライアント実装
- branch: `feat-client-retry`
- 依存: `B1`
- 対応要求: REQ-02
- 完了条件: リトライの単体テストが通る
- 変更対象:
  ```
  internal/client/retry.go
  internal/client/client.go
  tests/client/retry_test.go
  ```
- 規模目安: 150 行
- 境界:
  ```
  internal/client/**
  tests/client/**
  ```
- コミット計画:
  1. `feat(client): リトライを実装する`

## 4. 事前裁定

- 裁定: 既存 API の後方互換は保つ / 承認: ユーザー確認済み

## 5. スコープ外

- メトリクスの追加

## 6. 引き渡し

- 起動: `/job-graph tmp_claude/demo/plan.md`
"""


def tasks_ok() -> list[dict[str, object]]:
    return [
        {
            "id": "A",
            "branch": "refactor-logger",
            "depends_on": [],
            "prompt": "x",
            "boundary": ["pkg/logger/**"],
            "expected_files": ["pkg/logger/logger.go", "pkg/logger/logger_test.go"],
            "expected_scale": 120,
        },
        {
            "id": "B1",
            "branch": "feat-config-retry",
            "depends_on": [],
            "prompt": "x",
            "boundary": ["internal/config/**", "tests/config/**"],
            "expected_files": ["internal/config/retry.go", "tests/config/retry_test.go"],
            "expected_scale": 80,
        },
        {
            "id": "B2",
            "branch": "feat-client-retry",
            "depends_on": ["B1"],
            "prompt": "x",
            "boundary": ["internal/client/**", "tests/client/**"],
            "expected_files": [
                "internal/client/retry.go",
                "internal/client/client.go",
                "tests/client/retry_test.go",
            ],
            "expected_scale": 150,
        },
    ]


def spec_ok(
    plan: str = "tmp_claude/demo/plan.md", tasks: list[dict[str, object]] | None = None
) -> dict[str, object]:
    return {"default_base": "main", "plan": plan, "tasks": tasks_ok() if tasks is None else tasks}


CWD = "/repo"
PLAN_PATH = "tmp_claude/demo/plan.md"


def verdict(plan_text: str, spec: dict[str, object], plan_path: str = PLAN_PATH) -> cps.Verdict:
    return cps.compare(cps.parse_plan(plan_text), cps.parse_spec(spec), plan_path, CWD)


def errors(v: cps.Verdict) -> list[str]:
    return [f.message for f in v.findings if f.severity == "ERROR"]


def warnings(v: cps.Verdict) -> list[str]:
    return [f.message for f in v.findings if f.severity == "WARNING"]


# ---------- parse_plan ----------


def test_parse_plan_reads_sections_and_tasks() -> None:
    doc = cps.parse_plan(PLAN_OK)
    assert sorted(doc.chapters) == [1, 2, 3, 4, 5, 6]
    assert [t.id for t in doc.tasks] == ["A", "B1", "B2"]
    b2 = doc.tasks[2]
    assert b2.title == "クライアント実装"
    assert b2.branch == "feat-client-retry"
    assert b2.depends_on == frozenset({"B1"})
    assert b2.expected_files == frozenset(
        {"internal/client/retry.go", "internal/client/client.go", "tests/client/retry_test.go"}
    )
    assert b2.expected_scale == 150
    assert b2.boundary == frozenset({"internal/client/**", "tests/client/**"})
    assert b2.reqs == frozenset({"REQ-02"})
    assert set(cps.TASK_LABELS) <= b2.labels


def test_parse_id_list_variants() -> None:
    assert cps.parse_id_list("なし") == frozenset()
    assert cps.parse_id_list("`A`, `B`") == frozenset({"A", "B"})
    assert cps.parse_id_list("A、B") == frozenset({"A", "B"})
    assert cps.parse_id_list("") == frozenset()


def test_inline_none_for_paths() -> None:
    text = PLAN_OK.replace(
        "- 境界:\n  ```\n  pkg/logger/**\n  ```",
        "- 境界: なし",
    )
    doc = cps.parse_plan(text)
    assert doc.tasks[0].boundary == frozenset()
    assert "境界" in doc.tasks[0].labels


# ---------- compare: PASS ----------


def test_pass_on_consistent_inputs() -> None:
    v = verdict(PLAN_OK, spec_ok())
    assert errors(v) == []
    assert warnings(v) == []
    assert v.passed
    assert cps.render(v).splitlines()[-1] == "VERDICT: PASS"


def test_auto_boundary_is_ignored_on_both_sides() -> None:
    tasks = tasks_ok()
    tasks[0]["boundary"] = ["pkg/logger/**", "tmp_claude/**"]
    assert errors(verdict(PLAN_OK, spec_ok(tasks=tasks))) == []


def test_plan_path_relative_resolution_matches_job_graph_rule() -> None:
    # spec の plan は cwd 基準で絶対化される。引数側も同じ規則で揃えてから比較する。
    assert errors(verdict(PLAN_OK, spec_ok(), plan_path="/repo/tmp_claude/demo/plan.md")) == []
    assert errors(verdict(PLAN_OK, spec_ok(plan="/repo/tmp_claude/demo/plan.md"))) == []
    assert errors(verdict(PLAN_OK, spec_ok(plan="./tmp_claude/../tmp_claude/demo/plan.md"))) == []


# ---------- compare: FAIL ----------


def test_fail_when_task_sets_differ() -> None:
    tasks = tasks_ok()
    tasks.pop()
    tasks.append({"id": "C", "branch": "x", "expected_scale": 0})
    errs = errors(verdict(PLAN_OK, spec_ok(tasks=tasks)))
    assert any("spec に無い task: B2" in e for e in errs)
    assert any("第 3 章に無い task: C" in e for e in errs)


def test_fail_on_expected_files_mismatch() -> None:
    text = PLAN_OK.replace("  pkg/logger/logger_test.go\n", "")
    errs = errors(verdict(text, spec_ok()))
    assert len(errs) == 1
    assert "A: 変更対象 / expected_files" in errs[0]
    assert "spec のみ: pkg/logger/logger_test.go" in errs[0]


def test_fail_on_boundary_mismatch() -> None:
    text = PLAN_OK.replace("  tests/client/**\n", "")
    errs = errors(verdict(text, spec_ok()))
    assert errs and "B2: 境界 / boundary" in errs[0]


def test_fail_on_scale_mismatch_and_missing_int() -> None:
    errs = errors(verdict(PLAN_OK.replace("- 規模目安: 120 行", "- 規模目安: 130 行"), spec_ok()))
    assert errs == ["A: 規模目安 / expected_scale が一致しない（plan: 130 / spec: 120）"]
    errs = errors(verdict(PLAN_OK.replace("- 規模目安: 120 行", "- 規模目安: 未定"), spec_ok()))
    assert errs == ["A: 規模目安に整数が無い"]


def test_fail_on_depends_on_mismatch() -> None:
    errs = errors(verdict(PLAN_OK.replace("- 依存: `B1`", "- 依存: なし"), spec_ok()))
    assert errs == ["B2: 依存 が一致しない（plan のみ: （なし） / spec のみ: B1）"]


def test_fail_on_branch_mismatch() -> None:
    errs = errors(verdict(PLAN_OK.replace("- branch: `refactor-logger`", "- branch: `other`"), spec_ok()))
    assert errs == ["A: branch が一致しない（plan: 'other' / spec: 'refactor-logger'）"]


def test_fail_on_missing_labels() -> None:
    text = PLAN_OK.replace("- コミット計画:\n  1. `refactor(logger): インターフェースを整理する`\n", "")
    errs = errors(verdict(text, spec_ok()))
    assert errs == ["A: 小見出しが欠けている: - コミット計画:"]


def test_fail_on_missing_chapter() -> None:
    text = PLAN_OK.replace("## 5. スコープ外\n\n- メトリクスの追加\n", "")
    errs = errors(verdict(text, spec_ok()))
    assert errs == ["第 5 章 `## 5. スコープ外` が無い"]


def test_fail_on_plan_path_mismatch_or_empty() -> None:
    errs = errors(verdict(PLAN_OK, spec_ok(plan="tmp_claude/other/plan.md")))
    assert len(errs) == 1 and "spec の plan が渡した plan.md と一致しない" in errs[0]
    errs = errors(verdict(PLAN_OK, spec_ok(plan="")))
    assert errs == ["spec の plan が空（plan.md のパスを書く）"]


def test_rulings_format() -> None:
    ok_none = PLAN_OK.replace("- 裁定: 既存 API の後方互換は保つ / 承認: ユーザー確認済み", "- 該当なし")
    assert errors(verdict(ok_none, spec_ok())) == []
    withdrawn = PLAN_OK.replace("承認: ユーザー確認済み", "撤回済み（2026-09-06 10:00 JST）")
    assert errors(verdict(withdrawn, spec_ok())) == []
    unconfirmed = PLAN_OK.replace("承認: ユーザー確認済み", "承認: 親のみ（未確認）")
    errs = errors(verdict(unconfirmed, spec_ok()))
    assert len(errs) == 1 and "ユーザー未確認の裁定" in errs[0]
    prose = PLAN_OK.replace("- 裁定: 既存 API の後方互換は保つ / 承認: ユーザー確認済み", "後方互換は保つ")
    errs = errors(verdict(prose, spec_ok()))
    assert len(errs) == 1 and "様式でない行" in errs[0]
    empty = PLAN_OK.replace("- 裁定: 既存 API の後方互換は保つ / 承認: ユーザー確認済み\n", "")
    errs = errors(verdict(empty, spec_ok()))
    assert len(errs) == 1 and "第 4 章（事前裁定）が空" in errs[0]


def test_duplicate_task_ids() -> None:
    text = PLAN_OK.replace("### B1: 設定追加", "### A: 設定追加")
    errs = errors(verdict(text, spec_ok()))
    assert any("重複する task id: A" in e for e in errs)


# ---------- WARNING ----------


def test_warning_on_empty_scope_out() -> None:
    text = PLAN_OK.replace("- メトリクスの追加\n", "")
    v = verdict(text, spec_ok())
    assert errors(v) == []
    assert any("第 5 章（スコープ外）が空" in w for w in warnings(v))


def test_warning_on_orphan_req() -> None:
    text = PLAN_OK.replace("REQ-01 と REQ-02 を満たす。", "REQ-01 と REQ-02 と REQ-03 を満たす。")
    v = verdict(text, spec_ok())
    assert errors(v) == []
    assert warnings(v) == ["第 1 章の REQ-# がどの task にも対応付いていない: REQ-03"]


# ---------- parse_spec ----------


def test_parse_spec_rejects_broken_structure() -> None:
    with pytest.raises(cps.InputError):
        cps.parse_spec([])
    with pytest.raises(cps.InputError):
        cps.parse_spec({"tasks": []})
    with pytest.raises(cps.InputError):
        cps.parse_spec({"tasks": [{"id": "A", "expected_scale": -1}]})
    with pytest.raises(cps.InputError):
        cps.parse_spec({"tasks": [{"id": "A", "expected_files": "a.py"}]})


# ---------- CLI ----------


def run_cli(tmp_path: Path, plan_text: str, spec: dict[str, object]) -> subprocess.CompletedProcess[str]:
    job = tmp_path / "tmp_claude" / "demo"
    (job / "job-graph").mkdir(parents=True)
    (job / "plan.md").write_text(plan_text, encoding="utf-8")
    (job / "job-graph" / "spec.json").write_text(json.dumps(spec, ensure_ascii=False), encoding="utf-8")
    return subprocess.run(
        [sys.executable, str(SCRIPT), "tmp_claude/demo/plan.md", "tmp_claude/demo/job-graph/spec.json"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )


def test_cli_pass(tmp_path: Path) -> None:
    proc = run_cli(tmp_path, PLAN_OK, spec_ok())
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert proc.stdout.rstrip().splitlines()[-1] == "VERDICT: PASS"


def test_cli_fail_exit_1(tmp_path: Path) -> None:
    proc = run_cli(tmp_path, PLAN_OK.replace("- 規模目安: 120 行", "- 規模目安: 1 行"), spec_ok())
    assert proc.returncode == 1
    assert proc.stdout.rstrip().splitlines()[-1] == "VERDICT: FAIL"


def test_cli_unreadable_exit_2(tmp_path: Path) -> None:
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "nope.md", "nope.json"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 2
    assert "VERDICT: FAIL" in proc.stdout
