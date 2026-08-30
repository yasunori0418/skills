"""worker_contract.py のユニットテスト。parse_task / render の純粋な入出力を検証する。"""
from __future__ import annotations

import pytest

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
    return wc.parse_task(base)


# ------------------------------------------------------------
# parse_task
# ------------------------------------------------------------


def test_parse_task_defaults():
    assert wc.parse_task({}) == wc.TaskInfo()
    assert wc.TaskInfo().base == "main" and wc.TaskInfo().default_base == "main"


def test_parse_task_normalizes_values():
    info = wc.parse_task(
        {"task_id": " T1 ", "branch": "b", "base": "", "boundary": ["src/**", " ", "t/**"],
         "issue": 7, "parent": None}
    )
    assert info == wc.TaskInfo(
        task_id="T1", branch="b", base="main", boundary=("src/**", "t/**"), issue=7, parent=""
    )


def test_parse_task_rejects_bad_types():
    with pytest.raises(wc.ContractError):
        wc.parse_task([])
    with pytest.raises(wc.ContractError):
        wc.parse_task({"issue": "7"})
    with pytest.raises(wc.ContractError):
        wc.parse_task({"issue": -1})
    with pytest.raises(wc.ContractError):
        wc.parse_task({"boundary": "src/**"})
    with pytest.raises(wc.ContractError):
        wc.parse_task({"branch": 1})


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


def test_subagent_liveness_management():
    s = wc.render(task())
    assert "サブエージェントの生存管理" in s
    assert "TaskStop" in s
    assert "10 分" in s
    assert "2 回" in s
    assert s.index("サブエージェント委任") < s.index("サブエージェントの生存管理")


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
    assert wc.MILESTONES in s
    assert "報告は承認の代わりにならない" in s


def test_report_before_textual_approval_wait():
    s = wc.render(task())
    assert "親の承認・裁定待ちで停止する直前（ダイアログ以外の承認待ちを含む）" in s
    assert "テキストで承認を問うてターンを終える場合も、その直前に必ず報告する" in s


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


# ------------------------------------------------------------
# plan / scope_check（job-graph の計画突合）
# ------------------------------------------------------------


def test_parse_task_plan_and_scope_check_default_empty():
    info = wc.parse_task({})
    assert info.plan == "" and info.scope_check == ""
    with pytest.raises(wc.ContractError):
        wc.parse_task({"plan": ["/p"]})


def test_plan_clause_rendered_after_scope_with_ground_truth():
    s = wc.render(task(plan="/abs/plan.md"))
    assert "計画の参照" in s
    assert "DIFF_REVIEW_GROUND_TRUTH=/abs/plan.md" in s
    assert "候補の採否を親へ問い合わせない" in s
    assert s.index("編集してよい範囲") < s.index("計画の参照") < s.index("TDD 順序")


def test_scope_check_clause_between_pr_gate_and_iteration_bounds():
    cmd = "python3 /x/check_scope.py --base main --expected-file a.py"
    s = wc.render(task(scope_check=cmd))
    assert "計画との突合（PR 作成前）" in s
    assert f"`{cmd}`" in s
    assert "VERDICT: FAIL" in s
    assert "何を削る・分離するかを自分で判断しない" in s
    assert (
        s.index("PR 作成前ゲート")
        < s.index("計画との突合（PR 作成前）")
        < s.index("review-converge の反復境界")
    )


def test_plan_and_scope_check_omitted_when_empty():
    s = wc.render(task())
    assert "計画の参照" not in s
    assert "計画との突合" not in s
    assert "DIFF_REVIEW_GROUND_TRUTH" not in s


# ------------------------------------------------------------
# mode（implement / maintain）
# ------------------------------------------------------------


def test_parse_task_mode_defaults_to_implement():
    assert wc.parse_task({}).mode == "implement"
    assert wc.parse_task({"mode": " maintain "}).mode == "maintain"
    assert wc.parse_task({"mode": ""}).mode == "implement"


