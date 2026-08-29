"""watch_events.py のユニットテスト。購読構築・ack 判定・追随パースの純粋関数を検証する。

購読形状は herdr 公式スキーマ（`herdr api schema --json` / protocol 19）に対応させる。
特に `pane.agent_status_changed` は `pane_id` が required で、欠けるとサーバが
`invalid_request: missing field 'pane_id'` を返して購読が成立しない。
"""
from __future__ import annotations

import json

import watch_events as we


def test_pane_scoped_type_requires_pane():
    """pane が無いと pane_id required の type は展開されない（不正な購読を作らない）。"""
    assert we.build_subscriptions([], [], []) == []


def test_default_subscription_with_pane():
    subs = we.build_subscriptions([], ["w1:p1"], [])
    assert subs == [{"type": "pane.agent_status_changed", "pane_id": "w1:p1"}]


def test_pane_and_status_product():
    subs = we.build_subscriptions([], ["w1:p1", "w1:p2"], ["blocked"])
    assert {
        "type": "pane.agent_status_changed",
        "pane_id": "w1:p1",
        "agent_status": "blocked",
    } in subs
    assert {
        "type": "pane.agent_status_changed",
        "pane_id": "w1:p2",
        "agent_status": "blocked",
    } in subs
    assert len(subs) == 2


def test_every_pane_scoped_subscription_carries_pane_id():
    for t in sorted(we.PANE_SCOPED_TYPES):
        for sub in we.build_subscriptions([t], ["w1:p1"], ["blocked"]):
            assert sub.get("pane_id") == "w1:p1"


def test_global_type_needs_no_pane():
    """pane_id を取らない type は pane 未指定でも 1 件だけ積む。"""
    assert we.build_subscriptions(["worktree.created"], [], []) == [
        {"type": "worktree.created"}
    ]
    assert we.agent_detected_subscription() == {"type": "pane.agent_detected"}


def test_subscribe_request_is_ndjson_line():
    req = we.subscribe_request([{"type": "pane.agent_status_changed", "pane_id": "w1:p1"}])
    assert req.endswith("\n")
    data = json.loads(req)
    assert data["method"] == "events.subscribe"
    assert data["params"]["subscriptions"][0]["pane_id"] == "w1:p1"


def test_pane_list_request_is_ndjson_line():
    req = we.pane_list_request()
    assert req.endswith("\n")
    data = json.loads(req)
    assert data["method"] == "pane.list"
    assert data["id"] == we.PANE_LIST_ID


def test_is_ack_matches_own_ids_only():
    assert we.is_ack(json.dumps({"id": we.SUB_ID, "result": {"type": "subscription_started"}}))
    assert we.is_ack(json.dumps({"id": we.PANE_LIST_ID, "result": {}}))
    assert not we.is_ack(json.dumps({"event": "pane.agent_status_changed", "data": {}}))
    assert not we.is_ack("not json")


def test_is_ack_suppresses_error_response_with_empty_id():
    """リクエストを解釈できないときサーバは id 空でエラーを返す（イベントではない）。"""
    line = json.dumps(
        {"id": "", "error": {"code": "invalid_request", "message": "missing field `pane_id`"}}
    )
    assert we.is_ack(line)


def test_parse_pane_list():
    line = json.dumps(
        {
            "id": we.PANE_LIST_ID,
            "result": {
                "type": "pane_list",
                "panes": [{"pane_id": "wA:p1"}, {"pane_id": "wA:pA"}],
            },
        }
    )
    assert we.parse_pane_list(line) == ["wA:p1", "wA:pA"]
    assert we.parse_pane_list(json.dumps({"id": "other", "result": {}})) is None
    assert we.parse_pane_list("not json") is None


def test_parse_agent_detected():
    """event 系はアンダースコア記法（`pane_agent_detected`）で届く（実測形）。"""
    line = json.dumps(
        {
            "event": "pane_agent_detected",
            "data": {
                "type": "pane_agent_detected",
                "pane_id": "wA:p3",
                "agent": "claude",
                "workspace_id": "wA",
            },
        }
    )
    assert we.parse_agent_detected(line) == "wA:p3"
    assert we.parse_agent_detected(json.dumps({"event": "pane.agent_status_changed"})) is None
    assert (
        we.parse_agent_detected(
            json.dumps({"event": "pane_created", "data": {"pane": {"pane_id": "wA:p3"}}})
        )
        is None
    )
    assert we.parse_agent_detected("not json") is None


def test_follow_mode_subscription_set_is_single_request():
    """自動追随の購読は 1 リクエストにまとめる（1 接続 1 subscribe の制約）。

    herdr は同一接続への 2 回目の events.subscribe で接続をリセットするため、
    pane ごとの購読と pane.agent_detected を 1 つの subscriptions 配列へ
    積む必要がある。
    """
    subs = we.build_subscriptions([], ["wA:p1", "wA:pA"], ["blocked"])
    subs.append(we.agent_detected_subscription())
    assert len(subs) == 3
    assert {"type": "pane.agent_detected"} in subs
    assert all("pane_id" in s for s in subs if s["type"] != "pane.agent_detected")

    line = we.subscribe_request(subs)
    assert line.endswith("\n")
    assert len(line.splitlines()) == 1
    assert len(json.loads(line)["params"]["subscriptions"]) == 3


def test_is_stale_pane_error():
    """pane_not_found は購読全体を失敗させるので張り直しで回復する。"""
    line = json.dumps(
        {
            "id": "lane-ops-watch:sub:1:probe",
            "error": {"code": "pane_not_found", "message": "pane wA:p5 not found"},
        }
    )
    assert we.is_stale_pane_error(line)
    other = json.dumps({"id": "x", "error": {"code": "invalid_request", "message": "nope"}})
    assert not we.is_stale_pane_error(other)
    assert not we.is_stale_pane_error(json.dumps({"event": "pane.agent_status_changed"}))
    assert not we.is_stale_pane_error("not json")


def test_agent_statuses_matches_schema():
    assert set(we.agent_statuses()) == {"idle", "working", "blocked", "done", "unknown"}


def test_parse_args_include_self_flag():
    assert we.parse_args(["watch_events.py"]).include_self is False
    assert we.parse_args(["watch_events.py", "--include-self"]).include_self is True


def test_parse_args_once_flag():
    """--once は最初のマッチで exit 0 する（Monitor 無しセッションの push 通知用）。"""
    assert we.parse_args(["watch_events.py"]).once is False
    assert we.parse_args(["watch_events.py", "--once"]).once is True


def test_self_pane_excluded_by_default():
    """親自身の pane は既定で購読対象から外す（自己ノイズ対策）。"""
    env = {"HERDR_PANE_ID": "w1:p2"}
    assert we.self_pane_to_exclude(False, env) == "w1:p2"
    assert we.self_pane_to_exclude(True, env) == ""
    assert we.self_pane_to_exclude(False, {}) == ""
