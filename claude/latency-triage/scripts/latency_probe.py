"""Claude Code の応答遅延・長考・中断を transcript から定量化する診断スクリプト。

依存は Python stdlib のみで自己完結(他スキルへの依存なし)。
生 JSONL を直接 Read/Grep しないための決定論レイヤー。時刻は JST。

usage:
  python3 latency_probe.py                     # 全体サマリ(モデル別分布・長時間イベント・APIエラー)
  python3 latency_probe.py --since 2026-07-01  # 期間を絞る(ファイル最終更新の JST 日付)
  python3 latency_probe.py --session 3e3c06d8  # 個別セッションのタイムライン(遅延の所在特定)
"""

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

JST = timezone(timedelta(hours=9))
BUCKETS = ["<1m", "1-3m", "3-5m", "5-10m", ">10m"]


# ---------- transcript 読み出し(自己完結) ----------


def resolve_config_dir() -> Path:
    env = os.environ.get("CLAUDE_CONFIG_DIR")
    return Path(env).expanduser() if env else Path.home() / ".claude"


def parse_ts(value):
    """ISO 8601 文字列を JST の datetime に。失敗時 None。"""
    if not isinstance(value, str):
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(JST)


def jst_str(dt) -> str:
    return dt.strftime("%Y-%m-%d %H:%M:%S JST") if dt else "-----"


def iter_records(path: Path):
    """JSONL を1行ずつ寛容に読む。壊れた行は捨てる。"""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    yield obj
    except OSError:
        return


def find_session_files(config_dir: Path, project=None, since=None, until=None, session=None):
    """projects/<dir>/<uuid>.jsonl を列挙(最終更新の新しい順)。

    since/until は JST 日付 YYYY-MM-DD(ファイル最終更新で判定、until はその日を含む)。
    """
    projects_dir = config_dir / "projects"
    if not projects_dir.is_dir():
        return []
    since_dt = datetime.strptime(since, "%Y-%m-%d").replace(tzinfo=JST) if since else None
    until_dt = (
        datetime.strptime(until, "%Y-%m-%d").replace(tzinfo=JST) + timedelta(days=1)
        if until
        else None
    )
    out = []
    for proj_dir in sorted(projects_dir.iterdir()):
        if not proj_dir.is_dir():
            continue
        if project and project.lower() not in proj_dir.name.lower():
            continue
        for f in sorted(proj_dir.glob("*.jsonl")):
            if session and not f.stem.startswith(session):
                continue
            mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=JST)
            if since_dt and mtime < since_dt:
                continue
            if until_dt and mtime >= until_dt:
                continue
            out.append(f)
    out.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return out


def prompt_text(rec: dict):
    """type=user レコードから「人間が打った実プロンプト」の本文を返す。

    tool_result・メタ挿入・スラッシュコマンドのエコー・compact 要約・
    バックグラウンドタスク通知は除外する。
    """
    if rec.get("type") != "user":
        return None
    if rec.get("isMeta") or rec.get("isSidechain") or rec.get("isCompactSummary"):
        return None
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        parts = [
            b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"
        ]
        if not parts:
            return None  # tool_result のみ
        text = "\n".join(parts)
    else:
        return None
    text = text.strip()
    if not text or text.startswith("Caveat:"):
        return None
    if "<command-name>" in text or "<local-command-stdout>" in text:
        return None
    if text.startswith("<task-notification>") or text.startswith("<system-reminder>"):
        return None
    return text


# ---------- 集計 ----------


def bucket(sec: float) -> str:
    if sec < 60:
        return "<1m"
    if sec < 180:
        return "1-3m"
    if sec < 300:
        return "3-5m"
    if sec < 600:
        return "5-10m"
    return ">10m"


def fmt_hist(h: Counter) -> str:
    return f"total={sum(h.values()):4d}  " + "  ".join(f"{b}:{h.get(b, 0)}" for b in BUCKETS)


def brief(rec: dict) -> str:
    t = rec.get("type")
    if t == "user":
        txt = prompt_text(rec)
        if txt is not None:
            return f"USER-PROMPT: {' '.join(txt.split())[:70]}"
        c = (rec.get("message") or {}).get("content")
        if isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    return f"tool_result{'(ERR)' if b.get('is_error') else ''}"
        return "user(meta)"
    if t == "assistant":
        kinds = []
        for b in (rec.get("message") or {}).get("content") or []:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "text":
                kinds.append("text")
            elif bt == "thinking":
                kinds.append("think")
            elif bt == "tool_use":
                kinds.append(f"tool:{b.get('name')}")
        err = " [API-ERR]" if rec.get("isApiErrorMessage") else ""
        return f"asst[{','.join(kinds)}]{err}"
    if t == "system":
        sub = rec.get("subtype")
        if sub == "turn_duration":
            return f"== turn_duration {round(rec.get('durationMs', 0) / 1000)}s =="
        return f"system:{sub}"
    return str(t)


def timeline(config_dir: Path, prefix: str, gap_th: float) -> None:
    files = find_session_files(config_dir, session=prefix)
    if not files:
        sys.exit(f"session not found: {prefix}")
    f = files[0]
    print(f"session {f.stem}  project {f.parent.name}")
    prev = None
    for rec in iter_records(f):
        ts = parse_ts(rec.get("timestamp"))
        gap = (ts - prev).total_seconds() if (ts and prev) else 0
        if ts:
            prev = ts
        b = brief(rec)
        show = (
            gap >= gap_th
            or "turn_duration" in b
            or "USER-PROMPT" in b
            or "API-ERR" in b
            or "(ERR)" in b
        )
        if show:
            mark = f"  <<<< {int(gap // 60)}m{int(gap % 60):02d}s" if gap >= gap_th else ""
            print(f"{jst_str(ts)}  +{int(gap):4d}s  {b}{mark}")


