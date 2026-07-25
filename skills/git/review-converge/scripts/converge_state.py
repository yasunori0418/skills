#!/usr/bin/env python3
"""review-converge の収束ループ制御(決定論 CLI)。

diff-review の周回ごとの指摘一覧を状態ファイルへ記録し、収束・周回上限・振動を
機械判定する。判定と記録だけを行い、レビュー・修正・git 操作は一切しない(read-only
に近い。書き込むのは --state で指定された状態ファイルのみ)。

サブコマンド:

    converge_state.py record --state <path> [--head <sha>] [--threshold want]
                             [--max-rounds 5] < findings.json
        1 周回分の指摘を記録し、判定結果を JSON で stdout に出す。
        stdin は指摘の JSON 配列(または {"findings": [...]})。各要素:
            {"file": "src/a.py", "line": 42, "summary": "...",
             "severity": "must", "scope": "in"}
        severity は must / want+ / want / nit(既定 want)。
        scope は in / out(既定 in。out = タスク境界外 = 修正対象から除外)。
        指摘は file:line + 要旨の正規化ハッシュで同一性を判定する。

    converge_state.py status --state <path>
        直近の判定結果を再出力する(記録はしない)。

    converge_state.py prev-head --state <path>
        前周回の head sha を stdout に出す(未記録なら空文字・exit 1)。
        2 周目以降の差分レビュー最適化に使う。

    converge_state.py reset --state <path>
        状態ファイルを削除して収束ループを初期化する。

判定 verdict(record / status の "verdict"):

    converged       閾値以上の重みの境界内指摘がゼロ。ループを終了する
    continue        まだ閾値以上の指摘がある。次の周回へ進む
    limit-reached   周回上限(既定 5)に到達。ユーザーへエスカレーションする
    oscillation     振動を検出。ユーザーへエスカレーションする
                    - 同一指摘が 2 周連続で未解消(stuck)
                    - 一度消えた指摘が再出現(reappeared)
                    "oscillating" にどの指摘かを列挙する

verdict の優先順位は oscillation > converged > limit-reached > continue。
振動していても閾値以上の指摘が消えていれば収束を優先しないのは、打ち消し合いが
起きた状態のまま終わらせないため。

依存は標準ライブラリのみ(Python 3.12+)。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

SEVERITY_ORDER = ["nit", "want", "want+", "must"]
DEFAULT_THRESHOLD = "want"
DEFAULT_MAX_ROUNDS = 5
STATE_VERSION = 1


def severity_rank(severity: str) -> int:
    """severity の重み。未知の値は最も重い must 扱い(見落としを避ける)。"""
    s = (severity or "").strip().lower()
    if s in SEVERITY_ORDER:
        return SEVERITY_ORDER.index(s)
    return SEVERITY_ORDER.index("must")


def normalize_summary(summary: str) -> str:
    """要旨を正規化する。空白の揺れ・句読点や記号・大小文字差では別指摘と見なさない。

    `\\w` は Unicode 対応なので日本語(漢字・かな)はそのまま残り、句読点・括弧・
    記号だけが落ちる。空白は全角含めて**すべて除去**する: 日本語の要旨では空白の
    有無が意味を持たず、「同じ指摘の言い回しの揺れ」を別指摘と誤検出しないため。
    """
    s = (summary or "").lower()
    return re.sub(r"[^\w]+", "", s, flags=re.UNICODE)


def finding_key(finding: dict[str, Any]) -> str:
    """file:line + 正規化要旨のハッシュ。周回をまたいだ同一性判定に使う。"""
    path = str(finding.get("file", "")).strip()
    line = str(finding.get("line", "")).strip()
    body = normalize_summary(str(finding.get("summary", "")))
    raw = f"{path}:{line}:{body}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def parse_findings(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, dict):
        payload = payload.get("findings", [])
    if not isinstance(payload, list):
        raise ValueError("findings は JSON 配列、または {\"findings\": [...]} で渡すこと")
    out: list[dict[str, Any]] = []
    for item in payload:
        if not isinstance(item, dict):
            raise ValueError(f"指摘は object であること: {item!r}")
        scope = str(item.get("scope", "in")).strip().lower()
        if scope not in ("in", "out"):
            raise ValueError(f"scope は in / out のいずれか: {scope!r}")
        out.append(
            {
                "key": finding_key(item),
                "file": str(item.get("file", "")),
                "line": item.get("line"),
                "summary": str(item.get("summary", "")),
                "severity": str(item.get("severity", DEFAULT_THRESHOLD)),
                "scope": scope,
            }
        )
    return out


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": STATE_VERSION, "rounds": []}
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise SystemExit(f"ERROR: 状態ファイルが壊れている ({path}): {e}")
    if not isinstance(state, dict) or "rounds" not in state:
        raise SystemExit(f"ERROR: 状態ファイルの形式が不正: {path}")
    return state


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def actionable(findings: list[dict[str, Any]], threshold: str) -> list[dict[str, Any]]:
    """閾値以上の重みを持つ「境界内」指摘。境界外は修正対象から機械的に除外する。"""
    limit = severity_rank(threshold)
    return [f for f in findings if f["scope"] == "in" and severity_rank(f["severity"]) >= limit]


def detect_oscillation(rounds: list[dict[str, Any]], threshold: str) -> list[dict[str, Any]]:
    """振動の検出。対象は閾値以上・境界内の指摘のみ。

    - stuck:      同一指摘が直近 2 周連続で未解消
    - reappeared: 一度消えた指摘が後の周回で再出現
    """
    if len(rounds) < 2:
        return []

    per_round: list[dict[str, dict[str, Any]]] = []
    for r in rounds:
        actionable_map = {f["key"]: f for f in actionable(r["findings"], threshold)}
        per_round.append(actionable_map)

    oscillating: dict[str, dict[str, Any]] = {}

    # stuck: 直近 2 周の両方に存在する
    last, prev = per_round[-1], per_round[-2]
    for key, finding in last.items():
        if key in prev:
            oscillating[key] = {
                "kind": "stuck",
                "rounds": [len(rounds) - 1, len(rounds)],
                **{k: finding[k] for k in ("file", "line", "summary", "severity")},
            }

    # reappeared: ある周回で消えた(直前にあり当該周回に無い)後、later で再び現れる
    for idx in range(1, len(per_round)):
        for key in per_round[idx]:
            earlier = [i for i in range(idx) if key in per_round[i]]
            if not earlier:
                continue
            # 直前の周回に無ければ「一度消えて再出現した」
            if key not in per_round[idx - 1]:
                finding = per_round[idx][key]
                oscillating[key] = {
                    "kind": "reappeared",
                    "rounds": [earlier[-1] + 1, idx + 1],
                    **{k: finding[k] for k in ("file", "line", "summary", "severity")},
                }

    return sorted(oscillating.values(), key=lambda f: (f["kind"], f["file"], str(f["line"])))


def evaluate(state: dict[str, Any]) -> dict[str, Any]:
    rounds = state["rounds"]
    threshold = state.get("threshold", DEFAULT_THRESHOLD)
    max_rounds = state.get("max_rounds", DEFAULT_MAX_ROUNDS)
    current = rounds[-1]

    remaining = actionable(current["findings"], threshold)
    deferred = [f for f in current["findings"] if f["scope"] == "out"]
    oscillating = detect_oscillation(rounds, threshold)

    if oscillating:
        verdict = "oscillation"
    elif not remaining:
        verdict = "converged"
    elif len(rounds) >= max_rounds:
        verdict = "limit-reached"
    else:
        verdict = "continue"

    return {
        "verdict": verdict,
        "round": len(rounds),
        "max_rounds": max_rounds,
        "threshold": threshold,
        "head": current.get("head"),
        "prev_head": rounds[-2].get("head") if len(rounds) >= 2 else None,
        "remaining": remaining,
        "remaining_count": len(remaining),
        "deferred": deferred,
        "deferred_count": len(deferred),
        "oscillating": oscillating,
    }


def cmd_record(args: argparse.Namespace) -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        raw = "[]"
    try:
        findings = parse_findings(json.loads(raw))
    except (json.JSONDecodeError, ValueError) as e:
        print(f"ERROR: 指摘 JSON の解析に失敗: {e}", file=sys.stderr)
        return 2

    path = Path(args.state)
    state = load_state(path)
    state["version"] = STATE_VERSION
    state["threshold"] = args.threshold
    state["max_rounds"] = args.max_rounds
    state["rounds"].append({"head": args.head, "findings": findings})

    result = evaluate(state)
    state["last_result"] = result
    save_state(path, state)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    path = Path(args.state)
    if not path.exists():
        print(f"ERROR: 状態ファイルが無い: {path}", file=sys.stderr)
        return 1
    state = load_state(path)
    if not state["rounds"]:
        print(f"ERROR: 記録された周回が無い: {path}", file=sys.stderr)
        return 1
    print(json.dumps(evaluate(state), ensure_ascii=False, indent=2))
    return 0


def cmd_prev_head(args: argparse.Namespace) -> int:
    path = Path(args.state)
    if not path.exists():
        return 1
    state = load_state(path)
    if not state["rounds"]:
        return 1
    head = state["rounds"][-1].get("head")
    if not head:
        return 1
    print(head)
    return 0


def cmd_reset(args: argparse.Namespace) -> int:
    path = Path(args.state)
    path.unlink(missing_ok=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="converge_state.py",
        description="review-converge の収束ループ制御(決定論)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_record = sub.add_parser("record", help="1 周回分の指摘を記録して判定する")
    p_record.add_argument("--state", required=True, help="状態ファイルのパス(JSON)")
    p_record.add_argument("--head", default=None, help="この周回の head sha")
    p_record.add_argument(
        "--threshold",
        default=DEFAULT_THRESHOLD,
        choices=SEVERITY_ORDER,
        help=f"収束閾値(既定 {DEFAULT_THRESHOLD})",
    )
    p_record.add_argument(
        "--max-rounds",
        type=int,
        default=DEFAULT_MAX_ROUNDS,
        help=f"周回上限(既定 {DEFAULT_MAX_ROUNDS})",
    )
    p_record.set_defaults(func=cmd_record)

    p_status = sub.add_parser("status", help="直近の判定結果を再出力する")
    p_status.add_argument("--state", required=True)
    p_status.set_defaults(func=cmd_status)

    p_prev = sub.add_parser("prev-head", help="前周回の head sha を出力する")
    p_prev.add_argument("--state", required=True)
    p_prev.set_defaults(func=cmd_prev_head)

    p_reset = sub.add_parser("reset", help="状態ファイルを削除する")
    p_reset.add_argument("--state", required=True)
    p_reset.set_defaults(func=cmd_reset)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
