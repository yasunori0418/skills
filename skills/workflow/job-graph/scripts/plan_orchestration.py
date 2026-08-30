#!/usr/bin/env python3
"""job-graph オーケストレーション・スケジューラ（決定論 CLI）。

AI が計画ファイル・epic issue から抽出した「タスク + 依存辺 + 境界宣言」を JSON spec と
して受け取り、循環検出・base 解決・ウェーブ算出・レーン（herdr workspace/tab）割当・
境界ファイル生成・ワーカー指示テンプレ付与・wt/herdr コマンド列生成を決定論的に行う。
AI の責務は spec（特に depends_on の意味的判定と boundary の範囲決め）まで。ここから先の
順序・base・クォート・ワーカー指示の標準セクションはこのスクリプトが保証する。

設計上の要点:
- 実行基盤は herdr。レーン（直列チェーン）ごとに workspace を立てる:
  レーン先頭の task は `herdr workspace create` の root pane で起動し、stacked の
  後続段は同じレーンの workspace へ `herdr tab create` で tab を足して起動する
  （並列レーン = workspace の並び。レーンを別 session に分けることはしない。
  session はランタイム名前空間が分かれ、親の socket からレーンへ到達できなくなるため）
- herdr 呼び出しは全て `--session "$HSESSION"`（= `${HERDR_SESSION:-default}`）を明示する。
  CLI は env が生きていれば現在の session へ解決するが、COMMANDS を env の無い別 shell へ
  コピペすると既定 session へ落ちる。親と同じ session にレーンを並べる保証を env に預けない
- 各レーンの claude は独立したセッションなので、起動コマンドの先頭に `env -u` を置いて
  親（オーケストレータ）セッション固有のマーカーを断ち切る（ENV_STRIP_PREFIX）。
  放置するとレーンが親の子プロセスと誤認され、transcript 保存が切られる等の不整合が起きる
- stacked の起動ゲートは「前段の PR 作成」（implement のみ。maintain は全レーン同時起動）
- worktree 生成（implement）は `wt switch --create --base <解決済み base>`（base は必ず明示する）。
  maintain は既存 worktree（ブランチ作成済み・PR 済み）へ入るので `wt switch <branch>`
  （`--create` を付けると Path occupied で失敗する）
- ワーカープロンプトは herdr pane へ流し込める長さに限界があるためファイル渡し
  （--prompt-dir 配下に <task-id>.md を書き出し、起動コマンドは "$(cat <path>)" で読む）
- 起動コマンド自体（env -u ... wt switch ... -x claude ...）も 1 行で数百文字になり、
  pane run への長文注入で「入力されたまま未実行」「途中で切れる」事故が起きた実績がある。
  そのため起動コマンドは --prompt-dir 配下の launch_<task-id>.sh へ書き出し、
  pane run には `bash <path>` の短いコマンドだけを流す
- ワーカー規約（報告・凍結・承認の振る舞い）の正本は lane-ops の worker_contract.py。
  本スクリプトはタスク情報 JSON を渡して規約セクションを取得し、prompt へ連結する
- boundary を宣言した task には `tmp_claude/**` を自動で追加する（PR 本文ドラフト等の
  一時出力先が境界と衝突して詰まる事故の防止）

実行（cwd 非依存。uv が skill 直下の pyproject.toml から .venv を構築し、その中で実行）:
    uv run --project "<skill-dir>" python "<skill-dir>/scripts/plan_orchestration.py" \
        --prompt-dir <dir> <spec.json>
    ... <spec.json> の代わりに - で stdin から読む
    ... --parent-name <name> で親（オーケストレータ）の herdr エージェント名を
        ワーカー規約へ埋め込む（report.sh の宛先になる）
    ... --remote-control を付けると各 claude を --remote-control <ブランチ名> で起動する
    ... --model / --permission-mode / --effort で各 claude の起動既定を切り替える

依存は stdlib のみ。python バージョンは pyproject.toml の requires-python に従う。

spec の形:
{
  "default_base": "main",
  "plan": "tmp_claude/<job>/plan.md",
  "mode": "implement",
  "tasks": [
    {"id": "A",  "branch": "refactor-logger",  "depends_on": [],     "prompt": "...",
     "boundary": ["pkg/logger/**"], "issue": 123,
     "expected_files": ["pkg/logger/logger.go", "pkg/logger/logger_test.go"], "expected_scale": 120},
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
- issue は任意の GitHub issue 番号。ワーカー指示に issue 参照と PR へのリンク指示が載る。
- model / permission_mode / effort / boundary の意味は parallel-worktree と同じ。
- plan は計画ファイルのパス（相対なら cwd 基準で絶対化。指定されていて存在しなければ ERROR）。
  ワーカー規約の「計画の参照」条項に載り、review-converge のグラウンドトゥルースになる。
- mode はジョブ全体の性質（implement = 実装〜PR 作成 / maintain = PR 作成後のレビュー対応）。
  省略時 implement。maintain の運用は references/maintain.md。
- expected_files / expected_scale は計画に書かれた変更ファイル一覧（glob 不可）と規模目安
  （追加+削除の行数）。check_scope.py の突合基準になり、ワーカー規約（PR 前）と VERIFY 節
  （親が PR に対して行う）の両方に埋め込まれる。expected_files が無い task は WARNING
  （ファイル照合なしに縮退。この WARNING は maintain でも出す）。突合そのものと depends_on の
  検証は maintain では行わない。フィールドの詳細は references/spec.md。

レーン割当（= workspace 割当。レーン先頭が workspace、後続段はその tab）:
- 依存が無い、または親に複数の子がいる task は新しいレーンを開始する。
- 親の唯一の子である task は親のレーンに合流する（直列チェーン）。
- レーン先頭 task の起動が workspace create、合流 task の起動は同 workspace への tab create。
- maintain では depends_on を無視し、全 task を独立レーン（wave 0）として扱う。

終了コード: 致命的検証エラー（循環・未定義参照・重複・必須欠落・plan の不在）があれば 1、
警告のみなら 0。maintain では depends_on を検証しないので、循環・未定義参照・自己依存は
エラーにならない（重複・必須欠落・plan の不在は両モードで見る）。

設計: 純粋関数（parse_spec / analyze / detect_cycle / compute_levels / compute_lanes /
resolve_base / sanitize / scope_check_command / render）には副作用を持たせない。
I/O・終了コード・ワーカー規約の取得（lane-ops worker_contract.py の子プロセス実行）・
プロンプトファイル書き出し・計画ファイルの存在確認は read_spec / contract_sections /
write_prompts / check_plan_file / main にまとめる。
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path

# claude CLI の受け付ける選択肢（`claude --help` 準拠）。
# model は alias/フルネーム自由なので検証しない（存在チェックは claude 側に委ねる）。
PERMISSION_MODES = ("acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan")
EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")


class Mode(Enum):
    """ジョブ全体の性質。lane-ops worker_contract.py の Mode(Enum) と同じ語彙。

    implement = 実装 → PR 作成 / maintain = PR 作成後のレビュー対応（Phase 4.5）。
    入力 JSON では文字列で受け取り parse_spec で変換する。規約へも文字列
    （`.value`）のまま渡し、lane-ops 側の parse_task が自分で Mode へ変換する。

    mode による分岐は「軸」ごとのプロパティで表す。呼び出し側は
    `plan.mode.<軸>` を肯定形で読み、`!=` / `is not` による否定を書かない。
    軸ごとに独立した判断であることを名前で保証するため、意味の違う分岐へ
    同じプロパティを流用しない（新しい分岐が要るなら新しい軸を足す）。
    """

    IMPLEMENT = "implement"
    MAINTAIN = "maintain"

    @property
    def checks_dependency_graph(self) -> bool:
        """依存グラフ（未定義参照・自己依存・複数親・循環）を検証するか。

        maintain で検証を残すと、maintain.md が指示する「対応不要な task を spec から
        削る」操作で残った task の depends_on が宙に浮き、致命的エラーで COMMANDS が
        出なくなる。
        """
        return self is Mode.IMPLEMENT

    @property
    def lanes_follow_dependency_graph(self) -> bool:
        """レーン割当・起動ウェーブを依存グラフから決めるか。

        maintain は全 task を独立レーン（wave 0）として扱う。レビュー対応の起動順序は
        指摘の内容次第で決まり、「前段の PR 作成」というゲートは空回りするため。
        """
        return self is Mode.IMPLEMENT

    @property
    def uses_existing_worktree(self) -> bool:
        """既存 worktree（ブランチ作成済み・PR 済み）へ入るか。

        maintain は `wt switch <branch>`（`--create` を付けると Path occupied で失敗）。
        既存の境界ファイルもこのとき上書きされる。
        """
        return self is Mode.MAINTAIN

    @property
    def runs_scope_check(self) -> bool:
        """計画突合（check_scope.py）を行うか。

        maintain の差分は元計画に無いので突合が成立しない。
        """
        return self is Mode.IMPLEMENT

    @property
    def creates_pull_request(self) -> bool:
        """ワーカーが PR を作成するか（PR / VERIFY 節を出すか）。

        maintain の PR は既にあるので、両節を出すと規約が禁じた操作を親へ指示することになる。
        """
        return self is Mode.IMPLEMENT

    @property
    def push_needs_parent_approval(self) -> bool:
        """ワーカーの push に親の承認が要るか（親の監視項目が変わる）。"""
        return self is Mode.MAINTAIN


class SpecError(Exception):
    """spec の構造そのものが壊れていて解析不能な場合。"""


@dataclass(frozen=True)
class Task:
    id: str
    branch: str
    depends_on: tuple[str, ...]
    prompt: str
    # 対応する GitHub issue 番号。0 = 未指定。
    issue: int = 0
    # claude 起動オプションの task 個別上書き。空文字 = 未指定（グローバル既定を使う）。
    model: str = ""
    permission_mode: str = ""
    effort: str = ""
    # 触ってよいパスの glob。空 = 境界宣言なし（境界ファイルを生成しない）。
    boundary: tuple[str, ...] = ()
    # 計画に書かれた変更ファイル一覧（リポジトリルート相対。glob 不可）。空 = ファイル照合なし。
    expected_files: tuple[str, ...] = ()
    # 計画の規模目安（追加+削除の行数）。0 = 規模照合なし。
    expected_scale: int = 0


@dataclass(frozen=True)
class Plan:
    default_base: str
    tasks: tuple[Task, ...]
    # 計画ファイルの絶対パス。空 = 未指定（ワーカー規約に計画参照を載せない）。
    plan: str = ""
    # ジョブ全体のモード。task ごとの混在は想定しない。
    mode: Mode = Mode.IMPLEMENT


@dataclass(frozen=True)
class Launch:
    """全 worktree に一律適用する claude 起動の既定（CLI フラグ由来）。

    各 task の model/permission_mode/effort が空のとき、ここの値をフォールバックに使う。
    parent_name は親（オーケストレータ）の herdr エージェント名で、ワーカー規約の
    報告先（lane-ops report.sh の宛先）としてワーカー規約へ埋め込まれる。
    """
    model: str = ""
    permission_mode: str = ""
    effort: str = ""
    remote_control: bool = False
    parent_name: str = ""


# 起動既定を何も指定しないときの Launch。frozen なので共有して安全。
NO_LAUNCH_DEFAULTS = Launch()


@dataclass(frozen=True)
class Options:
    """CLI 引数のパース結果。

    spec / prompt_dir は入出力の指定、launch は全 worktree へ一律適用する
    claude 起動の既定（task 個別指定があればそちらが優先される）。
    """

    spec: str
    prompt_dir: str = ""
    launch: Launch = NO_LAUNCH_DEFAULTS


@dataclass(frozen=True)
class Analysis:
    errors: list[str]   # 致命的（あれば commands を出さず exit 1）
    warnings: list[str]  # 続行可
    levels: dict[str, int]  # task id -> 起動ウェーブ（cycle 時は空）
    bases: dict[str, str]   # task id -> 解決済み base ブランチ（cycle 時は空）
    lanes: tuple[tuple[str, ...], ...]  # 論理レーンごとの task id 列（段順）
    lane_of: dict[str, int]  # task id -> レーン番号


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
        issue_raw = t.get("issue", 0) or 0
        if isinstance(issue_raw, bool) or not isinstance(issue_raw, int) or issue_raw < 0:
            raise SpecError(f"issue は非負整数でない: {t.get('id')!r}")
        expected_raw = t.get("expected_files", []) or []
        if not isinstance(expected_raw, list) or not all(isinstance(x, str) for x in expected_raw):
            raise SpecError(f"expected_files は文字列配列でない: {t.get('id')!r}")
        scale_raw = t.get("expected_scale", 0) or 0
        if isinstance(scale_raw, bool) or not isinstance(scale_raw, int) or scale_raw < 0:
            raise SpecError(f"expected_scale は非負整数でない: {t.get('id')!r}")
        tasks.append(
            Task(
                id=str(t.get("id", "")).strip(),
                branch=str(t.get("branch", "")).strip(),
                depends_on=tuple(str(d).strip() for d in deps_raw),
                prompt=str(t.get("prompt", "")).strip(),
                issue=issue_raw,
                model=str(t.get("model", "")).strip(),
                permission_mode=str(t.get("permission_mode", "")).strip(),
                effort=str(t.get("effort", "")).strip(),
                boundary=with_default_boundary(
                    tuple(g for g in (str(b).strip() for b in bounds_raw) if g)
                ),
                expected_files=tuple(x for x in (e.strip() for e in expected_raw) if x),
                expected_scale=scale_raw,
            )
        )
    default_base = str(data.get("default_base", "main")).strip() or "main"
    plan_raw = data.get("plan", "") or ""
    if not isinstance(plan_raw, str):
        raise SpecError("plan は文字列でない")
    plan_path = os.path.abspath(plan_raw.strip()) if plan_raw.strip() else ""
    mode_raw = data.get("mode", "implement") or "implement"
    if not isinstance(mode_raw, str):
        raise SpecError("mode は文字列でない")
    # 空文字・null・空白のみは既定へ縮退する（兄弟フィールドの plan と同じ扱い）。
    mode_name = mode_raw.strip() or Mode.IMPLEMENT.value
    try:
        mode = Mode(mode_name)
    except ValueError:
        allowed = " / ".join(m.value for m in Mode)
        raise SpecError(f"mode は {allowed} のいずれかでない: {mode_name!r}") from None
    return Plan(default_base=default_base, tasks=tuple(tasks), plan=plan_path, mode=mode)


# 境界宣言に必ず含める glob。PR 本文ドラフト等の一時出力先（tmp_claude/）が
# 境界外だと PR 作成フェーズで必ず deny に当たるため、宣言時に自動で足す。
DEFAULT_BOUNDARY_GLOBS = ("tmp_claude/**",)


def with_default_boundary(boundary: tuple[str, ...]) -> tuple[str, ...]:
    """境界宣言あり（非空）の task に既定 glob を補う。未宣言（空）はそのまま。"""
    if not boundary:
        return boundary
    return boundary + tuple(g for g in DEFAULT_BOUNDARY_GLOBS if g not in boundary)


def sanitize(name: str) -> str:
    """ラベル・Remote Control 名向けに英数・ハイフン以外を - に。"""
    return re.sub(r"[^A-Za-z0-9_-]+", "-", name).strip("-") or "wt"


def detect_cycle(plan: Plan) -> list[str] | None:
    """依存グラフの循環を DFS で検出。あれば経路を返し、無ければ None。"""
    graph = {t.id: list(t.depends_on) for t in plan.tasks}
    WHITE, GRAY, BLACK = 0, 1, 2
    color = {k: WHITE for k in graph}

    def dfs(node: str, stack: list[str]) -> list[str] | None:
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


def compute_lanes(plan: Plan, levels: dict[str, int]) -> tuple[tuple[tuple[str, ...], ...], dict[str, int]]:
    """グラフ -> レーン割当（直列チェーンのグルーピング = workspace 割当）。

    規則（決定論）: 依存無し、または親に複数の子がいる task は新レーンを開始。
    親の唯一の子はレーンに合流。複数親は先頭親で判定。
    ウェーブ順・同ウェーブ内は id 順に処理するので入力順に依らない。
    """
    children: dict[str, list[str]] = {t.id: [] for t in plan.tasks}
    for t in plan.tasks:
        for d in t.depends_on:
            if d in children:
                children[d].append(t.id)
    lane_of: dict[str, int] = {}
    lanes: list[list[str]] = []
    for t in sorted(plan.tasks, key=lambda x: (levels[x.id], x.id)):
        parent = t.depends_on[0] if t.depends_on else ""
        if parent and parent in lane_of and len(children[parent]) == 1:
            lane = lane_of[parent]
            lane_of[t.id] = lane
            lanes[lane].append(t.id)
        else:
            lane_of[t.id] = len(lanes)
            lanes.append([t.id])
    return tuple(tuple(l) for l in lanes), lane_of


def resolve_base(task: Task, by_id: dict[str, Task], default_base: str) -> str:
    """依存なし -> デフォルト base。依存あり -> 先頭親のブランチ。"""
    if not task.depends_on:
        return default_base
    return by_id[task.depends_on[0]].branch


def independent(plan: Plan) -> Plan:
    """全 task の depends_on を落とした Plan（純粋）。maintain のレーン算出に使う。"""
    return dataclasses.replace(
        plan, tasks=tuple(dataclasses.replace(t, depends_on=()) for t in plan.tasks)
    )


def analyze(plan: Plan) -> Analysis:
    """検証 + レベル/base/レーン算出を 1 つの純粋関数に集約。"""
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

    # 依存グラフ検証の on/off（理由は Mode.checks_dependency_graph）。この軸は
    # 依存グラフの検証専用で、他の mode 分岐へ流用しない（expected_files の WARNING の
    # ように依存グラフと無関係な分岐は、それぞれ自分の軸のプロパティを見る）。
    graph_checked = plan.mode.checks_dependency_graph
    idset = set(ids)
    for t in plan.tasks:
        if graph_checked:
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
        # 突合は maintain では行わないが、WARNING は両モードで出す（同じ spec を
        # implement へ戻して再利用したとき、maintain 時に無警告で通った欠落に
        # 気づけなくなるため）。
        if not t.expected_files:
            if plan.mode.runs_scope_check:
                warnings.append(
                    f"task {t.id} に expected_files が無い。計画突合（check_scope.py）はファイル照合なしに"
                    "縮退する（規模目安のみ、それも無ければ SKIP）。計画の変更ファイル一覧を spec へ落とす"
                )
            else:
                warnings.append(
                    f"task {t.id} に expected_files が無い。maintain では計画突合を行わないので"
                    "この実行に影響はないが、同じ spec を implement で再利用すると突合が"
                    "ファイル照合なしに縮退する。計画の変更ファイル一覧を spec へ落とす"
                )

    if graph_checked:
        cycle = detect_cycle(plan)
        if cycle is not None:
            errors.append(f"依存に循環: {' -> '.join(cycle)}")

    if errors:
        return Analysis(errors=errors, warnings=warnings, levels={}, bases={}, lanes=(), lane_of={})

    # レーン割当・ウェーブは依存グラフに従う（理由は Mode.lanes_follow_dependency_graph）。
    # 従わない maintain では全 task を独立レーンにする。下段 PR に追加コミットが入った
    # ときの上段の載せ替えは references/restack.md の手順として親が制御する。
    graph = plan if plan.mode.lanes_follow_dependency_graph else independent(plan)
    by_id = {t.id: t for t in graph.tasks}
    levels = compute_levels(graph)
    bases = {t.id: resolve_base(t, by_id, graph.default_base) for t in graph.tasks}
    lanes, lane_of = compute_lanes(graph, levels)
    return Analysis(
        errors=[], warnings=warnings, levels=levels, bases=bases, lanes=lanes, lane_of=lane_of
    )


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


# 各レーンへ引き継いではいけない、親（オーケストレータ）セッション固有の環境変数。
#
# claude は Bash ツールで子シェルを spawn するとき自分の身元を示すマーカーをその
# 子シェルへ注入する（claude プロセス本体の environ には無く、子シェルにだけ現れる）。
# COMMANDS はその子シェルから実行され、各レーンの claude は独立したセッションなので、
# 放置するとレーンが親の子プロセスだと誤認し、
#   - transcript 保存が切られる（CLAUDE_CODE_CHILD_SESSION）
#   - 親宛のメッセージ経路を掴む（CLAUDE_CODE_MESSAGING_*）
#   - 親のセッション ID を名乗る（CLAUDE_CODE_*SESSION_ID）
# といった不整合が起きる。
#
# ユーザー設定由来のもの（CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY 等）や実行ファイル解決に
# 使う CLAUDE_CODE_EXECPATH は引き継ぐので、ここには挙げない。
# project-session の launch.sh（inherited_session_vars）と同じ対象を、言語が違うため
# それぞれで定義する。
INHERITED_SESSION_VARS = (
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_BRIDGE_SESSION_ID",
    "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_ENTRYPOINT",
)

# 起動コマンドの先頭へ置く env -u 列。wt より前に置くので、wt 自身にもその子の
# claude にもマーカーが渡らない（COMMANDS をコピペした shell の環境は壊さない）。
ENV_STRIP_PREFIX = "env" + "".join(f" -u {v}" for v in INHERITED_SESSION_VARS)


BOUNDARY_FILE = ".claude/task-boundary.json"

# 境界ファイルを worktree ローカルかつ gitignored に置くための bootstrap。
# 引数は $1=境界 JSON 本文（1 行）。cwd は wt switch 後の worktree ルート。
# 方式・選定理由は parallel-worktree と同一（references/orchestration.md 参照）。
# set -e は意図的（fail-closed）: 境界の無い状態でガードレール無しに claude を
# 起動するより、起動せず pane に失敗を残す方が安全。
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
    """task の境界宣言 -> 境界ファイル（.claude/task-boundary.json）の内容（1 行）。

    書式は task-boundary hook の公開契約（task_id / branch / allow）。herdr pane へ
    1 コマンドで流し込むため改行を含めない（JSON として等価）。
    """
    return json.dumps(
        {"task_id": task.id, "branch": task.branch, "allow": list(task.boundary)},
        ensure_ascii=False,
    )


# ワーカー規約の正本は lane-ops の worker_contract.py（同一プラグイン内の兄弟スキル）。
# 規約の文言をここへ複製せず、子プロセスで取得して prompt へ連結する。
LANE_OPS_SCRIPTS = Path(__file__).resolve().parents[2] / "lane-ops" / "scripts"
WORKER_CONTRACT = LANE_OPS_SCRIPTS / "worker_contract.py"


class ContractError(Exception):
    """lane-ops worker_contract.py が見つからない・実行に失敗した場合。"""


# 同梱の計画突合スクリプト。ワーカー規約（--base）と VERIFY 節（--pr）の両方から参照する。
CHECK_SCOPE = Path(__file__).resolve().parent / "check_scope.py"


def scope_check_args(task: Task) -> str:
    """期待（expected_files / expected_scale）を check_scope.py の引数列にする（純粋）。"""
    parts: list[str] = []
    for f in task.expected_files:
        parts += ["--expected-file", f]
    if task.expected_scale:
        parts += ["--expected-scale", str(task.expected_scale)]
    return "".join(f" {shlex.quote(a)}" for a in parts)


def scope_check_command(task: Task, base: str) -> str:
    """ワーカーが PR 前に worktree で実行する突合コマンド（純粋）。"""
    return f"python3 {shlex.quote(str(CHECK_SCOPE))} --base {shlex.quote(base)}{scope_check_args(task)}"


def verify_command(task: Task) -> str:
    """親が PR 報告を受けて実行する突合コマンド（PR 番号はプレースホルダ。純粋）。"""
    return f"python3 {shlex.quote(str(CHECK_SCOPE))} --pr <{task.id} の PR 番号>{scope_check_args(task)}"


@dataclass(frozen=True)
class ContractPayload:
    """worker_contract.py へ渡すタスク情報（lane-ops の TaskInfo と同じ項目）。"""

    task_id: str
    branch: str
    base: str
    default_base: str
    boundary: tuple[str, ...]
    issue: int
    parent: str
    plan: str
    scope_check: str
    mode: str = "implement"

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=False)


def contract_payload(task: Task, base: str, plan: Plan, launch: Launch) -> ContractPayload:
    """Task + 解決済み base + Plan + Launch -> worker_contract.py への入力（純粋）。"""
    return ContractPayload(
        task_id=task.id,
        branch=task.branch,
        base=base,
        default_base=plan.default_base,
        boundary=task.boundary,
        issue=task.issue,
        parent=launch.parent_name,
        plan=plan.plan,
        scope_check=scope_check_command(task, base),
        # lane-ops の契約は文字列で受け取り自分で Enum へ変換する。ここでは値を渡す。
        mode=plan.mode.value,
    )


def contract_sections(task: Task, base: str, plan: Plan, launch: Launch) -> str:
    """lane-ops worker_contract.py を呼び、ワーカー規約セクションを取得する（副作用: 子プロセス）。"""
    if not WORKER_CONTRACT.is_file():
        raise ContractError(
            f"lane-ops の worker_contract.py が見つからない: {WORKER_CONTRACT}\n"
            "job-graph は lane-ops スキルと同時に配置される前提（同一プラグイン）。"
        )
    proc = subprocess.run(
        [sys.executable, str(WORKER_CONTRACT)],
        input=contract_payload(task, base, plan, launch).to_json(),
        capture_output=True,
        text=True,
        # 失敗は下で returncode を見て ContractError に変換する（例外送出に頼らない）。
        check=False,
    )
    if proc.returncode != 0:
        raise ContractError(f"worker_contract.py が失敗: {proc.stderr.strip()}")
    return proc.stdout.rstrip("\n")


def prompt_path(prompt_dir: str, task: Task) -> str:
    """task のワーカープロンプトを書き出すファイルパス（純粋: パス算出のみ）。"""
    return str(Path(prompt_dir) / f"{sanitize(task.id)}.md")


def launch_script_path(prompt_dir: str, task: Task) -> str:
    """task の起動スクリプトを書き出すファイルパス（純粋: パス算出のみ）。"""
    return str(Path(prompt_dir) / f"launch_{sanitize(task.id)}.sh")


@dataclass(frozen=True)
class LaunchScript:
    """pane へ `bash <path>` で流す起動スクリプト（path と本文）。"""

    path: str
    body: str


def wt_switch(task: Task, base: str, mode: Mode) -> str:
    """worktree へ入る `wt switch` 部分（純粋）。mode で --create / --base の有無が変わる。

    既存 worktree（ブランチ作成済み・PR 済み）へ入る maintain は素の
    `wt switch <branch>`（既存 worktree に --create を付けると Path occupied で失敗する。
    --create なしの switch は既存 worktree があればそこへ入り冪等）。
    worktree を新規生成する implement は `--create <branch> --base <解決済み base>`。
    """
    if mode.uses_existing_worktree:
        return f"wt switch {shlex.quote(task.branch)}"
    return f"wt switch --create {shlex.quote(task.branch)} --base {shlex.quote(base)}"


def launch_script(
    task: Task, base: str, plan: Plan, launch: Launch, prompt_dir: str
) -> LaunchScript:
    """task の起動コマンド（env -u ... wt switch ... -x claude|bash ...）を
    スクリプト本文として組む（純粋）。

    claude 引数列: 起動フラグ -> --remote-control（オプトイン）-> プロンプト（ファイルから
    読む）。プロンプトは複数行のため直接埋め込まず "$(cat <path>)" で bash に展開させる
    （wt は EXECUTE_ARGS を shell-escape して exec するので安全）。
    親セッション固有のマーカーは wt より前で断ち切る（ENV_STRIP_PREFIX 参照）。
    """
    ppath = prompt_path(prompt_dir, task)
    rc_args = f" --remote-control {shlex.quote(sanitize(task.branch))}" if launch.remote_control else ""
    flags_str = "".join(f" {shlex.quote(a)}" for a in launch_flags(task, launch))
    prompt_ref = f'"$(cat {shlex.quote(ppath)})"'
    switch = wt_switch(task, base, plan.mode)
    if task.boundary:
        # 境界宣言ありは -x bash の bootstrap 経由（worktree 生成後・claude 起動前に
        # 境界ファイルを置く）。境界 JSON は 1 行なので positional で渡す。
        cmd = (
            f"{ENV_STRIP_PREFIX} {switch}"
            f" -x bash -- -c {shlex.quote(BOUNDARY_BOOTSTRAP)}"
            f" {shlex.quote('wt-boundary-' + task.id)} {shlex.quote(boundary_json(task))}"
            f"{flags_str}{rc_args} {prompt_ref}"
        )
    else:
        cmd = (
            f"{ENV_STRIP_PREFIX} {switch}"
            f" -x claude --{flags_str}{rc_args} {prompt_ref}"
        )
    where = "既存 worktree へ switch" if plan.mode.uses_existing_worktree else f"base={base}"
    body = "\n".join(
        [
            "#!/usr/bin/env bash",
            f"# job-graph launch: {task.id} ({task.branch}) {where}",
            "# pane run へ長文を注入せず、このファイルを `bash <path>` で実行する",
            "set -e",
            f"exec {cmd}",
            "",
        ]
    )
    return LaunchScript(path=launch_script_path(prompt_dir, task), body=body)


def full_prompt(task: Task, base: str, plan: Plan, launch: Launch) -> str:
    """spec の prompt + lane-ops ワーカー規約（プロンプトファイルの内容）。"""
    body = task.prompt or f"<{task.id} のタスクプロンプト未記入>"
    return f"{body}\n\n{contract_sections(task, base, plan, launch)}\n"


def shell_var(prefix: str, name: str) -> str:
    """shell 変数名として安全な識別子（英数・_ 以外を _ に）。"""
    return prefix + re.sub(r"[^A-Za-z0-9_]+", "_", name)


def render(
    plan: Plan, an: Analysis, launch: Launch = NO_LAUNCH_DEFAULTS, prompt_dir: str = ""
) -> str:
    """Plan + Analysis -> 人間/AI 向けテキスト出力（純粋）。

    COMMANDS は herdr の JSON 応答から ID を掴む shell ブロックで出力する（jq 必須）。
    implement では、レーン先頭の workspace 作成 / 後続段の tab 作成 → root pane への
    `wt switch --create ... -x claude` 流し込み、stacked の PR 作成ゲート、
    プロンプトのファイル渡しまでを列挙する。後続段の workspace ID はラベルから
    `herdr workspace list` で再解決する（wave 間で shell が変わっても動くように）。
    herdr 呼び出しは全て `--session "$HSESSION"` を明示し、COMMANDS を別 shell へ
    コピペしても親と同じセッションへレーンが並ぶようにする。

    maintain では全 task が独立レーンなので tab 作成も PR 作成ゲートも出さず、流し込みは
    `wt switch ... -x claude`（--create なし）になる。PR / VERIFY 節も出力しない
    （SCHEDULE / LANES / BOUNDARY / MONITOR は mode ごとに文言が変わる）。
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
    if plan.mode.lanes_follow_dependency_graph:
        out.append("同一ウェーブ内は並列起動可。後続ウェーブは依存親の『PR 作成』を確認してから起動する。")
    else:
        out.append("maintain は depends_on を無視して全 task を wave 0 に置く（全レーン同時起動）。")
    for level in range(max_level + 1):
        wave = sorted(t.id for t in plan.tasks if an.levels[t.id] == level)
        kind = "独立・並列" if level == 0 else f"stacked {level}段目"
        out.append(f"  wave {level} ({kind}): {', '.join(wave)}")

    if plan.mode.lanes_follow_dependency_graph:
        out.append("\n=== LANES (レーン = workspace: 先頭 task が workspace create、後続段は同 workspace への tab) ===")
    else:
        out.append("\n=== LANES (レーン = workspace: maintain は全 task が単独レーン。tab 追加は起きない) ===")
    for i, lane in enumerate(an.lanes):
        chain = " -> ".join(lane)
        out.append(f"  lane {i}: {chain}")

    declared = [t for t in sorted(plan.tasks, key=lambda x: x.id) if t.boundary]
    if declared:
        if plan.mode.uses_existing_worktree:
            out.append(f"\n=== BOUNDARY (既存 worktree の {BOUNDARY_FILE} をこの内容で上書きする) ===")
            out.append(
                "task-boundary hook が境界外の Edit/Write を機械ブロックする。"
                "実装フェーズ中に widen_boundary.sh で広げた glob はこの上書きで巻き戻るので、"
                "起動前に既存の境界ファイルと突き合わせる（references/maintain.md）。"
            )
        else:
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

    if prompt_dir:
        out.append("\n=== PROMPTS (書き出し済みワーカープロンプトと起動スクリプト) ===")
        for t in sorted(plan.tasks, key=lambda x: (an.levels[x.id], x.id)):
            out.append(
                f"  {t.id}: {prompt_path(prompt_dir, t)}  launch: {launch_script_path(prompt_dir, t)}"
            )

    defaults = []
    if launch.model:
        defaults.append(f"model={launch.model}")
    if launch.permission_mode:
        defaults.append(f"permission-mode={launch.permission_mode}")
    if launch.effort:
        defaults.append(f"effort={launch.effort}")
    if launch.remote_control:
        defaults.append("remote-control（各 claude を --remote-control <ブランチ名> でも起動）")
    if launch.parent_name:
        defaults.append(f"parent={launch.parent_name}")
    launch_note = f" [起動既定: {'; '.join(defaults)}]" if defaults else ""
    out.append(f"\n=== COMMANDS (列挙のみ。実行前に plan 承認。jq 必須){launch_note} ===")
    if not prompt_dir:
        out.append("# --prompt-dir 未指定のため COMMANDS は出力しない。--prompt-dir を付けて再実行。")
        return "\n".join(out)

    # herdr CLI は HERDR_SESSION / HERDR_SOCKET_PATH が生きていれば現在のセッションへ
    # 解決するが、env が失われると既定セッションへ落ちる。COMMANDS は親と別の shell へ
    # コピペされうるので、セッションを 1 度だけ変数に固定して全呼び出しで明示する
    # （`herdr --session ""` は拒否されるため、未設定時は default へ畳む）。
    out.append("\n# レーンを作る herdr セッション（親 pane と同一。env が無い shell では default）")
    out.append('HSESSION="${HERDR_SESSION:-default}"')

    for level in range(max_level + 1):
        wave_tasks = [t for t in plan.tasks if an.levels[t.id] == level]
        if not wave_tasks:
            continue
        if level == 0:
            out.append(f"\n# wave {level}: 独立タスク。まとめて並列起動してよい")
        else:
            parents = sorted({by_id[d].branch for t in wave_tasks for d in t.depends_on})
            checks = " / ".join(f"gh pr list --head {shlex.quote(b)}" for b in parents)
            out.append(
                f"\n# wave {level}: 前段 [{', '.join(parents)}] の PR 作成を確認してから起動"
                f"（{checks}）"
            )
        for t in sorted(wave_tasks, key=lambda x: x.id):
            base = an.bases[t.id]
            sess = sanitize(t.branch)
            lane = an.lane_of[t.id]
            pane_var = shell_var("PANE_", t.id)
            ws_var = f"WS_LANE_{lane}"
            is_lane_head = an.lanes[lane][0] == t.id
            out.append(f"\n# --- {t.id} ({t.branch}) lane {lane} ---")
            if is_lane_head:
                # レーン先頭はレーン専用の workspace を立て、その root pane で起動する
                # （ラベル = 先頭ブランチ名。後続段はこのラベルで workspace を再解決する）。
                out.append(
                    f"resp=$(herdr --session \"$HSESSION\" workspace create"
                    f" --cwd \"$PWD\" --label {shlex.quote(sess)} --no-focus)"
                )
                out.append(
                    f"{ws_var}=$(printf '%s' \"$resp\" | jq -r '.result.workspace.workspace_id')"
                )
                out.append(
                    f"{pane_var}=$(printf '%s' \"$resp\" | jq -r '.result.root_pane.pane_id')"
                )
            else:
                # stacked の後続段はレーンの workspace へ tab を足す。workspace ID は
                # レーン先頭のラベルから再解決する（wave 間で shell が変わっても動く）。
                head_label = sanitize(by_id[an.lanes[lane][0]].branch)
                out.append(
                    f"{ws_var}=$(herdr --session \"$HSESSION\" workspace list | jq -r"
                    f" '.result.workspaces[] | select(.label == {json.dumps(head_label)})"
                    f" | .workspace_id' | head -n1)"
                )
                out.append(
                    f"resp=$(herdr --session \"$HSESSION\" tab create --workspace \"${ws_var}\""
                    f" --cwd \"$PWD\" --label {shlex.quote(sess)} --no-focus)"
                )
                out.append(
                    f"{pane_var}=$(printf '%s' \"$resp\" | jq -r '.result.root_pane.pane_id')"
                )
            # 起動コマンド本体は launch_<id>.sh（write_prompts が書き出す）にあり、pane には
            # `bash <path>` だけを流す（長文注入で未実行・切断が起きた実績への対策）。
            script = launch_script(t, base, plan, launch, prompt_dir)
            out.append(
                f"herdr --session \"$HSESSION\" pane run \"${pane_var}\""
                f" {shlex.quote('bash ' + shlex.quote(script.path))}"
            )

    # PR 節はワーカーの /pr-create、VERIFY 節はその PR に対する計画突合なので、
    # PR を作るモードでだけ出す（理由は Mode.creates_pull_request）。
    if plan.mode.creates_pull_request:
        out.append("\n=== PR (各ワーカーが実装・コミット後、/review-converge 収束後に自分で実行) ===")
        for t in sorted(plan.tasks, key=lambda x: (an.levels[x.id], x.id)):
            base = an.bases[t.id]
            arg = "" if base == plan.default_base else f" {base}"
            note = "（base 省略=デフォルト）" if base == plan.default_base else "（stacked: base=前段）"
            out.append(f"# {t.id} ({t.branch}): /pr-create{arg}   {note}")

        out.append("\n=== VERIFY (PR 報告を受けたら親が実行する計画突合。手順は references/scope-gate.md) ===")
        out.append("# VERDICT: PASS のときだけ凍結確認・次段起動へ進む。FAIL なら次段を起動せずユーザーへ報告する")
        for t in sorted(plan.tasks, key=lambda x: (an.levels[x.id], x.id)):
            out.append(f"# {t.id} ({t.branch}):")
            out.append(f"#   {verify_command(t)}")

    out.append("\n=== MONITOR (親のゲート監視。lane-ops スキルの運用ループに従う) ===")
    pane_args = "".join(
        f" --pane \"${shell_var('PANE_', t.id)}\"" for t in sorted(plan.tasks, key=lambda x: x.id)
    )
    out.append(
        "# 状態監視: 自レーンの pane に限定し、--once でバックグラウンド Bash の完了通知を push 通知にする"
        "（起動済みの pane だけを列挙。未起動の wave は起動後に足して再起動）"
    )
    out.append(
        f"#   python3 {shlex.quote(str(LANE_OPS_SCRIPTS / 'watch_events.py'))}"
        f" --once --status blocked --status idle{pane_args}"
    )
    out.append(
        "# イベント処理後は watch を再起動し、直後に"
        " herdr --session \"$HSESSION\" agent get <pane> で現在状態を直接確認する（停止中の変化を取りこぼさない）"
    )
    out.append(
        "# 画面確認:     herdr --session \"$HSESSION\" agent read <pane>"
        " --source recent-unwrapped --lines 120"
    )
    out.append(
        f"# 報告の裏取り: bash {shlex.quote(str(LANE_OPS_SCRIPTS / 'verify_lane.sh'))} <branch> <worktree>"
    )
    if plan.mode.push_needs_parent_approval:
        out.append(
            "# push 承認:    ワーカーは push 前に停止して「push 承認待ち」を報告する。"
            "裏取りしてから承認する（手順は references/maintain.md）。"
            "stacked なら下段から先に捌く（上段を先に通すと restack が二度手間になる）"
        )
        out.append("# ワーカーの報告（[lane-ops:report ...]）は自己申告。必ず裏取りしてから承認する")
    else:
        out.append("# 計画突合:     VERIFY 節の check_scope.py --pr（PR 報告のたびに実行。PASS のときだけ次段へ）")
        out.append("# ワーカーの報告（[lane-ops:report ...]）は自己申告。必ず裏取りしてから次段を起動する")

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


