"""derive_state の純粋関数・ファイル走査に対するテスト。

git/gh を呼ぶ経路（collect_git_state / fetch_check_status）はネットワーク・外部
コマンドに依存するため、GitState をテスト側で組み立てて注入する形で検証する。
ネットワーク無し・gh 無しでも全件 PASS すること。
"""

from pathlib import Path

from derive_state import (
    Declaration,
    DodItem,
    GitState,
    build_report,
    derive_phase,
    extract_review_verdict,
    extract_summary_verdict,
    judge_dod_items,
    list_targets,
    load_declaration,
    next_actions,
    parse_dod,
    related_prs,
    render_target_list,
    scan_artifacts,
    scan_reviews,
)


# ---- fixture helpers ----


def write(root: Path, rel: str, text: str = "dummy\n") -> Path:
    """リポジトリ相対パスへファイルを作る（親ディレクトリも作る）。"""
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path


def review_doc(verdict: str) -> str:
    return (
        "# テストレビュー記録: sample / spec\n\n"
        "- レビュー対象: docs/dev/sample/spec.md\n"
        "- 実施日: 2026-07-25\n"
        f"- 判定: {verdict}（利用者判定）\n"
    )


def state_for(branches: list[str] | None = None) -> GitState:
    """git 呼び出しなしで GitState を組む（テスト用の注入）。"""
    return GitState(available=True, branches=branches or [], current_branch="main")


# ---- list_targets ----


def test_list_targets_empty_repo(tmp_path: Path) -> None:
    """観点: docs/ が無くても例外を出さず空 dict。"""
    assert list_targets(tmp_path) == {}


def test_list_targets_collects_both_trees(tmp_path: Path) -> None:
    """観点: docs/dev/*/ と docs/test/*/ の両方から対象を集め、系統を記録する。"""
    write(tmp_path, "docs/dev/alpha/spec.md")
    write(tmp_path, "docs/test/alpha/test-plan.md")
    write(tmp_path, "docs/test/beta/test-plan.md")
    found = list_targets(tmp_path)
    assert found == {"alpha": ["dev", "test"], "beta": ["test"]}


def test_list_targets_excludes_definition_of_done(tmp_path: Path) -> None:
    """観点: docs/dev/definition-of-done.md はファイルなので対象候補にならない。"""
    write(tmp_path, "docs/dev/definition-of-done.md")
    assert list_targets(tmp_path) == {}


def test_list_targets_ignores_dotdirs(tmp_path: Path) -> None:
    """観点: ドット始まりのディレクトリは対象候補から除外する。"""
    (tmp_path / "docs/dev/.hidden").mkdir(parents=True)
    assert list_targets(tmp_path) == {}


# ---- load_declaration ----


def test_load_declaration_absent(tmp_path: Path) -> None:
    """観点: pipeline.toml が無ければ present=False で既定値のまま返る。"""
    decl = load_declaration(tmp_path, "sample")
    assert decl.present is False
    assert decl.skip == []
    assert decl.error is None


def test_load_declaration_full(tmp_path: Path) -> None:
    """観点: spec.md のスキーマ例どおりの TOML を全項目パースできる。"""
    write(
        tmp_path,
        "docs/dev/sample/pipeline.toml",
        """
target = "sample"

[spec]
path = "docs/dev/sample/spec.md"

[design]
path = "docs/dev/sample/basic-design.md"

[scope]
skip = ["test-monitor"]

[implementation]
plan_file = "~/.claude/plans/sample.md"
branches = ["feat-a", "feat-b"]

[integration]
targets = ["docs/architecture.md"]
""",
    )
    decl = load_declaration(tmp_path, "sample")
    assert decl.present is True
    assert decl.target == "sample"
    assert decl.spec_path == "docs/dev/sample/spec.md"
    assert decl.design_path == "docs/dev/sample/basic-design.md"
    assert decl.skip == ["test-monitor"]
    assert decl.plan_file == "~/.claude/plans/sample.md"
    assert decl.branches == ["feat-a", "feat-b"]
    assert decl.integration_targets == ["docs/architecture.md"]