def summary(config_dir: Path, project, since, until) -> None:
    files = find_session_files(config_dir, project=project, since=since, until=until)
    turn_hist = defaultdict(Counter)   # turn_duration(離席含む)
    gap_hist = defaultdict(Counter)    # 実プロンプト→初回応答(API応答遅延の近似)
    think_hist = defaultdict(Counter)  # thinkingブロック直前gap(思考時間の近似)
    long_gaps, long_thinks, api_errs = [], [], []

    for f in files:
        recs = list(iter_records(f))
        # 1パス目: セッション属性(主モデル・Agent起動か・turn_duration)
        models, turn_ms, is_agent = Counter(), [], False
        for rec in recs:
            t = rec.get("type")
            if t == "agent-setting" and rec.get("agentSetting"):
                is_agent = True
            elif t == "agent-name" and rec.get("agentName"):
                is_agent = True
            elif t == "system" and rec.get("subtype") == "turn_duration":
                ms = rec.get("durationMs")
                if isinstance(ms, (int, float)):
                    turn_ms.append(ms)
            elif t == "assistant" and not rec.get("isSidechain"):
                m = (rec.get("message") or {}).get("model")
                if m:
                    models[m] += 1
        if is_agent:  # Agent/Task 起動由来は人間の運用分析を歪めるので除外
            continue
        model = models.most_common(1)[0][0] if models else "?"
        for ms in turn_ms:
            turn_hist[model][bucket(ms / 1000)] += 1
        # 2パス目: gap 系
        pending, prev = None, None
        for rec in recs:
            ts = parse_ts(rec.get("timestamp"))
            t = rec.get("type")
            if t == "user":
                if prompt_text(rec) is not None and ts is not None:
                    pending = ts
            elif t == "assistant" and not rec.get("isSidechain"):
                if pending is not None and ts is not None:
                    g = (ts - pending).total_seconds()
                    if g >= 0:
                        gap_hist[model][bucket(g)] += 1
                        if g >= 300:
                            long_gaps.append((round(g), f.stem[:8], model, jst_str(pending)))
                    pending = None
                blocks = (rec.get("message") or {}).get("content") or []
                if any(isinstance(b, dict) and b.get("type") == "thinking" for b in blocks):
                    if prev and ts:
                        g = (ts - prev).total_seconds()
                        if 0 < g < 3600:
                            think_hist[model][bucket(g)] += 1
                            if g >= 300:
                                long_thinks.append((round(g), f.stem[:8], model))
                if rec.get("isApiErrorMessage"):
                    msg = (rec.get("message") or {}).get("content")
                    txt = msg if isinstance(msg, str) else " ".join(
                        b.get("text", "") for b in (msg or []) if isinstance(b, dict)
                    )
                    api_errs.append((jst_str(ts), f.stem[:8], " ".join(txt.split())[:100]))
            if ts:
                prev = ts

    print("===== turn_duration 分布(セッション主モデル別・離席含む) =====")
    for m in sorted(turn_hist, key=lambda k: -sum(turn_hist[k].values())):
        print(f"{m:32s} {fmt_hist(turn_hist[m])}")
    print("\n===== 実プロンプト→初回応答 gap 分布(承認待ちなし・API応答の近似) =====")
    for m in sorted(gap_hist, key=lambda k: -sum(gap_hist[k].values())):
        print(f"{m:32s} {fmt_hist(gap_hist[m])}")
    print("\n===== thinking ブロック直前 gap 分布(思考時間の近似) =====")
    for m in sorted(think_hist, key=lambda k: -sum(think_hist[k].values())):
        print(f"{m:32s} {fmt_hist(think_hist[m])}")
    print(f"\n===== 5分超の初回応答 gap: {len(long_gaps)}件 =====")
    for g, sid, m, ts in sorted(long_gaps, reverse=True)[:10]:
        print(f"  {g // 60}m{g % 60:02d}s  {sid}  {m}  {ts}")
    print(f"\n===== 5分超の thinking: {len(long_thinks)}件 =====")
    for g, sid, m in sorted(long_thinks, reverse=True)[:10]:
        print(f"  {g // 60}m{g % 60:02d}s  {sid}  {m}")
    print(f"\n===== isApiErrorMessage: {len(api_errs)}件(直近10) =====")
    for ts, sid, txt in api_errs[:10]:
        print(f"  {ts}  {sid}  {txt}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--project", help="プロジェクトディレクトリ名への部分一致")
    ap.add_argument("--since", help="JST日付 YYYY-MM-DD")
    ap.add_argument("--until", help="JST日付 YYYY-MM-DD(その日を含む)")
    ap.add_argument("--session", help="セッションID前方一致: タイムラインモード")
    ap.add_argument("--gap-threshold", type=float, default=60.0)
    args = ap.parse_args()
    config_dir = resolve_config_dir()
    if args.session:
        timeline(config_dir, args.session, args.gap_threshold)
    else:
        summary(config_dir, args.project, args.since, args.until)


if __name__ == "__main__":
    main()
