#!/usr/bin/env python3
"""job-plan 整合検査（決定論 CLI）。plan.md と job-graph の spec.json を機械比較する。

job-plan が確定させた計画は 2 つの成果物に分かれる。ワーカーの review-converge が
ground truth として読む plan.md と、job-graph の plan_orchestration.py が読む spec.json。
両者がずれると「計画突合は通るが計画書と違うものを作る」状態になるので、書き終わりと
job-graph Phase 0 の入口で本スクリプトを通す。

検査項目（ERROR = FAIL）:
- 第 1〜6 章の見出し（`## <n>. <題名>`）が揃っている
- spec の全 task id が第 3 章の `### <id>: <概要>` に存在し、逆も成立
- task ごとに `- 変更対象:` のパス集合が spec の expected_files と一致
- task ごとに `- 境界:` の glob 集合が spec の boundary と一致（`tmp_claude/**` は job-graph が
  自動付与するため両側から除いて比較）
- task ごとに `- 規模目安:` の整数が spec の expected_scale と一致
- task ごとに `- 依存:` の id 集合が spec の depends_on と一致
- task ごとに `- branch:` が spec の branch と一致
- 第 3 章の各節に固定の小見出し（branch / 依存 / 完了条件 / 変更対象 / 規模目安 / 境界 /
  コミット計画）が全て存在する
- spec の plan を plan_orchestration.py と同じ規則（相対なら cwd 基準で絶対化）で解決した結果が、
  渡した plan.md の絶対パスと一致
- 第 4 章（事前裁定）の各行が `- 裁定: … / 承認: ユーザー確認済み` 様式（`- 該当なし` は可。
  `親のみ（未確認）` は job-graph が承認済みとして扱えないので ERROR）

WARNING（続行可）:
- 第 5 章（スコープ外）が空
- 第 1 章に書かれた REQ-# が、第 3 章のどの task にも現れない

出力は `=== ERROR ===` / `=== WARNING ===` と末尾の `VERDICT: PASS|FAIL`。
終了コード: PASS = 0、FAIL = 1、入力を読めない = 2。

使い方:
    python3 check_plan_spec.py tmp_claude/<job>/plan.md tmp_claude/<job>/job-graph/spec.json

依存は stdlib のみ（job-graph の Phase 0 から子プロセスで呼ばれる）。plan.md の文法は
references/plan-template.md が正本で、本スクリプトはそれを機械的に読む側。

設計: parse_plan / parse_spec / compare / render は純粋関数。ファイル読み込み・出力・終了コードは
main に閉じる。
"""
from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from typing import Literal

# 第 3 章の各 task 節に必須の小見出し（`- <label>:`）。plan-template.md と一致させる。
TASK_LABELS: tuple[str, ...] = (
    "branch",
    "依存",
    "完了条件",
    "変更対象",
    "規模目安",
    "境界",
    "コミット計画",
)

# 章番号 -> 題名。plan-template.md と一致させる。
CHAPTERS: dict[int, str] = {
    1: "目的・背景",
    2: "タスク一覧と依存グラフ",
    3: "タスク詳細",
    4: "事前裁定",
    5: "スコープ外",
    6: "引き渡し",
}

# job-graph が boundary へ自動付与する glob。plan.md に書かなくてよいので比較から除く。
AUTO_BOUNDARY = "tmp_claude/**"

NONE_WORDS = ("なし", "無し", "none", "-")

CHAPTER_RE = re.compile(r"^## (\d+)\.\s*(.*?)\s*$")
TASK_RE = re.compile(r"^### ([A-Za-z0-9_-]+):\s*(.*?)\s*$")
LABEL_RE = re.compile(r"^- ([^:：]+)[:：]\s*(.*?)\s*$")
FENCE_RE = re.compile(r"^\s*```")
REQ_RE = re.compile(r"REQ-\d+")
RULING_RE = re.compile(r"^- 裁定: .+ / (承認: ユーザー確認済み|撤回済み（.+）)$")
NONE_LINE_RE = re.compile(r"^- (該当なし|なし)$")

