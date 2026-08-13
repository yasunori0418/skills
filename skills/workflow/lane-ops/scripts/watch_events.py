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
- --pane / --status を付けるとその組み合わせに絞る（省略 = 全 pane / 全状態）
- ソケットは $HERDR_SOCKET_PATH（herdr が pane へ注入する）を使う

出力: 購読 ack を除く受信行をそのまま 1 行ずつ flush 付きで出力。
接続が切れたら exit 1（呼び出し側が再起動を判断する）。
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys

DEFAULT_TYPE = "pane.agent_status_changed"
SUB_ID = "lane-ops-watch"


def build_subscriptions(
    types: list[str], panes: list[str], statuses: list[str]
) -> list[dict]:
    """購読リストの構築（純粋）。type × pane × status の直積。

    pane / status が空ならそのキーを付けず「全対象」を購読する。
    """
    subs = []
    for t in types or [DEFAULT_TYPE]:
        for pane in panes or [None]:
            for status in statuses or [None]:
                sub: dict = {"type": t}
                if pane:
                    sub["pane_id"] = pane
                if status:
                    sub["agent_status"] = status
                subs.append(sub)
    return subs


def subscribe_request(subs: list[dict]) -> str:
    """subscribe リクエスト行（NDJSON 1 行）。"""
    return (
        json.dumps(
            {"id": SUB_ID, "method": "events.subscribe", "params": {"subscriptions": subs}},
            ensure_ascii=False,
        )
        + "\n"
    )


def is_ack(line: str) -> bool:
    """自分の subscribe への応答行か（イベント行と区別する）。"""
    try:
        data = json.loads(line)
    except json.JSONDecodeError:
        return False
    return isinstance(data, dict) and data.get("id") == SUB_ID


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="watch_events.py", description="herdr socket API イベント購読フィルタ"
    )
    parser.add_argument("--pane", action="append", default=[], metavar="PANE_ID")
    parser.add_argument("--status", action="append", default=[], metavar="STATUS")
    parser.add_argument("--type", action="append", default=[], metavar="EVENT_TYPE")
    ns = parser.parse_args(argv[1:])

    sock_path = os.environ.get("HERDR_SOCKET_PATH", "")
    if not sock_path:
        print(
            "ERROR: HERDR_SOCKET_PATH が無い（herdr 管理下の pane で実行すること）",
            file=sys.stderr,
        )
        return 1

    subs = build_subscriptions(ns.type, ns.pane, ns.status)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(sock_path)
        s.sendall(subscribe_request(subs).encode("utf-8"))
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                print("ERROR: herdr socket が切断された", file=sys.stderr)
                return 1
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                text = line.decode("utf-8", errors="replace").strip()
                if not text or is_ack(text):
                    continue
                print(text, flush=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
