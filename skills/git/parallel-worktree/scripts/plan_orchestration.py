#!/usr/bin/env python3
"""parallel-worktree オーケストレーション・スケジューラ（決定論 CLI）。

AI が計画ファイルから抽出した「タスク + 依存辺 + 境界宣言」を JSON spec として受け取り、
循環検出・base 解決・並列ウェーブ算出・境界ファイル生成・ワーカー指示テンプレ付与・
wt/tmux//pr-create コマンド列生成を決定論的に行う。AI の責務は spec（特に depends_on の
意味的判定と boundary の範囲決め）まで。ここから先の順序・base・クォート・
ワーカー指示の標準セクションはこのスクリプトが保証する。

実行（cwd 非依存。uv が skill 直下の pyproject.toml から .venv を構築し、その中で実行）:
    uv run --project "<skill-dir>" python "<skill-dir>/scripts/plan_orchestration.py" <spec.json>
    ... <spec.json> の代わりに - で stdin から読む
    ... --remote-control を付けると各 claude を --remote-control <ブランチ名> で起動する
        （detached tmux のまま claude.ai 等からリモート接続できるようにする）
    ... --model / --permission-mode / --effort で各 claude の起動既定を切り替える
        （全 worktree に一律適用。task 個別指定があればそちらが優先）

依存は stdlib のみ。python バージョンは pyproject.toml の requires-python に従い、
無ければ uv が自動取得する。

spec の形:
{
  "default_base": "main",
  "tasks": [
    {"id": "A",  "branch": "refactor-logger",  "depends_on": [],     "prompt": "...",
     "boundary": ["pkg/logger/**"]},
    {"id": "B1", "branch": "feat-config-retry", "depends_on": [],     "prompt": "..."},
    {"id": "B2", "branch": "feat-client-retry", "depends_on": ["B1"], "prompt": "...",
     "boundary": ["internal/client/**", "docs/dev/retry/**"],
     "model": "opus", "permission_mode": "plan", "effort": "high"}
  ]
}

- depends_on は「前段の成果物に依存する／その上に積む（stacked）」タスク id の配列。
- 空 = 独立タスク（base はデフォルトブランチ、並列起動可）。
- 親 1 つ = その親ブランチを base にした stacked 段。
- 親 複数 = 単純な線形 stack 不可。WARNING（base は先頭親を仮採用）。
- model / permission_mode / effort は任意。その task の claude をこの設定で起動する。
  未指定なら CLI の --model / --permission-mode / --effort（グローバル既定）を使う。
  どちらも無ければ claude のデフォルト（＝呼び出し元の設定）に従う。
- boundary は任意の「触ってよいパス」glob 配列。指定すると、その worktree に
  境界ファイル `.claude/task-boundary.json`（task-boundary hook の公開契約書式）を
  生成する起動コマンドを組む。未指定の task は境界ファイルを作らない（従来動作）。

終了コード: 致命的検証エラー（循環・未定義参照・重複・必須欠落）があれば 1、警告のみなら 0。

設計: 純粋関数（parse_spec / analyze / detect_cycle / compute_levels / resolve_base /
sanitize / render）には副作用を持たせない。I/O・終了コードは read_spec / main にまとめる。
"""
from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from dataclasses import dataclass


# ============================================================
# 純粋ドメイン（副作用なし: 入力 -> 値。例外は構造破綻時の SpecError のみ）
# ============================================================

# claude CLI の受け付ける選択肢（`claude --help` 準拠）。
# model は alias/フルネーム自由なので検証しない（存在チェックは claude 側に委ねる）。
PERMISSION_MODES = ("acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan")
EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")


class SpecError(Exception):
    """spec の構造そのものが壊れていて解析不能な場合。"""


@dataclass(frozen=True)
class Task:
    id: str
    branch: str
    depends_on: tuple[str, ...]
    prompt: str
    # claude 起動オプションの task 個別上書き。空文字 = 未指定（グローバル既定を使う）。
    model: str = ""
    permission_mode: str = ""
    effort: str = ""
    # 触ってよいパスの glob。空 = 境界宣言なし（境界ファイルを生成しない従来動作）。
    boundary: tuple[str, ...] = ()