def test_parse_task_rejects_unknown_mode():
    with pytest.raises(wc.ContractError):
        wc.parse_task({"mode": "maintainance"})
    with pytest.raises(wc.ContractError):
        wc.parse_task({"mode": "MAINTAIN"})
    with pytest.raises(wc.ContractError):
        wc.parse_task({"mode": 1})


def maintain_task(**kw):
    return task(mode="maintain", plan="/abs/plan.md", scope_check="python3 /x/check_scope.py", **kw)


def test_maintain_drops_implement_only_clauses():
    s = wc.render(maintain_task())
    assert "PR 作成前ゲート" not in s
    assert "review-converge の反復境界" not in s
    assert "PR 作成後の凍結" not in s
    assert "計画との突合" not in s


def test_maintain_ignores_plan_and_scope_check_clauses():
    s = wc.render(maintain_task())
    assert "check_scope.py" not in s
    assert "VERDICT: FAIL" not in s
    assert "DIFF_REVIEW_GROUND_TRUTH" not in s


def test_maintain_states_pr_already_exists():
    s = wc.render(task(mode="maintain"))
    assert "PR の状態" in s
    assert "既に作成済み" in s
    assert "実装変更はレビュー指摘への対応に限る" in s


def test_maintain_limits_targets_to_review_findings():
    s = wc.render(task(mode="maintain"))
    assert "対応対象の限定" in s
    assert "対応対象はレビュー指摘・親の指示に限る" in s
    assert "自分で追加の指摘を探しに行かない" in s


def test_maintain_push_requires_parent_approval():
    s = wc.render(task(mode="maintain"))
    assert "push・force-push は親の承認を得てから実行する" in s
    assert "計画承認済み扱いにしない" in s
    assert "push 前に報告コマンドで「push 承認待ち」を報告し、親の応答を待ってから実行する" in s
    assert "個別の確認へ回さず実行する" not in s


def test_maintain_forbids_converge_and_pr_create_with_reason():
    s = wc.render(task(mode="maintain"))
    assert "`/review-converge`・`/pr-create` は実行しない" in s
    assert "PR は既に存在し、修正は既存 PR のブランチへの追加コミットとして反映される" in s


def test_maintain_tdd_clause_allows_trivial_fixes_without_tests():
    s = wc.render(task(mode="maintain"))
    assert "振る舞いが変わる修正はテストを先に書く" in s
    assert "typo・コメント・ドキュメントのみの修正はテスト不要" in s
    assert "テストを先に実装し（失敗を確認）" not in s


def test_maintain_structural_escalation_scoped_to_findings():
    s = wc.render(task(mode="maintain"))
    assert "構造変更エスカレーション" in s
    assert "指摘の範囲を超える既存コードの構造変更" in s
    assert "計画に無い既存コードの構造変更" not in s


def test_maintain_milestones_replace_converge_and_pr():
    s = wc.render(task(mode="maintain"))
    assert wc.MILESTONES_MAINTAIN in s
    assert "最初のコミット完了 / push 承認待ち / push 完了 / 作業のブロック・境界の不足" in s
    assert "review-converge 収束" not in s
    assert "PR 作成（番号付き）" not in s


def test_maintain_scope_clause_drops_review_converge_precedence():
    s = wc.render(task(mode="maintain"))
    assert "依頼されたスコープで納品する" in s
    assert "スコープ規約は review-converge の指摘にも優先して適用される" not in s


def test_maintain_keeps_common_clauses():
    s = wc.render(task(mode="maintain", boundary=["src/**"], issue=42))
    assert "編集してよい範囲（境界）" in s
    assert "境界の拡張は親だけが行える" in s
    assert "コミット粒度" in s
    assert "サブエージェント委任" in s
    assert "サブエージェントの生存管理" in s
    assert "進捗ナレーション" in s
    assert "報告: 次のマイルストーンごとに" in s
    assert "gh issue view 42" in s
