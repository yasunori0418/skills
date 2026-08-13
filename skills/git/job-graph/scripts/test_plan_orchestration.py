"""plan_orchestration.py（job-graph 版）のユニットテスト。

純粋関数（parse_spec / analyze / compute_lanes / worker_sections / render）を
入出力で検証する。herdr/wt の実行はしない。
"""
from __future__ import annotations

import json

import pytest

import plan_orchestration as po


def spec(tasks, default_base="main"):
    return po.parse_spec({"default_base": default_base, "tasks": tasks})


def task(id, branch=None, deps=(), **kw):
    return {"id": id, "branch": branch or f"br-{id}", "depends_on": list(deps),
            "prompt": f"task {id}", **kw}


# ------------------------------------------------------------
# parse_spec
# ------------------------------------------------------------


def test_parse_spec_minimal():
    plan = spec([task("A")])
    assert plan.default_base == "main"
    assert plan.tasks[0].id == "A"
    assert plan.tasks[0].issue == 0
    assert plan.tasks[0].boundary == ()


def test_parse_spec_issue_field():
    plan = spec([task("A", issue=123)])
    assert plan.tasks[0].issue == 123


def test_parse_spec_rejects_bad_issue():
    with pytest.raises(po.SpecError):
        spec([task("A", issue="123")])
    with pytest.raises(po.SpecError):
        spec([task("A", issue=-1)])


def test_parse_spec_rejects_empty_tasks():
    with pytest.raises(po.SpecError):
        po.parse_spec({"tasks": []})


def test_parse_spec_rejects_non_dict():
    with pytest.raises(po.SpecError):
        po.parse_spec([1, 2])


# ------------------------------------------------------------
# analyze: 検証
# ------------------------------------------------------------


def test_analyze_ok():
    an = po.analyze(spec([task("A"), task("B", deps=["A"])]))
    assert an.errors == []
    assert an.levels == {"A": 0, "B": 1}
    assert an.bases == {"A": "main", "B": "br-A"}


def test_analyze_detects_cycle():
    an = po.analyze(spec([task("A", deps=["B"]), task("B", deps=["A"])]))
    assert any("循環" in e for e in an.errors)


def test_analyze_detects_undefined_dep():
    an = po.analyze(spec([task("A", deps=["X"])]))
    assert any("未定義" in e for e in an.errors)


def test_analyze_detects_duplicates():
    an = po.analyze(spec([task("A"), task("A")]))
    assert any("id が重複" in e for e in an.errors)


def test_analyze_detects_bad_permission_mode_and_effort():
    an = po.analyze(spec([task("A", permission_mode="yolo", effort="ultra")]))
    assert any("permission_mode" in e for e in an.errors)
    assert any("effort" in e for e in an.errors)


def test_analyze_warns_multi_parent():
    an = po.analyze(spec([task("A"), task("B"), task("C", deps=["A", "B"])]))
    assert an.errors == []
    assert any("複数親" in w for w in an.warnings)
    assert an.bases["C"] == "br-A"  # 先頭親を仮採用


# ------------------------------------------------------------
# compute_lanes: workspace/tab 割当
# ------------------------------------------------------------


def lanes_of(tasks):
    plan = spec(tasks)
    an = po.analyze(plan)
    assert an.errors == []
    return an.lanes, an.lane_of


def test_lanes_independent_tasks_get_own_lane():
    lanes, lane_of = lanes_of([task("A"), task("B")])
    assert lanes == (("A",), ("B",))
    assert lane_of == {"A": 0, "B": 1}


def test_lanes_serial_chain_shares_lane():
    lanes, _ = lanes_of([task("A"), task("B", deps=["A"]), task("C", deps=["B"])])
    assert lanes == (("A", "B", "C"),)


