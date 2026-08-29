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


def test_parse_spec_expected_fields():
    plan = spec([task("A", expected_files=["src/a.py", " ", "tests/test_a.py"], expected_scale=40)])
    assert plan.tasks[0] == po.Task(
        id="A", branch="br-A", depends_on=(), prompt="task A",
        expected_files=("src/a.py", "tests/test_a.py"), expected_scale=40,
    )
    assert spec([task("A")]).tasks[0].expected_files == ()
    assert spec([task("A")]).tasks[0].expected_scale == 0


def test_parse_spec_rejects_bad_expected_fields():
    with pytest.raises(po.SpecError):
        spec([task("A", expected_files="src/a.py")])
    with pytest.raises(po.SpecError):
        spec([task("A", expected_scale="40")])
    with pytest.raises(po.SpecError):
        spec([task("A", expected_scale=-1)])


def test_parse_spec_plan_absolutized(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    plan = po.parse_spec({"plan": "docs/plan.md", "tasks": [task("A")]})
    assert plan.plan == str(tmp_path / "docs" / "plan.md")
    assert po.parse_spec({"tasks": [task("A")]}).plan == ""
    with pytest.raises(po.SpecError):
        po.parse_spec({"plan": 1, "tasks": [task("A")]})


def test_check_plan_file_reports_missing(tmp_path):
    missing = po.Plan(default_base="main", tasks=(), plan=str(tmp_path / "no.md"))
    assert po.check_plan_file(missing) == [f"plan が存在しない: {tmp_path / 'no.md'}（相対パスは cwd 基準で絶対化される）"]
    exists = tmp_path / "plan.md"
    exists.write_text("x", encoding="utf-8")
    assert po.check_plan_file(po.Plan(default_base="main", tasks=(), plan=str(exists))) == []
    assert po.check_plan_file(po.Plan(default_base="main", tasks=())) == []


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


def test_analyze_warns_missing_expected_files():
    an = po.analyze(spec([task("A"), task("B", expected_files=["b.py"])]))
    assert an.errors == []
    hits = [w for w in an.warnings if "expected_files が無い" in w]
    assert len(hits) == 1 and "task A" in hits[0] and "縮退" in hits[0]


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
    out = po.full_prompt(t, "main", plan, po.Launch(parent_name="orc"))
    assert out.startswith("task A")
    assert "## 制約（lane-ops ワーカー規約）" in out
    assert "report.sh orc A" in out


def test_scope_check_command_is_base_form_with_expectations():
    plan = spec([task("A", expected_files=["src/a b.py", "tests/t.py"], expected_scale=30)])
    cmd = po.scope_check_command(plan.tasks[0], "feat-x")
    assert cmd.startswith(f"python3 {po.CHECK_SCOPE} --base feat-x")
    assert "--expected-file 'src/a b.py' --expected-file tests/t.py --expected-scale 30" in cmd
    bare = po.scope_check_command(spec([task("B")]).tasks[0], "main")
    assert bare == f"python3 {po.CHECK_SCOPE} --base main"


def test_contract_payload_to_json_carries_plan_and_scope_check():
    plan = po.Plan(default_base="main", tasks=(), plan="/abs/plan.md")
    t = spec([task("A", expected_files=["a.py"], boundary=["src/**"], issue=3)]).tasks[0]
    payload = po.contract_payload(t, "main", plan, po.Launch(parent_name="orc"))
    assert payload == po.ContractPayload(
        task_id="A", branch="br-A", base="main", default_base="main",
        boundary=("src/**", "tmp_claude/**"), issue=3, parent="orc", plan="/abs/plan.md",
        scope_check=po.scope_check_command(t, "main"),
    )
    data = json.loads(payload.to_json())
    assert data["plan"] == "/abs/plan.md"
    assert data["scope_check"].endswith("--expected-file a.py")
    assert data["boundary"] == ["src/**", "tmp_claude/**"]


def test_full_prompt_embeds_scope_check_and_plan():
    plan = po.Plan(default_base="main", tasks=(), plan="/abs/plan.md")
    t = spec([task("A", expected_files=["a.py"], expected_scale=10)]).tasks[0]
    out = po.full_prompt(t, "main", plan, po.Launch(parent_name="orc"))
    assert "check_scope.py --base main --expected-file a.py --expected-scale 10" in out
    assert "DIFF_REVIEW_GROUND_TRUTH=/abs/plan.md" in out


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
    assert "HSESSION" not in out


def test_render_all_herdr_calls_pin_session():
    # herdr 呼び出しは env の暗黙解決に頼らず、必ず --session を明示する
    # （COMMANDS が env の無い別 shell へコピペされても既定 session へ落ちないこと）。
    out = rendered([task("A"), task("B", deps=["A"]), task("C")])
    assert 'HSESSION="${HERDR_SESSION:-default}"' in out
    bare = [
        line
        for line in out.splitlines()
        if "herdr " in line
        and not line.lstrip().startswith("#")
        and 'herdr --session "$HSESSION"' not in line
    ]
    assert bare == []


def test_render_base_always_explicit():
    # wave 0 の独立タスクにも必ず --base を明示する
    out = rendered([task("A")], default_base="develop")
    assert "--create br-A --base develop" in out


def test_render_lane_head_creates_workspace_and_stacked_adds_tab():
    out = rendered([task("A"), task("B", deps=["A"]), task("C")])
    # レーン先頭（A・C）は workspace create、stacked の後続段（B）は
    # レーンの workspace への tab create
    assert out.count('herdr --session "$HSESSION" workspace create') == 2
    assert out.count('herdr --session "$HSESSION" tab create --workspace "$WS_LANE_0"') == 1
    assert "$HERDR_WORKSPACE_ID" not in out
    # 後続段の workspace ID はレーン先頭のラベルから再解決する
    assert (
        'herdr --session "$HSESSION" workspace list | jq -r'
        " '.result.workspaces[] | select(.label == \"br-A\")" in out
    )
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


def test_render_strips_parent_session_markers():
    # 各レーンは独立したセッションなので、親セッション固有のマーカーを wt より前で
    # 断ち切る（放置するとレーンが親の子と誤認され transcript 保存が切られる）。
    # 境界あり（-x bash bootstrap）・境界なし（-x claude）の両経路が対象。
    out = rendered([task("A"), task("B", boundary=["pkg/**"])])
    launches = [ln for ln in out.splitlines() if "pane run" in ln]
    assert len(launches) == 2
    for ln in launches:
        # env -u は wt より前に置く（wt 自身にもその子の claude にも渡らないように）。
        assert "env -u CLAUDE_CODE_CHILD_SESSION" in ln
        assert ln.index("env -u CLAUDE_CODE_CHILD_SESSION") < ln.index("wt switch")
    for var in po.INHERITED_SESSION_VARS:
        assert all(f"-u {var}" in ln for ln in launches)
    # ユーザー設定・実行ファイル解決に使うものは落とさない。
    assert "CLAUDE_CODE_EXECPATH" not in out
    # COMMANDS をコピペした shell の環境は壊さない（unset は使わない）。
    assert "unset CLAUDE_CODE" not in out


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


def test_render_verify_section_lists_pr_form_per_task():
    out = rendered([task("A", expected_files=["a.py"], expected_scale=5), task("B", deps=["A"])])
    verify = out.split("=== VERIFY")[1].split("=== MONITOR")[0]
    assert "scope-gate.md" in verify
    assert "FAIL なら次段を起動せず" in verify
    assert f"python3 {po.CHECK_SCOPE} --pr <A の PR 番号> --expected-file a.py --expected-scale 5" in verify
    assert f"python3 {po.CHECK_SCOPE} --pr <B の PR 番号>" in verify
    assert out.index("=== PR") < out.index("=== VERIFY") < out.index("=== MONITOR")


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


def test_main_exit_1_on_missing_plan(tmp_path):
    spec_file = tmp_path / "spec.json"
    spec_file.write_text(json.dumps({
        "plan": str(tmp_path / "missing.md"),
        "tasks": [task("A")],
    }), encoding="utf-8")
    rc = po.main(["plan_orchestration.py", str(spec_file), "--prompt-dir", str(tmp_path / "p")])
    assert rc == 1
    assert not (tmp_path / "p").exists()


def test_main_exit_1_on_cycle(tmp_path):
    spec_file = tmp_path / "spec.json"
    spec_file.write_text(json.dumps({
        "tasks": [task("A", deps=["B"]), task("B", deps=["A"])],
    }), encoding="utf-8")
    rc = po.main(["plan_orchestration.py", str(spec_file), "--prompt-dir", str(tmp_path / "p")])
    assert rc == 1
    assert not (tmp_path / "p").exists()