def write_prompts(plan: Plan, an: Analysis, launch: Launch, prompt_dir: str) -> None:
    """各 task のワーカープロンプト（本文 + 標準セクション）と起動スクリプトを prompt_dir へ書き出す。"""
    Path(prompt_dir).mkdir(parents=True, exist_ok=True)
    for t in plan.tasks:
        Path(prompt_path(prompt_dir, t)).write_text(
            full_prompt(t, an.bases[t.id], plan, launch), encoding="utf-8"
        )
        script = launch_script(t, an.bases[t.id], plan, launch, prompt_dir)
        Path(script.path).write_text(script.body, encoding="utf-8")


def check_plan_file(plan: Plan) -> list[str]:
    """spec の plan が指定されていて存在しなければ ERROR 文を返す（副作用: ファイル存在確認）。"""
    if plan.plan and not Path(plan.plan).is_file():
        return [f"plan が存在しない: {plan.plan}（相対パスは cwd 基準で絶対化される）"]
    return []


def parse_args(argv: list[str]) -> Options:
    """コマンドライン引数 -> Options（純粋: パースのみ）。

    起動既定（--model / --permission-mode / --effort / --remote-control /
    --parent-name）は Launch へまとめる。
    """
    parser = argparse.ArgumentParser(
        prog="plan_orchestration.py",
        description="job-graph オーケストレーション・スケジューラ（決定論 CLI）",
    )
    parser.add_argument("spec", help="spec.json のパス、または - で stdin から読む")
    parser.add_argument(
        "--prompt-dir",
        default="",
        metavar="DIR",
        help="ワーカープロンプトの書き出し先。指定すると <DIR>/<task-id>.md を生成し、"
        "COMMANDS がそれを参照する（未指定なら COMMANDS は出力しない）",
    )
    parser.add_argument(
        "--parent-name",
        default="",
        metavar="NAME",
        help="親（オーケストレータ）の herdr エージェント名。ワーカー規約の報告先"
        "（lane-ops report.sh の宛先）として埋め込む",
    )
    parser.add_argument(
        "--remote-control",
        action="store_true",
        help="各 worktree の claude を --remote-control <ブランチ名> でも起動し、"
        "claude.ai 等からリモート接続できるようにする",
    )
    parser.add_argument(
        "--model",
        default=None,
        metavar="MODEL",
        help="全 worktree の claude 既定モデル。task 個別の model 指定があればそちらが優先",
    )
    parser.add_argument(
        "--permission-mode",
        default=None,
        choices=PERMISSION_MODES,
        help="全 worktree の claude 既定パーミッションモード。task 個別指定があればそちらが優先",
    )
    parser.add_argument(
        "--effort",
        default=None,
        choices=EFFORT_LEVELS,
        help="全 worktree の claude 既定 effort レベル。task 個別指定があればそちらが優先",
    )
    ns = parser.parse_args(argv[1:])
    return Options(
        spec=ns.spec,
        prompt_dir=ns.prompt_dir,
        launch=Launch(
            model=ns.model or "",
            permission_mode=ns.permission_mode or "",
            effort=ns.effort or "",
            remote_control=ns.remote_control,
            parent_name=ns.parent_name or "",
        ),
    )


def main(argv: list[str]) -> int:
    opts = parse_args(argv)
    try:
        plan = parse_spec(read_spec(opts.spec))
    except SpecError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    an = analyze(plan)
    plan_errors = check_plan_file(plan)
    if plan_errors:
        an = Analysis(
            errors=an.errors + plan_errors, warnings=an.warnings,
            levels={}, bases={}, lanes=(), lane_of={},
        )
    if not an.errors and opts.prompt_dir:
        try:
            write_prompts(plan, an, opts.launch, opts.prompt_dir)
        except ContractError as e:
            print(f"ERROR: {e}", file=sys.stderr)
            return 1
    print(render(plan, an, opts.launch, opts.prompt_dir))
    return 1 if an.errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
