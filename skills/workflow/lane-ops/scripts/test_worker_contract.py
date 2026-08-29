"""worker_contract.py のユニットテスト。render の純粋な入出力を検証する。"""
from __future__ import annotations

import worker_contract as wc


def task(**kw):
    base = {
        "task_id": "A",
        "branch": "feat-a",
        "base": "main",
        "default_base": "main",
        "parent": "orc",
    }
    base.update(kw)
    return base


def test_header_is_lane_ops_contract():
    s = wc.render(task())
    assert "## 制約（lane-ops ワーカー規約）" in s


def test_freeze_after_pr():
    s = wc.render(task())
    assert "PR 作成後の凍結" in s
    assert "実装を凍結" in s


def test_review_converge_bounds():
    s = wc.render(task())
    assert "review-converge の反復境界" in s
    assert "見送り" in s


def test_improvement_deferred_in_pr_gate():
    s = wc.render(task())
    assert "improvement" in s
    assert "修正せず見送る" in s
    assert "迷ったら improvement に倒す" in s
    assert "review-converge が書き出す見送りファイルに委ねる" in s


def test_iteration_bounds_limited_to_diff_introduced():
    s = wc.render(task())
    assert "このタスクの diff が導入した問題" in s
    assert "既存コードへの改修提案（improvement）は実質的な指摘に含めない" in s
    assert "improvement だけが残った状態も同様に収束扱いで終了してよい" in s


def test_scope_overrides_review_converge():
    s = wc.render(task())
    assert "スコープ規約は review-converge の指摘にも優先して適用される" in s


def test_scope_forbids_convention_overextension():
    s = wc.render(task())
    assert "既存の適用範囲を超えて新しい種類の対象へ拡張適用しない" in s


def test_structural_change_escalation_after_tdd():
    s = wc.render(task())
    assert "構造変更エスカレーション" in s
    assert "実施せず「作業のブロック」として親へ報告し裁定を待つ" in s
    assert s.index("TDD 順序") < s.index("構造変更エスカレーション")


def test_push_and_pr_preapproved():
    s = wc.render(task())
    assert "計画承認済みの前提" in s
    assert "個別の確認へ回さず実行する" in s


def test_report_command_embeds_script_path_and_parent():
    s = wc.render(task(parent="orc-repo", task_id="T1"))
    assert "report.sh orc-repo T1" in s
    assert wc.report_script() in s
    assert "報告は承認の代わりにならない" in s


def test_report_omitted_without_parent():
    s = wc.render(task(parent=""))
    assert "報告先（親セッション名）が未指定" in s
    assert "report.sh" not in s


def test_boundary_deny_behavior_points_to_parent():
    s = wc.render(task(boundary=["src/x/**", "tests/x/**"]))
    assert "src/x/**" in s and "tests/x/**" in s
    assert "deny されたら境界ファイルに触れようとせず" in s
    assert "境界の拡張は親だけが行える" in s


def test_no_boundary_falls_back():
    s = wc.render(task())
    assert "このタスクの担当範囲に限る" in s


def test_issue_reference():
    s = wc.render(task(issue=42))
    assert "gh issue view 42" in s
    assert "#42" in s


def test_no_issue_reference_when_unset():
    assert "issue 参照" not in wc.render(task())


def test_stacked_pr_base():
    s = wc.render(task(base="feat-parent"))
    assert "/pr-create feat-parent" in s


def test_default_base_pr_no_arg():
    s = wc.render(task(base="main", default_base="main"))
    assert "/pr-create`" in s