def test_load_declaration_broken_toml(tmp_path: Path) -> None:
    """観点: 壊れた TOML でもクラッシュせず error に理由が入る（fail-open）。"""
    write(tmp_path, "docs/dev/sample/pipeline.toml", "target = \n[unclosed\n")
    decl = load_declaration(tmp_path, "sample")
    assert decl.present is True
    assert decl.error is not None
    assert decl.skip == []


def test_load_declaration_wrong_types(tmp_path: Path) -> None:
    """観点: 型が違う値（skip が文字列など）は黙って無視して既定値にする。"""
    write(
        tmp_path,
        "docs/dev/sample/pipeline.toml",
        'target = 1\n[scope]\nskip = "test-monitor"\n',
    )
    decl = load_declaration(tmp_path, "sample")
    assert decl.target is None
    assert decl.skip == []


# ---- scan_artifacts / scan_reviews ----


def test_scan_artifacts_all_absent(tmp_path: Path) -> None:
    """観点: 成果物が一つも無くても全キーが None で返る（クラッシュしない）。"""
    result = scan_artifacts(tmp_path, "sample", Declaration())
    assert set(result) >= {"spec", "basic-design", "test-plan", "test-summary-report"}
    assert all(value is None for value in result.values())


def test_scan_artifacts_declared_spec_path(tmp_path: Path) -> None:
    """観点: pipeline.toml の [spec].path が既定パスより優先される。"""
    write(tmp_path, "docs/spec/custom.md")
    decl = Declaration(present=True, spec_path="docs/spec/custom.md")
    result = scan_artifacts(tmp_path, "sample", decl)
    assert result["spec"] == tmp_path / "docs/spec/custom.md"


def test_scan_reviews_extracts_verdicts(tmp_path: Path) -> None:
    """観点: test-review-*.md から工程名と判定を抽出する。"""
    write(tmp_path, "docs/test/sample/test-review-spec.md", review_doc("通過"))
    write(
        tmp_path,
        "docs/test/sample/test-review-design-doc.md",
        review_doc("条件付き通過"),
    )
    assert scan_reviews(tmp_path, "sample") == {
        "spec": "通過",
        "design-doc": "条件付き通過",
    }


def test_scan_reviews_missing_dir(tmp_path: Path) -> None:
    """観点: docs/test/<対象>/ が無くても空 dict。"""
    assert scan_reviews(tmp_path, "sample") == {}


def test_extract_review_verdict_prefers_longest_vocabulary() -> None:
    """観点: 「条件付き通過」は「通過」を部分文字列に持つが、長い語彙が優先される。"""
    assert extract_review_verdict("- 判定: 条件付き通過\n") == "条件付き通過"


def test_extract_review_verdict_sendback() -> None:
    """観点: 差し戻しを抽出できる。"""
    assert extract_review_verdict("- 判定: 差し戻し（機械検査 NG）\n") == "差し戻し"


def test_extract_review_verdict_unknown() -> None:
    """観点: 判定行が無い / 語彙外なら「判定不明」（例外にしない）。"""
    assert extract_review_verdict("# 見出しだけ\n") == "判定不明"
    assert extract_review_verdict("- 判定: よくわからない\n") == "判定不明"


def test_extract_summary_verdict() -> None:
    """観点: test-summary-report.md の総合判定行を抽出する。"""
    text = "# テスト結果評価\n\n- 実施日: 2026-07-25\n- 総合判定: 完了\n"
    assert extract_summary_verdict(text) == "完了"


def test_extract_summary_verdict_absent() -> None:
    """観点: 総合判定行が無ければ None。"""
    assert extract_summary_verdict("# 何もなし\n") is None


# ---- parse_dod ----

DOD_SAMPLE = """# 完成の定義

## 機械判定

| ID | 項目 | 種別 | 対象 | 条件 |
|---|---|---|---|---|
| DOD-01 | CI が green | ci-check | test | success |
| DOD-02 | テスト評価がある | artifact | docs/test/{target}/test-summary-report.md | exists |
| DOD-03 | 総合判定が完了 | artifact | docs/test/{target}/test-summary-report.md | contains:完了 |

## 人判定

- [ ] 手動テストのシナリオを一通り確認した
- [x] リリースノートを書いた
"""


