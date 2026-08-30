"""plan_orchestration.py（job-graph 版）のユニットテスト。

純粋関数（parse_spec / analyze / compute_lanes / render）を入出力で検証する。
ワーカー規約の文言は lane-ops（worker_contract.py）側のテストで担保するため、
ここでは連結の統合（full_prompt が規約ヘッダを含むこと）だけを見る。
herdr/wt の実行はしない。
"""
from __future__ import annotations

import json
import subprocess

import pytest

import plan_orchestration as po


def spec(tasks, default_base="main", **kw):
    return po.parse_spec({"default_base": default_base, "tasks": tasks, **kw})


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


def test_parse_spec_mode_defaults_to_implement():
    # 入力 JSON は文字列のまま。parse_spec が Mode へ変換する。
    assert spec([task("A")]).mode is po.Mode.IMPLEMENT
    # 空文字・null・空白のみは拒否ではなく既定へ縮退する（plan と同じ扱い）。
    assert spec([task("A")], mode="").mode is po.Mode.IMPLEMENT
    assert spec([task("A")], mode=None).mode is po.Mode.IMPLEMENT
    assert spec([task("A")], mode="  ").mode is po.Mode.IMPLEMENT
    assert spec([task("A")], mode=" maintain ").mode is po.Mode.MAINTAIN


def test_parse_spec_accepts_maintain_mode():
    assert spec([task("A")], mode="maintain").mode is po.Mode.MAINTAIN


def test_parse_spec_rejects_unknown_mode():
    with pytest.raises(po.SpecError):
        spec([task("A")], mode="mantain")
    with pytest.raises(po.SpecError):
        spec([task("A")], mode=1)


def test_parse_spec_unknown_mode_message_lists_modes_as_strings():
    # エラーメッセージは Enum の repr ではなく従来どおりモード名の文字列で読めること。
    with pytest.raises(po.SpecError) as e:
        spec([task("A")], mode="mantain")
    assert "implement / maintain" in str(e.value)


def test_mode_values_are_the_wire_strings():
    # 入力 JSON・ContractPayload へ載る語彙（lane-ops の Mode と同じ）。
    assert po.Mode.IMPLEMENT.value == "implement"
    assert po.Mode.MAINTAIN.value == "maintain"


def test_mode_behaviour_properties():
    # mode 分岐は「軸」ごとのプロパティで肯定形に読む（呼び出し側に != / is not を残さない）。
    assert po.Mode.IMPLEMENT.checks_dependency_graph
    assert not po.Mode.MAINTAIN.checks_dependency_graph
    assert po.Mode.IMPLEMENT.lanes_follow_dependency_graph
    assert not po.Mode.MAINTAIN.lanes_follow_dependency_graph
    assert po.Mode.MAINTAIN.uses_existing_worktree
    assert not po.Mode.IMPLEMENT.uses_existing_worktree
    assert po.Mode.IMPLEMENT.runs_scope_check
    assert not po.Mode.MAINTAIN.runs_scope_check
    assert po.Mode.IMPLEMENT.creates_pull_request
    assert not po.Mode.MAINTAIN.creates_pull_request
    assert po.Mode.MAINTAIN.push_needs_parent_approval
    assert not po.Mode.IMPLEMENT.push_needs_parent_approval


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
    # implement 側の文言であること（maintain 用の文言と取り違えていない）。
    assert "計画突合（check_scope.py）はファイル照合なしに縮退する" in hits[0]
    assert "maintain では計画突合を行わない" not in hits[0]


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


def test_lanes_maintain_ignores_depends_on():
    # maintain では全 task を独立レーン扱いにする（起動順序は指摘の内容次第で
    # 決まり、前段の PR 作成というゲートは空回りする）。
    plan = spec([task("A"), task("B", deps=["A"]), task("C", deps=["B"])], mode="maintain")
    an = po.analyze(plan)
    assert an.errors == []
    assert an.levels == {"A": 0, "B": 0, "C": 0}
    assert an.lanes == (("A",), ("B",), ("C",))
    assert an.bases == {"A": "main", "B": "main", "C": "main"}
    # 突合は行わないが expected_files 欠落の WARNING は maintain でも出す。
    assert len([w for w in an.warnings if "expected_files が無い" in w]) == 3