@dataclass(frozen=True)
class Plan:
    default_base: str
    tasks: tuple[Task, ...]


@dataclass(frozen=True)
class Launch:
    """全 worktree に一律適用する claude 起動の既定（CLI フラグ由来）。

    各 task の model/permission_mode/effort が空のとき、ここの値をフォールバックに使う。
    remote_control は従来通り「detached tmux のままリモート接続可」にするオプトイン。
    """
    model: str = ""
    permission_mode: str = ""
    effort: str = ""
    remote_control: bool = False


@dataclass(frozen=True)
class Analysis:
    errors: list[str]   # 致命的（あれば commands を出さず exit 1）
    warnings: list[str]  # 続行可
    levels: dict[str, int]  # task id -> 起動ウェーブ（cycle 時は空）
    bases: dict[str, str]   # task id -> 解決済み base ブランチ（cycle 時は空）


def parse_spec(data: object) -> Plan:
    """JSON 由来の値 -> Plan。構造が壊れていれば SpecError。"""
    if not isinstance(data, dict):
        raise SpecError("spec はオブジェクトではない")
    tasks_raw = data.get("tasks")
    if not isinstance(tasks_raw, list) or not tasks_raw:
        raise SpecError("tasks が空、または配列ではない")
    tasks = []
    for t in tasks_raw:
        if not isinstance(t, dict):
            raise SpecError(f"task はオブジェクトではない: {t!r}")
        deps_raw = t.get("depends_on", []) or []
        if not isinstance(deps_raw, list):
            raise SpecError(f"depends_on は配列でない: {t.get('id')!r}")
        bounds_raw = t.get("boundary", []) or []
        if not isinstance(bounds_raw, list):
            raise SpecError(f"boundary は配列でない: {t.get('id')!r}")
        tasks.append(
            Task(
                id=str(t.get("id", "")).strip(),
                branch=str(t.get("branch", "")).strip(),
                depends_on=tuple(str(d).strip() for d in deps_raw),
                prompt=str(t.get("prompt", "")).strip(),
                model=str(t.get("model", "")).strip(),
                permission_mode=str(t.get("permission_mode", "")).strip(),
                effort=str(t.get("effort", "")).strip(),
                boundary=tuple(g for g in (str(b).strip() for b in bounds_raw) if g),
            )
        )
    default_base = str(data.get("default_base", "main")).strip() or "main"
    return Plan(default_base=default_base, tasks=tuple(tasks))


def sanitize(name: str) -> str:
    """tmux セッション名向けに英数・ハイフン以外を - に。"""
    return re.sub(r"[^A-Za-z0-9_-]+", "-", name).strip("-") or "wt"


def detect_cycle(plan: Plan) -> list[str] | None:
    """依存グラフの循環を DFS で検出。あれば経路を返し、無ければ None。"""
    graph = {t.id: list(t.depends_on) for t in plan.tasks}
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {k: WHITE for k in graph}

    def dfs(node: str, stack: list[str]) -> list[str] | None:
        """node から DFS。循環を見つけたら経路を返し、無ければ None。"""
        color[node] = GRAY
        for dep in graph.get(node, []):
            if dep not in color:
                continue  # 未定義参照は validate 側で報告
            if color[dep] == GRAY:
                return stack + [node, dep]
            if color[dep] == WHITE:
                cycle = dfs(dep, stack + [node])
                if cycle is not None:
                    return cycle
        color[node] = BLACK
        return None

    for k in graph:
        if color[k] == WHITE:
            cycle = dfs(k, [])
            if cycle is not None:
                return cycle
    return None


def compute_levels(plan: Plan) -> dict[str, int]:
    """各タスクの依存レベル（起動ウェーブ）。level=0 は独立。要・非循環。"""
    by_id = {t.id: t for t in plan.tasks}
    memo: dict[str, int] = {}

    def lvl(tid: str) -> int:
        if tid in memo:
            return memo[tid]
        deps = by_id[tid].depends_on
        memo[tid] = 0 if not deps else 1 + max(lvl(d) for d in deps)
        return memo[tid]

    return {t.id: lvl(t.id) for t in plan.tasks}


