from __future__ import annotations

import json
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import cast

import pytest

import check_plan_spec as cps
import create_issues as ci
from test_check_plan_spec import PLAN_OK, spec_ok, tasks_ok

PLAN_PATH = "tmp-agents/demo/plan.md"
SPEC_PATH = "tmp-agents/demo/job-graph/spec.json"
REPO_JSON = json.dumps({"nameWithOwner": "o/r", "url": "https://github.com/o/r"})

Responder = Callable[[Sequence[str], str], ci.GhResult | None]


@dataclass
class Call:
    args: tuple[str, ...]
    input: str


@dataclass
class FakeGhRunner:
    """呼び出し列を記録し、responder が None を返した呼び出しは成功（空出力）にする。"""

    responder: Responder
    calls: list[Call] = field(default_factory=lambda: [])
    next_issue: int = 100

    def run(self, args: Sequence[str], input: str = "") -> ci.GhResult:
        argv = tuple(args)
        self.calls.append(Call(args=argv, input=input))
        res = self.responder(argv, input)
        args = argv
        if res is not None:
            return res
        if args[:3] == ("gh", "repo", "view"):
            return ci.GhResult(0, REPO_JSON)
        if args[:3] == ("gh", "issue", "create"):
            self.next_issue += 1
            return ci.GhResult(0, f"\nhttps://github.com/o/r/issues/{self.next_issue}\n")
        if args[:2] == ("gh", "api") and args[-2:] == ("--jq", ".id"):
            number = args[2].rsplit("/", 1)[-1]
            return ci.GhResult(0, f"9000{number}\n")
        if args[:3] == ("gh", "pr", "list"):
            return ci.GhResult(0, "[]")
        return ci.GhResult(0, "")

    def argv(self) -> list[tuple[str, ...]]:
        return [c.args for c in self.calls]


@dataclass
class FakeEffects:
    issues: list[tuple[str, int]] = field(default_factory=lambda: [])
    plan_lines: list[str] = field(default_factory=lambda: [])
    infos: list[str] = field(default_factory=lambda: [])
    warns: list[str] = field(default_factory=lambda: [])

    def set_issue(self, task_id: str, number: int) -> None:
        self.issues.append((task_id, number))

    def append_plan(self, lines: Sequence[str]) -> None:
        self.plan_lines.extend(lines)

    def info(self, message: str) -> None:
        self.infos.append(message)

    def warn(self, message: str) -> None:
        self.warns.append(message)


def no_override(_args: Sequence[str], _input: str) -> ci.GhResult | None:
    return None


def opts(epic: int = 0, sync: bool = False) -> ci.Options:
    return ci.Options(plan=PLAN_PATH, spec=SPEC_PATH, epic=epic, sync=sync)


def spec_with_issues(issues: dict[str, int]) -> dict[str, object]:
    tasks = tasks_ok()
    for t in tasks:
        tid = t["id"]
        assert isinstance(tid, str)
        if tid in issues:
            t["issue"] = issues[tid]
    return spec_ok(tasks=tasks)


# ---------- 純粋関数 ----------


def test_parse_plan_text_slices_task_sections() -> None:
    plan = ci.parse_plan_text(PLAN_PATH, PLAN_OK)
    assert plan.job == "demo"
    assert plan.heading == "計画: demo"
    assert [t.id for t in plan.tasks] == ["A", "B1", "B2"]
    b1 = plan.task("B1")
    assert b1 is not None
    assert b1.title == "設定追加"
    assert b1.branch == "feat-config-retry"
    assert b1.section.startswith("### B1: 設定追加\n- branch: `feat-config-retry`")
    assert "### B2" not in b1.section
    assert b1.section.rstrip().endswith("1. `feat(config): リトライ設定を追加する`")


def test_parse_created_number_and_sub_issues() -> None:
    assert ci.parse_created_number("Creating issue in o/r\n\nhttps://github.com/o/r/issues/12\n") == 12
    with pytest.raises(ci.GhError):
        ci.parse_created_number("nothing here")
    subs = ci.parse_sub_issues('[{"number": 1, "title": "a", "state": "open"}][{"number": 2, "title": "b", "state": "closed"}]')
    assert subs == (ci.RemoteSubIssue(1, "a", "open"), ci.RemoteSubIssue(2, "b", "closed"))
    assert ci.parse_sub_issues("") == ()
    assert ci.parse_pr_exists("[]") is False
    assert ci.parse_pr_exists('[{"number": 5}]') is True