def test_analyze_maintain_skips_depends_on_validation():
    # maintain は depends_on を無視するので、その検証も掛けない。対応不要な task を
    # spec から削ると残った task の depends_on が宙に浮くが、これは maintain では
    # エラーにならない（maintain.md §2 が「対応不要な task を削る」と指示している）。
    an = po.analyze(spec([task("B", deps=["A"])], mode="maintain"))
    assert an.errors == []
    assert an.lanes == (("B",),)
    assert an.bases == {"B": "main"}
    # 自己依存・循環・複数親も maintain では判定対象外。
    assert po.analyze(spec([task("A", deps=["A"])], mode="maintain")).errors == []
    assert po.analyze(
        spec([task("A", deps=["B"]), task("B", deps=["A"])], mode="maintain")
    ).errors == []
    multi = po.analyze(spec([task("C", deps=["A", "B"])], mode="maintain"))
    assert not any("複数親" in w for w in multi.warnings)


def test_analyze_maintain_still_warns_missing_expected_files():
    # 突合は maintain では行わないが、WARNING は両モードで出す（同じ spec を
    # implement へ戻して再利用したときに欠落へ気づけるように）。
    an = po.analyze(spec([task("A"), task("B", expected_files=["b.py"])], mode="maintain"))
    hits = [w for w in an.warnings if "expected_files が無い" in w]
    assert len(hits) == 1 and "task A" in hits[0]
    # maintain 側の文言であること（implement 用の文言と取り違えていない）。
    assert "maintain では計画突合を行わない" in hits[0]
    assert "計画突合（check_scope.py）はファイル照合なしに縮退する" not in hits[0]


def test_analyze_implement_still_validates_depends_on():
    # implement 側の検証は落とさない（退行検知）。
    assert any("未定義" in e for e in po.analyze(spec([task("B", deps=["A"])])).errors)
    assert any("自分自身" in e for e in po.analyze(spec([task("A", deps=["A"])])).errors)


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
    assert data["mode"] == "implement"


def test_contract_payload_carries_plan_mode():
    # mode は top-level（ジョブ全体の性質）なので plan から流す。
    # ContractPayload へ渡す値は文字列（lane-ops 側が受け取って Enum へ変換する契約）。
    t = spec([task("A")]).tasks[0]
    maintain = po.Plan(default_base="main", tasks=(), mode=po.Mode.MAINTAIN)
    assert po.contract_payload(t, "main", maintain, po.Launch()).mode == "maintain"
    assert json.loads(
        po.contract_payload(t, "main", maintain, po.Launch()).to_json()
    )["mode"] == "maintain"


def test_full_prompt_maintain_uses_maintain_contract():
    # lane-ops 側の maintain 規約（push 親承認・pr-create 禁止）が連結されること。
    plan = spec([task("A")], mode="maintain")
    out = po.full_prompt(plan.tasks[0], "main", plan, po.Launch(parent_name="orc"))
    assert "`/review-converge`・`/pr-create` は実行しない" in out
    assert "push 前に報告コマンドで「push 承認待ち」を報告し" in out
    assert "PR 作成後の凍結" not in out


def test_full_prompt_embeds_scope_check_and_plan():
    plan = po.Plan(default_base="main", tasks=(), plan="/abs/plan.md")
    t = spec([task("A", expected_files=["a.py"], expected_scale=10)]).tasks[0]
    out = po.full_prompt(t, "main", plan, po.Launch(parent_name="orc"))
    assert "check_scope.py --base main --expected-file a.py --expected-scale 10" in out
    assert "DIFF_REVIEW_GROUND_TRUTH=/abs/plan.md" in out


# ------------------------------------------------------------
# render: コマンド生成
# ------------------------------------------------------------


def rendered(tasks, launch=None, prompt_dir="/tmp/jg-prompts", default_base="main", **kw):
    plan = spec(tasks, default_base=default_base, **kw)
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


def test_launch_script_base_always_explicit():
    # wave 0 の独立タスクにも必ず --base を明示する
    assert "--create br-A --base develop" in launch_body([task("A")], default_base="develop")["A"]


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