Severity = Literal["ERROR", "WARNING"]


class InputError(Exception):
    """plan.md / spec.json を読めない・構造が壊れている場合。"""


@dataclass(frozen=True)
class Finding:
    severity: Severity
    message: str


@dataclass(frozen=True)
class Verdict:
    findings: tuple[Finding, ...]

    @property
    def passed(self) -> bool:
        return not any(f.severity == "ERROR" for f in self.findings)


@dataclass(frozen=True)
class TaskSection:
    id: str
    title: str
    branch: str
    depends_on: frozenset[str]
    expected_files: frozenset[str]
    expected_scale: int | None
    boundary: frozenset[str]
    # 節内に現れた小見出し。必須ラベルの欠落検査に使う。
    labels: frozenset[str]
    # 節本文に現れた REQ-#。第 1 章との対応付け検査に使う。
    reqs: frozenset[str]


@dataclass(frozen=True)
class PlanDoc:
    # 章番号 -> 本文行（見出し行を除く）。無い章はキーごと無い。
    chapters: dict[int, tuple[str, ...]]
    tasks: tuple[TaskSection, ...]


@dataclass(frozen=True)
class SpecTask:
    id: str
    branch: str
    depends_on: frozenset[str]
    boundary: frozenset[str]
    expected_files: frozenset[str]
    expected_scale: int


@dataclass(frozen=True)
class Spec:
    plan: str
    tasks: tuple[SpecTask, ...]


# ============================================================
# plan.md の解析（純粋）
# ============================================================


def split_chapters(text: str) -> dict[int, tuple[str, ...]]:
    """`## <n>. <題名>` で本文を章に割る。見出し前の前書きは捨てる。"""
    chapters: dict[int, list[str]] = {}
    current: int | None = None
    for line in text.splitlines():
        m = CHAPTER_RE.match(line)
        if m:
            current = int(m.group(1))
            chapters.setdefault(current, [])
            continue
        if current is not None:
            chapters[current].append(line)
    return {n: tuple(lines) for n, lines in chapters.items()}


def strip_code(value: str) -> str:
    """`` `x` `` のバッククォートを外す。"""
    v = value.strip()
    if len(v) >= 2 and v.startswith("`") and v.endswith("`"):
        return v[1:-1].strip()
    return v


def is_none_word(value: str) -> bool:
    return strip_code(value).lower() in NONE_WORDS


def parse_id_list(value: str) -> frozenset[str]:
    """`` `A`, `B` `` / `A, B` / `なし` -> id 集合。"""
    if not value.strip() or is_none_word(value):
        return frozenset()
    parts = re.split(r"[,、\s]+", value.strip())
    return frozenset(strip_code(p) for p in parts if strip_code(p))


def parse_int(value: str) -> int | None:
    """`120 行` / `120` -> 120。整数が無ければ None。"""
    m = re.search(r"\d+", value)
    return int(m.group(0)) if m else None


@dataclass(frozen=True)
class _Block:
    """`- label:` の直後に続くフェンス付きコードブロックの行（無ければ空）。"""

    lines: tuple[str, ...]
    consumed: int


def take_fenced_block(lines: tuple[str, ...], start: int) -> _Block:
    """lines[start:] の先頭にあるコードブロックを読む。空行は読み飛ばす。"""
    i = start
    while i < len(lines) and not lines[i].strip():
        i += 1
    if i >= len(lines) or not FENCE_RE.match(lines[i]):
        return _Block(lines=(), consumed=0)
    body: list[str] = []
    j = i + 1
    while j < len(lines) and not FENCE_RE.match(lines[j]):
        body.append(lines[j].strip())
        j += 1
    return _Block(lines=tuple(b for b in body if b), consumed=(j + 1) - start)


def parse_path_set(inline: str, lines: tuple[str, ...], start: int) -> tuple[frozenset[str], int]:
    """`- 変更対象:` / `- 境界:` の値。インラインの `なし` か、直後のコードブロック。"""
    if inline.strip():
        return (frozenset() if is_none_word(inline) else frozenset({strip_code(inline)})), 0
    block = take_fenced_block(lines, start)
    return frozenset(block.lines), block.consumed