def test_plan_actions_new_only() -> None:
    plan = ci.parse_plan_text(PLAN_PATH, PLAN_OK)
    spec = ci.parse_spec_tasks(spec_with_issues({"A": 11}))
    actions = ci.plan_actions(plan, spec, 10, None)
    assert [type(a).__name__ for a in actions] == ["CreateSubIssue", "CreateSubIssue"]
    first = actions[0]
    assert isinstance(first, ci.CreateSubIssue)
    assert first.task_id == "B1"
    assert first.title == "demo: B1 設定追加"
    assert first.body.startswith("epic: #10\nローカル計画: `tmp-agents/demo/plan.md`\n\n### B1: 設定追加")


def test_plan_actions_sync_paths() -> None:
    plan = ci.parse_plan_text(PLAN_PATH, PLAN_OK)
    spec = ci.parse_spec_tasks(spec_with_issues({"A": 11, "B1": 12}))
    remote = ci.RemoteState(
        sub_issues=(
            ci.RemoteSubIssue(11, "demo: A", "open"),
            ci.RemoteSubIssue(12, "demo: B1", "open"),
            ci.RemoteSubIssue(99, "demo: old", "open"),
            ci.RemoteSubIssue(98, "demo: older", "closed"),
        ),
        started={"refactor-logger": True, "feat-config-retry": False},
    )
    actions = ci.plan_actions(plan, spec, 10, remote)
    assert [type(a).__name__ for a in actions] == ["NotifySubIssue", "UpdateSubIssue", "CreateSubIssue", "CloseSubIssue"]
    closed = actions[3]
    assert isinstance(closed, ci.CloseSubIssue)
    assert closed.number == 99


def test_plan_actions_rejects_task_missing_in_plan() -> None:
    plan = ci.parse_plan_text(PLAN_PATH, PLAN_OK)
    tasks = tasks_ok()
    tasks.append({"id": "Z", "branch": "z"})
    with pytest.raises(cps.InputError):
        ci.plan_actions(plan, ci.parse_spec_tasks(spec_ok(tasks=tasks)), 1, None)


def test_handoff_lines_skip_existing_urls() -> None:
    repo = ci.Repo("o/r", "https://github.com/o/r")
    text = "## 6. 引き渡し\n- epic: https://github.com/o/r/issues/10\n"
    lines = ci.handoff_lines(text, repo, 10, [("A", 11), ("B1", 12)])
    assert lines == ("- sub-issue: A → https://github.com/o/r/issues/11", "- sub-issue: B1 → https://github.com/o/r/issues/12")


# ---------- execute: 新規 epic ----------


def test_new_epic_creates_links_and_writes_back() -> None:
    runner = FakeGhRunner(no_override)
    fx = FakeEffects()
    rc = ci.run(opts(), runner, fx, PLAN_OK, spec_ok())
    assert rc == 0, fx.warns
    argv = runner.argv()
    assert argv[0] == ("gh", "auth", "status")
    assert argv[1] == ("gh", "repo", "view", "--json", "nameWithOwner,url")
    assert argv[2] == ("gh", "issue", "create", "--title", "計画: demo", "--body-file", "-")
    assert runner.calls[2].input.startswith("ローカル計画: `tmp-agents/demo/plan.md`\n\n# 計画: demo")
    # epic = 101。以降 task ごとに create → id 取得 → 紐付け
    assert argv[3] == ("gh", "issue", "create", "--title", "demo: A ロガー整理", "--body-file", "-")
    assert runner.calls[3].input.startswith("epic: #101\n")
    assert argv[4] == ("gh", "api", "repos/o/r/issues/102", "--jq", ".id")
    assert argv[5] == ("gh", "api", "repos/o/r/issues/101/sub_issues", "-X", "POST", "-F", "sub_issue_id=9000102")
    assert argv[6][:4] == ("gh", "issue", "create", "--title")
    assert argv[9][:4] == ("gh", "issue", "create", "--title")
    assert len(argv) == 12
    assert fx.issues == [("A", 102), ("B1", 103), ("B2", 104)]
    assert fx.plan_lines == [
        "- epic: https://github.com/o/r/issues/101",
        "- sub-issue: A → https://github.com/o/r/issues/102",
        "- sub-issue: B1 → https://github.com/o/r/issues/103",
        "- sub-issue: B2 → https://github.com/o/r/issues/104",
    ]
    assert fx.warns == []