def test_render_maintain_has_no_stacked_gate():
    # maintain は wave 0 のみ・全レーン同時起動。前段の PR 作成ゲートは出さない。
    out = rendered([task("A"), task("B", deps=["A"])], mode="maintain")
    assert "PR 作成を確認してから起動" not in out
    assert "後続ウェーブは依存親の『PR 作成』を確認してから起動する" not in out
    assert "maintain は depends_on を無視して全 task を wave 0 に置く" in out
    assert "wave 1" not in out
    assert out.count('herdr --session "$HSESSION" workspace create') == 2
    assert "tab create" not in out


def launch_body(tasks, launch=None, prompt_dir="/tmp/jg-prompts", default_base="main", **kw):
    """各 task の起動スクリプト本文（task id -> body）。"""
    plan = spec(tasks, default_base=default_base, **kw)
    an = po.analyze(plan)
    assert an.errors == []
    return {
        t.id: po.launch_script(t, an.bases[t.id], plan, launch or po.Launch(), prompt_dir).body
        for t in plan.tasks
    }


def test_launch_script_uses_wt_and_prompt_file():
    plan = spec([task("A")])
    script = po.launch_script(plan.tasks[0], "main", plan, po.Launch(), "/tmp/jg-prompts")
    assert script.path == "/tmp/jg-prompts/launch_A.sh"
    assert script.body.startswith("#!/usr/bin/env bash\n")
    assert "wt switch --create br-A --base main -x claude --" in script.body
    assert "$(cat /tmp/jg-prompts/A.md)" in script.body
    assert "\nexec env -u" in script.body


def test_launch_script_maintain_switches_into_existing_worktree():
    # maintain は既存 worktree（ブランチ作成済み・PR 済み）へ入る。--create を付けると
    # Path occupied で失敗するため、--create も --base も外した素の switch にする。
    # default_base を既定から変えて、base の値そのものが漏れないことまで見る
    # （既定の "main" のままだと「落ちている」のか「たまたま一致」なのか区別できない）。
    body = launch_body([task("A")], default_base="develop", mode="maintain")["A"]
    assert "wt switch br-A -x claude --" in body
    assert "--create" not in body
    assert "--base" not in body
    assert "develop" not in body


def test_launch_script_maintain_keeps_boundary_bootstrap():
    # 境界宣言ありの経路（-x bash bootstrap）でも --create / --base だけが外れる。
    body = launch_body([task("A", boundary=["src/**"])], mode="maintain")["A"]
    assert "wt switch br-A -x bash --" in body
    assert "--create" not in body
    assert "--base" not in body
    assert "wt-boundary-A" in body
    assert "task-boundary.json" in body


def test_launch_script_implement_keeps_create_and_base():
    # implement 側は従来どおり --create と解決済み base を明示する（退行検知）。
    bodies = launch_body([task("A"), task("A2", boundary=["src/**"])])
    assert "wt switch --create br-A --base main -x claude --" in bodies["A"]
    assert "wt switch --create br-A2 --base main -x bash --" in bodies["A2"]


def test_launch_script_header_comment_states_where_it_lands():
    # ヘッダコメントの mode 分岐を両側とも断定する。maintain 側は base を隠すのが
    # 目的の分岐なので、base= が漏れていないことまで見る。
    assert "# job-graph launch: A (br-A) base=main" in launch_body([task("A")])["A"]
    maintain = launch_body([task("A")], default_base="develop", mode="maintain")["A"]
    header = maintain.splitlines()[1]
    assert header == "# job-graph launch: A (br-A) 既存 worktree へ switch"
    assert "base=" not in header


def test_render_pane_run_only_references_launch_script():
    # pane run には `bash <launch_<id>.sh>` の短いコマンドだけを流す
    # （長文注入で未実行・切断が起きた実績への対策）。
    out = rendered([task("A"), task("B", boundary=["pkg/**"])])
    launches = [ln for ln in out.splitlines() if "pane run" in ln]
    assert len(launches) == 2
    assert any("'bash /tmp/jg-prompts/launch_A.sh'" in ln for ln in launches)
    assert any("'bash /tmp/jg-prompts/launch_B.sh'" in ln for ln in launches)
    assert "wt switch" not in out.split("=== COMMANDS")[1]
    assert "launch: /tmp/jg-prompts/launch_A.sh" in out.split("=== PROMPTS")[1]


