#!/usr/bin/env python3
"""job-plan issue 起票（決定論 CLI）。plan.md / spec.json から GitHub の epic と sub-issue を作る。

使い方:
    python3 create_issues.py --plan tmp_claude/<job>/plan.md --spec tmp_claude/<job>/job-graph/spec.json
    python3 create_issues.py --plan ... --spec ... --epic 42          # 既存 epic へ計画をコメント投稿
    python3 create_issues.py --plan ... --spec ... --epic 42 --sync   # 改訂を sub-issue へ同期

動作:
- 事前検査: `gh auth status` と `gh repo view`。失敗なら何も作らず終了コード 2
- `--epic` なし: plan.md 全文を本文にした epic を作る。`--epic <番号>`: 本文は触らず全文をコメント投稿
- spec の task ごと（`issue` が 0 のものだけ）: sub-issue を作る → 直後に spec.json の `issue` を書き戻す
  → epic の sub-issue として紐付ける。紐付けに失敗した分は WARNING を出し、最後に epic 本文
  （新規 epic）/ コメント（既存 epic）へ `- [ ] #N` のタスクリストを追記する
- 完了後 plan.md 第 6 章へ epic / sub-issue の URL を追記する
- `--sync`（改訂。`--epic` 必須）: 現在の sub-issue 集合を API から取り、spec の `issue` と突合する。
  既存 task は `gh pr list --head <branch>` で着手済みを判定し、未着手は本文更新・着手済みは通知コメント。
  API にあって spec に無い sub-issue は理由コメント付きで close。新規 task は新規経路。epic に新版コメント
- 冪等: 書き戻しは task ごとに即時。途中で失敗しても再実行は `issue` が埋まった task を飛ばす

終了コード: 0 = 完了、1 = 途中で gh が失敗（書き戻し済みの分は spec に残る。再実行で続きから）、
2 = 事前検査・入力の失敗。

設計: gh 呼び出しは GhRunner（Protocol）経由、ファイル書き戻しと表示は Effects（Protocol）経由。
本文生成・行動計画（plan_*）・差分計算は値 → 値の純粋関数。main が subprocess 実装を注入する。
依存は stdlib のみ。plan.md の章・task 節の切り出しは兄弟の check_plan_spec.py と同じ文法。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol, cast

import check_plan_spec as cps

# ============================================================
# 型
# ============================================================


@dataclass(frozen=True)
class GhResult:
    returncode: int
    stdout: str
    stderr: str = ""

    @property
    def ok(self) -> bool:
        return self.returncode == 0


class GhRunner(Protocol):
    def run(self, args: Sequence[str], input: str = "") -> GhResult: ...


class Effects(Protocol):
    def set_issue(self, task_id: str, number: int) -> None: ...

    def append_plan(self, lines: Sequence[str]) -> None: ...

    def info(self, message: str) -> None: ...

    def warn(self, message: str) -> None: ...


class GhError(Exception):
    """gh の実行が失敗した場合（メッセージに argv と stderr を含める）。"""


@dataclass(frozen=True)
class Repo:
    name_with_owner: str
    url: str

    def issue_url(self, number: int) -> str:
        return f"{self.url}/issues/{number}"

    def api(self, path: str) -> str:
        return f"repos/{self.name_with_owner}/{path}"


@dataclass(frozen=True)
class PlanTask:
    id: str
    title: str
    # `### <id>: <概要>` から次の task 節までの本文（見出し行を含む）
    section: str
    branch: str


@dataclass(frozen=True)
class PlanText:
    path: str
    job: str
    text: str
    heading: str
    tasks: tuple[PlanTask, ...]

    def task(self, task_id: str) -> PlanTask | None:
        return next((t for t in self.tasks if t.id == task_id), None)


@dataclass(frozen=True)
class SpecTask:
    id: str
    branch: str
    issue: int


@dataclass(frozen=True)
class RemoteSubIssue:
    number: int
    title: str
    state: str


@dataclass(frozen=True)
class RemoteState:
    sub_issues: tuple[RemoteSubIssue, ...]
    # branch -> PR が存在する（open / merged / closed を問わず）
    started: dict[str, bool]


@dataclass(frozen=True)
class Options:
    plan: str
    spec: str
    epic: int
    sync: bool


# ---------- 行動（純粋に算出し、execute が順に実行する） ----------


@dataclass(frozen=True)
class CreateSubIssue:
    task_id: str
    title: str
    body: str


@dataclass(frozen=True)
class UpdateSubIssue:
    task_id: str
    number: int
    title: str
    body: str


@dataclass(frozen=True)
class NotifySubIssue:
    task_id: str
    number: int
    body: str


@dataclass(frozen=True)
class CloseSubIssue:
    number: int
    comment: str


Action = CreateSubIssue | UpdateSubIssue | NotifySubIssue | CloseSubIssue


@dataclass(frozen=True)
class EpicPlan:
    """epic に対して行うこと。number == 0 なら新規作成。"""

    number: int
    title: str
    body: str

    @property
    def is_new(self) -> bool:
        return self.number == 0


@dataclass
class Outcome:
    epic: int = 0
    epic_is_new: bool = False
    created: list[tuple[str, int]] = field(default_factory=lambda: [])
    link_failed: list[int] = field(default_factory=lambda: [])


# ============================================================
# 入力の解析（純粋）
# ============================================================


def parse_plan_text(path: str, text: str) -> PlanText:
    """plan.md の全文 -> 見出し・task 節（本文そのまま）の切り出し。"""
    heading = next((l.lstrip("# ").strip() for l in text.splitlines() if l.startswith("# ")), "")
    chapters = cps.split_chapters(text)
    ch3 = chapters.get(3, ())
    tasks: list[PlanTask] = []
    current: tuple[str, str] | None = None
    body: list[str] = []

    def flush() -> None:
        if current is None:
            return
        section = "\n".join([f"### {current[0]}: {current[1]}", *body]).strip() + "\n"
        branch = ""
        for line in body:
            m = cps.LABEL_RE.match(line)
            if m and m.group(1).strip() == "branch":
                branch = cps.strip_code(m.group(2))
        tasks.append(PlanTask(id=current[0], title=current[1], section=section, branch=branch))

    for line in ch3:
        m = cps.TASK_RE.match(line)
        if m:
            flush()
            current, body = (m.group(1), m.group(2)), []
            continue
        body.append(line)
    flush()
    job = Path(path).parent.name
    return PlanText(path=path, job=job, text=text, heading=heading, tasks=tuple(tasks))


def parse_spec_tasks(data: object) -> tuple[SpecTask, ...]:
    """spec.json（生の JSON）から id / branch / issue だけを取り出す。"""
    if not isinstance(data, dict):
        raise cps.InputError("spec がオブジェクトではない")
    obj: dict[str, object] = {str(k): v for k, v in data.items()}  # pyright: ignore[reportUnknownVariableType, reportUnknownArgumentType]
    tasks_raw = obj.get("tasks")
    if not isinstance(tasks_raw, list) or not tasks_raw:
        raise cps.InputError("spec: tasks が空、または配列ではない")
    out: list[SpecTask] = []
    for t in tasks_raw:  # pyright: ignore[reportUnknownVariableType]
        if not isinstance(t, dict):
            raise cps.InputError("spec: task がオブジェクトではない")
        td: dict[str, object] = {str(k): v for k, v in t.items()}  # pyright: ignore[reportUnknownVariableType, reportUnknownArgumentType]
        task_id = str(td.get("id", "")).strip()
        if not task_id:
            raise cps.InputError("spec: id の無い task がある")
        issue_raw = td.get("issue", 0) or 0
        if isinstance(issue_raw, bool) or not isinstance(issue_raw, int) or issue_raw < 0:
            raise cps.InputError(f"spec: issue が非負整数でない: {task_id!r}")
        out.append(SpecTask(id=task_id, branch=str(td.get("branch", "")).strip(), issue=issue_raw))
    return tuple(out)


def parse_repo(stdout: str) -> Repo:
    try:
        data = json.loads(stdout)
    except json.JSONDecodeError as e:
        raise GhError(f"gh repo view の出力が JSON でない: {e}") from e
    if not isinstance(data, dict):
        raise GhError("gh repo view の出力がオブジェクトでない")
    obj: dict[str, object] = {str(k): v for k, v in data.items()}  # pyright: ignore[reportUnknownVariableType, reportUnknownArgumentType]
    name = str(obj.get("nameWithOwner", "")).strip()
    url = str(obj.get("url", "")).strip().rstrip("/")
    if not name or not url:
        raise GhError("gh repo view に nameWithOwner / url が無い")
    return Repo(name_with_owner=name, url=url)


ISSUE_URL_RE = re.compile(r"/issues/(\d+)\s*$")


def parse_created_number(stdout: str) -> int:
    """`gh issue create` が最後に出す URL から番号を取る。"""
    for line in reversed(stdout.strip().splitlines()):
        m = ISSUE_URL_RE.search(line.strip())
        if m:
            return int(m.group(1))
    raise GhError(f"gh issue create の出力から issue 番号を読めない: {stdout!r}")


def parse_sub_issues(stdout: str) -> tuple[RemoteSubIssue, ...]:
    """`gh api .../sub_issues --paginate` の出力（JSON 配列。ページごとに配列が連結されることがある）。"""
    text = stdout.strip()
    if not text:
        return ()
    # --paginate は配列を "][" で連結して出すことがある。1 本の配列へ直す。
    merged = "[" + re.sub(r"\]\s*\[", ",", text).strip("[]") + "]"
    try:
        data = json.loads(merged)
    except json.JSONDecodeError as e:
        raise GhError(f"sub_issues の出力が JSON でない: {e}") from e
    if not isinstance(data, list):
        raise GhError("sub_issues の出力が配列でない")
    out: list[RemoteSubIssue] = []
    for item in data:  # pyright: ignore[reportUnknownVariableType]
        if not isinstance(item, dict):
            continue
        obj: dict[str, object] = {str(k): v for k, v in item.items()}  # pyright: ignore[reportUnknownVariableType, reportUnknownArgumentType]
        number = obj.get("number")
        if isinstance(number, bool) or not isinstance(number, int):
            continue
        out.append(
            RemoteSubIssue(number=number, title=str(obj.get("title", "")), state=str(obj.get("state", "")))
        )
    return tuple(out)


def parse_pr_exists(stdout: str) -> bool:
    text = stdout.strip()
    if not text:
        return False
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise GhError(f"gh pr list の出力が JSON でない: {e}") from e
    return isinstance(data, list) and len(data) > 0  # pyright: ignore[reportUnknownArgumentType]


# ============================================================
# 本文と行動計画（純粋）
# ============================================================


def local_plan_note(plan: PlanText) -> str:
    return f"ローカル計画: `tmp_claude/{plan.job}/plan.md`"


def epic_title(plan: PlanText) -> str:
    return plan.heading or f"計画: {plan.job}"


def epic_body(plan: PlanText) -> str:
    return f"{local_plan_note(plan)}\n\n{plan.text.rstrip()}\n"


def epic_comment_body(plan: PlanText, sync: bool) -> str:
    lead = "計画を改訂した。最新版:" if sync else "計画を確定した。全文:"
    return f"{lead}\n\n{local_plan_note(plan)}\n\n{plan.text.rstrip()}\n"


def sub_issue_title(plan: PlanText, task: PlanTask) -> str:
    return f"{plan.job}: {task.id} {task.title}".rstrip()


def sub_issue_body(plan: PlanText, task: PlanTask, epic: int) -> str:
    return f"epic: #{epic}\n{local_plan_note(plan)}\n\n{task.section.rstrip()}\n"


def notify_body(plan: PlanText, epic: int) -> str:
    return (
        f"計画が改訂された（epic #{epic} の最新コメント参照）。この issue は着手済み（PR あり）のため"
        f"本文を更新していない。差分は {local_plan_note(plan)} を確認すること。"
    )


def close_comment(plan: PlanText, epic: int) -> str:
    return f"計画の改訂（epic #{epic}）でこのタスクは計画から外れたため close する。{local_plan_note(plan)}"


def task_list_body(numbers: Sequence[int]) -> str:
    return "\n".join(f"- [ ] #{n}" for n in numbers)


def plan_epic(opts: Options, plan: PlanText) -> EpicPlan:
    if opts.epic:
        return EpicPlan(number=opts.epic, title="", body=epic_comment_body(plan, opts.sync))
    return EpicPlan(number=0, title=epic_title(plan), body=epic_body(plan))


def plan_actions(
    plan: PlanText, spec: Sequence[SpecTask], epic: int, remote: RemoteState | None
) -> tuple[Action, ...]:
    """task ごとの行動。remote は --sync のときだけ渡す（None = 新規経路のみ）。"""
    actions: list[Action] = []
    known: set[int] = set()
    for st in spec:
        pt = plan.task(st.id)
        if pt is None:
            raise cps.InputError(f"spec の task {st.id!r} が plan.md 第 3 章に無い（先に check_plan_spec.py を通す）")
        if st.issue == 0:
            actions.append(CreateSubIssue(task_id=st.id, title=sub_issue_title(plan, pt), body=sub_issue_body(plan, pt, epic)))
            continue
        known.add(st.issue)
        if remote is None:
            continue
        if remote.started.get(st.branch, False):
            actions.append(NotifySubIssue(task_id=st.id, number=st.issue, body=notify_body(plan, epic)))
        else:
            actions.append(
                UpdateSubIssue(
                    task_id=st.id,
                    number=st.issue,
                    title=sub_issue_title(plan, pt),
                    body=sub_issue_body(plan, pt, epic),
                )
            )
    if remote is not None:
        for r in remote.sub_issues:
            if r.number not in known and r.state.lower() != "closed":
                actions.append(CloseSubIssue(number=r.number, comment=close_comment(plan, epic)))
    return tuple(actions)


def handoff_lines(plan_text: str, repo: Repo, epic: int, created: Sequence[tuple[str, int]]) -> tuple[str, ...]:
    """第 6 章へ追記する行。既に plan.md に載っている URL は重複させない。"""
    lines: list[str] = []
    epic_url = repo.issue_url(epic)
    if epic_url not in plan_text:
        lines.append(f"- epic: {epic_url}")
    for task_id, number in created:
        url = repo.issue_url(number)
        if url not in plan_text:
            lines.append(f"- sub-issue: {task_id} → {url}")
    return tuple(lines)


# ============================================================
# 実行（副作用は runner / effects 経由）
# ============================================================


def gh(runner: GhRunner, args: Sequence[str], input: str = "") -> GhResult:
    """成功を要求する呼び出し。失敗は GhError。"""
    res = runner.run(args, input)
    if not res.ok:
        raise GhError(f"gh {' '.join(args)} が失敗（exit {res.returncode}）: {res.stderr.strip()}")
    return res


def preflight(runner: GhRunner) -> Repo:
    gh(runner, ["gh", "auth", "status"])
    res = gh(runner, ["gh", "repo", "view", "--json", "nameWithOwner,url"])
    return parse_repo(res.stdout)


def fetch_remote(runner: GhRunner, repo: Repo, epic: int, spec: Sequence[SpecTask]) -> RemoteState:
    subs = parse_sub_issues(gh(runner, ["gh", "api", repo.api(f"issues/{epic}/sub_issues"), "--paginate"]).stdout)
    started: dict[str, bool] = {}
    for st in spec:
        if st.issue and st.branch:
            res = gh(runner, ["gh", "pr", "list", "--head", st.branch, "--state", "all", "--json", "number"])
            started[st.branch] = parse_pr_exists(res.stdout)
    return RemoteState(sub_issues=subs, started=started)


def ensure_epic(runner: GhRunner, effects: Effects, repo: Repo, ep: EpicPlan) -> int:
    if ep.is_new:
        res = gh(runner, ["gh", "issue", "create", "--title", ep.title, "--body-file", "-"], ep.body)
        number = parse_created_number(res.stdout)
        effects.info(f"epic を作成: {repo.issue_url(number)}")
        return number
    gh(runner, ["gh", "issue", "comment", str(ep.number), "--body-file", "-"], ep.body)
    effects.info(f"epic #{ep.number} へ計画をコメント投稿")
    return ep.number


def link_sub_issue(runner: GhRunner, repo: Repo, epic: int, number: int) -> None:
    """sub-issue API は issue 番号ではなく数値 id（database id）を要求する。-F で数値として送る。"""
    res = gh(runner, ["gh", "api", repo.api(f"issues/{number}"), "--jq", ".id"])
    sub_id = res.stdout.strip()
    if not sub_id.isdigit():
        raise GhError(f"issue #{number} の id を読めない: {res.stdout!r}")
    gh(runner, ["gh", "api", repo.api(f"issues/{epic}/sub_issues"), "-X", "POST", "-F", f"sub_issue_id={sub_id}"])


def execute_actions(
    runner: GhRunner, effects: Effects, repo: Repo, epic_body_text: str, actions: Sequence[Action], out: Outcome
) -> None:
    """epic 確定後の各行動 → 紐付けフォールバック。途中の GhError は呼び出し側へ伝える（書き戻し済みは残る）。"""
    for a in actions:
        if isinstance(a, CreateSubIssue):
            res = gh(runner, ["gh", "issue", "create", "--title", a.title, "--body-file", "-"], a.body)
            number = parse_created_number(res.stdout)
            effects.set_issue(a.task_id, number)
            out.created.append((a.task_id, number))
            effects.info(f"sub-issue を作成: {a.task_id} → {repo.issue_url(number)}")
            try:
                link_sub_issue(runner, repo, out.epic, number)
            except GhError as e:
                out.link_failed.append(number)
                effects.warn(f"sub-issue #{number} を epic #{out.epic} へ紐付けられなかった（タスクリストで代替）: {e}")
        elif isinstance(a, UpdateSubIssue):
            gh(runner, ["gh", "issue", "edit", str(a.number), "--title", a.title, "--body-file", "-"], a.body)
            effects.info(f"sub-issue を更新: {a.task_id} → #{a.number}")
        elif isinstance(a, NotifySubIssue):
            gh(runner, ["gh", "issue", "comment", str(a.number), "--body-file", "-"], a.body)
            effects.info(f"着手済みのため通知のみ: {a.task_id} → #{a.number}")
        else:
            gh(runner, ["gh", "issue", "close", str(a.number), "--comment", a.comment])
            effects.info(f"計画から外れた sub-issue を close: #{a.number}")
    if out.link_failed:
        body = task_list_body(out.link_failed)
        if out.epic_is_new:
            gh(runner, ["gh", "issue", "edit", str(out.epic), "--body-file", "-"], f"{epic_body_text.rstrip()}\n\n{body}\n")
        else:
            gh(runner, ["gh", "issue", "comment", str(out.epic), "--body-file", "-"], f"{body}\n")


# ============================================================
# 副作用の実装
# ============================================================


class SubprocessGhRunner:
    def run(self, args: Sequence[str], input: str = "") -> GhResult:
        try:
            proc = subprocess.run(list(args), input=input, capture_output=True, text=True, check=False)
        except OSError as e:
            return GhResult(returncode=127, stdout="", stderr=str(e))
        return GhResult(returncode=proc.returncode, stdout=proc.stdout, stderr=proc.stderr)


class FileEffects:
    def __init__(self, spec_path: str, plan_path: str) -> None:
        self.spec_path = spec_path
        self.plan_path = plan_path

    def set_issue(self, task_id: str, number: int) -> None:
        data = cast(object, json.loads(Path(self.spec_path).read_text(encoding="utf-8")))
        if not isinstance(data, dict):
            raise cps.InputError("spec がオブジェクトではない")
        obj = cast(dict[str, object], data)
        tasks = obj.get("tasks")
        if not isinstance(tasks, list):
            raise cps.InputError("spec: tasks が配列ではない")
        for t in cast(list[object], tasks):
            if not isinstance(t, dict):
                continue
            td = cast(dict[str, object], t)
            if str(td.get("id", "")).strip() == task_id:
                td["issue"] = number
        Path(self.spec_path).write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    def append_plan(self, lines: Sequence[str]) -> None:
        if not lines:
            return
        p = Path(self.plan_path)
        text = p.read_text(encoding="utf-8").rstrip("\n")
        p.write_text(text + "\n" + "\n".join(lines) + "\n", encoding="utf-8")

    def info(self, message: str) -> None:
        print(f"INFO: {message}")

    def warn(self, message: str) -> None:
        print(f"WARNING: {message}")


def parse_args(argv: Sequence[str]) -> Options:
    parser = argparse.ArgumentParser(prog="create_issues.py", description="job-plan の epic / sub-issue 起票")
    parser.add_argument("--plan", required=True, help="plan.md のパス")
    parser.add_argument("--spec", required=True, help="spec.json のパス（issue 番号を書き戻す）")
    parser.add_argument("--epic", type=int, default=0, metavar="N", help="既存 epic の番号（省略時は新規作成）")
    parser.add_argument("--sync", action="store_true", help="改訂を既存 sub-issue へ同期する（--epic 必須）")
    ns = parser.parse_args(list(argv[1:]))
    opts = Options(plan=str(ns.plan), spec=str(ns.spec), epic=int(ns.epic), sync=bool(ns.sync))
    if opts.sync and not opts.epic:
        parser.error("--sync には --epic <番号> が必要")
    return opts


def run(opts: Options, runner: GhRunner, effects: Effects, plan_text: str, spec_data: object) -> int:
    """main から呼ばれる本体（ファイル読み込み済みの値を受け取る。テストから直接呼べる）。"""
    try:
        plan = parse_plan_text(opts.plan, plan_text)
        spec = parse_spec_tasks(spec_data)
        repo = preflight(runner)
    except (cps.InputError, GhError) as e:
        effects.warn(f"事前検査に失敗（何も作っていない）: {e}")
        return 2
    out = Outcome()
    try:
        remote = fetch_remote(runner, repo, opts.epic, spec) if opts.sync else None
        ep = plan_epic(opts, plan)
        out.epic = ensure_epic(runner, effects, repo, ep)
        out.epic_is_new = ep.is_new
        # 新規 epic の番号は作成後に決まるので、行動計画（本文の `epic: #N`）は確定後に組む。
        actions = plan_actions(plan, spec, out.epic, remote)
        execute_actions(runner, effects, repo, ep.body, actions, out)
    except (cps.InputError, GhError) as e:
        effects.warn(f"途中で失敗した。spec.json へ書き戻した分はそのまま残る（再実行で続きから）: {e}")
        return 1
    effects.append_plan(handoff_lines(plan.text, repo, out.epic, out.created))
    effects.info(f"完了: epic {repo.issue_url(out.epic)} / sub-issue {len(out.created)} 件作成")
    return 0


def main(argv: list[str]) -> int:
    opts = parse_args(argv)
    try:
        plan_text = cps.read_text(opts.plan)
        spec_data = cps.read_json(opts.spec)
    except cps.InputError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    return run(opts, SubprocessGhRunner(), FileEffects(opts.spec, opts.plan), plan_text, spec_data)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