def test_lanes_branching_starts_new_lanes():
    # A の子が 2 つ → 両方とも新レーン（A のレーンは A で終わる）
    lanes, lane_of = lanes_of([task("A"), task("B", deps=["A"]), task("C", deps=["A"])])
    assert lanes == (("A",), ("B",), ("C",))
    assert lane_of["B"] != lane_of["A"]
    assert lane_of["C"] != lane_of["A"]


def test_lanes_mixed_graph():
    # A -> B -> C の直列 + 独立 D
    lanes, lane_of = lanes_of(
        [task("A"), task("B", deps=["A"]), task("C", deps=["B"]), task("D")]
    )
    assert ("A", "B", "C") in lanes
    assert ("D",) in lanes
    assert lane_of["C"] == lane_of["A"]


# ------------------------------------------------------------
# worker_sections: 標準セクション
# ------------------------------------------------------------


def sections(t=None, base="main", default_base="main", launch=None):
    t = t or po.Task(id="A", branch="feat-a", depends_on=(), prompt="p")
    return po.worker_sections(t, base, default_base, launch or po.Launch())


def test_sections_include_freeze_after_pr():
    s = sections()
    assert "PR 作成後の凍結" in s
    assert "実装を凍結" in s


def test_sections_include_review_converge_bounds():
    s = sections()
    assert "review-converge の反復境界" in s
    assert "見送り" in s


def test_sections_push_and_pr_preapproved():
    s = sections()
    assert "計画承認済みの前提" in s
    assert "個別の確認へ回さず実行する" in s


def test_sections_report_with_parent_name():
    s = sections(launch=po.Launch(parent_name="orchestrator-1"))
    assert "SendMessage" in s
    assert "`orchestrator-1`" in s
    assert "メッセージは承認の代わりにならない" in s


def test_sections_report_without_parent_name_falls_back():
    s = sections()
    assert "ListAgents" in s


def test_sections_issue_reference():
    t = po.Task(id="A", branch="feat-a", depends_on=(), prompt="p", issue=42)
    s = po.worker_sections(t, "main", "main", po.Launch())
    assert "gh issue view 42" in s
    assert "#42" in s


def test_sections_no_issue_reference_when_unset():
    assert "issue 参照" not in sections()


def test_sections_boundary_glob_matches_boundary_json():
    t = po.Task(
        id="B2", branch="feat-b2", depends_on=("B1",), prompt="p",
        boundary=("src/x/**", "tests/x/**"),
    )
    s = po.worker_sections(t, "feat-b1", "main", po.Launch())
    data = json.loads(po.boundary_json(t))
    for g in data["allow"]:
        assert g in s
    assert data == {"task_id": "B2", "branch": "feat-b2", "allow": ["src/x/**", "tests/x/**"]}
    # herdr pane へ 1 コマンドで流すため 1 行
    assert "\n" not in po.boundary_json(t)


def test_sections_stacked_pr_base():
    t = po.Task(id="B", branch="feat-b", depends_on=("A",), prompt="p")
    s = po.worker_sections(t, "feat-a", "main", po.Launch())
    assert "/pr-create feat-a" in s


# ------------------------------------------------------------
# render: コマンド生成
# ------------------------------------------------------------


def rendered(tasks, launch=None, prompt_dir="/tmp/jg-prompts", default_base="main"):
    plan = spec(tasks, default_base=default_base)
    an = po.analyze(plan)
    assert an.errors == []
    return po.render(plan, an, launch or po.Launch(), prompt_dir)


def test_render_errors_suppress_commands():
    plan = spec([task("A", deps=["A"])])
    an = po.analyze(plan)
    out = po.render(plan, an, po.Launch(), "/tmp/p")
    assert "ERROR" in out
    assert "COMMANDS" not in out


def test_render_no_prompt_dir_suppresses_commands():
    plan = spec([task("A")])
    an = po.analyze(plan)
    out = po.render(plan, an, po.Launch(), "")
    assert "--prompt-dir 未指定のため COMMANDS は出力しない" in out
    assert "herdr pane run" not in out