def test_launch_script_strips_parent_session_markers():
    # 各レーンは独立したセッションなので、親セッション固有のマーカーを wt より前で
    # 断ち切る（放置するとレーンが親の子と誤認され transcript 保存が切られる）。
    # 境界あり（-x bash bootstrap）・境界なし（-x claude）の両経路が対象。
    bodies = launch_body([task("A"), task("B", boundary=["pkg/**"])])
    assert len(bodies) == 2
    for body in bodies.values():
        # env -u は wt より前に置く（wt 自身にもその子の claude にも渡らないように）。
        assert "env -u CLAUDE_CODE_CHILD_SESSION" in body
        assert body.index("env -u CLAUDE_CODE_CHILD_SESSION") < body.index("wt switch")
        for var in po.INHERITED_SESSION_VARS:
            assert f"-u {var}" in body
        # ユーザー設定・実行ファイル解決に使うものは落とさない。
        assert "CLAUDE_CODE_EXECPATH" not in body
        # 実行した shell の環境は壊さない（unset は使わない）。
        assert "unset CLAUDE_CODE" not in body


def test_launch_script_no_claude_name_flag():
    # 報告は lane-ops（herdr agent prompt）経由なので --name は付けない
    assert "--name" not in launch_body([task("A")])["A"]


def test_launch_script_remote_control_optin():
    assert "--remote-control br-A" in launch_body([task("A")], launch=po.Launch(remote_control=True))["A"]
    assert "--remote-control" not in launch_body([task("A")])["A"]


def test_launch_script_model_flags_task_over_global():
    bodies = launch_body(
        [task("A", model="sonnet"), task("B")],
        launch=po.Launch(model="opus", effort="high"),
    )
    assert "--model sonnet" in bodies["A"]
    assert "--model opus" in bodies["B"]
    assert "--effort high" in bodies["A"] and "--effort high" in bodies["B"]


def test_launch_script_boundary_uses_bootstrap():
    body = launch_body([task("A", boundary=["src/**"])])["A"]
    assert "-x bash --" in body
    assert "wt-boundary-A" in body
    assert "task-boundary.json" in body


# ------------------------------------------------------------
# BOUNDARY_BOOTSTRAP（統合: 実 git repo で bash 実行）
# ------------------------------------------------------------
#
# plan_orchestration.py が生成するのはコマンド文字列だけなので、既存境界ファイルとの
# マージ・fail-closed が実際に起きるかはここで実行して確認する（parallel-worktree 側の
# 統合テストと同じく exec claude "$@" だけを引数エコーへ差し替える）。


def git_repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    git = ["git", "-C", str(repo)]
    subprocess.run(git + ["init", "-q"], check=True)
    subprocess.run(git + ["config", "user.email", "t@example.com"], check=True)
    subprocess.run(git + ["config", "user.name", "t"], check=True)
    subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "init"], check=True)
    return repo


BOOTSTRAP_PROBE = po.BOUNDARY_BOOTSTRAP.replace(
    'exec claude "$@"', 'printf "ARGC=%s\\n" "$#"; printf "ARG=%s\\n" "$@"'
)


def run_bootstrap(repo, decl, *claude_args):
    return subprocess.run(
        ["bash", "-c", BOOTSTRAP_PROBE, "argv0", decl, *claude_args],
        cwd=repo, capture_output=True, text=True,
    )


def boundary_file(repo):
    return repo / po.BOUNDARY_FILE


def test_bootstrap_fresh_worktree_writes_declaration(tmp_path):
    # 既存ファイルなし（implement / worktree 再作成）: 宣言をそのまま置き、exclude 登録し、
    # claude 引数を素通しする。
    repo = git_repo(tmp_path)
    t = spec([task("A", boundary=["src/**"])]).tasks[0]
    proc = run_bootstrap(repo, po.boundary_json(t), "--model", "opus", "the prompt")
    assert proc.returncode == 0, proc.stderr
    assert json.loads(boundary_file(repo).read_text()) == {
        "task_id": "A", "branch": "br-A", "allow": ["src/**", "tmp_claude/**"],
    }
    assert "ARGC=3" in proc.stdout and "ARG=the prompt" in proc.stdout
    status = subprocess.run(
        ["git", "-C", str(repo), "status", "--porcelain"], capture_output=True, text=True, check=True
    )
    assert status.stdout.strip() == ""
    # 無視の由来が info/exclude であること（.gitignore 等の偶然の一致ではない）
    ignored = subprocess.run(
        ["git", "-C", str(repo), "check-ignore", "-v", po.BOUNDARY_FILE],
        capture_output=True, text=True, check=True,
    )
    assert "info/exclude" in ignored.stdout