def test_parse_dod_items_and_checklist() -> None:
    """観点: 機械判定テーブル 3 行と人判定チェックリスト 2 件をパースする。"""
    items, checklist = parse_dod(DOD_SAMPLE)
    assert [item.id for item in items] == ["DOD-01", "DOD-02", "DOD-03"]
    assert items[0].kind == "ci-check"
    assert items[1].subject == "docs/test/{target}/test-summary-report.md"
    assert items[2].condition == "contains:完了"
    assert checklist == [
        (False, "手動テストのシナリオを一通り確認した"),
        (True, "リリースノートを書いた"),
    ]


def test_parse_dod_ignores_header_and_separator_rows() -> None:
    """観点: ヘッダ行・区切り行・種別語彙外の行はテーブル項目として拾わない。"""
    text = (
        "## 機械判定\n\n"
        "| ID | 項目 | 種別 | 対象 | 条件 |\n"
        "|---|---|---|---|---|\n"
        "| DOD-99 | 未知種別 | unknown-kind | x | y |\n"
    )
    items, _ = parse_dod(text)
    assert items == []


def test_parse_dod_empty_document() -> None:
    """観点: 空文書でもクラッシュせず空の結果。"""
    assert parse_dod("") == ([], [])


def test_parse_dod_checklist_only_under_human_section() -> None:
    """観点: 人判定節の外側にあるチェックリストは残チェックに含めない。"""
    text = "## 機械判定\n\n- [ ] 機械判定節のメモ\n\n## 人判定\n\n- [ ] 本物\n"
    _, checklist = parse_dod(text)
    assert checklist == [(False, "本物")]


# ---- judge_dod_items ----


def test_judge_artifact_exists_ok(tmp_path: Path) -> None:
    """観点: artifact/exists は {target} 展開後のパスの存在で判定する。"""
    write(tmp_path, "docs/test/sample/test-summary-report.md")
    items = [
        DodItem(
            "DOD-02",
            "評価がある",
            "artifact",
            "docs/test/{target}/test-summary-report.md",
            "exists",
        )
    ]
    judge_dod_items(items, tmp_path, "sample", GitState())
    assert items[0].verdict == "OK"


def test_judge_artifact_exists_ng(tmp_path: Path) -> None:
    """観点: 対象ファイルが無ければ NG。"""
    items = [DodItem("DOD-02", "評価がある", "artifact", "docs/x.md", "exists")]
    judge_dod_items(items, tmp_path, "sample", GitState())
    assert items[0].verdict == "NG"


def test_judge_artifact_contains(tmp_path: Path) -> None:
    """観点: artifact/contains:<文字列> は本文の部分一致で OK/NG を分ける。"""
    write(tmp_path, "docs/test/sample/test-summary-report.md", "- 総合判定: 完了\n")
    ok = [
        DodItem(
            "A", "", "artifact", "docs/test/{target}/test-summary-report.md", "contains:完了"
        )
    ]
    ng = [
        DodItem(
            "B", "", "artifact", "docs/test/{target}/test-summary-report.md", "contains:未完了"
        )
    ]
    judge_dod_items(ok, tmp_path, "sample", GitState())
    judge_dod_items(ng, tmp_path, "sample", GitState())
    assert ok[0].verdict == "OK"
    assert ng[0].verdict == "NG"


def test_judge_artifact_unknown_condition(tmp_path: Path) -> None:
    """観点: 語彙外の条件は「判定不能」（クラッシュも誤 OK もしない）。"""
    write(tmp_path, "docs/x.md")
    items = [DodItem("C", "", "artifact", "docs/x.md", "matches:/re/")]
    judge_dod_items(items, tmp_path, "sample", GitState())
    assert items[0].verdict == "判定不能"


def test_judge_ci_check_without_gh(tmp_path: Path) -> None:
    """観点: git 不能（=gh 判定不能）のとき ci-check は「判定不能」になる（NFR-04）。"""
    items = [DodItem("DOD-01", "CI green", "ci-check", "test", "success")]
    judge_dod_items(items, tmp_path, "sample", GitState(available=False))
    assert items[0].verdict == "判定不能"
    assert "gh" in items[0].detail