def resolve_base(task: Task, by_id: dict[str, Task], default_base: str) -> str:
    """依存なし -> デフォルト base。依存あり -> 先頭親のブランチ。"""
    if not task.depends_on:
        return default_base
    return by_id[task.depends_on[0]].branch


def analyze(plan: Plan) -> Analysis:
    """検証 + レベル/base 算出を 1 つの純粋関数に集約。"""
    errors: list[str] = []
    warnings: list[str] = []
    ids = [t.id for t in plan.tasks]
    branches = [t.branch for t in plan.tasks]

    for t in plan.tasks:
        if not t.id:
            errors.append(f"id が空のタスクがある: {t!r}")
        if not t.branch:
            errors.append(f"branch が空: id={t.id!r}")
        if t.permission_mode and t.permission_mode not in PERMISSION_MODES:
            errors.append(
                f"task {t.id} の permission_mode '{t.permission_mode}' が不正"
                f"（{', '.join(PERMISSION_MODES)} のいずれか）"
            )
        if t.effort and t.effort not in EFFORT_LEVELS:
            errors.append(
                f"task {t.id} の effort '{t.effort}' が不正"
                f"（{', '.join(EFFORT_LEVELS)} のいずれか）"
            )
    dup_ids = sorted({x for x in ids if ids.count(x) > 1 and x})
    if dup_ids:
        errors.append(f"id が重複: {dup_ids}")
    dup_br = sorted({x for x in branches if branches.count(x) > 1 and x})
    if dup_br:
        errors.append(f"branch が重複: {dup_br}")

    idset = set(ids)
    for t in plan.tasks:
        for d in t.depends_on:
            if d not in idset:
                errors.append(f"task {t.id} の depends_on '{d}' が未定義")
        if t.id in t.depends_on:
            errors.append(f"task {t.id} が自分自身に依存")
        if len(t.depends_on) > 1:
            warnings.append(
                f"task {t.id} は複数親 {list(t.depends_on)} に依存。単純な線形 stack 不可。"
                "integration ブランチか逐次 rebase を検討（base は先頭親を仮採用）"
            )

    cycle = detect_cycle(plan)
    if cycle is not None:
        errors.append(f"依存に循環: {' -> '.join(cycle)}")

    if errors:
        return Analysis(errors=errors, warnings=warnings, levels={}, bases={})

    by_id = {t.id: t for t in plan.tasks}
    levels = compute_levels(plan)
    bases = {t.id: resolve_base(t, by_id, plan.default_base) for t in plan.tasks}
    return Analysis(errors=[], warnings=warnings, levels=levels, bases=bases)


def launch_flags(task: Task, launch: Launch) -> list[str]:
    """その task の claude 起動フラグ列（prompt より前に置く分）を組む。

    優先順は task 個別指定 > グローバル既定（Launch）。どちらも空なら flag を出さず、
    claude のデフォルト（呼び出し元の設定）に委ねる。
    """
    model = task.model or launch.model
    permission_mode = task.permission_mode or launch.permission_mode
    effort = task.effort or launch.effort
    flags: list[str] = []
    if model:
        flags += ["--model", model]
    if permission_mode:
        flags += ["--permission-mode", permission_mode]
    if effort:
        flags += ["--effort", effort]
    return flags


BOUNDARY_FILE = ".claude/task-boundary.json"

# 境界ファイルを worktree ローカルかつ gitignored に置くための bootstrap。
# 引数は $1=境界 JSON 本文。cwd は wt switch 後の worktree ルート（wt --execute の仕様）。
#
# gitignore 方式は `git rev-parse --git-path info/exclude` への追記を採る。linked worktree
# から実行しても common dir（メインリポジトリの .git/info/exclude）へ正しく解決されるため、
# worktree の .git がファイル（gitdir ポインタ）である差異を呼び出し側で場合分けしなくて済む。
# パターンは 1 ファイル固定・行頭 / 付き・重複追記を grep -qxF で抑止するので冪等。
#
# set -e は意図的（fail-closed）。cwd は wt switch --create が作った worktree なので git
# リポジトリであることが前提で、rev-parse がコケるのは環境が壊れている場合だけ。そのとき
# 境界の無い状態で claude を起動する（＝ガードレール無しで走らせる）より、起動せず
# tmux セッションに失敗を残す方が安全。hook 側の fail-open とは役割が逆であることに注意。
BOUNDARY_BOOTSTRAP = (
    "set -e; "
    f"mkdir -p {shlex.quote(BOUNDARY_FILE.rsplit('/', 1)[0])}; "
    f"printf '%s\\n' \"$1\" > {shlex.quote(BOUNDARY_FILE)}; "
    'ex="$(git rev-parse --path-format=absolute --git-path info/exclude)"; '
    'mkdir -p "$(dirname "$ex")"; '
    f"pat='/{BOUNDARY_FILE}'; "
    'grep -qxF "$pat" "$ex" 2>/dev/null || printf \'%s\\n\' "$pat" >> "$ex"; '
    "shift; "
    'exec claude "$@"'
)