def test_existing_epic_comments_instead_of_creating() -> None:
    runner = FakeGhRunner(no_override)
    fx = FakeEffects()
    rc = ci.run(opts(epic=10), runner, fx, PLAN_OK, spec_ok())
    assert rc == 0, fx.warns
    argv = runner.argv()
    assert argv[2] == ("gh", "issue", "comment", "10", "--body-file", "-")
    assert runner.calls[2].input.startswith("計画を確定した。全文:\n\nローカル計画:")
    assert argv[3][:3] == ("gh", "issue", "create")
    assert runner.calls[3].input.startswith("epic: #10\n")
    assert argv[5] == ("gh", "api", "repos/o/r/issues/10/sub_issues", "-X", "POST", "-F", "sub_issue_id=9000101")
    assert fx.plan_lines[0] == "- epic: https://github.com/o/r/issues/10"


# ---------- 紐付け失敗のフォールバック ----------


def fail_link_for(sub_id: str) -> Responder:
    def responder(args: Sequence[str], _input: str) -> ci.GhResult | None:
        if args[-1] == f"sub_issue_id={sub_id}":
            return ci.GhResult(1, "", "HTTP 422")
        return None

    return responder


def test_link_failure_falls_back_to_task_list_on_new_epic() -> None:
    runner = FakeGhRunner(fail_link_for("9000103"))
    fx = FakeEffects()
    rc = ci.run(opts(), runner, fx, PLAN_OK, spec_ok())
    assert rc == 0
    assert len(fx.warns) == 1 and "#103" in fx.warns[0]
    last = runner.calls[-1]
    assert last.args == ("gh", "issue", "edit", "101", "--body-file", "-")
    assert last.input.rstrip().endswith("- [ ] #103")
    assert last.input.startswith("ローカル計画:")
    # 書き戻しは紐付け失敗に関係なく行われる
    assert fx.issues == [("A", 102), ("B1", 103), ("B2", 104)]


def test_link_failure_falls_back_to_comment_on_existing_epic() -> None:
    runner = FakeGhRunner(fail_link_for("9000101"))
    fx = FakeEffects()
    rc = ci.run(opts(epic=10), runner, fx, PLAN_OK, spec_ok())
    assert rc == 0
    last = runner.calls[-1]
    assert last.args == ("gh", "issue", "comment", "10", "--body-file", "-")
    assert last.input == "- [ ] #101\n"


# ---------- 部分失敗と再実行 ----------


def fail_create_titled(title: str) -> Responder:
    def responder(args: Sequence[str], _input: str) -> ci.GhResult | None:
        if args[:3] == ("gh", "issue", "create") and args[4] == title:
            return ci.GhResult(1, "", "boom")
        return None

    return responder


def test_partial_failure_then_rerun_skips_written_back_tasks() -> None:
    runner = FakeGhRunner(fail_create_titled("demo: B1 設定追加"))
    fx = FakeEffects()
    rc = ci.run(opts(epic=10), runner, fx, PLAN_OK, spec_ok())
    assert rc == 1
    assert fx.issues == [("A", 101)]
    # epic 行は sub-issue 作業の前に書かれる（途中で落ちても --epic で拾える）
    assert fx.plan_lines == ["- epic: https://github.com/o/r/issues/10"]
    assert any("--epic 10 を付けて再実行" in w for w in fx.warns)

    # 再実行: A は issue 済みなので飛ばし、B1 / B2 だけ作る
    runner2 = FakeGhRunner(no_override)
    fx2 = FakeEffects()
    rc2 = ci.run(opts(epic=10), runner2, fx2, PLAN_OK, spec_with_issues({"A": 101}))
    assert rc2 == 0
    creates = [c for c in runner2.calls if c.args[:3] == ("gh", "issue", "create")]
    assert [c.args[4] for c in creates] == ["demo: B1 設定追加", "demo: B2 クライアント実装"]
    assert fx2.issues == [("B1", 101), ("B2", 102)]


def test_new_epic_failure_records_epic_url_before_sub_issues() -> None:
    runner = FakeGhRunner(fail_create_titled("demo: A ロガー整理"))
    fx = FakeEffects()
    rc = ci.run(opts(), runner, fx, PLAN_OK, spec_ok())
    assert rc == 1
    assert fx.plan_lines == ["- epic: https://github.com/o/r/issues/101"]
    assert any("--epic 101" in w for w in fx.warns)


def test_task_missing_in_plan_is_rejected_before_any_gh_call() -> None:
    tasks = tasks_ok()
    tasks.append({"id": "Z", "branch": "z"})
    runner = FakeGhRunner(no_override)
    fx = FakeEffects()
    rc = ci.run(opts(), runner, fx, PLAN_OK, spec_ok(tasks=tasks))
    assert rc == 2
    assert runner.argv() == []


# ---------- --sync ----------


