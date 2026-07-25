#!/usr/bin/env python3
"""dev-pipeline の決定論導出スクリプト。

シフトレフト開発プロセスの現在フェーズ・ゲート通過状況・マージ可否の判定材料を、
成果物（`docs/dev/<対象>/` / `docs/test/<対象>/`）と git/gh の状態から毎回導出する。
状態ファイルは持たない（SSOT は成果物そのもの）。導出不能な意図情報だけを
`docs/dev/<対象>/pipeline.toml` から読む。

読み取り専用。ファイルの書き込み・worktree 生成・エージェント起動は一切しない。

使い方:
    python derive_state.py [対象名] [-C <リポジトリルート>]

引数なし: 対象一覧モード（docs/dev/*/ と docs/test/*/ から候補を列挙）
対象指定: フェーズ導出 + ゲート通過状況 + マージ可否の判定材料

fail-open 設計（NFR-04）: gh が無い・git リポジトリでない・API 失敗時は静かに
スキップし「導出不能（理由）」として報告する。成果物が無い任意の組み合わせ状態でも
クラッシュせず、その状態から言える範囲だけを出力する（AC-05）。
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# 定数（成果物の規約パスと工程定義）
# ---------------------------------------------------------------------------

DEV_DIR = "docs/dev"
TEST_DIR = "docs/test"
DOD_PATH = "docs/dev/definition-of-done.md"

#: docs/dev/ 直下にあってもパイプライン対象ディレクトリではないもの
NON_TARGET_DEV_ENTRIES = {"definition-of-done.md"}

#: 対象ディレクトリ配下でスキャンする成果物（キー → 相対ファイル名）
DEV_ARTIFACTS = {
    "spec": "spec.md",
    "basic-design": "basic-design.md",
    "pipeline-toml": "pipeline.toml",
}

TEST_ARTIFACTS = {
    "test-plan": "test-plan.md",
    "test-analysis": "test-analysis.md",
    "test-design": "test-design.md",
    "test-case": "test-case.md",
    "test-procedures": "test-procedures.md",
    "test-execution-log": "test-execution-log.md",
    "test-monitoring": "test-monitoring.md",
    "test-summary-report": "test-summary-report.md",
}

#: 5 工程（spec.md の「全体アーキテクチャ」節が正）
PHASES: list[tuple[int, str]] = [
    (0, "完成の定義"),
    (1, "要求整理 → 仕様"),
    (2, "テスト計画/分析 ⇄ 仕様見直し"),
    (3, "テスト設計 ⇄ 基本設計"),
    (4, "テスト実装 → 実装 ⇄ レビュー"),
    (5, "PR・テスト評価 → 統合"),
]

VERDICTS = ("通過", "条件付き通過", "差し戻し")

#: test-review 記録の判定行（references/template.md の書式）
VERDICT_LINE_RE = re.compile(r"^\s*[-*]?\s*判定\s*[:：]\s*(.*)$")

#: definition-of-done.md 機械判定テーブルの行
DOD_ROW_RE = re.compile(r"^\|(.+)\|\s*$")

#: test-summary-report.md の総合判定行
SUMMARY_VERDICT_RE = re.compile(r"^\s*[-*]?\s*総合判定\s*[:：]\s*(.*)$")

#: 人判定節のチェックリスト行
CHECKLIST_RE = re.compile(r"^\s*[-*]\s*\[( |x|X)\]\s*(.*)$")


# ---------------------------------------------------------------------------
# データ構造
# ---------------------------------------------------------------------------


@dataclass
class Declaration:
    """pipeline.toml の宣言内容（無ければ全て既定値）。"""

    present: bool = False
    path: str | None = None
    error: str | None = None
    target: str | None = None
    spec_path: str | None = None
    design_path: str | None = None
    skip: list[str] = field(default_factory=list)
    plan_file: str | None = None
    branches: list[str] = field(default_factory=list)
    integration_targets: list[str] = field(default_factory=list)


@dataclass
class DodItem:
    """完成の定義 機械判定テーブルの 1 行。"""

    id: str
    description: str
    kind: str
    subject: str
    condition: str
    verdict: str = "判定不能"
    detail: str = ""


@dataclass
class GitState:
    """git/gh 系統の導出結果。取得できなかった項目は None + reason。"""

    available: bool = False
    reason: str | None = None
    branches: list[str] = field(default_factory=list)
    current_branch: str | None = None
    gh_available: bool = False
    gh_reason: str | None = None
    open_prs: list[dict] = field(default_factory=list)
    merged_prs: list[dict] = field(default_factory=list)


# ---------------------------------------------------------------------------
# 宣言ファイル（pipeline.toml）
# ---------------------------------------------------------------------------


def load_declaration(root: Path, target: str) -> Declaration:
    """`docs/dev/<対象>/pipeline.toml` を読む。無い・壊れていても例外を出さない。"""
    path = root / DEV_DIR / target / "pipeline.toml"
    if not path.is_file():
        return Declaration(present=False, path=str(path))

    decl = Declaration(present=True, path=str(path))
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        decl.error = f"{type(exc).__name__}: {exc}"
        return decl

    def table(name: str) -> dict:
        value = data.get(name)
        return value if isinstance(value, dict) else {}

    def string(value: object) -> str | None:
        return value if isinstance(value, str) else None

    def string_list(value: object) -> list[str]:
        if not isinstance(value, list):
            return []
        return [item for item in value if isinstance(item, str)]

    decl.target = string(data.get("target"))
    decl.spec_path = string(table("spec").get("path"))
    decl.design_path = string(table("design").get("path"))
    decl.skip = string_list(table("scope").get("skip"))
    decl.plan_file = string(table("implementation").get("plan_file"))
    decl.branches = string_list(table("implementation").get("branches"))
    decl.integration_targets = string_list(table("integration").get("targets"))
    return decl


# ---------------------------------------------------------------------------
# 対象一覧モード
# ---------------------------------------------------------------------------


def list_targets(root: Path) -> dict[str, list[str]]:
    """docs/dev/*/ と docs/test/*/ から対象候補を列挙する。

    Returns:
        対象名 → その対象がどちらの系統に現れたか（"dev" / "test"）のリスト。
    """
    found: dict[str, list[str]] = {}

    for kind, rel in (("dev", DEV_DIR), ("test", TEST_DIR)):
        base = root / rel
        if not base.is_dir():
            continue
        try:
            entries = sorted(base.iterdir())
        except OSError:
            continue
        for entry in entries:
            if not entry.is_dir():
                continue
            if entry.name.startswith(".") or entry.name in NON_TARGET_DEV_ENTRIES:
                continue
            found.setdefault(entry.name, []).append(kind)

    return found


# ---------------------------------------------------------------------------
# ファイル系統スキャン
# ---------------------------------------------------------------------------


def scan_artifacts(root: Path, target: str, decl: Declaration) -> dict[str, Path | None]:
    """成果物の存在をスキャンする。存在すれば絶対パス、無ければ None。"""
    result: dict[str, Path | None] = {}

    dev_base = root / DEV_DIR / target
    for key, name in DEV_ARTIFACTS.items():
        override = None
        if key == "spec" and decl.spec_path:
            override = root / decl.spec_path
        elif key == "basic-design" and decl.design_path:
            override = root / decl.design_path
        path = override if override is not None else dev_base / name
        result[key] = path if path.is_file() else None

    test_base = root / TEST_DIR / target
    for key, name in TEST_ARTIFACTS.items():
        path = test_base / name
        result[key] = path if path.is_file() else None

    return result


def scan_reviews(root: Path, target: str) -> dict[str, str]:
    """`docs/test/<対象>/test-review-*.md` の判定を工程名 → 判定で返す。

    判定行は test-review の references/template.md の書式（`- 判定: <通過 / ...>`）。
    行から 通過 / 条件付き通過 / 差し戻し を抽出する。判定行が無い・語彙外なら
    「判定不明」とする（クラッシュさせない）。
    """
    reviews: dict[str, str] = {}
    base = root / TEST_DIR / target
    if not base.is_dir():
        return reviews

    try:
        files = sorted(base.glob("test-review-*.md"))
    except OSError:
        return reviews

    for path in files:
        stage = path.stem[len("test-review-") :]
        if not stage:
            continue
        reviews[stage] = extract_review_verdict(read_text(path))
    return reviews


def read_text(path: Path) -> str:
    """テキストを読む。読めなければ空文字（fail-open）。"""
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""


def extract_review_verdict(text: str) -> str:
    """レビュー記録本文から判定語彙を抽出する。"""
    for line in text.splitlines():
        match = VERDICT_LINE_RE.match(line)
        if not match:
            continue
        rest = match.group(1)
        # 「条件付き通過」は「通過」を含むため長い語彙から先に照合する
        for verdict in sorted(VERDICTS, key=len, reverse=True):
            if verdict in rest:
                return verdict
        return "判定不明"
    return "判定不明"


def extract_summary_verdict(text: str) -> str | None:
    """test-summary-report.md の総合判定行の値を返す。無ければ None。"""
    for line in text.splitlines():
        match = SUMMARY_VERDICT_RE.match(line)
        if match:
            value = match.group(1).strip()
            return value if value else None
    return None


# ---------------------------------------------------------------------------
# 完成の定義（definition-of-done.md）
# ---------------------------------------------------------------------------


def parse_dod(text: str) -> tuple[list[DodItem], list[tuple[bool, str]]]:
    """完成の定義をパースし、機械判定テーブルの項目と人判定チェックリストを返す。

    テーブル契約（def-done の references/template.md が正）:
        `| ID | 項目 | 種別 | 対象 | 条件 |`
    種別は `ci-check` / `artifact`。それ以外の行・区切り行・見出し行は無視する。

    人判定のチェックリストは「人判定」見出し以降の `- [ ]` 行のみを拾う。
    """
    items: list[DodItem] = []
    checklist: list[tuple[bool, str]] = []
    in_human_section = False

    for raw in text.splitlines():
        line = raw.rstrip()

        if line.lstrip().startswith("#"):
            heading = line.lstrip("#").strip()
            in_human_section = heading.startswith("人判定")
            continue

        if in_human_section:
            check = CHECKLIST_RE.match(line)
            if check:
                checked = check.group(1).lower() == "x"
                label = check.group(2).strip()
                if label:
                    checklist.append((checked, label))
            continue

        row = DOD_ROW_RE.match(line)
        if not row:
            continue
        cells = [cell.strip() for cell in row.group(1).split("|")]
        if len(cells) != 5:
            continue
        item_id, description, kind, subject, condition = cells
        if kind not in ("ci-check", "artifact"):
            continue  # ヘッダ行・区切り行・テンプレのプレースホルダ行を弾く
        if not item_id:
            continue
        items.append(
            DodItem(
                id=item_id,
                description=description,
                kind=kind,
                subject=subject,
                condition=condition,
            )
        )

    return items, checklist


def judge_dod_items(
    items: list[DodItem],
    root: Path,
    target: str,
    git: GitState,
) -> list[DodItem]:
    """機械判定テーブルの各項目を判定する（items を破壊的に更新して返す）。"""
    check_status: dict[str, str] | None = None

    for item in items:
        if item.kind == "artifact":
            judge_artifact_item(item, root, target)
        elif item.kind == "ci-check":
            if check_status is None:
                check_status = fetch_check_status(root, git)
            judge_ci_item(item, check_status)
    return items


def judge_artifact_item(item: DodItem, root: Path, target: str) -> None:
    """artifact 種別の判定。対象パスの `{target}` を対象名へ展開する。"""
    rel = item.subject.replace("{target}", target)
    path = root / rel
    condition = item.condition

    if condition == "exists":
        if path.is_file():
            item.verdict = "OK"
            item.detail = f"{rel} が存在する"
        else:
            item.verdict = "NG"
            item.detail = f"{rel} が無い"
        return

    if condition.startswith("contains:"):
        needle = condition[len("contains:") :]
        if not path.is_file():
            item.verdict = "NG"
            item.detail = f"{rel} が無い"
            return
        text = read_text(path)
        if needle and needle in text:
            item.verdict = "OK"
            item.detail = f"{rel} が {needle!r} を含む"
        else:
            item.verdict = "NG"
            item.detail = f"{rel} が {needle!r} を含まない"
        return

    item.verdict = "判定不能"
    item.detail = f"未知の条件 {condition!r}（語彙は exists / contains:<文字列>）"


def judge_ci_item(item: DodItem, check_status: dict[str, str] | None) -> None:
    """ci-check 種別の判定。gh が使えないときは「判定不能」。"""
    if check_status is None:
        item.verdict = "判定不能"
        item.detail = "gh でチェック状態を取得できない"
        return

    conclusion = check_status.get(item.subject)
    if conclusion is None:
        item.verdict = "判定不能"
        item.detail = f"check {item.subject!r} が見つからない"
        return

    if item.condition != "success":
        item.verdict = "判定不能"
        item.detail = f"未知の条件 {item.condition!r}（語彙は success）"
        return

    if conclusion.lower() == "success":
        item.verdict = "OK"
        item.detail = f"check {item.subject!r} = success"
    else:
        item.verdict = "NG"
        item.detail = f"check {item.subject!r} = {conclusion}"


# ---------------------------------------------------------------------------
# git / gh 系統（fail-open）
# ---------------------------------------------------------------------------


def run(cmd: list[str], cwd: Path, timeout: int = 20) -> tuple[int, str, str]:
    """外部コマンドを実行する。失敗・不在・タイムアウトでも例外を出さない。"""
    if shutil.which(cmd[0]) is None:
        return 127, "", f"{cmd[0]} が見つからない"
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, "", f"{type(exc).__name__}: {exc}"
    return proc.returncode, proc.stdout, proc.stderr


def collect_git_state(root: Path) -> GitState:
    """git / gh から収束点 docs PR・実装レーンの状態を集める（fail-open）。"""
    state = GitState()

    code, out, err = run(["git", "rev-parse", "--is-inside-work-tree"], root)
    if code != 0 or out.strip() != "true":
        state.reason = (err.strip() or "git リポジトリではない")
        return state
    state.available = True

    code, out, _ = run(["git", "branch", "--format=%(refname:short)"], root)
    if code == 0:
        state.branches = [line.strip() for line in out.splitlines() if line.strip()]

    code, out, _ = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], root)
    if code == 0:
        state.current_branch = out.strip() or None

    collect_gh_state(root, state)
    return state


def collect_gh_state(root: Path, state: GitState) -> None:
    """gh から PR 一覧を取得する。失敗したら静かにスキップして理由を残す。"""
    if shutil.which("gh") is None:
        state.gh_reason = "gh が見つからない"
        return

    fields = "number,title,state,headRefName,baseRefName,mergedAt,url"
    code, out, err = run(
        ["gh", "pr", "list", "--state", "all", "--limit", "50", "--json", fields],
        root,
        timeout=30,
    )
    if code != 0:
        state.gh_reason = err.strip().splitlines()[0] if err.strip() else "gh pr list に失敗"
        return

    try:
        prs = json.loads(out or "[]")
    except json.JSONDecodeError as exc:
        state.gh_reason = f"gh pr list の JSON を解釈できない: {exc}"
        return
    if not isinstance(prs, list):
        state.gh_reason = "gh pr list の出力形式が想定外"
        return

    state.gh_available = True
    for pr in prs:
        if not isinstance(pr, dict):
            continue
        if pr.get("mergedAt"):
            state.merged_prs.append(pr)
        elif str(pr.get("state", "")).upper() == "OPEN":
            state.open_prs.append(pr)


def fetch_check_status(root: Path, git: GitState) -> dict[str, str] | None:
    """現在ブランチの HEAD に紐づく check 名 → conclusion を返す。取れなければ None。"""
    if not git.available or shutil.which("gh") is None:
        return None

    code, out, _ = run(
        [
            "gh",
            "api",
            "repos/{owner}/{repo}/commits/HEAD/check-runs",
            "--jq",
            ".check_runs[] | [.name, (.conclusion // .status)] | @tsv",
        ],
        root,
        timeout=30,
    )
    if code != 0:
        return None

    status: dict[str, str] = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 2 and parts[0]:
            status[parts[0]] = parts[1]
    return status or None


def related_prs(prs: list[dict], target: str, branches: list[str]) -> list[dict]:
    """対象名・宣言ブランチ名に関連しそうな PR を絞り込む。"""
    needles = {target.lower()} | {b.lower() for b in branches if b}
    hits = []
    for pr in prs:
        haystack = " ".join(
            str(pr.get(key, "")) for key in ("title", "headRefName", "baseRefName")
        ).lower()
        if any(needle and needle in haystack for needle in needles):
            hits.append(pr)
    return hits


# ---------------------------------------------------------------------------
# フェーズ導出
# ---------------------------------------------------------------------------


def is_skipped(stage: str, decl: Declaration) -> bool:
    return stage in decl.skip


def review_passed(reviews: dict[str, str], stage: str) -> bool:
    """該当工程の test-review が通過（条件付き含む）しているか。"""
    return reviews.get(stage) in ("通過", "条件付き通過")


def derive_phase(
    root: Path,
    target: str,
    artifacts: dict[str, Path | None],
    reviews: dict[str, str],
    decl: Declaration,
    git: GitState,
) -> tuple[int, str, list[str]]:
    """現在フェーズ（工程 0〜5）を導出する。

    Returns:
        (工程番号, 導出したフェーズ名, 判断理由のリスト)
    """
    reasons: list[str] = []
    have = {key: artifacts.get(key) is not None for key in artifacts}

    dev_dir_exists = (root / DEV_DIR / target).is_dir()
    test_dir_exists = (root / TEST_DIR / target).is_dir()
    dod_exists = (root / DOD_PATH).is_file()

    # 終了判定: 作業ディレクトリが消えていればパイプライン終了（doc-integrate 済み）
    if not dev_dir_exists and not test_dir_exists:
        reasons.append(f"{DEV_DIR}/{target}/ も {TEST_DIR}/{target}/ も存在しない")
        return 5, "終了（作業ディレクトリ削除済み）", reasons
    if not dev_dir_exists and test_dir_exists:
        reasons.append(
            f"{DEV_DIR}/{target}/ は無いが {TEST_DIR}/{target}/ が残っている"
            "（doc-integrate 途中か、テスト成果物のみ先行）"
        )

    if not dod_exists:
        reasons.append(f"{DOD_PATH} が無い（工程 0 未実施）")

    # 工程 5: テスト実行・評価
    if have.get("test-execution-log") or have.get("test-summary-report"):
        reasons.append("テスト実行/評価の成果物がある")
        return 5, "PR・テスト評価 → 統合", reasons

    # 工程 4: テスト実装 → 実装
    impl_branch_hit = [
        b for b in git.branches if b in decl.branches or (target and target in b)
    ]
    if have.get("test-procedures") or impl_branch_hit:
        if impl_branch_hit:
            reasons.append(f"実装レーンらしきブランチ: {', '.join(impl_branch_hit)}")
        if have.get("test-procedures"):
            reasons.append("test-procedures.md がある（テスト実装済み）")
        return 4, "テスト実装 → 実装 ⇄ レビュー", reasons

    # 工程 3: テスト設計 ⇄ 基本設計
    design_done = (
        have.get("basic-design")
        and have.get("test-case")
        and review_passed(reviews, "design-doc")
    )
    if design_done:
        reasons.append(
            "basic-design.md / test-case.md が揃い test-review-design-doc が通過している"
        )
        return 4, "テスト実装 → 実装 ⇄ レビュー", reasons
    if have.get("test-design") or have.get("test-case") or have.get("basic-design"):
        reasons.append("テスト設計・基本設計の成果物が揃い途中")
        return 3, "テスト設計 ⇄ 基本設計", reasons

    # 工程 2: テスト計画/分析 ⇄ 仕様見直し
    plan_done = have.get("test-plan") and have.get("test-analysis")
    if plan_done and review_passed(reviews, "test-analysis"):
        reasons.append("test-plan / test-analysis が揃い test-review-test-analysis が通過")
        return 3, "テスト設計 ⇄ 基本設計", reasons
    if have.get("test-plan") or have.get("test-analysis"):
        reasons.append("テスト計画/分析の成果物が揃い途中")
        return 2, "テスト計画/分析 ⇄ 仕様見直し", reasons

    # 工程 1: 要求整理 → 仕様
    if have.get("spec"):
        if review_passed(reviews, "spec"):
            reasons.append("spec.md があり test-review-spec が通過している")
            return 2, "テスト計画/分析 ⇄ 仕様見直し", reasons
        reasons.append("spec.md はあるが test-review-spec の通過記録が無い")
        return 1, "要求整理 → 仕様", reasons

    if not dod_exists:
        return 0, "完成の定義", reasons

    reasons.append("spec.md が無い")
    return 1, "要求整理 → 仕様", reasons


def next_actions(
    phase: int,
    target: str,
    artifacts: dict[str, Path | None],
    reviews: dict[str, str],
    decl: Declaration,
    root: Path,
) -> list[str]:
    """次の一手（次に実行すべき工程スキルの提案文）を組み立てる。"""
    have = {key: artifacts.get(key) is not None for key in artifacts}
    dod_exists = (root / DOD_PATH).is_file()
    actions: list[str] = []

    if not dod_exists and phase < 5:
        actions.append(
            f"`/def-done` — {DOD_PATH} が未整備。マージゲートの判定材料になるため先に用意する"
        )

    if phase == 0:
        actions.append(f"`/feature-spec {target}` — 仕様（spec.md）を作成する")
    elif phase == 1:
        if not have.get("spec"):
            actions.append(f"`/feature-spec {target}` — 仕様（spec.md）を作成する")
        elif reviews.get("spec") == "差し戻し":
            actions.append(
                f"`/feature-spec {target}`（改訂モード）— test-review-spec が差し戻し。"
                "未解消の指摘を反映してから `/test-review` を再実行する"
            )
        else:
            actions.append(
                f"`/test-review {target} spec` — 仕様のゲート（軽量・機械検査中心）を通す"
            )
    elif phase == 2:
        if not have.get("test-plan"):
            actions.append(f"`/test-plan {target}` — テスト計画を作成する")
        elif not have.get("test-analysis"):
            actions.append(f"`/test-analyze {target}` — テスト分析（TC-# 導出）を行う")
        else:
            actions.append(
                f"`/test-review {target} test-analysis` — テスト分析のゲートを通す"
            )
        if "test-monitor" not in decl.skip and not have.get("test-monitoring"):
            actions.append(
                f"`/test-monitor {target}` — test-plan 収束後に監視・CI 構築を開始できる"
            )
    elif phase == 3:
        if not have.get("test-design"):
            actions.append(f"`/test-design {target}` — テスト設計（CASE-# 導出）を行う")
        if not have.get("basic-design"):
            actions.append(f"`/basic-design {target}` — 基本設計書を作成する")
        if have.get("basic-design") and not review_passed(reviews, "design-doc"):
            actions.append(f"`/test-review {target} design-doc` — 基本設計のゲートを通す")
    elif phase == 4:
        if not have.get("test-procedures"):
            actions.append(f"`/test-implement {target}` — テスト実装（自動テスト）を進める")
        actions.append(
            "実装フェーズ入口: 基本設計（basic-design.md）と test-case.md から"
            "**実装計画ファイルを作成**し、`/parallel-worktree <計画ファイル>` を起動して"
            "実装レーンを走らせる"
        )
        actions.append(
            "各レーンでは PR 作成前に `/review-converge` を回して収束させ、"
            "`/pr-create [base]` で PR を出す"
        )
    elif phase == 5:
        if not have.get("test-execution-log"):
            actions.append(f"`/test-execute {target}` — テストを実行して記録を残す")
        elif not have.get("test-summary-report"):
            actions.append(f"`/test-report {target}` — テスト結果を評価して総合判定を出す")
        else:
            actions.append(
                f"`/doc-integrate {target}` — 本体ドキュメントへ統合し "
                f"{DEV_DIR}/{target}/ を削除する（マージ判断はユーザー）"
            )

    if not decl.present and phase < 5:
        actions.append(
            f"（任意）{DEV_DIR}/{target}/pipeline.toml を置くと、"
            "スキップ工程・実装レーン・統合先を宣言して導出精度を上げられる"
        )

    return actions


# ---------------------------------------------------------------------------
# レポート整形
# ---------------------------------------------------------------------------


def render_target_list(root: Path, found: dict[str, list[str]]) -> str:
    lines = ["# dev-pipeline: 対象一覧", "", f"リポジトリルート: {root}", ""]
    if not found:
        lines += [
            "対象候補が見つからない。",
            "",
            f"- `{DEV_DIR}/<対象>/` も `{TEST_DIR}/<対象>/` も存在しない",
            f"- 新規に始めるなら `/def-done`（{DOD_PATH} 未整備なら）→ `/feature-spec <対象>` から",
        ]
        return "\n".join(lines) + "\n"

    lines.append("| 対象 | docs/dev | docs/test | pipeline.toml |")
    lines.append("|---|---|---|---|")
    for name in sorted(found):
        kinds = found[name]
        decl_mark = (
            "あり" if (root / DEV_DIR / name / "pipeline.toml").is_file() else "-"
        )
        lines.append(
            f"| {name} | {'あり' if 'dev' in kinds else '-'} "
            f"| {'あり' if 'test' in kinds else '-'} | {decl_mark} |"
        )

    lines += [
        "",
        "どの対象のパイプライン状態を導出するか選び、`/dev-pipeline <対象>` を実行する。",
    ]
    dod_exists = (root / DOD_PATH).is_file()
    lines.append(
        f"完成の定義（{DOD_PATH}）: {'あり' if dod_exists else '**無し**（`/def-done` で作成できる）'}"
    )
    return "\n".join(lines) + "\n"


def render_report(
    root: Path,
    target: str,
    decl: Declaration,
    artifacts: dict[str, Path | None],
    reviews: dict[str, str],
    git: GitState,
    phase: int,
    phase_name: str,
    reasons: list[str],
    actions: list[str],
    dod_items: list[DodItem],
    dod_checklist: list[tuple[bool, str]],
    dod_error: str | None,
    summary_verdict: str | None,
) -> str:
    lines: list[str] = []
    add = lines.append

    add(f"# dev-pipeline: {target}")
    add("")
    add(f"リポジトリルート: {root}")
    add("")

    # --- 現在フェーズ ---
    add("## 現在フェーズ")
    add("")
    add(f"**工程 {phase}: {phase_name}**")
    add("")
    for reason in reasons:
        add(f"- 導出根拠: {reason}")
    if decl.skip:
        add(f"- スキップ宣言済み: {', '.join(decl.skip)}")
    add("")
    add("| 工程 | 名前 |")
    add("|---|---|")
    for number, name in PHASES:
        marker = " ←現在地" if number == phase else ""
        add(f"| {number} | {name}{marker} |")
    add("")

    # --- 宣言ファイル ---
    add("## 宣言ファイル（pipeline.toml）")
    add("")
    if not decl.present:
        add(f"- 無し（{DEV_DIR}/{target}/pipeline.toml）。既定パス・全工程実施として導出した")
    elif decl.error:
        add(f"- **パース失敗**: {decl.error}")
        add("- 宣言なしとして導出した（fail-open）")
    else:
        add(f"- パス: {decl.path}")
        if decl.target and decl.target != target:
            add(f"- 警告: `target = \"{decl.target}\"` が指定対象 `{target}` と一致しない")
        if decl.spec_path:
            add(f"- `[spec].path` = {decl.spec_path}")
        if decl.design_path:
            add(f"- `[design].path` = {decl.design_path}")
        if decl.skip:
            add(f"- `[scope].skip` = {', '.join(decl.skip)}")
        if decl.plan_file:
            add(f"- `[implementation].plan_file` = {decl.plan_file}")
        if decl.branches:
            add(f"- `[implementation].branches` = {', '.join(decl.branches)}")
        if decl.integration_targets:
            add(f"- `[integration].targets` = {', '.join(decl.integration_targets)}")
    add("")

    # --- 成果物 ---
    add("## 成果物スキャン")
    add("")
    add("| 成果物 | 状態 |")
    add("|---|---|")
    for key in list(DEV_ARTIFACTS) + list(TEST_ARTIFACTS):
        path = artifacts.get(key)
        if path is not None:
            try:
                shown = path.relative_to(root)
            except ValueError:
                shown = path
            add(f"| {key} | あり（{shown}） |")
        elif is_skipped(key, decl):
            add(f"| {key} | スキップ宣言済み |")
        else:
            add(f"| {key} | 無し |")
    dod_exists = (root / DOD_PATH).is_file()
    add(f"| definition-of-done | {'あり' if dod_exists else '無し'} |")
    add("")

    # --- ゲート通過状況 ---
    add("## ゲート通過状況")
    add("")
    if reviews:
        add("| 工程 | 判定 |")
        add("|---|---|")
        for stage in sorted(reviews):
            add(f"| {stage} | {reviews[stage]} |")
    else:
        add("- `test-review-*.md` の記録が無い（未レビュー、または該当工程に未到達）")
    add("")

    add("### 収束点 docs PR / 実装レーン")
    add("")
    if not git.available:
        add(f"- 導出不能（{git.reason or 'git の状態を取得できない'}）")
    else:
        if git.current_branch:
            add(f"- 現在ブランチ: {git.current_branch}")
        lane_hits = [
            b for b in git.branches if b in decl.branches or (target and target in b)
        ]
        if lane_hits:
            add(f"- 実装レーン候補ブランチ: {', '.join(lane_hits)}")
        elif decl.branches:
            add(f"- 宣言ブランチ {', '.join(decl.branches)} はローカルに見当たらない")
        else:
            add("- 実装レーンらしきローカルブランチは見当たらない")

        if not git.gh_available:
            add(f"- PR 状態は導出不能（{git.gh_reason or 'gh を利用できない'}）")
        else:
            merged = related_prs(git.merged_prs, target, decl.branches)
            opened = related_prs(git.open_prs, target, decl.branches)
            if merged:
                add("- マージ済み PR:")
                for pr in merged:
                    add(f"  - #{pr.get('number')} {pr.get('title')} ({pr.get('headRefName')})")
            else:
                add("- 対象に関連するマージ済み PR は見つからない")
            if opened:
                add("- オープン中の PR:")
                for pr in opened:
                    add(f"  - #{pr.get('number')} {pr.get('title')} ({pr.get('headRefName')})")
            else:
                add("- 対象に関連するオープン PR は見つからない")
    add("")

    # --- マージ可否の判定材料 ---
    add("## マージ可否の判定材料")
    add("")
    add("> 最終判断は常にユーザーが行う。以下は判定材料の提示であり、自動マージはしない。")
    add("")

    add("### 受け入れ基準（テスト結果評価）")
    add("")
    if artifacts.get("test-summary-report") is None:
        add(f"- {TEST_DIR}/{target}/test-summary-report.md が無い（`/test-report` 未実施）")
    elif summary_verdict:
        add(f"- 総合判定: **{summary_verdict}**")
    else:
        add("- test-summary-report.md はあるが「総合判定」行を検出できない")
    add("")

    add("### 完成の定義（機械判定）")
    add("")
    if dod_error:
        add(f"- 導出不能（{dod_error}）")
    elif not dod_items:
        add(f"- {DOD_PATH} に機械判定テーブルの有効行が見つからない")
    else:
        add("| ID | 項目 | 種別 | 判定 | 詳細 |")
        add("|---|---|---|---|---|")
        for item in dod_items:
            add(
                f"| {item.id} | {item.description} | {item.kind} "
                f"| {item.verdict} | {item.detail} |"
            )
        ng = [i.id for i in dod_items if i.verdict == "NG"]
        unknown = [i.id for i in dod_items if i.verdict == "判定不能"]
        add("")
        add(
            f"- 集計: OK {sum(1 for i in dod_items if i.verdict == 'OK')} "
            f"/ NG {len(ng)} / 判定不能 {len(unknown)}"
        )
        if ng:
            add(f"- NG: {', '.join(ng)}")
        if unknown:
            add(f"- 判定不能: {', '.join(unknown)}")
    add("")

    add("### 人判定の残チェックリスト")
    add("")
    if dod_error:
        add("- 導出不能（完成の定義を読めない）")
    elif not dod_checklist:
        add("- 人判定節にチェックリスト項目が無い")
    else:
        for checked, label in dod_checklist:
            add(f"- [{'x' if checked else ' '}] {label}")
    add("")

    # --- 次の一手 ---
    add("## 次の一手（提案）")
    add("")
    if actions:
        for action in actions:
            add(f"- {action}")
    else:
        add("- 提案なし（状態から次の工程を特定できない。成果物を確認して手動で選ぶ）")
    add("")
    add("> dev-pipeline は読み取り専用。工程スキルの起動はユーザーが行う。")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# エントリポイント
# ---------------------------------------------------------------------------


def build_report(root: Path, target: str) -> str:
    """対象を指定したときのレポート本文を組み立てる。"""
    decl = load_declaration(root, target)
    artifacts = scan_artifacts(root, target, decl)
    reviews = scan_reviews(root, target)
    git = collect_git_state(root)

    phase, phase_name, reasons = derive_phase(root, target, artifacts, reviews, decl, git)
    actions = next_actions(phase, target, artifacts, reviews, decl, root)

    dod_items: list[DodItem] = []
    dod_checklist: list[tuple[bool, str]] = []
    dod_error: str | None = None
    dod_path = root / DOD_PATH
    if dod_path.is_file():
        text = read_text(dod_path)
        if not text:
            dod_error = f"{DOD_PATH} を読めない"
        else:
            dod_items, dod_checklist = parse_dod(text)
            judge_dod_items(dod_items, root, target, git)
    else:
        dod_error = f"{DOD_PATH} が無い（`/def-done` で作成できる）"

    summary_verdict = None
    summary_path = artifacts.get("test-summary-report")
    if summary_path is not None:
        summary_verdict = extract_summary_verdict(read_text(summary_path))

    return render_report(
        root=root,
        target=target,
        decl=decl,
        artifacts=artifacts,
        reviews=reviews,
        git=git,
        phase=phase,
        phase_name=phase_name,
        reasons=reasons,
        actions=actions,
        dod_items=dod_items,
        dod_checklist=dod_checklist,
        dod_error=dod_error,
        summary_verdict=summary_verdict,
    )


def resolve_root(explicit: str | None) -> Path:
    """リポジトリルートを決める。git で解決できなければ cwd（fail-open）。"""
    base = Path(explicit).expanduser() if explicit else Path.cwd()
    base = base.resolve()
    code, out, _ = run(["git", "rev-parse", "--show-toplevel"], base)
    if code == 0 and out.strip():
        return Path(out.strip())
    return base


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="dev-pipeline の現在フェーズ・ゲート・マージ判定材料を導出する（読み取り専用）"
    )
    parser.add_argument("target", nargs="?", help="対象名（省略時は対象一覧モード）")
    parser.add_argument(
        "-C",
        dest="root",
        default=None,
        help="リポジトリルート（既定: cwd から git で解決）",
    )
    args = parser.parse_args(argv)

    root = resolve_root(args.root)

    if not args.target:
        sys.stdout.write(render_target_list(root, list_targets(root)))
        return 0

    found = list_targets(root)
    if args.target not in found and not (root / DEV_DIR / args.target).exists():
        sys.stdout.write(
            f"# dev-pipeline: {args.target}\n\n"
            f"対象 `{args.target}` の作業ディレクトリが見つからない"
            f"（{DEV_DIR}/{args.target}/ も {TEST_DIR}/{args.target}/ も無い）。\n\n"
        )
        sys.stdout.write(render_target_list(root, found))
        return 0

    sys.stdout.write(build_report(root, args.target))
    return 0


if __name__ == "__main__":
    sys.exit(main())