# ---- derive_phase ----


def test_derive_phase_nothing(tmp_path: Path) -> None:
    """観点: 何も無ければ工程 0（完成の定義）から始まると導出する。"""
    (tmp_path / "docs/dev/sample").mkdir(parents=True)
    decl = Declaration()
    phase, name, _ = derive_phase(
        tmp_path, "sample", scan_artifacts(tmp_path, "sample", decl), {}, decl,
        state_for(),
    )
    assert phase == 0
    assert name == "完成の定義"


def test_derive_phase_spec_without_review(tmp_path: Path) -> None:
    """観点: spec.md はあるがゲート未通過なら工程 1 に留まる。"""
    write(tmp_path, "docs/dev/definition-of-done.md", DOD_SAMPLE)
    write(tmp_path, "docs/dev/sample/spec.md")
    decl = Declaration()
    phase, _, _ = derive_phase(
        tmp_path, "sample", scan_artifacts(tmp_path, "sample", decl), {}, decl,
        state_for(),
    )
    assert phase == 1


def test_derive_phase_spec_review_passed(tmp_path: Path) -> None:
    """観点: test-review-spec が通過していれば工程 2 へ進む。"""
    write(tmp_path, "docs/dev/definition-of-done.md", DOD_SAMPLE)
    write(tmp_path, "docs/dev/sample/spec.md")
    write(tmp_path, "docs/test/sample/test-review-spec.md", review_doc("通過"))
    decl = Declaration()
    phase, _, _ = derive_phase(
        tmp_path,
        "sample",
        scan_artifacts(tmp_path, "sample", decl),
        scan_reviews(tmp_path, "sample"),
        decl,
        state_for(),
    )
    assert phase == 2


def test_derive_phase_conditional_pass_counts_as_gate(tmp_path: Path) -> None:
    """観点: 「条件付き通過」もゲート通過として扱う。"""
    write(tmp_path, "docs/dev/definition-of-done.md", DOD_SAMPLE)
    write(tmp_path, "docs/dev/sample/spec.md")
    write(tmp_path, "docs/test/sample/test-review-spec.md", review_doc("条件付き通過"))
    decl = Declaration()
    phase, _, _ = derive_phase(
        tmp_path,
        "sample",
        scan_artifacts(tmp_path, "sample", decl),
        scan_reviews(tmp_path, "sample"),
        decl,
        state_for(),
    )
    assert phase == 2


def test_derive_phase_sendback_stays(tmp_path: Path) -> None:
    """観点: 差し戻しならゲート未通過として工程 1 に留まる。"""
    write(tmp_path, "docs/dev/sample/spec.md")
    write(tmp_path, "docs/test/sample/test-review-spec.md", review_doc("差し戻し"))
    decl = Declaration()
    phase, _, _ = derive_phase(
        tmp_path,
        "sample",
        scan_artifacts(tmp_path, "sample", decl),
        scan_reviews(tmp_path, "sample"),
        decl,
        state_for(),
    )
    assert phase == 1


def test_derive_phase_test_planning(tmp_path: Path) -> None:
    """観点: test-plan だけある状態は工程 2。"""
    write(tmp_path, "docs/dev/sample/spec.md")
    write(tmp_path, "docs/test/sample/test-plan.md")
    decl = Declaration()
    phase, _, _ = derive_phase(
        tmp_path, "sample", scan_artifacts(tmp_path, "sample", decl), {}, decl,
        state_for(),
    )
    assert phase == 2


def test_derive_phase_design_stage(tmp_path: Path) -> None:
    """観点: test-design / basic-design が揃い途中なら工程 3。"""
    write(tmp_path, "docs/dev/sample/spec.md")
    write(tmp_path, "docs/dev/sample/basic-design.md")
    write(tmp_path, "docs/test/sample/test-design.md")
    decl = Declaration()
    phase, _, _ = derive_phase(
        tmp_path, "sample", scan_artifacts(tmp_path, "sample", decl), {}, decl,
        state_for(),
    )
    assert phase == 3