def boundary_json(task: Task) -> str:
    """task の境界宣言 -> 境界ファイル（.claude/task-boundary.json）の内容。

    書式は task-boundary hook の公開契約（task_id / branch / allow）。生成者を
    parallel-worktree に限定しないため、キー順・構造をここで固定する。
    """
    return json.dumps(
        {"task_id": task.id, "branch": task.branch, "allow": list(task.boundary)},
        ensure_ascii=False,
        indent=2,
    )


def worker_sections(task: Task, base: str, default_base: str) -> str:
    """ワーカーへ渡す指示の標準セクション（常設テンプレ）。

    手書き指示への依存を廃し、境界・TDD 順序・PR 前ゲート・コミット粒度に加え、
    サブエージェント委任の抑制・スコープ制約・進捗ナレーションの抑制を全 task に必ず載せる
    （後者 3 つは detached tmux で人の介入無しに長時間走るワーカー向けの対策。境界 glob と
    hook は境界内でのスコープ拡大・サブエージェント乱発を止められない）。
    境界の記述は境界ファイル（boundary_json）と同じ glob を使い、hook のブロック条件と
    指示文が食い違わないようにする。
    """
    if task.boundary:
        scope = (
            "- 編集してよい範囲（境界）: "
            + ", ".join(task.boundary)
            + f"\n  この glob 外のファイルは編集しない。宣言は {BOUNDARY_FILE} と同一で、"
            "task-boundary hook が境界外の Edit/Write を機械ブロックする。\n"
            "  境界を広げる必要が出たら自分で境界ファイルを書き換えず、ユーザーに相談する。"
        )
    else:
        scope = (
            "- 編集してよい範囲（境界）: このタスクの担当範囲に限る。他タスクのファイルに触れない"
        )
    pr_arg = "" if base == default_base else f" {base}"
    return "\n".join(
        [
            "## 制約（parallel-worktree 標準セクション）",
            scope,
            "- TDD 順序: テストを先に実装し（失敗を確認）、その後アプリケーション実装で通す",
            (
                "- コミット粒度: 論理的に独立した修正は都度コミットする"
                "（commit-flow スキル準拠、Conventional Commits）"
            ),
            (
                f"- push: 自分の feature ブランチ {task.branch} に限り push してよい。"
                "main 等の保護ブランチへは push しない"
            ),
            (
                "- PR 作成前ゲート: `/review-converge` を実行して指摘を収束させてから "
                f"`/pr-create{pr_arg}` を実行する（収束前に PR を作らない）"
            ),
            (
                "- サブエージェント委任: 複数ファイル横断調査のような真に独立した大きな作業に限る。"
                "数回のツール呼び出しで済む作業は委任しない。"
                "自分の作業の検証・ダブルチェック目的でサブエージェントを使わない。1 体で足りるなら 1 体に留める"
            ),
            (
                "- スコープ: 依頼されたスコープで納品する。頼まれていない改善・リファクタ・追加作業を足さない。"
                "依頼に誤りがある・より良い方法があると考えたら 1 文で指摘し、依頼どおりの作業を続ける"
            ),
            (
                "- 進捗ナレーション: 最初のツール呼び出し前に 1 文だけ宣言し、"
                "以降は重要な発見・方針転換のときのみ短く述べる（detached tmux で逐次読む人はいない）"
            ),
        ]
    )