def parse_task_section(header: re.Match[str], lines: tuple[str, ...]) -> TaskSection:
    """`### <id>: <概要>` から次の `###` までの行 -> TaskSection。"""
    branch = ""
    depends_on: frozenset[str] = frozenset()
    expected_files: frozenset[str] = frozenset()
    expected_scale: int | None = None
    boundary: frozenset[str] = frozenset()
    labels: set[str] = set()
    reqs: set[str] = set(REQ_RE.findall(header.group(0)))
    i = 0
    while i < len(lines):
        line = lines[i]
        reqs.update(REQ_RE.findall(line))
        m = LABEL_RE.match(line)
        if not m:
            i += 1
            continue
        label, value = m.group(1).strip(), m.group(2)
        labels.add(label)
        consumed = 0
        if label == "branch":
            branch = strip_code(value)
        elif label == "依存":
            depends_on = parse_id_list(value)
        elif label == "変更対象":
            expected_files, consumed = parse_path_set(value, lines, i + 1)
        elif label == "境界":
            boundary, consumed = parse_path_set(value, lines, i + 1)
        elif label == "規模目安":
            expected_scale = parse_int(value)
        i += 1 + consumed
    return TaskSection(
        id=header.group(1),
        title=header.group(2),
        branch=branch,
        depends_on=depends_on,
        expected_files=expected_files,
        expected_scale=expected_scale,
        boundary=boundary,
        labels=frozenset(labels),
        reqs=frozenset(reqs),
    )


def parse_tasks(chapter3: tuple[str, ...]) -> tuple[TaskSection, ...]:
    """第 3 章の本文 -> task 節の列。"""
    sections: list[TaskSection] = []
    header: re.Match[str] | None = None
    body: list[str] = []
    for line in chapter3:
        m = TASK_RE.match(line)
        if m:
            if header is not None:
                sections.append(parse_task_section(header, tuple(body)))
            header, body = m, []
            continue
        body.append(line)
    if header is not None:
        sections.append(parse_task_section(header, tuple(body)))
    return tuple(sections)


def parse_plan(text: str) -> PlanDoc:
    chapters = split_chapters(text)
    return PlanDoc(chapters=chapters, tasks=parse_tasks(chapters.get(3, ())))


# ============================================================
# spec.json の解析（純粋）
# ============================================================


def _str_list(raw: object, what: str, task_id: str) -> frozenset[str]:
    if raw is None:
        return frozenset()
    if not isinstance(raw, list):
        raise InputError(f"spec: {what} が配列でない: {task_id!r}")
    items: list[str] = []
    for x in raw:  # pyright: ignore[reportUnknownVariableType]
        if not isinstance(x, str):
            raise InputError(f"spec: {what} に文字列以外がある: {task_id!r}")
        if x.strip():
            items.append(x.strip())
    return frozenset(items)


def _nonneg_int(raw: object, what: str, task_id: str) -> int:
    if raw is None:
        return 0
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 0:
        raise InputError(f"spec: {what} が非負整数でない: {task_id!r}")
    return raw


def parse_spec(data: object) -> Spec:
    """JSON 由来の値 -> Spec。plan_orchestration.py の parse_spec と同じ受け付け方をする。"""
    if not isinstance(data, dict):
        raise InputError("spec がオブジェクトではない")
    obj: dict[str, object] = {str(k): v for k, v in data.items()}  # pyright: ignore[reportUnknownVariableType, reportUnknownArgumentType]
    tasks_raw = obj.get("tasks")
    if not isinstance(tasks_raw, list) or not tasks_raw:
        raise InputError("spec: tasks が空、または配列ではない")
    tasks: list[SpecTask] = []
    for t in tasks_raw:  # pyright: ignore[reportUnknownVariableType]
        if not isinstance(t, dict):
            raise InputError("spec: task がオブジェクトではない")
        td: dict[str, object] = {str(k): v for k, v in t.items()}  # pyright: ignore[reportUnknownVariableType, reportUnknownArgumentType]
        task_id = str(td.get("id", "")).strip()
        if not task_id:
            raise InputError("spec: id の無い task がある")
        tasks.append(
            SpecTask(
                id=task_id,
                branch=str(td.get("branch", "")).strip(),
                depends_on=_str_list(td.get("depends_on"), "depends_on", task_id),
                boundary=_str_list(td.get("boundary"), "boundary", task_id),
                expected_files=_str_list(td.get("expected_files"), "expected_files", task_id),
                expected_scale=_nonneg_int(td.get("expected_scale"), "expected_scale", task_id),
            )
        )
    plan_raw = obj.get("plan", "") or ""
    if not isinstance(plan_raw, str):
        raise InputError("spec: plan が文字列でない")
    return Spec(plan=plan_raw.strip(), tasks=tuple(tasks))