def test_bootstrap_merges_existing_allow_and_keeps_widened_globs(tmp_path):
    # 既存ファイルあり（maintain が既存 worktree へ入る）: 実装フェーズ中に widen した
    # docs/** が保たれ、宣言側の新 glob も入る。task_id / branch は宣言が正。
    repo = git_repo(tmp_path)
    boundary_file(repo).parent.mkdir()
    boundary_file(repo).write_text(json.dumps(
        {"task_id": "old-id", "branch": "br-A", "allow": ["src/**", "tmp_claude/**", "docs/**"]}
    ))
    t = spec([task("A", boundary=["src/**", "tests/**"])]).tasks[0]
    proc = run_bootstrap(repo, po.boundary_json(t))
    assert proc.returncode == 0, proc.stderr
    written = json.loads(boundary_file(repo).read_text())
    assert written["task_id"] == "A" and written["branch"] == "br-A"
    assert set(written["allow"]) == {"src/**", "tmp_claude/**", "docs/**", "tests/**"}
    assert len(written["allow"]) == 4  # 重複なし
    # mv で書き直しても exclude 登録済み ＝ git status に現れない
    status = subprocess.run(
        ["git", "-C", str(repo), "status", "--porcelain"], capture_output=True, text=True, check=True
    )
    assert status.stdout.strip() == ""


def test_bootstrap_merge_keeps_unknown_top_level_keys(tmp_path):
    # 契約外の top-level キーは既存ファイル側を保持する（widen_boundary.sh が .allow だけを
    # 書き換えるのと同じ扱い。将来 hook の契約にキーが増えても bootstrap が消さない）。
    repo = git_repo(tmp_path)
    boundary_file(repo).parent.mkdir()
    boundary_file(repo).write_text(json.dumps(
        {"task_id": "A", "branch": "br-A", "allow": ["src/**"], "note": "kept"}
    ))
    t = spec([task("A", boundary=["src/**"])]).tasks[0]
    proc = run_bootstrap(repo, po.boundary_json(t))
    assert proc.returncode == 0, proc.stderr
    written = json.loads(boundary_file(repo).read_text())
    assert written["note"] == "kept"
    assert sorted(written["allow"]) == ["src/**", "tmp_claude/**"]


@pytest.mark.parametrize(
    "existing",
    [{"task_id": "A", "branch": "br-A"}, {"task_id": "A", "branch": "br-A", "allow": None}],
    ids=["allow-missing", "allow-null"],
)
def test_bootstrap_merge_tolerates_missing_allow(tmp_path, existing):
    # 既存ファイルに allow が無い・null でも (.allow // []) で空扱いにして宣言をそのまま入れる。
    repo = git_repo(tmp_path)
    boundary_file(repo).parent.mkdir()
    boundary_file(repo).write_text(json.dumps(existing))
    t = spec([task("A", boundary=["src/**"])]).tasks[0]
    proc = run_bootstrap(repo, po.boundary_json(t))
    assert proc.returncode == 0, proc.stderr
    written = json.loads(boundary_file(repo).read_text())
    assert sorted(written["allow"]) == ["src/**", "tmp_claude/**"]


def test_bootstrap_merge_is_idempotent(tmp_path):
    # 同じ宣言で再起動しても allow は増えず、exclude の行も重複しない。
    repo = git_repo(tmp_path)
    t = spec([task("A", boundary=["src/**"])]).tasks[0]
    for _ in range(3):
        proc = run_bootstrap(repo, po.boundary_json(t))
        assert proc.returncode == 0, proc.stderr
    written = json.loads(boundary_file(repo).read_text())
    assert sorted(written["allow"]) == ["src/**", "tmp_claude/**"]
    exclude = repo / ".git" / "info" / "exclude"
    hits = [ln for ln in exclude.read_text().splitlines() if "task-boundary" in ln]
    assert hits == [f"/{po.BOUNDARY_FILE}"]