def sync_remote(subs: str, pr_branches: Sequence[str]) -> Responder:
    def responder(args: Sequence[str], _input: str) -> ci.GhResult | None:
        if args[:2] == ("gh", "api") and args[2].endswith("/sub_issues") and "--paginate" in args:
            return ci.GhResult(0, subs)
        if args[:3] == ("gh", "pr", "list"):
            return ci.GhResult(0, '[{"number": 7}]' if args[4] in pr_branches else "[]")
        return None

    return responder


def test_sync_updates_notifies_creates_and_closes() -> None:
    subs = json.dumps(
        [
            {"number": 11, "title": "demo: A", "state": "open"},
            {"number": 12, "title": "demo: B1", "state": "open"},
            {"number": 99, "title": "demo: old", "state": "open"},
        ]
    )
    runner = FakeGhRunner(sync_remote(subs, ["refactor-logger"]))
    fx = FakeEffects()
    rc = ci.run(opts(epic=10, sync=True), runner, fx, PLAN_OK, spec_with_issues({"A": 11, "B1": 12}))
    assert rc == 0, fx.warns
    argv = runner.argv()
    assert argv[2] == ("gh", "api", "repos/o/r/issues/10/sub_issues", "--paginate")
    assert argv[3] == ("gh", "pr", "list", "--head", "refactor-logger", "--state", "all", "--json", "number")
    assert argv[4] == ("gh", "pr", "list", "--head", "feat-config-retry", "--state", "all", "--json", "number")
    assert argv[5] == ("gh", "issue", "comment", "10", "--body-file", "-")
    assert runner.calls[5].input.startswith("計画を改訂した。最新版:")
    assert argv[6] == ("gh", "issue", "comment", "11", "--body-file", "-")  # 着手済み → 通知
    assert argv[7] == ("gh", "issue", "edit", "12", "--title", "demo: B1 設定追加", "--body-file", "-")
    assert argv[8] == ("gh", "issue", "create", "--title", "demo: B2 クライアント実装", "--body-file", "-")
    assert argv[9] == ("gh", "api", "repos/o/r/issues/101", "--jq", ".id")
    assert argv[10] == ("gh", "api", "repos/o/r/issues/10/sub_issues", "-X", "POST", "-F", "sub_issue_id=9000101")
    assert argv[11][:4] == ("gh", "issue", "close", "99")
    assert argv[11][4] == "--comment"
    assert len(argv) == 12
    assert fx.issues == [("B2", 101)]
    assert fx.plan_lines == [
        "- epic: https://github.com/o/r/issues/10",
        "- sub-issue: B2 → https://github.com/o/r/issues/101",
    ]


# ---------- 事前検査 ----------


def test_preflight_failure_creates_nothing() -> None:
    def responder(args: Sequence[str], _input: str) -> ci.GhResult | None:
        if args == ("gh", "auth", "status"):
            return ci.GhResult(1, "", "not logged in")
        return None

    runner = FakeGhRunner(responder)
    fx = FakeEffects()
    rc = ci.run(opts(), runner, fx, PLAN_OK, spec_ok())
    assert rc == 2
    assert runner.argv() == [("gh", "auth", "status")]
    assert fx.issues == [] and fx.plan_lines == []


def test_parse_args_requires_epic_for_sync() -> None:
    with pytest.raises(SystemExit):
        ci.parse_args(["x", "--plan", "p", "--spec", "s", "--sync"])
    o = ci.parse_args(["x", "--plan", "p", "--spec", "s", "--epic", "3", "--sync"])
    assert o == ci.Options(plan="p", spec="s", epic=3, sync=True)


# ---------- FileEffects ----------


def test_file_effects_write_back_and_append(tmp_path: Path) -> None:
    spec_p = tmp_path / "spec.json"
    plan_p = tmp_path / "plan.md"
    spec_p.write_text(json.dumps(spec_ok(), ensure_ascii=False), encoding="utf-8")
    plan_p.write_text(PLAN_OK, encoding="utf-8")
    fx = ci.FileEffects(str(spec_p), str(plan_p))
    fx.set_issue("B1", 42)
    data = json.loads(spec_p.read_text(encoding="utf-8"))
    assert isinstance(data, dict)
    tasks = cast(list[dict[str, object]], cast(dict[str, object], data)["tasks"])
    assert tasks[1]["issue"] == 42
    assert tasks[1]["expected_scale"] == 80  # 他フィールドは保たれる
    fx.append_plan(["- epic: https://github.com/o/r/issues/1"])
    assert plan_p.read_text(encoding="utf-8").endswith("- 起動: `/job-graph tmp-agents/demo/plan.md`\n- epic: https://github.com/o/r/issues/1\n")