def test_derive_phase_design_gate_passed_moves_to_impl(tmp_path: Path) -> None:
    """観点: basic-design + test-case + design-doc ゲート通過で工程 4（実装）へ。"""
    write(tmp_path, "docs/dev/sample/spec.md")
    write(tmp_path, "docs/dev/sample/basic-design.md")
    write(tmp_path, "docs/test/sample/test-case.md")
    write(tmp_path, "docs/test/sample/test-review-design-doc.md", review_doc("通過"))
    decl = Declaration()
    phase, _, _ = derive_phase(
        tmp_path,
        "sample",
        scan_artifacts(tmp_path, "sample", decl),
        scan_reviews(tmp_path, "sample"),
        decl,
        state_for(),
    )
    assert phase == 4


def test_derive_phase_impl_branch_hint(tmp_path: Path) -> None:
    """観点: pipeline.toml の [implementation].branches が実在すれば工程 4 と導出する。"""
    write(tmp_path, "docs/dev/sample/spec.md")
    decl = Declaration(present=True, branches=["feat-a"])
    phase, _, reasons = derive_phase(
        tmp_path,
        "sample",
        scan_artifacts(tmp_path, "sample", decl),
        {},
        decl,
        state_for(branches=["main", "feat-a"]),
    )
    assert phase == 4
    assert any("feat-a" in reason for reason in reasons)


def test_derive_phase_execution(tmp_path: Path) -> None:
    """観点: test-execution-log があれば工程 5。"""
    write(tmp_path, "docs/dev/sample/spec.md")
    write(tmp_path, "docs/test/sample/test-execution-log.md")
    decl = Declaration()
    phase, _, _ = derive_phase(
        tmp_path, "sample", scan_artifacts(tmp_path, "sample", decl), {}, decl,
        state_for(),
    )
    assert phase == 5


def test_derive_phase_finished_after_doc_integrate(tmp_path: Path) -> None:
    """観点: 作業ディレクトリが両方消えていればパイプライン終了と導出する（AC-04）。"""
    write(tmp_path, "docs/dev/definition-of-done.md", DOD_SAMPLE)
    decl = Declaration()
    phase, name, _ = derive_phase(
        tmp_path, "sample", scan_artifacts(tmp_path, "sample", decl), {}, decl,
        state_for(),
    )
    assert phase == 5
    assert "終了" in name


# ---- next_actions ----


def test_next_actions_suggests_def_done_when_missing(tmp_path: Path) -> None:
    """観点: definition-of-done.md が無ければ /def-done を先頭で提案する。"""
    (tmp_path / "docs/dev/sample").mkdir(parents=True)
    decl = Declaration()
    actions = next_actions(0, "sample", scan_artifacts(tmp_path, "sample", decl), {}, decl, tmp_path)
    assert any("/def-done" in action for action in actions)


def test_next_actions_impl_phase_proposes_parallel_worktree(tmp_path: Path) -> None:
    """観点: 実装フェーズ入口では実装計画ファイル作成 → /parallel-worktree を提案する。"""
    write(tmp_path, "docs/dev/definition-of-done.md", DOD_SAMPLE)
    write(tmp_path, "docs/dev/sample/basic-design.md")
    write(tmp_path, "docs/test/sample/test-case.md")
    decl = Declaration()
    actions = next_actions(
        4, "sample", scan_artifacts(tmp_path, "sample", decl), {}, decl, tmp_path
    )
    joined = "\n".join(actions)
    assert "/parallel-worktree" in joined
    assert "実装計画ファイル" in joined
    assert "/review-converge" in joined


def test_next_actions_final_phase_proposes_doc_integrate(tmp_path: Path) -> None:
    """観点: 評価まで終わっていれば /doc-integrate を提案する。"""
    write(tmp_path, "docs/dev/definition-of-done.md", DOD_SAMPLE)
    write(tmp_path, "docs/test/sample/test-execution-log.md")
    write(tmp_path, "docs/test/sample/test-summary-report.md", "- 総合判定: 完了\n")
    decl = Declaration()
    actions = next_actions(
        5, "sample", scan_artifacts(tmp_path, "sample", decl), {}, decl, tmp_path
    )
    assert any("/doc-integrate" in action for action in actions)


