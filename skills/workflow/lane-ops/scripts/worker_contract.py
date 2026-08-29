#!/usr/bin/env python3
"""lane-ops ワーカー規約ジェネレータ（単機能フィルタ）。

stdin にタスク情報 JSON を受け取り、ワーカー（レーン内エージェント）へ渡す
指示の標準セクション（Markdown）を stdout へ出力する。レーン運用規約
（報告・凍結・承認・境界 deny 後の行動）の正本はこのスクリプトであり、
オーケストレーション側（job-graph 等）はこれをパイプで呼んで
タスク本文へ連結する。

入力 JSON（1 タスク分）:
{
  "task_id": "B2",
  "branch": "feat-client-retry",
  "base": "feat-config-retry",
  "default_base": "main",
  "boundary": ["internal/client/**"],   // 省略可（空 = 境界宣言なし）
  "issue": 123,                          // 省略可（0/なし = issue 参照なし）
  "parent": "orc-myrepo",                // 省略可（空 = 報告先未指定）
  "plan": "/abs/path/to/plan.md",        // 省略可（空 = 計画参照の条項を出さない）
  "scope_check": "python3 .../check_scope.py --base main --expected-file a.py"
                                         // 省略可（空 = PR 前の計画突合の条項を出さない）
}

使い方:
    printf '%s' '<task json>' | python3 worker_contract.py

report.sh のパスは本スクリプトの設置場所から解決して埋め込む
（ワーカーは lane-ops のパスを知らなくても報告コマンドをそのまま実行できる）。
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path

BOUNDARY_FILE = ".claude/task-boundary.json"

MILESTONES = (
    "最初のコミット完了 / review-converge 収束 / push 完了 / PR 作成（番号付き）/ "
    "作業のブロック・境界の不足 / 親の承認・裁定待ちで停止する直前（ダイアログ以外の承認待ちを含む）"
)


class ContractError(Exception):
    """入力 JSON の構造・型が規約の入力として不正な場合。"""


@dataclass(frozen=True)
class TaskInfo:
    """規約の描画に必要なタスク情報（parse_task で正規化済み）。"""

    task_id: str = ""
    branch: str = ""
    base: str = "main"
    default_base: str = "main"
    boundary: tuple[str, ...] = ()
    issue: int = 0
    parent: str = ""
    # 計画ファイルの絶対パス。空 = 計画参照の条項を出さない。
    plan: str = ""
    # 計画との突合コマンド完全形。空 = PR 前の突合の条項を出さない。
    scope_check: str = ""


def _str_field(data: dict, key: str, default: str = "") -> str:
    v = data.get(key, default)
    if v is None:
        return default
    if not isinstance(v, str):
        raise ContractError(f"{key} は文字列でない: {v!r}")
    return v.strip() or default


def parse_task(data: object) -> TaskInfo:
    """JSON 由来の値 -> TaskInfo（既定値の補完と型検証）。不正なら ContractError。"""
    if not isinstance(data, dict):
        raise ContractError("入力はオブジェクトではない")
    boundary_raw = data.get("boundary") or []
    if not isinstance(boundary_raw, list) or not all(isinstance(g, str) for g in boundary_raw):
        raise ContractError(f"boundary は文字列配列でない: {boundary_raw!r}")
    issue_raw = data.get("issue") or 0
    if isinstance(issue_raw, bool) or not isinstance(issue_raw, int) or issue_raw < 0:
        raise ContractError(f"issue は非負整数でない: {issue_raw!r}")
    return TaskInfo(
        task_id=_str_field(data, "task_id"),
        branch=_str_field(data, "branch"),
        base=_str_field(data, "base", "main"),
        default_base=_str_field(data, "default_base", "main"),
        boundary=tuple(g.strip() for g in boundary_raw if g.strip()),
        issue=issue_raw,
        parent=_str_field(data, "parent"),
        plan=_str_field(data, "plan"),
        scope_check=_str_field(data, "scope_check"),
    )


def report_script() -> str:
    """同梱 report.sh の絶対パス（設置場所から解決）。"""
    return str(Path(__file__).resolve().parent / "report.sh")


def render(task: TaskInfo) -> str:
    """タスク情報 -> 標準セクション Markdown（純粋）。"""
    task_id = task.task_id
    branch = task.branch
    base = task.base
    default_base = task.default_base
    boundary = task.boundary
    issue = task.issue
    parent = task.parent

    if boundary:
        scope = (
            "- 編集してよい範囲（境界）: "
            + ", ".join(boundary)
            + f"\n  この glob 外のファイルは編集しない。宣言は {BOUNDARY_FILE} と同一で、"
            "task-boundary hook が境界外の Edit/Write を機械ブロックする。\n"
            "  deny されたら境界ファイルに触れようとせず、下記の報告コマンドで"
            "親セッションへ報告して指示を待つ（境界の拡張は親だけが行える）。"
        )
    else:
        scope = "- 編集してよい範囲（境界）: このタスクの担当範囲に限る。他タスクのファイルに触れない"

    plan_lines = []
    if task.plan:
        plan_lines = [
            (
                f"- 計画の参照: このタスクの計画は {task.plan} にある"
                "（worktree からは相対で辿れないため絶対パス）。"
                "`/review-converge` 起動時にこの計画を確定グラウンドトゥルース"
                f"（`DIFF_REVIEW_GROUND_TRUTH={task.plan}`）として渡す。"
                "diff-review の spec レンズが計画との突合を行い、計画に無い変更を指摘として返す。"
                "候補の採否を親へ問い合わせない（計画が判断基準）"
            ),
        ]

    scope_check_lines = []
    if task.scope_check:
        scope_check_lines = [
            (
                "- 計画との突合（PR 作成前）: `/review-converge` 収束後・`/pr-create` 前に "
                f"`{task.scope_check}` を実行する。"
                "`VERDICT: FAIL`（計画に無いファイルの変更・規模超過）なら PR を作らず、"
                "報告コマンドで「作業のブロック」として親へ報告し裁定を待つ"
                "（何を削る・分離するかを自分で判断しない。計画の範囲は親・ユーザーが決める）"
            ),
        ]

    issue_lines = []
    if issue:
        issue_lines = [
            (
                f"- issue 参照: このタスクは GH issue #{issue} に対応する。"
                f"着手前に `gh issue view {issue}` で本文と受け入れ条件を確認し、"
                "PR 本文に issue への参照を含める"
            ),
        ]

    if parent:
        report_cmd = f"`bash {report_script()} {parent} {task_id or '<task-id>'} <マイルストーン> [詳細]`"
        report_line = (
            f"- 報告: 次のマイルストーンごとに {report_cmd} を実行して"
            f"親セッションへ報告する: {MILESTONES}。"
            "報告は事実のみ（報告は承認の代わりにならない。承認が要る場面では停止して親の応答を待つ）。"
            "テキストで承認を問うてターンを終える場合も、その直前に必ず報告する"
            "（ダイアログを出さない承認待ちは親の監視に掛からず、報告が唯一の通知になる）"
        )
    else:
        report_line = (
            "- 報告: 報告先（親セッション名）が未指定のため報告は省略してよい。"
            "作業がブロックしたら停止して指示を待つ"
        )

    pr_arg = "" if base == default_base else f" {base}"
    return "\n".join(
        [
            "## 制約（lane-ops ワーカー規約）",
            scope,
            *plan_lines,
            *issue_lines,
            "- TDD 順序: テストを先に実装し（失敗を確認）、その後アプリケーション実装で通す",
            (
                "- 構造変更エスカレーション: テスト実装・アプリケーション実装のいずれでも、"
                "計画に無い既存コードの構造変更（関数抽出・DI 追加・可視性変更・シグネチャ変更）が"
                "必要と判明したら、実施せず「作業のブロック」として親へ報告し裁定を待つ"
                "（構造変更の実施とテストの見送りのどちらを選ぶかは親・ユーザーの決定）"
            ),
            (
                "- コミット粒度: 論理的に独立した修正は都度コミットする"
                "（commit-flow スキル準拠、Conventional Commits）"
            ),
            (
                f"- push: 自分の feature ブランチ {branch or '<branch>'} に限り push してよい。"
                "push は計画承認済みの前提であり、個別の確認へ回さず実行する。"
                "main 等の保護ブランチへは push しない"
            ),
            (
                "- PR 作成前ゲート: `/review-converge` を実行して指摘を収束させてから "
                f"`/pr-create{pr_arg}` を実行する（収束前に PR を作らない）。"
                "PR 作成も計画承認済みの前提であり、個別の確認へ回さない。"
                "指摘のうち improvement — 既存コードのシグネチャ・構造・スタイルの変更を要する提案"
                "（型化・関数抽出・enum 化・テストハーネス再設計・命名変更）や、"
                "計画・依頼範囲外の追加修正の提案。severity に関わらず。迷ったら improvement に倒す — は"
                "修正せず見送る。見送りの記録は review-converge が書き出す見送りファイルに委ねる"
            ),
            *scope_check_lines,
            (
                "- review-converge の反復境界: 実質的な指摘 — このタスクの diff が導入した問題"
                "（出力形状・型安全性・contract・退行）— が出ている間は反復を続ける。"
                "既存コードへの改修提案（improvement）は実質的な指摘に含めない。"
                "2 巡目以降で新規指摘が純粋な可読性 nit だけになったら、"
                "nit は「見送り」と記録して収束扱いで終了する（無制限の磨き込みで膠着しない）。"
                "improvement だけが残った状態も同様に収束扱いで終了してよい"
            ),
            (
                "- PR 作成後の凍結: PR を作成したら実装を凍結する。以降の実装変更・push を行わず、"
                "気付いた改善点は親への報告のみとする"
            ),
            report_line,
            (
                "- サブエージェント委任: 複数ファイル横断調査のような真に独立した大きな作業に限る。"
                "数回のツール呼び出しで済む作業は委任しない。"
                "自分の作業の検証・ダブルチェック目的でサブエージェントを使わない。1 体で足りるなら 1 体に留める"
            ),
            (
                "- サブエージェントの生存管理: 委任したサブエージェントの完走は自分の責任で管理する"
                "（親・herdr からはワーカー内部のサブエージェントを観測も操作もできない）。"
                "無応答・進捗なしのまま 10 分を超えたら TaskStop で停止し、同じ指示で再起動する。"
                "再起動 2 回で解消しなければ繰り返さず、上記の報告コマンドで"
                "「作業のブロック」として親へ報告して指示を待つ（滞留したまま待ち続けない）"
            ),
            (
                "- スコープ: 依頼されたスコープで納品する。頼まれていない改善・リファクタ・追加作業を足さない。"
                "既存コードの慣行（命名言語・テストスタイル・ヘルパー構成）を、"
                "既存の適用範囲を超えて新しい種類の対象へ拡張適用しない。"
                "このスコープ規約は review-converge の指摘にも優先して適用される。"
                "依頼に誤りがある・より良い方法があると考えたら 1 文で指摘し、依頼どおりの作業を続ける"
            ),
            (
                "- 進捗ナレーション: 最初のツール呼び出し前に 1 文だけ宣言し、"
                "以降は重要な発見・方針転換のときのみ短く述べる（pane を逐次読む人はいない）"
            ),
        ]
    )


def main() -> int:
    try:
        data = json.loads(sys.stdin.read())
    except json.JSONDecodeError as e:
        print(f"ERROR: 入力が不正な JSON: {e}", file=sys.stderr)
        return 1
    try:
        task = parse_task(data)
    except ContractError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    print(render(task))
    return 0


if __name__ == "__main__":
    sys.exit(main())