def render(plan: Plan, an: Analysis, launch: Launch = Launch()) -> str:
    """Plan + Analysis -> 人間/AI 向けテキスト出力（純粋）。

    launch のグローバル既定と task 個別指定から、各 claude の起動フラグ
    （--model / --permission-mode / --effort / --remote-control）を生成する。
    remote_control=True のとき、各 claude を --remote-control <ブランチ名> で起動する
    コマンドを生成する（detached tmux のまま claude.ai 等からリモート接続できる）。
    """
    out: list[str] = []
    out.append("=== VALIDATION ===")
    out.append(f"tasks: {len(plan.tasks)}  default_base: {plan.default_base}")
    if an.errors:
        for e in an.errors:
            out.append(f"ERROR: {e}")
        out.append("\n致命的エラーのため schedule/commands は出力しない。spec を修正して再実行。")
        return "\n".join(out)
    if an.warnings:
        for w in an.warnings:
            out.append(f"WARNING: {w}")
    else:
        out.append("ok（致命的問題なし）")

    by_id = {t.id: t for t in plan.tasks}
    max_level = max(an.levels.values())

    out.append("\n=== SCHEDULE (起動ウェーブ) ===")
    out.append("同一ウェーブ内は並列起動可。後続ウェーブは依存親の『コミット完了後』に起動する。")
    for level in range(max_level + 1):
        wave = sorted(t.id for t in plan.tasks if an.levels[t.id] == level)
        kind = "独立・並列" if level == 0 else f"stacked {level}段目"
        out.append(f"  wave {level} ({kind}): {', '.join(wave)}")

    declared = [t for t in sorted(plan.tasks, key=lambda x: x.id) if t.boundary]
    if declared:
        out.append(f"\n=== BOUNDARY (各 worktree に生成する {BOUNDARY_FILE}) ===")
        out.append(
            "worktree ローカル・gitignored（git rev-parse --git-path info/exclude へ追記）。"
            "task-boundary hook が境界外の Edit/Write を機械ブロックする。"
        )
        for t in declared:
            out.append(f"  {t.id} ({t.branch}): {', '.join(t.boundary)}")
        undeclared = sorted(t.id for t in plan.tasks if not t.boundary)
        if undeclared:
            out.append(
                f"  境界宣言なし（境界ファイルを生成しない・hook は沈黙）: {', '.join(undeclared)}"
            )

    defaults = []
    if launch.model:
        defaults.append(f"model={launch.model}")
    if launch.permission_mode:
        defaults.append(f"permission-mode={launch.permission_mode}")
    if launch.effort:
        defaults.append(f"effort={launch.effort}")
    if launch.remote_control:
        defaults.append("remote-control（各 claude を --remote-control <ブランチ名> で起動）")
    launch_note = f" [起動既定: {'; '.join(defaults)}]" if defaults else ""
    out.append(f"\n=== COMMANDS (列挙のみ。実行前に plan 承認){launch_note} ===")
    for level in range(max_level + 1):
        wave_tasks = [t for t in plan.tasks if an.levels[t.id] == level]
        if not wave_tasks:
            continue
        if level == 0:
            out.append(f"\n# wave {level}: 独立タスク。まとめて並列起動")
        else:
            parents = sorted({by_id[d].branch for t in wave_tasks for d in t.depends_on})
            out.append(
                f"\n# wave {level}: 前段 [{', '.join(parents)}] のコミット完了を wt list で確認後に起動"
            )
        for t in sorted(wave_tasks, key=lambda x: x.id):
            base = an.bases[t.id]
            sess = sanitize(t.branch)
            body = t.prompt or f"<{t.id} のタスクプロンプト未記入>"
            # ワーカー指示は「タスク本文 + 標準セクション」を常に連結する（手書き指示の廃止）。
            prompt = f"{body}\n\n{worker_sections(t, base, plan.default_base)}"
            base_part = "" if (level == 0 and base == plan.default_base) else f" --base {shlex.quote(base)}"
            # -x claude の -- 以降に渡す引数列。すべて positional な prompt より前に置く。
            # 起動フラグ（--model/--permission-mode/--effort）は task 個別 > グローバル既定で解決。
            # remote_control 時は claude を --remote-control <セッション名> で起動し、detached
            # tmux のまま claude.ai 等から接続できるようにする。名前は tmux セッション名
            # （sanitize 済みブランチ名）に揃え、tmux ls / wt list / リモート一覧で同じ識別子で
            # 追えるようにする。--remote-control は値オプション省略可だが、後続の prompt を名前
            # として誤食いしないよう常に名前を明示する。
            rc_args = ["--remote-control", sess] if launch.remote_control else []
            claude_args = launch_flags(t, launch) + rc_args + [prompt]
            if t.boundary:
                # 境界宣言ありのときは claude を直接 exec せず、bootstrap シェル経由にする。
                # wt --execute は worktree ルートを cwd にして走るので、ここで境界ファイルを
                # 置いてから exec claude "$@" に繋ぐ（worktree 生成後・claude 起動前の唯一の窓）。
                # 境界 JSON と claude 引数はすべて positional 引数で渡し、入れ子クォートを避ける。
                exec_cmd = "bash"
                exec_args = [
                    "-c",
                    BOUNDARY_BOOTSTRAP,
                    f"wt-boundary-{t.id}",
                    boundary_json(t),
                    *claude_args,
                ]
            else:
                exec_cmd = "claude"
                exec_args = claude_args
            args_str = " ".join(shlex.quote(a) for a in exec_args)
            inner = (
                f"wt switch --create {shlex.quote(t.branch)}{base_part}"
                f" -x {exec_cmd} -- {args_str}"
            )
            out.append(f"tmux new-session -d -s {shlex.quote(sess)} {shlex.quote(inner)}")

    out.append("\n=== PR (各エージェントが実装・コミット後、/review-converge 収束後に実行) ===")
    for t in sorted(plan.tasks, key=lambda x: (an.levels[x.id], x.id)):
        base = an.bases[t.id]
        arg = "" if base == plan.default_base else f" {base}"
        note = "（base 省略=デフォルト）" if base == plan.default_base else "（stacked: base=前段）"
        out.append(f"# {t.id} ({t.branch}): /pr-create{arg}   {note}")

    return "\n".join(out)