@pytest.mark.parametrize(
    "broken",
    ["", "{nope", "[1, 2]", '{"task_id": "A", "allow": "src/**"}'],
    ids=["empty", "invalid-json", "not-an-object", "allow-not-array"],
)
def test_bootstrap_fails_closed_on_broken_existing_file(tmp_path, broken):
    # 既存ファイルが空・不正 JSON（widen_boundary.sh の空 stdin 事故跡など）・妥当な JSON
    # だが境界の書式でない: 上書きせず exit≠0 で claude を起動しない（事故の痕跡を消さない）。
    repo = git_repo(tmp_path)
    boundary_file(repo).parent.mkdir()
    boundary_file(repo).write_text(broken)
    t = spec([task("A", boundary=["src/**"])]).tasks[0]
    proc = run_bootstrap(repo, po.boundary_json(t))
    assert proc.returncode != 0
    # 中止の由来を固定する: 書式検査で止まったのであって、jq 不在の誤診ではない
    assert "境界の書式でない" in proc.stderr
    assert "jq が無い" not in proc.stderr
    assert "ARGC=" not in proc.stdout
    assert boundary_file(repo).read_text() == broken


def test_bootstrap_fails_closed_without_jq_and_names_the_cause(tmp_path):
    # jq が無い環境で既存ファイルがあるとき: 書式検査の 2>/dev/null が command not found を
    # 飲んで「壊れている」と誤診しないよう、jq 不在を名指しして止める（既存ファイルは不変）。
    import shutil

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for tool in ("bash", "git", "mkdir", "mktemp", "mv", "rm", "grep", "dirname"):
        real = shutil.which(tool)
        assert real, tool
        (bin_dir / tool).symlink_to(real)
    repo = git_repo(tmp_path)
    boundary_file(repo).parent.mkdir()
    good = json.dumps({"task_id": "A", "branch": "br-A", "allow": ["src/**", "docs/**"]})
    boundary_file(repo).write_text(good)
    t = spec([task("A", boundary=["src/**"])]).tasks[0]
    proc = subprocess.run(
        ["bash", "-c", BOOTSTRAP_PROBE, "argv0", po.boundary_json(t)],
        cwd=repo, capture_output=True, text=True, env={"PATH": str(bin_dir)},
    )
    assert proc.returncode != 0
    assert "jq が無い" in proc.stderr
    assert "境界の書式でない" not in proc.stderr
    assert "ARGC=" not in proc.stdout
    assert boundary_file(repo).read_text() == good


def test_render_lanes_section():
    out = rendered([task("A"), task("B", deps=["A"]), task("C")])
    assert "=== LANES" in out
    assert "先頭 task が workspace create、後続段は同 workspace への tab" in out
    assert "A -> B" in out


def test_render_maintain_lanes_header_states_no_tab():
    # LANES ヘッダも SCHEDULE と同じく mode で分ける（implement 前提の説明が
    # maintain で空振りしないように）。両側を断定する。
    out = rendered([task("A"), task("B", deps=["A"])], mode="maintain")
    assert "maintain は全 task が単独レーン。tab 追加は起きない" in out
    assert "先頭 task が workspace create、後続段は同 workspace への tab" not in out


def test_render_maintain_has_stack_section():
    # maintain はレーンを独立にする分、spec の depends_on 由来の base を STACK 節で見せる
    # （push 承認の差分確認と restack の下段/上段判定の入力になる）。
    out = rendered([task("A"), task("B", deps=["A"])], mode="maintain")
    stack = out.split("=== STACK")[1].split("=== PROMPTS")[0]
    assert "spec の depends_on から見た PR の base。レーン割当には使わない" in stack
    assert "  A (br-A) -> base: main" in stack
    assert "  B (br-B) -> base: br-A (A)" in stack
    # ヘッダ直下の用途 1 行も断定する（空文字・誤文言でも task 行の assert は緑のまま通る）。
    assert "push 承認時の `git diff <base>...HEAD --stat` の base と、restack の下段/上段判定に使う。" in stack
    assert "references/maintain.md §5" in stack
    # LANES の直後に置く（レーン割当と並べて読む節）。
    assert out.index("=== LANES") < out.index("=== STACK") < out.index("=== PROMPTS")


def test_render_implement_omits_stack_section():
    # implement では base が wt switch --create --base と PR 節に既に出る。
    out = rendered([task("A"), task("B", deps=["A"])])
    assert "=== STACK" not in out


