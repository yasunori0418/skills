"""plan_orchestration.py（job-graph 版）のユニットテスト。

純粋関数（parse_spec / analyze / compute_lanes / render）を入出力で検証する。
ワーカー規約の文言は lane-ops（worker_contract.py）側のテストで担保するため、
ここでは連結の統合（full_prompt が規約ヘッダを含むこと）だけを見る。
herdr/wt の実行はしない。
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


def test_boundary_auto_adds_tmp_claude():
    plan = spec([task("A", boundary=["src/**"]), task("B")])
    assert "tmp_claude/**" in plan.tasks[0].boundary
    assert "src/**" in plan.tasks[0].boundary
    # 未宣言の task には足さない（境界ファイル自体を生成しない従来動作の維持）
    assert plan.tasks[1].boundary == ()


def test_boundary_auto_add_is_idempotent():
    plan = spec([task("A", boundary=["src/**", "tmp_claude/**"])])
    assert plan.tasks[0].boundary.count("tmp_claude/**") == 1


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
    lanes, lane_of = lanes_of([task("A"), task("B", deps=["A"]), task("C", deps=["A"])])
    assert lanes == (("A",), ("B",), ("C",))
    assert lane_of["B"] != lane_of["A"]
    assert lane_of["C"] != lane_of["A"]


# ------------------------------------------------------------
# boundary_json
# ------------------------------------------------------------


def test_boundary_json_single_line_contract():
    plan = spec([task("B2", branch="feat-b2", boundary=["src/x/**"])])
    t = plan.tasks[0]
    data = json.loads(po.boundary_json(t))
    assert data["task_id"] == "B2"
    assert data["branch"] == "feat-b2"
    assert "src/x/**" in data["allow"] and "tmp_claude/**" in data["allow"]
    assert "\n" not in po.boundary_json(t)


# ------------------------------------------------------------
# lane-ops 連携（統合）
# ------------------------------------------------------------


def test_full_prompt_appends_lane_ops_contract():
    plan = spec([task("A")])
    t = plan.tasks[0]
    out = po.full_prompt(t, "main", "main", po.Launch(parent_name="orc"))
    assert out.startswith("task A")
    assert "## 制約（lane-ops ワーカー規約）" in out
    assert "report.sh orc A" in out


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
    # wave 0 の独立タスクにも必ず --base を明示する
    out = rendered([task("A")], default_base="develop")
    assert "--create br-A --base develop" in out


def test_render_workspace_for_lane_start_and_tab_for_next_stage():
    out = rendered([task("A"), task("B", deps=["A"])])
    assert "herdr workspace create" in out
    assert "herdr tab create --workspace" in out
    assert ".result.workspace.workspace_id" in out
    assert ".result.root_pane.pane_id" in out


def test_render_stacked_gate_is_pr_creation():
    out = rendered([task("A"), task("B", deps=["A"])])
    assert "PR 作成を確認してから起動" in out
    assert "gh pr list --head br-A" in out


def test_render_launch_uses_wt_and_prompt_file():
    out = rendered([task("A")])
    assert "wt switch --create br-A --base main -x claude --" in out
    assert "$(cat /tmp/jg-prompts/A.md)" in out


def test_render_no_claude_name_flag():
    # 報告は lane-ops（herdr agent prompt）経由なので --name は付けない
    out = rendered([task("A")])
    assert "--name" not in out


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


def test_render_monitor_section_points_to_lane_ops():
    out = rendered([task("A")])
    assert "watch_events.py" in out
    assert "verify_lane.sh" in out
    assert "[lane-ops:report" in out


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
    assert "task A" in a and "lane-ops ワーカー規約" in a
    assert "gh issue view 7" in b
    assert "report.sh orc" in a


def test_main_exit_1_on_cycle(tmp_path):
    spec_file = tmp_path / "spec.json"
    spec_file.write_text(json.dumps({
        "tasks": [task("A", deps=["B"]), task("B", deps=["A"])],
    }), encoding="utf-8")
    rc = po.main(["plan_orchestration.py", str(spec_file), "--prompt-dir", str(tmp_path / "p")])
    assert rc == 1
    assert not (tmp_path / "p").exists()