def resolve_plan_path(plan: str, cwd: str) -> str:
    """plan_orchestration.py の parse_spec と同じ規則: 相対なら cwd 基準で絶対化（symlink は解決しない）。"""
    if not plan:
        return ""
    return os.path.normpath(os.path.join(cwd, plan))


# ============================================================
# 突合（純粋）
# ============================================================


def _set_diff(label: str, task_id: str, plan_set: frozenset[str], spec_set: frozenset[str]) -> list[Finding]:
    if plan_set == spec_set:
        return []
    only_plan = ", ".join(sorted(plan_set - spec_set)) or "（なし）"
    only_spec = ", ".join(sorted(spec_set - plan_set)) or "（なし）"
    return [
        Finding(
            "ERROR",
            f"{task_id}: {label} が一致しない（plan のみ: {only_plan} / spec のみ: {only_spec}）",
        )
    ]


def compare_task(p: TaskSection, s: SpecTask) -> list[Finding]:
    out: list[Finding] = []
    missing = [l for l in TASK_LABELS if l not in p.labels]
    if missing:
        out.append(Finding("ERROR", f"{p.id}: 小見出しが欠けている: {', '.join(f'- {m}:' for m in missing)}"))
    if p.branch != s.branch:
        out.append(Finding("ERROR", f"{p.id}: branch が一致しない（plan: {p.branch!r} / spec: {s.branch!r}）"))
    out += _set_diff("依存", p.id, p.depends_on, s.depends_on)
    out += _set_diff("変更対象 / expected_files", p.id, p.expected_files, s.expected_files)
    out += _set_diff(
        "境界 / boundary",
        p.id,
        p.boundary - {AUTO_BOUNDARY},
        s.boundary - {AUTO_BOUNDARY},
    )
    if p.expected_scale is None:
        out.append(Finding("ERROR", f"{p.id}: 規模目安に整数が無い"))
    elif p.expected_scale != s.expected_scale:
        out.append(
            Finding(
                "ERROR",
                f"{p.id}: 規模目安 / expected_scale が一致しない（plan: {p.expected_scale} / spec: {s.expected_scale}）",
            )
        )
    return out


def check_rulings(lines: tuple[str, ...]) -> list[Finding]:
    """第 4 章: 各行が裁定様式か「該当なし」であること。"""
    bullets = [l.rstrip() for l in lines if l.strip()]
    if not bullets:
        return [Finding("ERROR", "第 4 章（事前裁定）が空。裁定が無いなら `- 該当なし` と書く")]
    out: list[Finding] = []
    for b in bullets:
        if NONE_LINE_RE.match(b) or RULING_RE.match(b):
            continue
        if "親のみ" in b:
            out.append(Finding("ERROR", f"第 4 章: ユーザー未確認の裁定は job-plan では確定できない: {b}"))
        else:
            out.append(
                Finding(
                    "ERROR",
                    f"第 4 章: `- 裁定: <内容> / 承認: ユーザー確認済み` 様式でない行: {b}",
                )
            )
    return out