def test_stack_lines_dangling_parent_is_a_note_without_error():
    # maintain.md は「対応不要な task を spec から削る」と指示するので、残った
    # depends_on が宙に浮くのは正常運用。ERROR / WARNING は出さず注記に留める。
    # expected_files を付けて欠落 WARNING を消し、警告がゼロであることを直に断定する。
    plan = spec([task("B", deps=["X"], expected_files=["b.py"])], mode="maintain")
    an = po.analyze(plan)
    assert an.errors == []
    assert an.warnings == []
    out = po.render(plan, an, po.Launch(), "/tmp/jg-prompts")
    stack = out.split("=== STACK")[1].split("=== PROMPTS")[0]
    assert "  B (br-B) -> base: (spec に無い task: X。gh pr view <PR#> --json baseRefName で確認)" in stack


def test_stack_lines_multi_parent_uses_first_parent():
    lines = po.stack_lines(spec([task("A"), task("B"), task("C", deps=["A", "B"])], mode="maintain"))
    assert lines == [
        "  A (br-A) -> base: main",
        "  B (br-B) -> base: main",
        "  C (br-C) -> base: br-A (A) (複数親: A, B)",
    ]


def test_maintain_bases_stay_default_base_despite_stack_section():
    # STACK 節は表示だけ。レーン割当・base 解決は従来どおり全 task が default_base。
    plan = spec([task("A"), task("B", deps=["A"])], mode="maintain")
    an = po.analyze(plan)
    assert an.bases == {"A": "main", "B": "main"}


def test_render_maintain_boundary_header_says_merge():
    # maintain は既存 worktree へ入るので境界ファイルは「生成」ではなく「マージ」。
    # widen_boundary.sh で広げた分が保たれる旨と、一覧が spec 側の宣言のみである旨を出す。
    out = rendered([task("A", boundary=["src/**"])], mode="maintain")
    assert f"既存 worktree の {po.BOUNDARY_FILE} とこの内容をマージする" in out
    assert "widen_boundary.sh で広げた glob は保たれる" in out
    assert "上書き" not in out.split("=== BOUNDARY")[1].split("=== PROMPTS")[0]
    assert "各 worktree に生成する" not in out
    # implement 側は従来の文言のまま（退行検知）。判定は BOUNDARY 節に限定する。
    impl = rendered([task("A", boundary=["src/**"])])
    impl_boundary = impl.split("=== BOUNDARY")[1].split("=== PROMPTS")[0]
    assert f"各 worktree に生成する {po.BOUNDARY_FILE}" in impl
    assert "マージする" not in impl_boundary


def test_render_verify_section_lists_pr_form_per_task():
    out = rendered([task("A", expected_files=["a.py"], expected_scale=5), task("B", deps=["A"])])
    verify = out.split("=== VERIFY")[1].split("=== MONITOR")[0]
    assert "scope-gate.md" in verify
    assert "FAIL なら次段を起動せず" in verify
    assert f"python3 {po.CHECK_SCOPE} --pr <A の PR 番号> --expected-file a.py --expected-scale 5" in verify
    assert f"python3 {po.CHECK_SCOPE} --pr <B の PR 番号>" in verify
    assert out.index("=== PR") < out.index("=== VERIFY") < out.index("=== MONITOR")


def test_render_maintain_omits_pr_and_verify_sections():
    # maintain のワーカーは /pr-create を実行せず（PR は既にある）、レビュー対応の
    # 差分は元計画に無いので計画突合も成立しない。MONITOR は両モードで出す。
    # maintain.md は expected_files を消した spec の再利用を案内しているので、
    # 期待あり・なしの両方で節が出ないことを見る。
    for tasks in ([task("A", expected_files=["a.py"])], [task("A")]):
        out = rendered(tasks, mode="maintain")
        assert "=== PR (" not in out
        assert "=== VERIFY" not in out
        assert "/pr-create" not in out
        assert "=== MONITOR" in out
        # 突合コマンドは COMMANDS 以降のどこにも出ない（VALIDATION の WARNING 本文は
        # check_scope.py に言及するので、節の判定に混ぜない）。
        assert "check_scope.py" not in out.split("=== COMMANDS")[1]


