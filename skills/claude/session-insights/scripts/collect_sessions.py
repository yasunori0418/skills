#!/usr/bin/env python3
"""session-insights 収集 CLI（決定論）。

Claude Code のセッション JSONL を機械的に読み出して JSON で標準出力に返す。
分析 AI が生の JSONL を Grep/Read で無作為に漁らないための唯一の読み出し口。

横断集計（ツール/スキル使用頻度・トークンとコスト・ツールエラーの分類・
設定の棚卸し）は cclens へ委譲した。このスクリプトが担うのは、cclens が
構造上持てない領域だけ:

  - プロンプト本文（cclens は instruct/steer/correct/question の 4 ラベルに
    集約するのみで本文を保持しない）
  - 生 transcript の時系列読み出し
  - compaction の発生記録（cclens は compaction を差分計算時に補正する
    ノイズとしてしか扱わず、発生回数・トリガーを残さない）

- 依存は stdlib のみ。Python バージョンは skill 直下の pyproject.toml（uv 管理）に
  従い、次の形で実行する（cwd 非依存。uv が .venv を skill 直下に構築する）:
      uv run --project "<skill-dir>" python "<skill-dir>/scripts/collect_sessions.py" <subcommand>
- 設定ディレクトリは CLAUDE_CONFIG_DIR を尊重する（未設定時は ~/.claude）。
  テスト・検証用に --config-dir で明示上書きもできる。
- タイムスタンプは全て JST（UTC+9）表記で出力する（ユーザー環境ルール）。
- 出力サイズには既定の上限（limit / max-chars）を設けてある。コンテキストを
  食い潰さないための意図的な制約なので、外すときは明示フラグで。

サブコマンド:
  paths       設定ディレクトリの解決結果とデータ配置の一覧
  sessions    セッション一覧（メタデータ + セッション単位の集計値）
  prompts     ユーザープロンプトの抽出（本文つき）
  transcript  単一セッションの会話を時系列で抽出

設計: 「純粋層」と「副作用層」を分離している。
  純粋層 … レコード解釈（prompt_text 等）、セッション畳み込み
           （reduce_session: レコード列 -> SessionStats）、レポート整形
           （*_report: SessionStats 列 -> dict）。データクラス
           （TokenUsage / SessionStats / SessionFilters 等）で受け渡す。
           入力は値のみ・I/O なし・同じ入力なら同じ出力。テスト対象はここ。
  副作用層 … ファイル走査・JSONL 読み出し・環境変数・stdout 出力
           （find_session_files / iter_records / cmd_* / emit）。
壊れた行・未知のレコード型は黙って読み飛ばす（フォーマットは Claude Code の
バージョンで変わるため、寛容パースが前提）。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from collections.abc import Iterable, Iterator
from dataclasses import dataclass, field, fields
from datetime import datetime, timedelta, timezone
from pathlib import Path

JST = timezone(timedelta(hours=9), "JST")

COMMAND_NAME_RE = re.compile(r"<command-name>([^<]+)</command-name>")


# ============================================================
# 純粋層: 基本変換
# ============================================================


def parse_ts(value) -> datetime | None:
    """ISO8601（Z 終端可）を datetime に。解釈できなければ None。"""
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_jst_date(value: str | None) -> datetime | None:
    """YYYY-MM-DD を JST 0時の datetime に。None/不正は None。"""
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%d").replace(tzinfo=JST)
    except ValueError:
        return None


def jst_str(dt: datetime | None, seconds: bool = False) -> str | None:
    if dt is None:
        return None
    fmt = "%Y-%m-%d %H:%M:%S JST" if seconds else "%Y-%m-%d %H:%M JST"
    return dt.astimezone(JST).strftime(fmt)


def human_duration(sec: float | None) -> str | None:
    if sec is None or sec < 0:
        return None
    m, s = divmod(int(sec), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"


def truncate(text: str, max_chars: int) -> str:
    if max_chars <= 0 or len(text) <= max_chars:
        return text
    return text[:max_chars] + f"…(+{len(text) - max_chars}字)"


def in_range(dt: datetime, since: datetime | None, until: datetime | None) -> bool:
    """since <= dt < until+1日 の判定（until はその日を含む）。"""
    if since and dt < since:
        return False
    if until and dt >= until + timedelta(days=1):
        return False
    return True


# ============================================================
# 純粋層: データモデル
# ============================================================


@dataclass(frozen=True)
class TokenUsage:
    """assistant メッセージの usage の集計値（イミュータブル）。"""

    input: int = 0
    output: int = 0
    cache_read: int = 0
    cache_creation: int = 0

    @classmethod
    def from_api_usage(cls, u) -> TokenUsage:
        if not isinstance(u, dict):
            return cls()

        def num(key: str) -> int:
            v = u.get(key)
            return int(v) if isinstance(v, (int, float)) else 0

        return cls(
            input=num("input_tokens"),
            output=num("output_tokens"),
            cache_read=num("cache_read_input_tokens"),
            cache_creation=num("cache_creation_input_tokens"),
        )

    def __add__(self, other: TokenUsage) -> TokenUsage:
        return TokenUsage(
            input=self.input + other.input,
            output=self.output + other.output,
            cache_read=self.cache_read + other.cache_read,
            cache_creation=self.cache_creation + other.cache_creation,
        )

    @property
    def context_size(self) -> int:
        """このメッセージ時点のコンテキスト量の近似（入力側の合計）。"""
        return self.input + self.cache_read + self.cache_creation

    def as_dict(self) -> dict:
        return {f.name: getattr(self, f.name) for f in fields(self)}


@dataclass(frozen=True)
class PromptEntry:
    ts: datetime | None
    text: str


@dataclass(frozen=True)
class ToolErrorEntry:
    ts: datetime | None
    tool: str
    message: str


@dataclass(frozen=True)
class Compaction:
    trigger: str | None
    pre_tokens: int | None

    def as_dict(self) -> dict:
        return {"trigger": self.trigger, "pre_tokens": self.pre_tokens}


@dataclass
class SessionStats:
    """1 セッション JSONL を畳み込んだ結果。reduce_session が生成する。"""

    session_id: str
    project: str
    cwd: str | None = None
    git_branch: str | None = None
    version: str | None = None
    title: str | None = None
    agent_type: str | None = None  # Agent/Task 起動由来なら subagent type
    agent_name: str | None = None
    first: datetime | None = None
    last: datetime | None = None
    prompts: list = field(default_factory=list)  # list[PromptEntry]
    assistant_msgs: int = 0
    tools: Counter = field(default_factory=Counter)
    skills: Counter = field(default_factory=Counter)
    commands: Counter = field(default_factory=Counter)
    agents: Counter = field(default_factory=Counter)
    models: Counter = field(default_factory=Counter)
    usage: TokenUsage = field(default_factory=TokenUsage)
    peak_context: int = 0
    errors: list = field(default_factory=list)  # list[ToolErrorEntry]
    compactions: list = field(default_factory=list)  # list[Compaction]
    permission_modes: set = field(default_factory=set)
    turn_ms: list = field(default_factory=list)
    pr_links: list = field(default_factory=list)
    # reduce_session は 0 のまま。副作用層（load_sessions 等）がファイル配置を
    # 見て埋める（subagents/ ディレクトリの transcript 数）
    subagent_files: int = 0

    @property
    def spawned_as_agent(self) -> bool:
        return bool(self.agent_type or self.agent_name)

    @property
    def duration_sec(self) -> float | None:
        if self.first and self.last:
            return (self.last - self.first).total_seconds()
        return None


@dataclass(frozen=True)
class SessionFilters:
    """セッション選択条件。ファイル発見（副作用層）と共有する値オブジェクト。"""

    project: str | None = None
    since: str | None = None  # YYYY-MM-DD (JST)
    until: str | None = None
    session: str | None = None  # ID 前方一致
    include_agents: bool = False

    @classmethod
    def from_args(cls, args) -> SessionFilters:
        return cls(
            project=getattr(args, "project", None),
            since=getattr(args, "since", None),
            until=getattr(args, "until", None),
            session=getattr(args, "session", None),
            include_agents=getattr(args, "include_agents", False),
        )

    def as_dict(self) -> dict:
        return {
            k: v
            for k, v in (
                ("project", self.project),
                ("since", self.since),
                ("until", self.until),
                ("session", self.session),
                ("include_agents", self.include_agents or None),
            )
            if v
        }


# ============================================================
# 純粋層: レコード解釈
# ============================================================


def prompt_text(rec: dict) -> str | None:
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
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
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
    if text.startswith(("<task-notification>", "<system-reminder>")):
        return None
    return text


def iter_assistant_blocks(rec: dict) -> Iterator[dict]:
    """type=assistant レコードの content ブロックを安全に列挙する。"""
    if rec.get("type") != "assistant" or rec.get("isSidechain"):
        return
    content = (rec.get("message") or {}).get("content")
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict):
                yield b


def extract_command_names(text) -> list:
    """<command-name>...</command-name> を全て取り出す。"""
    if not isinstance(text, str):
        return []
    return [m.group(1).strip() for m in COMMAND_NAME_RE.finditer(text)]


def tool_brief(tool_input) -> str:
    """tool_use の入力から transcript 表示用の短い要約を作る。"""
    if not isinstance(tool_input, dict):
        return ""
    for key in ("description", "command", "file_path", "skill", "prompt", "query", "pattern", "url"):
        v = tool_input.get(key)
        if isinstance(v, str) and v:
            return truncate(v.replace("\n", " "), 100)
    return ""


def tool_result_errors(rec: dict, tool_use_names: dict) -> list:
    """type=user レコード中の is_error な tool_result を ToolErrorEntry に。"""
    content = (rec.get("message") or {}).get("content")
    if not isinstance(content, list):
        return []
    ts = parse_ts(rec.get("timestamp"))
    out = []
    for b in content:
        if not (isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error")):
            continue
        raw = b.get("content")
        if isinstance(raw, list):
            raw = " ".join(x.get("text", "") for x in raw if isinstance(x, dict))
        out.append(
            ToolErrorEntry(
                ts=ts,
                tool=tool_use_names.get(b.get("tool_use_id"), "?"),
                message=(raw or "").strip().replace("\n", " "),
            )
        )
    return out


# ============================================================
# 純粋層: セッション畳み込み（レコード列 -> SessionStats）
# ============================================================


def reduce_session(session_id: str, project: str, records: Iterable[dict]) -> SessionStats:
    """レコード列を単一パスで畳み込む。I/O なし・入力順のみに依存。"""
    s = SessionStats(session_id=session_id, project=project)
    tool_use_names: dict = {}  # tool_use_id -> tool name（エラー対応付け用）
    for rec in records:
        if not isinstance(rec, dict):
            continue
        ts = parse_ts(rec.get("timestamp"))
        if ts:
            if s.first is None or ts < s.first:
                s.first = ts
            if s.last is None or ts > s.last:
                s.last = ts
        if rec.get("cwd") and not s.cwd:
            s.cwd = rec["cwd"]
        if rec.get("gitBranch"):
            s.git_branch = rec["gitBranch"]
        if rec.get("version"):
            s.version = rec["version"]

        rtype = rec.get("type")
        if rtype == "ai-title" and rec.get("aiTitle"):
            s.title = rec["aiTitle"]
        elif rtype == "agent-setting" and rec.get("agentSetting"):
            s.agent_type = rec["agentSetting"]
        elif rtype == "agent-name" and rec.get("agentName"):
            s.agent_name = rec["agentName"]
        elif rtype == "permission-mode" and rec.get("permissionMode"):
            s.permission_modes.add(rec["permissionMode"])
        elif rtype == "pr-link" and rec.get("prUrl"):
            s.pr_links.append(rec["prUrl"])
        elif rtype == "system":
            sub = rec.get("subtype")
            if sub == "turn_duration" and isinstance(rec.get("durationMs"), (int, float)):
                s.turn_ms.append(rec["durationMs"])
            elif sub == "compact_boundary":
                meta = rec.get("compactMetadata") or {}
                s.compactions.append(
                    Compaction(trigger=meta.get("trigger"), pre_tokens=meta.get("preTokens"))
                )
            for name in extract_command_names(rec.get("content")):
                s.commands[name] += 1
        elif rtype == "user":
            if rec.get("isCompactSummary"):
                s.compactions.append(Compaction(trigger="summary-record", pre_tokens=None))
            text = prompt_text(rec)
            if text is not None:
                s.prompts.append(PromptEntry(ts=ts, text=text))
            content = (rec.get("message") or {}).get("content")
            if isinstance(content, str):
                for name in extract_command_names(content):
                    s.commands[name] += 1
            s.errors.extend(tool_result_errors(rec, tool_use_names))
        elif rtype == "assistant" and not rec.get("isSidechain"):
            s.assistant_msgs += 1
            msg = rec.get("message") or {}
            if msg.get("model"):
                s.models[msg["model"]] += 1
            u = TokenUsage.from_api_usage(msg.get("usage"))
            s.usage = s.usage + u
            s.peak_context = max(s.peak_context, u.context_size)
            for b in iter_assistant_blocks(rec):
                if b.get("type") != "tool_use":
                    continue
                name = b.get("name") or "?"
                s.tools[name] += 1
                tool_use_names[b.get("id")] = name
                inp = b.get("input")
                if not isinstance(inp, dict):
                    continue
                if name == "Skill" and inp.get("skill"):
                    s.skills[inp["skill"]] += 1
                if name in ("Task", "Agent"):
                    s.agents[inp.get("subagent_type") or "general-purpose"] += 1
    return s


# ============================================================
# 純粋層: レポート整形（SessionStats 列 -> dict）
# ============================================================


def summarize_session(s: SessionStats, top_tools: int = 10) -> dict:
    turn_ms = s.turn_ms
    return {
        "session_id": s.session_id,
        "title": s.title,
        "spawned_as_agent": (
            {"type": s.agent_type, "name": s.agent_name} if s.spawned_as_agent else None
        ),
        "project": s.project,
        "cwd": s.cwd,
        "git_branch": s.git_branch,
        "start": jst_str(s.first),
        "end": jst_str(s.last),
        "duration": human_duration(s.duration_sec),
        "prompts": len(s.prompts),
        "assistant_msgs": s.assistant_msgs,
        "models": dict(s.models.most_common()),
        "tools_total": sum(s.tools.values()),
        "tools_top": dict(s.tools.most_common(top_tools)),
        "skills": dict(s.skills.most_common()),
        "commands": dict(s.commands.most_common()),
        "agents": dict(s.agents.most_common()),
        "subagent_files": s.subagent_files,
        "usage": s.usage.as_dict(),
        "peak_context": s.peak_context,
        "compactions": [c.as_dict() for c in s.compactions],
        "errors": len(s.errors),
        "permission_modes": sorted(s.permission_modes),
        "avg_turn": human_duration(sum(turn_ms) / len(turn_ms) / 1000) if turn_ms else None,
        "max_turn": human_duration(max(turn_ms) / 1000) if turn_ms else None,
        "pr_links": list(s.pr_links),
        "version": s.version,
    }


def sessions_report(stats: list, filters: SessionFilters, limit: int) -> dict:
    """stats: list[SessionStats]（新しい順）。"""
    total = len(stats)
    if limit > 0:
        stats = stats[:limit]
    summaries = [summarize_session(s) for s in stats]
    usage = TokenUsage()
    for s in stats:
        usage = usage + s.usage
    return {
        "filters": filters.as_dict(),
        "total_matched": total,
        "shown": len(summaries),
        "aggregate": {
            "prompts": sum(x["prompts"] for x in summaries),
            "assistant_msgs": sum(x["assistant_msgs"] for x in summaries),
            "tools_total": sum(x["tools_total"] for x in summaries),
            "errors": sum(x["errors"] for x in summaries),
            "compactions": sum(len(x["compactions"]) for x in summaries),
            "usage": usage.as_dict(),
        },
        "sessions": summaries,
    }


def prompts_report(stats: list, filters: SessionFilters, limit: int, max_chars: int) -> dict:
    items = []
    total = 0
    for s in stats:
        for p in s.prompts:
            total += 1
            if limit > 0 and len(items) >= limit:
                continue
            items.append(
                {
                    "ts": jst_str(p.ts),
                    "session_id": s.session_id[:8],
                    "project": s.project,
                    "chars": len(p.text),
                    "text": truncate(p.text, max_chars),
                }
            )
    return {
        "filters": filters.as_dict(),
        "total_prompts": total,
        "shown": len(items),
        "prompts": items,
    }


def transcript_turns(records: Iterable[dict], max_chars: int, include_tools: bool) -> list:
    """レコード列を表示用ターン列に変換する（順序保存）。"""
    turns = []
    for rec in records:
        if not isinstance(rec, dict):
            continue
        ts = jst_str(parse_ts(rec.get("timestamp")), seconds=True)
        text = prompt_text(rec)
        if text is not None:
            turns.append({"role": "user", "ts": ts, "text": truncate(text, max_chars)})
            continue
        if rec.get("type") == "assistant" and not rec.get("isSidechain"):
            texts, tool_uses = [], []
            for b in iter_assistant_blocks(rec):
                if b.get("type") == "text" and b.get("text", "").strip():
                    texts.append(b["text"].strip())
                elif b.get("type") == "tool_use":
                    tool_uses.append({"tool": b.get("name"), "brief": tool_brief(b.get("input"))})
            if texts:
                turns.append(
                    {"role": "assistant", "ts": ts, "text": truncate("\n".join(texts), max_chars)}
                )
            if tool_uses and include_tools:
                turns.append({"role": "assistant:tools", "ts": ts, "tools": tool_uses})
        elif rec.get("type") == "system" and rec.get("subtype") == "compact_boundary":
            turns.append({"role": "system", "ts": ts, "text": "--- compact 発生 ---"})
    return turns


# ============================================================
# 副作用層: パス解決・ファイル走査・読み出し
# ============================================================


def resolve_config_dir(override: str | None, env: dict | None = None) -> tuple:
    """設定ディレクトリと、その決定根拠を返す。env は注入可能（テスト用）。"""
    environ = env if env is not None else os.environ
    if override:
        return Path(override).expanduser(), "cli:--config-dir"
    from_env = environ.get("CLAUDE_CONFIG_DIR")
    if from_env:
        return Path(from_env).expanduser(), "env:CLAUDE_CONFIG_DIR"
    return Path.home() / ".claude", "default:~/.claude"


def iter_records(path: Path) -> Iterator[dict]:
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


def find_session_files(config_dir: Path, filters: SessionFilters) -> list:
    """projects/<dir>/<uuid>.jsonl を列挙する（subagents 配下は含めない）。

    since/until はファイル更新時刻（≒最終活動時刻）を JST 日付で判定する。
    project はプロジェクトディレクトリ名（cwd を '-' 連結したもの）への
    部分一致（大文字小文字無視）。session はセッション ID の前方一致。
    戻りは最終活動が新しい順。
    """
    projects_dir = config_dir / "projects"
    if not projects_dir.is_dir():
        return []
    since_dt = parse_jst_date(filters.since)
    until_dt = parse_jst_date(filters.until)
    out = []
    for proj_dir in sorted(projects_dir.iterdir()):
        if not proj_dir.is_dir():
            continue
        if filters.project and filters.project.lower() not in proj_dir.name.lower():
            continue
        for f in sorted(proj_dir.glob("*.jsonl")):
            if filters.session and not f.stem.startswith(filters.session):
                continue
            mtime = datetime.fromtimestamp(f.stat().st_mtime, tz=JST)
            if not in_range(mtime, since_dt, until_dt):
                continue
            out.append(f)
    out.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return out


def subagent_file_count(session_file: Path) -> int:
    d = session_file.parent / session_file.stem / "subagents"
    if not d.is_dir():
        return 0
    return len(list(d.glob("agent-*.jsonl")))


def load_sessions(config_dir: Path, filters: SessionFilters) -> list:
    """フィルタ適用済みの SessionStats 列を新しい順で返す。

    Agent/Task から起動されたセッション（subagent の transcript が独立
    セッションとして残るもの）は、人間の運用分析を歪めるので既定で除外。
    純粋層が扱えないファイル配置由来の値（subagent_files）はここで埋める。
    """
    out = []
    for f in find_session_files(config_dir, filters):
        s = reduce_session(f.stem, f.parent.name, iter_records(f))
        if not filters.include_agents and s.spawned_as_agent:
            continue
        s.subagent_files = subagent_file_count(f)
        out.append(s)
    return out


def emit(obj) -> None:
    json.dump(obj, sys.stdout, ensure_ascii=False, indent=1)
    sys.stdout.write("\n")


# ============================================================
# 副作用層: サブコマンドハンドラ
# ============================================================


def cmd_paths(config_dir: Path, source: str) -> None:
    def entry(rel: str, count_entries: bool = False) -> dict:
        p = config_dir / rel
        info = {"path": str(p), "exists": p.exists()}
        if p.is_symlink():
            info["resolves_to"] = str(p.resolve())
        if count_entries and p.is_dir():
            info["entry_count"] = len(list(p.iterdir()))
        return info

    projects_dir = config_dir / "projects"
    session_count = (
        len(list(projects_dir.glob("*/*.jsonl"))) if projects_dir.is_dir() else 0
    )
    project_count = (
        len([d for d in projects_dir.iterdir() if d.is_dir()]) if projects_dir.is_dir() else 0
    )
    memory_projects = (
        sorted(d.name for d in projects_dir.iterdir() if (d / "memory").is_dir())
        if projects_dir.is_dir()
        else []
    )
    cwd = Path.cwd()
    emit(
        {
            "config_dir": str(config_dir),
            "config_dir_source": source,
            "env_CLAUDE_CONFIG_DIR": os.environ.get("CLAUDE_CONFIG_DIR"),
            "projects": {
                "path": str(projects_dir),
                "exists": projects_dir.is_dir(),
                "project_dirs": project_count,
                "session_files": session_count,
                "projects_with_memory": memory_projects,
            },
            "entries": {
                "settings.json": entry("settings.json"),
                "settings.local.json": entry("settings.local.json"),
                "CLAUDE.md": entry("CLAUDE.md"),
                "skills/": entry("skills", count_entries=True),
                "commands/": entry("commands", count_entries=True),
                "agents/": entry("agents", count_entries=True),
                "rules/": entry("rules", count_entries=True),
                "workflows/": entry("workflows", count_entries=True),
                "output-styles/": entry("output-styles", count_entries=True),
                "agent-memory/": entry("agent-memory", count_entries=True),
                "plugins/": entry("plugins", count_entries=True),
                "history.jsonl": entry("history.jsonl"),
                "plans/": entry("plans", count_entries=True),
                "todos/": entry("todos", count_entries=True),
                "tasks/": entry("tasks", count_entries=True),
                "file-history/": entry("file-history", count_entries=True),
                "shell-snapshots/": entry("shell-snapshots", count_entries=True),
                "stats-cache.json": entry("stats-cache.json"),
            },
            "home_state_file": {
                "path": str(Path.home() / ".claude.json"),
                "exists": (Path.home() / ".claude.json").exists(),
                "note": "オンボーディング状態・プロジェクト別ローカル状態（allowedTools等）",
            },
            "project_local": {
                "cwd": str(cwd),
                "CLAUDE.md": (cwd / "CLAUDE.md").exists(),
                ".claude/settings.json": (cwd / ".claude" / "settings.json").exists(),
                ".claude/settings.local.json": (cwd / ".claude" / "settings.local.json").exists(),
                ".claude/rules/": (cwd / ".claude" / "rules").is_dir(),
                ".claude/skills/": (cwd / ".claude" / "skills").is_dir(),
                ".claude/commands/": (cwd / ".claude" / "commands").is_dir(),
                ".claude/agents/": (cwd / ".claude" / "agents").is_dir(),
                ".mcp.json": (cwd / ".mcp.json").exists(),
            },
        }
    )


def cmd_sessions(config_dir: Path, args) -> None:
    filters = SessionFilters.from_args(args)
    stats = load_sessions(config_dir, filters)
    emit(sessions_report(stats, filters, args.limit))


def cmd_prompts(config_dir: Path, args) -> None:
    filters = SessionFilters.from_args(args)
    stats = load_sessions(config_dir, filters)
    emit(prompts_report(stats, filters, args.limit, args.max_chars))


def cmd_transcript(config_dir: Path, args) -> None:
    filters = SessionFilters(session=args.session, include_agents=True)
    files = find_session_files(config_dir, filters)
    if not files:
        emit({"error": f"セッション {args.session} が見つからない"})
        sys.exit(1)
    if len(files) > 1:
        emit({"error": "セッションIDが曖昧。候補:", "candidates": [f.stem for f in files[:10]]})
        sys.exit(1)
    path = files[0]
    s = reduce_session(path.stem, path.parent.name, iter_records(path))
    s.subagent_files = subagent_file_count(path)
    turns = transcript_turns(iter_records(path), args.max_chars, args.include_tools)
    if args.tail > 0:
        turns = turns[-args.tail :]
    emit(
        {
            "session": summarize_session(s),
            "turn_count": len(turns),
            "turns": turns,
        }
    )


# ============================================================
# main
# ============================================================


def add_filter_args(p: argparse.ArgumentParser, with_session: bool = True) -> None:
    p.add_argument("--project", help="プロジェクトディレクトリ名への部分一致")
    p.add_argument("--since", help="JST日付 YYYY-MM-DD（ファイル最終更新で判定）")
    p.add_argument("--until", help="JST日付 YYYY-MM-DD（同上・その日を含む）")
    p.add_argument(
        "--include-agents",
        action="store_true",
        help="Agent/Task 起動由来のセッションも含める（既定は人間が開始したセッションのみ）",
    )
    if with_session:
        p.add_argument("--session", help="セッションIDの前方一致")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="collect_sessions.py",
        description=(
            "Claude Code セッションの決定論収集 CLI（出力は JSON・時刻は JST）。"
            "横断集計・設定棚卸し・エラー分類は cclens へ委譲する"
        ),
    )
    p.add_argument(
        "--config-dir", help="設定ディレクトリの明示上書き（既定: $CLAUDE_CONFIG_DIR → ~/.claude）"
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("paths", help="設定ディレクトリ解決とデータ配置の一覧")

    sp = sub.add_parser("sessions", help="セッション一覧（メタデータ + 集計）")
    add_filter_args(sp)
    sp.add_argument("--limit", type=int, default=30, help="最大件数（既定30、0で無制限）")

    sp = sub.add_parser("prompts", help="ユーザープロンプト抽出")
    add_filter_args(sp)
    sp.add_argument("--limit", type=int, default=120, help="最大件数（既定120、0で無制限）")
    sp.add_argument(
        "--max-chars", type=int, default=240, help="本文の切り詰め文字数（既定240、0で無制限）"
    )

    sp = sub.add_parser("transcript", help="単一セッションの会話抽出")
    sp.add_argument("--session", required=True, help="セッションIDの前方一致（一意になる長さで）")
    sp.add_argument(
        "--max-chars", type=int, default=400, help="各発話の切り詰め文字数（既定400、0で無制限）"
    )
    sp.add_argument("--tail", type=int, default=0, help="末尾Nターンのみ表示（既定0=全部）")
    sp.add_argument("--include-tools", action="store_true", help="ツール呼び出し行も含める")
    return p


def main(argv: list | None = None) -> int:
    args = build_parser().parse_args(argv)
    config_dir, source = resolve_config_dir(args.config_dir)
    if not config_dir.is_dir():
        emit({"error": f"設定ディレクトリが存在しない: {config_dir}", "source": source})
        return 1
    # 各ハンドラは必要な引数だけ受け取る（未使用引数を持つ統一シグネチャにしない）
    handlers = {
        "paths": lambda: cmd_paths(config_dir, source),
        "sessions": lambda: cmd_sessions(config_dir, args),
        "prompts": lambda: cmd_prompts(config_dir, args),
        "transcript": lambda: cmd_transcript(config_dir, args),
    }
    handlers[args.cmd]()
    return 0


if __name__ == "__main__":
    sys.exit(main())