def test_next_actions_respects_skip_declaration(tmp_path: Path) -> None:
    """観点: [scope].skip に test-monitor があれば test-monitor を提案しない。"""
    write(tmp_path, "docs/dev/definition-of-done.md", DOD_SAMPLE)
    write(tmp_path, "docs/test/sample/test-plan.md")
    write(tmp_path, "docs/test/sample/test-analysis.md")
    decl = Declaration(present=True, skip=["test-monitor"])
    actions = next_actions(
        2, "sample", scan_artifacts(tmp_path, "sample", decl), {}, decl, tmp_path
    )
    assert not any("/test-monitor" in action for action in actions)


# ---- related_prs ----


def test_related_prs_matches_target_and_branches() -> None:
    """観点: 対象名・宣言ブランチ名に一致する PR だけを拾う。"""
    prs = [
        {"number": 1, "title": "docs(sample): spec", "headRefName": "docs-x", "baseRefName": "main"},
        {"number": 2, "title": "chore: bump", "headRefName": "feat-a", "baseRefName": "main"},
        {"number": 3, "title": "unrelated", "headRefName": "other", "baseRefName": "main"},
    ]
    hits = related_prs(prs, "sample", ["feat-a"])
    assert [pr["number"] for pr in hits] == [1, 2]


# ---- レポート生成（統合） ----


def test_render_target_list_empty(tmp_path: Path) -> None:
    """観点: 対象ゼロでもレポートを生成し、始め方を案内する。"""
    text = render_target_list(tmp_path, list_targets(tmp_path))
    assert "対象候補が見つからない" in text
    assert "/feature-spec" in text


def test_render_target_list_table(tmp_path: Path) -> None:
    """観点: 対象一覧を表で出し、pipeline.toml の有無を示す。"""
    write(tmp_path, "docs/dev/alpha/spec.md")
    write(tmp_path, "docs/dev/alpha/pipeline.toml", 'target = "alpha"\n')
    text = render_target_list(tmp_path, list_targets(tmp_path))
    assert "| alpha |" in text
    assert "pipeline.toml" in text


def test_build_report_empty_state_does_not_crash(tmp_path: Path) -> None:
    """観点: 成果物ゼロ・git 不能な tmp ディレクトリでもレポートを出す（AC-05 / NFR-04）。"""
    (tmp_path / "docs/dev/sample").mkdir(parents=True)
    text = build_report(tmp_path, "sample")
    assert "# dev-pipeline: sample" in text
    assert "## 現在フェーズ" in text
    assert "## マージ可否の判定材料" in text
    assert "導出不能" in text  # git/gh もしくは完成の定義が導出不能


def test_build_report_full_state(tmp_path: Path) -> None:
    """観点: 一通り成果物が揃った状態で、総合判定・DoD 判定・残チェックを報告する。"""
    write(tmp_path, "docs/dev/definition-of-done.md", DOD_SAMPLE)
    write(tmp_path, "docs/dev/sample/spec.md")
    write(tmp_path, "docs/dev/sample/basic-design.md")
    write(tmp_path, "docs/test/sample/test-case.md")
    write(tmp_path, "docs/test/sample/test-execution-log.md")
    write(tmp_path, "docs/test/sample/test-summary-report.md", "- 総合判定: 完了\n")
    write(tmp_path, "docs/test/sample/test-review-spec.md", review_doc("通過"))
    text = build_report(tmp_path, "sample")
    assert "総合判定: **完了**" in text
    assert "DOD-02" in text
    assert "手動テストのシナリオを一通り確認した" in text
    assert "| spec | 通過 |" in text


def test_build_report_broken_declaration(tmp_path: Path) -> None:
    """観点: pipeline.toml が壊れていてもレポートを出し、fail-open を明記する。"""
    write(tmp_path, "docs/dev/sample/spec.md")
    write(tmp_path, "docs/dev/sample/pipeline.toml", "[broken\n")
    text = build_report(tmp_path, "sample")
    assert "パース失敗" in text
    assert "fail-open" in text