# ============================================================
# 副作用（I/O・終了コード）
# ============================================================


def read_spec(arg: str) -> object:
    """spec を読み JSON を返す。読めない/不正なら SpecError。"""
    if arg == "-":
        raw = sys.stdin.read()
    else:
        try:
            with open(arg, encoding="utf-8") as f:
                raw = f.read()
        except OSError as e:
            raise SpecError(f"spec を読めない: {e}") from e
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        raise SpecError(f"spec が不正な JSON: {e}") from e


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="plan_orchestration.py",
        description="parallel-worktree オーケストレーション・スケジューラ（決定論 CLI）",
    )
    parser.add_argument("spec", help="spec.json のパス、または - で stdin から読む")
    parser.add_argument(
        "--remote-control",
        action="store_true",
        help="各 worktree の claude を --remote-control <ブランチ名> で起動し、"
        "detached tmux のまま claude.ai 等からリモート接続できるようにする",
    )
    parser.add_argument(
        "--model",
        default=None,
        metavar="MODEL",
        help="全 worktree の claude 既定モデル（alias: opus/sonnet/fable 等、または"
        "フルネーム）。task 個別の model 指定があればそちらが優先",
    )
    parser.add_argument(
        "--permission-mode",
        default=None,
        choices=PERMISSION_MODES,
        help="全 worktree の claude 既定パーミッションモード。task 個別の"
        "permission_mode 指定があればそちらが優先",
    )
    parser.add_argument(
        "--effort",
        default=None,
        choices=EFFORT_LEVELS,
        help="全 worktree の claude 既定 effort レベル。task 個別の effort 指定が"
        "あればそちらが優先",
    )
    ns = parser.parse_args(argv[1:])
    launch = Launch(
        model=ns.model or "",
        permission_mode=ns.permission_mode or "",
        effort=ns.effort or "",
        remote_control=ns.remote_control,
    )
    try:
        plan = parse_spec(read_spec(ns.spec))
    except SpecError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    an = analyze(plan)
    print(render(plan, an, launch))
    return 1 if an.errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
