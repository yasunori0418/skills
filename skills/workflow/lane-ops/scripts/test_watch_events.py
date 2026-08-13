"""watch_events.py のユニットテスト。購読構築・ack 判定の純粋関数を検証する。"""
from __future__ import annotations

import json

import watch_events as we


def test_default_subscription():
    subs = we.build_subscriptions([], [], [])
    assert subs == [{"type": "pane.agent_status_changed"}]


def test_pane_and_status_product():
    subs = we.build_subscriptions([], ["w1:p1", "w1:p2"], ["blocked"])
    assert {"type": "pane.agent_status_changed", "pane_id": "w1:p1", "agent_status": "blocked"} in subs
    assert {"type": "pane.agent_status_changed", "pane_id": "w1:p2", "agent_status": "blocked"} in subs
    assert len(subs) == 2


def test_custom_type():
    subs = we.build_subscriptions(["worktree.created"], [], [])
    assert subs == [{"type": "worktree.created"}]


def test_subscribe_request_is_ndjson_line():
    req = we.subscribe_request([{"type": "pane.agent_status_changed"}])
    assert req.endswith("\n")
    data = json.loads(req)
    assert data["method"] == "events.subscribe"
    assert data["params"]["subscriptions"][0]["type"] == "pane.agent_status_changed"


def test_is_ack_matches_own_id_only():
    assert we.is_ack(json.dumps({"id": we.SUB_ID, "result": {}}))
    assert not we.is_ack(json.dumps({"event": {"type": "pane.agent_status_changed"}}))
    assert not we.is_ack("not json")