def test_render_base_always_explicit():
    # default_base が worktree 生成に効かない旧バグの再発防止:
    # wave 0 の独立タスクにも必ず --base を明示する
    out = rendered([task("A")], default_base="develop")
    assert "--create br-A --base develop" in out


def test_render_workspace_for_lane_start_and_tab_for_next_stage():
    out = rendered([task("A"), task("B", deps=["A"])])
    assert "herdr workspace create" in out
    assert "herdr tab create --workspace" in out
    # ID は JSON 応答から jq で掴む
    assert ".result.workspace.workspace_id" in out
    assert ".result.root_pane.pane_id" in out


def test_render_stacked_gate_is_pr_creation():
    out = rendered([task("A"), task("B", deps=["A"])])
    assert "PR 作成を確認してから起動" in out
    assert "gh pr list --head br-A" in out
    # 旧「コミット完了」ゲートの残骸が無いこと
    assert "コミット完了を wt list" not in out


def test_render_launch_uses_wt_and_prompt_file():
    out = rendered([task("A")])
    assert "wt switch --create br-A --base main -x claude --" in out
    assert "$(cat /tmp/jg-prompts/A.md)" in out


def test_render_claude_name_flag():
    out = rendered([task("A", branch="feat/foo")])
    # --name は sanitize 済みブランチ名
    assert "--name feat-foo" in out


def test_render_remote_control_optin():
    out = rendered([task("A")], launch=po.Launch(remote_control=True))
    assert "--remote-control br-A" in out
    out2 = rendered([task("A")])
    assert "--remote-control" not in out2


def test_render_model_flags_task_over_global():
    out = rendered(
        [task("A", model="sonnet"), task("B")],
        launch=po.Launch(model="opus", effort="high"),
    )
    # A は task 個別、B はグローバル既定
    a_line = next(l for l in out.splitlines() if "br-A" in l and "pane run" in l)
    b_line = next(l for l in out.splitlines() if "br-B" in l and "pane run" in l)
    assert "--model sonnet" in a_line
    assert "--model opus" in b_line
    assert "--effort high" in a_line and "--effort high" in b_line


def test_render_boundary_uses_bootstrap():
    out = rendered([task("A", boundary=["src/**"])])
    assert "-x bash --" in out
    assert "wt-boundary-A" in out
    assert "task-boundary.json" in out


def test_render_lanes_section():
    out = rendered([task("A"), task("B", deps=["A"]), task("C")])
    assert "=== LANES" in out
    assert "A -> B" in out


def test_render_monitor_section():
    out = rendered([task("A")])
    assert "agent wait" in out
    assert "--until blocked" in out
    assert "機械検証" in out


# ------------------------------------------------------------
# write_prompts / main
# ------------------------------------------------------------


def test_write_prompts_and_main(tmp_path):
    spec_file = tmp_path / "spec.json"
    spec_file.write_text(json.dumps({
        "default_base": "main",
        "tasks": [task("A"), task("B", deps=["A"], issue=7)],
    }), encoding="utf-8")
    pdir = tmp_path / "prompts"
    rc = po.main([
        "plan_orchestration.py", str(spec_file),
        "--prompt-dir", str(pdir), "--parent-name", "orc",
    ])
    assert rc == 0
    a = (pdir / "A.md").read_text(encoding="utf-8")
    b = (pdir / "B.md").read_text(encoding="utf-8")
    assert "task A" in a and "job-graph 標準セクション" in a
    assert "gh issue view 7" in b
    assert "`orc`" in a


def test_main_exit_1_on_cycle(tmp_path):
    spec_file = tmp_path / "spec.json"
    spec_file.write_text(json.dumps({
        "tasks": [task("A", deps=["B"]), task("B", deps=["A"])],
    }), encoding="utf-8")
    rc = po.main(["plan_orchestration.py", str(spec_file), "--prompt-dir", str(tmp_path / "p")])
    assert rc == 1
    # 致命的エラー時はプロンプトファイルを書かない
    assert not (tmp_path / "p").exists()
