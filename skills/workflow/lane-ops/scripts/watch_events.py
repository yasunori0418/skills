#!/usr/bin/env python3
"""herdr socket API のイベント購読フィルタ（長寿命）。

herdr の socket（NDJSON over Unix domain socket）へ `events.subscribe` を送り、
届いたイベントを 1 行 1 JSON で stdout へ流し続ける。標準の用途は
エージェント状態変化（`pane.agent_status_changed`）の push 監視で、
レーンごとに `herdr agent wait` プロセスを並べる代わりに本スクリプト 1 本で
全レーンを見張れる（Monitor / バックグラウンド Bash から persistent に使う）。

使い方:
    python3 watch_events.py [--pane <pane_id>]... [--status <status>]... \
        [--type <event_type>]...

- --type 省略時は pane.agent_status_changed を購読する
- --status を付けるとその状態に絞る（省略 = 全状態）
- **--pane 省略時は全 pane を自動追随する**: `pane.list` で既存 pane を列挙して
  購読し、併せて `pane.agent_detected`（グローバル購読・pane_id 不要）を購読する。
  エージェントが載った pane が現れたら購読ストリームを張り直して取り込む
  （後から起動したレーンも取りこぼさない）。--pane を明示したときは
  その pane だけを購読し、自動追随はしない。
- ソケットは $HERDR_SOCKET_PATH（herdr が pane へ注入する）を使う

追随トリガーに `pane.created` を使ってはならない（過去の欠陥）。`tab create` 等の
pane 生成とエージェント起動は別ステップで、pane_created の時点ではエージェントが
まだ載っていない。そこで agent 有無を確認して見送ると、後から claude が起動しても
再購読の契機が二度と来ず、そのレーンの blocked を取りこぼす（実運用で発生）。
`pane.agent_detected` は「エージェントが載った瞬間」に配信されるため競合が無く、
コマンド実行用の短命 pane（エージェントが載らない）による張り直しチャーンも
構造的に起きない。

出力: 購読 ack と内部管理用イベントを除く受信行をそのまま 1 行ずつ flush 付きで
出力。接続が切れたら exit 1（呼び出し側が再起動を判断する）。

herdr socket の実測制約（protocol 19。スキーマには現れない）:

- **1 接続につき `events.subscribe` は 1 回だけ**。2 回目を送ると herdr は接続を
  リセットする（`ConnectionResetError`）。購読を増やすには接続を張り直す
- **購読を張った接続では他メソッドを呼べない**。`pane.list` 等を後から送ると
  同様にリセットされる。列挙は購読前・別接続で行う
- 1 リクエストの `subscriptions` 配列に複数要素を積むのは可

型は herdr の公式スキーマ（`herdr api schema --json`、protocol 19）に対応する。
購読 type はドット記法（`pane.agent_status_changed`）だが、配信 envelope の
`event` 値は系統によって異なる:

- subscription_event 系（`pane.output_matched` / `pane.agent_status_changed` /
  `pane.scroll_changed`）はドット記法のまま届く
- event 系（`pane_created` 等のライフサイクル）はアンダースコア記法で届く

このため受信側の型は 2 系統を分けて表現する。
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from dataclasses import dataclass
from typing import Literal, NotRequired, TypedDict, get_args

# ---------------------------------------------------------------------------
# herdr API 型（`herdr api schema --json` / protocol 19 に対応）
# ---------------------------------------------------------------------------

AgentStatus = Literal["idle", "working", "blocked", "done", "unknown"]
"""schemas.subscription_event.$defs.AgentStatus"""

SubscriptionEventKind = Literal[
    "pane.output_matched",
    "pane.agent_status_changed",
    "pane.scroll_changed",
]
"""購読由来イベントの kind。配信 envelope でもドット記法のまま届く。"""


class AgentStatusSubscription(TypedDict):
    """schemas.request.$defs.Subscription（pane.agent_status_changed 版）。

    `pane_id` はスキーマ上 **required**。省略すると herdr は
    `invalid_request: missing field 'pane_id'` を返して購読が成立しない。
    """

    type: Literal["pane.agent_status_changed"]
    pane_id: str
    agent_status: NotRequired[AgentStatus]


class PaneScopedSubscription(TypedDict):
    """pane_id を要求するその他の購読（pane.scroll_changed 等）。"""

    type: str
    pane_id: str
    agent_status: NotRequired[AgentStatus]


class GlobalSubscription(TypedDict):
    """pane_id を取らない購読（`pane.created` 等のライフサイクル系）。"""

    type: str


Subscription = AgentStatusSubscription | PaneScopedSubscription | GlobalSubscription


class EventsSubscribeParams(TypedDict):
    """schemas.request.$defs.EventsSubscribeParams"""

    subscriptions: list[Subscription]


class EventsSubscribeRequest(TypedDict):
    """`events.subscribe` リクエスト（NDJSON 1 行分）。"""

    id: str
    method: Literal["events.subscribe"]
    params: EventsSubscribeParams


class PaneListParams(TypedDict):
    """schemas.request.$defs.PaneListParams"""

    workspace_id: NotRequired[str | None]


class PaneListRequest(TypedDict):
    """`pane.list` リクエスト（起動時の pane 列挙に使う）。"""

    id: str
    method: Literal["pane.list"]
    params: PaneListParams


class PaneAgentStatusChangedData(TypedDict):
    """schemas.subscription_event.$defs.PaneAgentStatusChangedEvent

    required は pane_id / workspace_id / agent_status の 3 つ。実配信でも
    任意フィールドは省略されて届く。
    """

    pane_id: str
    workspace_id: str
    agent_status: AgentStatus
    agent: NotRequired[str | None]
    display_agent: NotRequired[str | None]
    title: NotRequired[str | None]
    state_labels: NotRequired[dict[str, str]]


class PaneAgentDetectedData(TypedDict):
    """`pane_agent_detected` イベントのデータ（必要なキーのみ）。

    実測（protocol 19）: {"agent": "claude", "pane_id": "w1:p2",
    "type": "pane_agent_detected", "workspace_id": "w1"} の形で届く。
    """

    type: Literal["pane_agent_detected"]
    pane_id: str
    agent: NotRequired[str]
    workspace_id: NotRequired[str]


class SubscriptionEventEnvelope(TypedDict):
    """schemas.subscription_event（SubscriptionEventEnvelope）。"""

    event: SubscriptionEventKind
    data: PaneAgentStatusChangedData


class PaneAgentDetectedEnvelope(TypedDict):
    """schemas.event（EventEnvelope）のうち本スクリプトが解釈する種別。"""

    event: Literal["pane_agent_detected"]
    data: PaneAgentDetectedData


class SuccessResponse(TypedDict):
    """schemas.success_response（購読 ack 等）。"""

    id: str
    result: dict[str, object]


class ErrorBody(TypedDict):
    code: str
    message: str


class ErrorResponse(TypedDict):
    """schemas.error_response。id はサーバがリクエストを解釈できないとき空になる。"""

    id: str
    error: ErrorBody


DEFAULT_TYPE = "pane.agent_status_changed"
SUB_ID = "lane-ops-watch"
PANE_LIST_ID = "lane-ops-pane-list"
AGENT_DETECTED_EVENT = "pane_agent_detected"
RESUBSCRIBE_DELAY_SEC = 0.5

# pane_id が required な購読 type（pane 未指定時は pane 列挙が必要になる）。
PANE_SCOPED_TYPES = frozenset(
    {"pane.agent_status_changed", "pane.scroll_changed", "pane.output_matched"}
)


@dataclass(frozen=True)
class Options:
    """CLI 引数のパース結果。

    panes が空なら自動追随モード（`pane.list` で全 pane を購読し、
    エージェントが載った pane を `pane.agent_detected` 経由で取り込む）。
    """

    panes: tuple[str, ...] = ()
    statuses: tuple[AgentStatus, ...] = ()
    types: tuple[str, ...] = (DEFAULT_TYPE,)

    @property
    def follow(self) -> bool:
        """全 pane 自動追随モードか（--pane 明示時はその pane に固定する）。"""
        return not self.panes


def parse_args(argv: list[str]) -> Options:
    """コマンドライン引数 -> Options（純粋: パースのみ）。

    --status は AgentStatus の値だけを受け付ける（不正値はサーバ往復前に弾く）。
    """
    parser = argparse.ArgumentParser(
        prog="watch_events.py", description="herdr socket API イベント購読フィルタ"
    )
    parser.add_argument("--pane", action="append", default=[], metavar="PANE_ID")
    parser.add_argument(
        "--status",
        action="append",
        default=[],
        metavar="STATUS",
        choices=agent_statuses(),
    )
    parser.add_argument("--type", action="append", default=[], metavar="EVENT_TYPE")
    ns = parser.parse_args(argv[1:])
    return Options(
        panes=tuple(ns.pane),
        statuses=tuple(ns.status),
        types=tuple(ns.type) or (DEFAULT_TYPE,),
    )


def build_subscriptions(
    types: list[str], panes: list[str], statuses: list[AgentStatus]
) -> list[Subscription]:
    """購読リストの構築（純粋）。type × pane × status の直積。

    pane_id を要求する type は pane ごとに 1 件ずつ展開する。pane が空のとき
    その type は展開できない（呼び出し側が `pane.list` で解決してから渡す）。
    pane を取らない type（`pane.created` 等）は 1 件だけ積む。
    """
    subs: list[Subscription] = []
    for t in types or [DEFAULT_TYPE]:
        if t not in PANE_SCOPED_TYPES:
            global_sub: GlobalSubscription = {"type": t}
            subs.append(global_sub)
            continue
        for pane in panes:
            for status in statuses or [None]:
                sub: PaneScopedSubscription = {"type": t, "pane_id": pane}
                if status is not None:
                    sub["agent_status"] = status
                subs.append(sub)
    return subs


def agent_statuses() -> tuple[AgentStatus, ...]:
    """AgentStatus の許容値（argparse の choices と実行時検証に使う）。"""
    return get_args(AgentStatus)


def subscribe_request(subs: list[Subscription], sub_id: str = SUB_ID) -> str:
    """subscribe リクエスト行（NDJSON 1 行）。"""
    req: EventsSubscribeRequest = {
        "id": sub_id,
        "method": "events.subscribe",
        "params": {"subscriptions": subs},
    }
    return json.dumps(req, ensure_ascii=False) + "\n"


def pane_list_request() -> str:
    """`pane.list` リクエスト行（NDJSON 1 行）。"""
    req: PaneListRequest = {"id": PANE_LIST_ID, "method": "pane.list", "params": {}}
    return json.dumps(req, ensure_ascii=False) + "\n"


def agent_detected_subscription() -> Subscription:
    """エージェント搭載 pane の追随用購読（pane_id を取らない）。

    `pane.created` ではなくこちらを使う。pane 生成時点ではエージェントが
    載っておらず、そこで判定すると後から起動したエージェントを永久に
    取りこぼす（モジュール docstring 参照）。
    """
    return {"type": "pane.agent_detected"}


def is_ack(line: str) -> bool:
    """自分の subscribe / pane.list への応答行か（イベント行と区別する）。

    サーバがリクエストを解釈できなかったときのエラー応答は id が空文字で返るが、
    `error` を持つ行はイベントではないので同様に抑止する。
    """
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        return False
    if not isinstance(data, dict):
        return False
    if data.get("id") in {SUB_ID, PANE_LIST_ID}:
        return True
    return "error" in data and "id" in data


def parse_pane_list(line: str) -> list[str] | None:
    """`pane.list` 応答なら pane_id の一覧を返す。該当しなければ None。"""
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or data.get("id") != PANE_LIST_ID:
        return None
    result = data.get("result")
    if not isinstance(result, dict):
        return None
    panes = result.get("panes")
    if not isinstance(panes, list):
        return None
    return [p["pane_id"] for p in panes if isinstance(p, dict) and p.get("pane_id")]


def parse_agent_detected(line: str) -> str | None:
    """`pane_agent_detected` イベントなら対象 pane_id を返す。該当しなければ None。"""
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or data.get("event") != AGENT_DETECTED_EVENT:
        return None
    body = data.get("data")
    if not isinstance(body, dict):
        return None
    pane_id = body.get("pane_id")
    return pane_id if isinstance(pane_id, str) and pane_id else None


def list_panes(sock_path: str) -> list[str]:
    """短命接続で `pane.list` を叩き pane_id を列挙する。

    購読を張った接続では他メソッドを呼べない（herdr が接続をリセットする）ため、
    列挙は必ず購読前・別接続で行う。
    """
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(sock_path)
        s.sendall(pane_list_request().encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                return []
            buf += chunk
        line = buf.split(b"\n", 1)[0].decode("utf-8", errors="replace").strip()
        return parse_pane_list(line) or []


def is_stale_pane_error(line: str) -> bool:
    """購読対象の pane が既に消えていることを示すエラー行か。

    herdr は購読リクエストに 1 件でも実在しない pane が混ざると
    `pane_not_found` を返し、**購読全体を失敗させて接続を閉じる**。列挙から
    購読確立までの間に pane が消えると起きるため、張り直しで回復する。
    """
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        return False
    if not isinstance(data, dict):
        return False
    error = data.get("error")
    return isinstance(error, dict) and error.get("code") == "pane_not_found"


def stream_events(
    sock_path: str, subs: list[Subscription], known: set[str] | None
) -> str | None:
    """購読ストリームを 1 本張り、受信行を stdout へ流す。

    known が渡されたとき（自動追随モード）は `pane_agent_detected` を監視し、
    未知の pane にエージェントが載ったらその pane_id を返して呼び出し側に
    張り直しを促す。herdr は 1 接続につき `events.subscribe` を 1 回しか
    受け付けないため、購読の追加は「新しい接続を張り直す」以外に方法がない。

    消えた pane による `pane_not_found` も張り直しで回復する（そのままだと
    購読が成立せず接続が閉じられる）。

    戻り値: pane_id = その pane を取り込むため張り直す / "" = 理由を特定しない
    張り直し（stale pane の回復）/ None = 接続断（回復不能）
    """
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(sock_path)
        s.sendall(subscribe_request(subs).encode("utf-8"))
        buf = b""
        while True:
            try:
                chunk = s.recv(65536)
            except ConnectionResetError:
                return None
            if not chunk:
                return None
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode("utf-8", errors="replace").strip()
                if not text:
                    continue

                if known is not None:
                    if is_stale_pane_error(text):
                        # 購読は成立していない。列挙し直して張り直す。
                        return ""
                    detected = parse_agent_detected(text)
                    if detected is not None:
                        if detected not in known:
                            # イベント自体がエージェント搭載の証明なので、
                            # pane.get での在否確認は不要（確認を挟むと
                            # 検出タイミングによっては見送りが起きる）。
                            return detected
                        continue

                if is_ack(text):
                    continue
                print(text, flush=True)


def main(argv: list[str]) -> int:
    opts = parse_args(argv)

    sock_path = os.environ.get("HERDR_SOCKET_PATH", "")
    if not sock_path:
        print(
            "ERROR: HERDR_SOCKET_PATH が無い（herdr 管理下の pane で実行すること）",
            file=sys.stderr,
        )
        return 1

    types = list(opts.types)
    statuses = list(opts.statuses)
    follow = opts.follow
    known: set[str] = set(opts.panes)

    # 張り直しのきっかけになったが、次の列挙には現れなかった pane。
    # エージェント検出の直後に pane ごと消えた場合の保険で、以後は張り直しの
    # トリガーにしない（同じ pane で無限に張り直すのを防ぐ）。
    ignored: set[str] = set()

    while True:
        if follow:
            # 購読を張る前に毎回列挙し直す（購読後は同一接続で他メソッドを呼べない）。
            # 消えた pane を購読対象に残すと購読ごと失敗するため、列挙結果で置き換える。
            known = set(list_panes(sock_path))
        subs = build_subscriptions(types, sorted(known), statuses)
        if follow:
            # エージェントが載った pane は購読ストリームを張り直して取り込む。
            subs.append(agent_detected_subscription())
        if not subs:
            print(
                "ERROR: 購読対象が無い（--pane を指定するか herdr 管理下で実行すること）",
                file=sys.stderr,
            )
            return 1

        trigger = stream_events(sock_path, subs, (known | ignored) if follow else None)
        if trigger is None:
            print("ERROR: herdr socket が切断された", file=sys.stderr)
            return 1
        if follow and trigger and trigger not in known:
            # 張り直しのきっかけになった pane が次の列挙にも現れなければ、
            # 購読が成立する前に消えた pane。以後は無視して張り直しを止める。
            ignored.add(trigger)
        # 張り直しが密に走らないよう、間隔を空けて列挙し直す。
        time.sleep(RESUBSCRIBE_DELAY_SEC)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
