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
  購読し、併せて `pane.created` を購読する。新 pane が現れたら購読ストリームを
  張り直して取り込む（後から起動したレーンも取りこぼさない）。ただし取り込むのは
  **エージェントが載っている pane だけ**で、コマンド実行用の短命 pane は
  `pane.get` で除外する（それらで張り直すと購読が切れ続けて本来のイベントを
  取りこぼす）。--pane を明示したときはその pane だけを購読し、自動追随はしない。
- ソケットは $HERDR_SOCKET_PATH（herdr が pane へ注入する）を使う

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


class PaneGetParams(TypedDict):
    """schemas.request.$defs（pane.get のパラメータ）。"""

    pane_id: str


class PaneGetRequest(TypedDict):
    """`pane.get` リクエスト（pane にエージェントが載っているかの判定に使う）。"""

    id: str
    method: Literal["pane.get"]
    params: PaneGetParams


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


class PaneCreatedPane(TypedDict):
    """`pane_created` イベントが載せる pane 情報（必要なキーのみ）。"""

    pane_id: str
    workspace_id: NotRequired[str]
    tab_id: NotRequired[str]
    agent_status: NotRequired[AgentStatus]


class PaneCreatedData(TypedDict):
    """schemas.event.$defs 側の pane_created データ。"""

    type: Literal["pane_created"]
    pane: PaneCreatedPane


class SubscriptionEventEnvelope(TypedDict):
    """schemas.subscription_event（SubscriptionEventEnvelope）。"""

    event: SubscriptionEventKind
    data: PaneAgentStatusChangedData


class PaneCreatedEnvelope(TypedDict):
    """schemas.event（EventEnvelope）のうち本スクリプトが解釈する種別。"""

    event: Literal["pane_created"]
    data: PaneCreatedData


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
PANE_GET_ID = "lane-ops-pane-get"
PANE_CREATED_EVENT = "pane_created"
RESUBSCRIBE_DELAY_SEC = 0.5

# pane_id が required な購読 type（pane 未指定時は pane 列挙が必要になる）。
PANE_SCOPED_TYPES = frozenset(
    {"pane.agent_status_changed", "pane.scroll_changed", "pane.output_matched"}
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


def pane_created_subscription() -> Subscription:
    """新 pane 追随用の購読（pane_id を取らない）。"""
    return {"type": "pane.created"}


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
    if data.get("id") in {SUB_ID, PANE_LIST_ID, PANE_GET_ID}:
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


def parse_pane_created(line: str) -> str | None:
    """`pane_created` イベントなら新 pane の pane_id を返す。該当しなければ None。"""
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or data.get("event") != PANE_CREATED_EVENT:
        return None
    body = data.get("data")
    if not isinstance(body, dict):
        return None
    pane = body.get("pane")
    if not isinstance(pane, dict):
        return None
    pane_id = pane.get("pane_id")
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


def pane_get_request(pane_id: str) -> str:
    """`pane.get` リクエスト行（NDJSON 1 行）。"""
    req: PaneGetRequest = {
        "id": PANE_GET_ID,
        "method": "pane.get",
        "params": {"pane_id": pane_id},
    }
    return json.dumps(req, ensure_ascii=False) + "\n"


def parse_pane_agent(line: str) -> str | None:
    """`pane.get` 応答なら pane に載っているエージェント名を返す。

    エージェント不在（シェルだけの pane）や応答不一致のときは None。
    """
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or data.get("id") != PANE_GET_ID:
        return None
    result = data.get("result")
    if not isinstance(result, dict):
        return None
    pane = result.get("pane")
    if not isinstance(pane, dict):
        return None
    agent = pane.get("agent")
    return agent if isinstance(agent, str) and agent else None


def pane_has_agent(sock_path: str, pane_id: str) -> bool:
    """pane にエージェントが載っているか（短命なコマンド実行 pane を除外する）。

    購読ストリームとは別接続で問い合わせる（購読済み接続では他メソッドを
    呼べない）。pane が既に消えていれば False。
    """
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.connect(sock_path)
            s.sendall(pane_get_request(pane_id).encode("utf-8"))
            buf = b""
            while b"\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    return False
                buf += chunk
            line = buf.split(b"\n", 1)[0].decode("utf-8", errors="replace").strip()
            return parse_pane_agent(line) is not None
    except OSError:
        return False


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

    known が渡されたとき（自動追随モード）は `pane_created` を監視し、未知の
    pane が現れたらその pane_id を返して呼び出し側に張り直しを促す。herdr は
    1 接続につき `events.subscribe` を 1 回しか受け付けないため、購読の追加は
    「新しい接続を張り直す」以外に方法がない。

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
                    created = parse_pane_created(text)
                    if created is not None:
                        if created not in known and pane_has_agent(sock_path, created):
                            # エージェントが載っている pane だけ取り込む。
                            # コマンド実行用の短命 pane で張り直すと、そのたびに
                            # 購読が切れて本来のイベントを取りこぼす。
                            return created
                        continue

                if is_ack(text):
                    continue
                print(text, flush=True)


def main(argv: list[str]) -> int:
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

    sock_path = os.environ.get("HERDR_SOCKET_PATH", "")
    if not sock_path:
        print(
            "ERROR: HERDR_SOCKET_PATH が無い（herdr 管理下の pane で実行すること）",
            file=sys.stderr,
        )
        return 1

    types: list[str] = ns.type or [DEFAULT_TYPE]
    # argparse の choices で AgentStatus の値だけに絞り込み済み。
    statuses: list[AgentStatus] = ns.status
    # --pane 明示時はその pane に固定し、省略時は pane.list + pane.created で追随する。
    follow = not ns.pane
    known: set[str] = set(ns.pane)

    # 張り直しのきっかけになったが、次の列挙には現れなかった pane。
    # エージェント判定を通った直後に消えた場合の保険で、以後は張り直しの
    # トリガーにしない（同じ pane で無限に張り直すのを防ぐ）。
    ignored: set[str] = set()

    while True:
        if follow:
            # 購読を張る前に毎回列挙し直す（購読後は同一接続で他メソッドを呼べない）。
            # 消えた pane を購読対象に残すと購読ごと失敗するため、列挙結果で置き換える。
            known = set(list_panes(sock_path))
        subs = build_subscriptions(types, sorted(known), statuses)
        if follow:
            # 新 pane は購読ストリームを張り直して取り込む。
            subs.append(pane_created_subscription())
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
            # 購読が成立する前に消えた短命 pane。以後は無視して張り直しを止める。
            ignored.add(trigger)
        # 短命 pane（コマンド実行用の一時 pane 等）が連続生成されると張り直しが
        # 密に走るため、間隔を空けて列挙し直す（落ち着いた状態を購読する）。
        time.sleep(RESUBSCRIBE_DELAY_SEC)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