def test_render_maintain_without_expected_files_warns_in_validation():
    # 裁定により WARNING は maintain でも出す。VALIDATION 節に載ることまで見る
    # （analyze 止まりのテストだと render への配線が切れても気付けない）。
    validation = rendered([task("A")], mode="maintain").split("=== SCHEDULE")[0]
    assert "WARNING: task A に expected_files が無い" in validation
    assert "ok（致命的問題なし）" not in validation
    # maintain 版の文言は「この実行では突合しない」と断る（implement 前提の
    # 「縮退する」だけだと、この実行で突合が動くと読める）。
    assert "maintain では計画突合を行わないのでこの実行に影響はない" in validation
    assert "同じ spec を implement で再利用すると" in validation


def test_render_maintain_monitor_section_is_push_approval():
    # MONITOR 節の maintain 分岐を肯定的に断定する（消失の断定だけだと、
    # if 側が空文字・誤文言・別セクションへの誤挿入になっても緑のままになる）。
    monitor = rendered([task("A")], mode="maintain").split("=== MONITOR")[1]
    assert "# push 承認:" in monitor
    assert "references/maintain.md" in monitor
    assert "「push 承認待ち」を報告する" in monitor
    # maintain に次段起動は無い（全レーン wave 0）ので、その文言も出さない。
    assert "次段を起動する" not in monitor
    assert "裏取りしてから承認する" in monitor


def test_render_monitor_section_points_to_lane_ops():
    out = rendered([task("B"), task("A")])
    monitor = out.split("=== MONITOR")[1]
    assert f"python3 {po.LANE_OPS_SCRIPTS / 'watch_events.py'} --once --status blocked --status idle" in monitor
    # 自レーンの pane に限定（id 順に列挙）
    assert '--pane "$PANE_A" --pane "$PANE_B"' in monitor
    assert "agent get <pane>" in monitor
    assert f"bash {po.LANE_OPS_SCRIPTS / 'verify_lane.sh'}" in monitor
    assert "check_scope.py --pr" in monitor
    assert "[lane-ops:report" in monitor
    assert "常駐" not in monitor


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
    la = (pdir / "launch_A.sh").read_text(encoding="utf-8")
    lb = (pdir / "launch_B.sh").read_text(encoding="utf-8")
    assert "wt switch --create br-A --base main" in la
    assert "wt switch --create br-B --base br-A" in lb
    assert f"$(cat {pdir / 'B.md'})" in lb


def test_write_prompts_and_main_maintain(tmp_path):
    # write_prompts が plan を launch_script へ渡す配線の end-to-end 検証
    # （launch_body ヘルパは launch_script を直接叩くのでこの経路を守れない）。
    spec_file = tmp_path / "spec.json"
    spec_file.write_text(json.dumps({
        "default_base": "main",
        "mode": "maintain",
        "tasks": [task("A"), task("B", deps=["A"])],
    }), encoding="utf-8")
    pdir = tmp_path / "prompts"
    rc = po.main([
        "plan_orchestration.py", str(spec_file),
        "--prompt-dir", str(pdir), "--parent-name", "orc",
    ])
    assert rc == 0
    for tid, branch in (("A", "br-A"), ("B", "br-B")):
        body = (pdir / f"launch_{tid}.sh").read_text(encoding="utf-8")
        assert f"wt switch {branch} -x claude --" in body
        assert "--create" not in body and "--base" not in body
    # maintain 規約が連結されていること（implement の規約と取り違えていない）。
    assert "`/review-converge`・`/pr-create` は実行しない" in (pdir / "A.md").read_text(encoding="utf-8")


def test_main_exit_1_on_missing_plan(tmp_path):
    spec_file = tmp_path / "spec.json"
    spec_file.write_text(json.dumps({
        "plan": str(tmp_path / "missing.md"),
        "tasks": [task("A")],
    }), encoding="utf-8")
    rc = po.main(["plan_orchestration.py", str(spec_file), "--prompt-dir", str(tmp_path / "p")])
    assert rc == 1
    assert not (tmp_path / "p").exists()


def test_main_exit_1_on_missing_plan_in_maintain(tmp_path):
    # plan の存在確認は mode に依らず走る（spec.md / maintain.md が明文化した挙動）。
    spec_file = tmp_path / "spec.json"
    spec_file.write_text(json.dumps({
        "mode": "maintain",
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