def compare(plan: PlanDoc, spec: Spec, plan_path: str, cwd: str) -> Verdict:
    """plan.md と spec.json の突合。plan_path は渡された plan.md のパス（cwd 基準で絶対化して比較）。"""
    findings: list[Finding] = []

    for n, title in CHAPTERS.items():
        if n not in plan.chapters:
            findings.append(Finding("ERROR", f"第 {n} 章 `## {n}. {title}` が無い"))

    plan_ids = [t.id for t in plan.tasks]
    dup = sorted({i for i in plan_ids if plan_ids.count(i) > 1})
    if dup:
        findings.append(Finding("ERROR", f"第 3 章に重複する task id: {', '.join(dup)}"))
    spec_ids = [t.id for t in spec.tasks]
    dup_spec = sorted({i for i in spec_ids if spec_ids.count(i) > 1})
    if dup_spec:
        findings.append(Finding("ERROR", f"spec に重複する task id: {', '.join(dup_spec)}"))

    plan_by_id = {t.id: t for t in plan.tasks}
    spec_by_id = {t.id: t for t in spec.tasks}
    only_plan = sorted(set(plan_by_id) - set(spec_by_id))
    only_spec = sorted(set(spec_by_id) - set(plan_by_id))
    if only_plan:
        findings.append(Finding("ERROR", f"plan.md 第 3 章にあって spec に無い task: {', '.join(only_plan)}"))
    if only_spec:
        findings.append(Finding("ERROR", f"spec にあって plan.md 第 3 章に無い task: {', '.join(only_spec)}"))
    for task_id in sorted(set(plan_by_id) & set(spec_by_id)):
        findings += compare_task(plan_by_id[task_id], spec_by_id[task_id])

    expected = os.path.normpath(os.path.join(cwd, plan_path))
    resolved = resolve_plan_path(spec.plan, cwd)
    if not resolved:
        findings.append(Finding("ERROR", "spec の plan が空（plan.md のパスを書く）"))
    elif resolved != expected:
        findings.append(Finding("ERROR", f"spec の plan が渡した plan.md と一致しない（spec: {resolved} / 引数: {expected}）"))

    if 4 in plan.chapters:
        findings += check_rulings(plan.chapters[4])

    if 5 in plan.chapters and not any(l.strip() for l in plan.chapters[5]):
        findings.append(Finding("WARNING", "第 5 章（スコープ外）が空。落としたものを明示しないと手放し中のドリフト判定材料が無い"))

    reqs_in_intro = frozenset(REQ_RE.findall("\n".join(plan.chapters.get(1, ()))))
    covered: set[str] = set()
    for t in plan.tasks:
        covered |= t.reqs
    orphan = sorted(reqs_in_intro - covered, key=lambda r: int(r.split("-")[1]))
    if orphan:
        findings.append(Finding("WARNING", f"第 1 章の REQ-# がどの task にも対応付いていない: {', '.join(orphan)}"))

    return Verdict(findings=tuple(findings))


def render(verdict: Verdict) -> str:
    errors = [f.message for f in verdict.findings if f.severity == "ERROR"]
    warnings = [f.message for f in verdict.findings if f.severity == "WARNING"]
    out: list[str] = ["=== ERROR ==="]
    out += [f"- {m}" for m in errors] or ["(none)"]
    out.append("=== WARNING ===")
    out += [f"- {m}" for m in warnings] or ["(none)"]
    out.append(f"VERDICT: {'PASS' if verdict.passed else 'FAIL'}")
    return "\n".join(out)


# ============================================================
# 副作用層
# ============================================================


def read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise InputError(f"読めない: {path}: {e}") from e


def read_json(path: str) -> object:
    try:
        return json.loads(read_text(path))
    except json.JSONDecodeError as e:
        raise InputError(f"不正な JSON: {path}: {e}") from e


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: check_plan_spec.py <plan.md> <spec.json>", file=sys.stderr)
        return 2
    plan_path, spec_path = argv[1], argv[2]
    try:
        plan = parse_plan(read_text(plan_path))
        spec = parse_spec(read_json(spec_path))
    except InputError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        print("VERDICT: FAIL")
        return 2
    verdict = compare(plan, spec, plan_path, os.getcwd())
    print(render(verdict))
    return 0 if verdict.passed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
