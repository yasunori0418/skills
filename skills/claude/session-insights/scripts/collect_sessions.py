#!/usr/bin/env python3
"""session-insights 収集 CLI（決定論）。

Claude Code のセッション JSONL を機械的に読み出して JSON で標準出力に返す。
分析 AI が生の JSONL を Grep/Read で無作為に漁らないための唯一の読み出し口。

横断集計（ツール/スキル使用頻度・コンテキスト常時コスト・ツールエラーの分類・
設定の棚卸し）は cclens へ委譲した。このスクリプトが担うのは、cclens が
構造上持てない領域だけ:

  - プロンプト本文（cclens は instruct/steer/correct/question の 4 ラベルに
    集約するのみで本文を保持しない）
  - 生 transcript の時系列読み出しと、ツールの入出力本文
  - 本文の横断検索（cclens の events は本文を持たず、bash_cmd もコマンドの
    先頭語しか残らない）
  - compaction の発生記録（cclens は compaction を差分計算時に補正する
    ノイズとしてしか扱わず、発生回数・トリガーを残さない）
  - 金額（USD）の取得。cclens はトークン量とコンテキスト増加は出すが USD 換算を
    持たないため、cost サブコマンドが ccusage へ移譲する

- 依存は stdlib のみ。Python バージョンは skill 直下の pyproject.toml（uv 管理）に
  従い、次の形で実行する（cwd 非依存。uv が .venv を skill 直下に構築する）:
      uv run --project "<skill-dir>" python "<skill-dir>/scripts/collect_sessions.py" <subcommand>
- 設定ディレクトリは CLAUDE_CONFIG_DIR を尊重する（未設定時は ~/.claude）。
  テスト・検証用に --config-dir で明示上書きもできる。
- タイムスタンプは全て JST（UTC+9）表記で出力する（ユーザー環境ルール）。
- 出力サイズには既定の上限（limit / max-chars）を設けてある。コンテキストを
  食い潰さないための意図的な制約なので、外すときは明示フラグで。
- 本文を出す箇所は全て秘密情報の伏せ字（redact）を通す（clip = 伏せ字 → 切り詰め）。
  伏せ字を外すオプションは持たない。

サブコマンド:
  paths       設定ディレクトリの解決結果とデータ配置の一覧
  sessions    セッション一覧（メタデータ + セッション単位の集計値）
  prompts     ユーザープロンプトの抽出（本文つき。--grep でキーワード絞り込み）
  cost        トークン消費と金額（USD）を ccusage から取得
  search      全セッションの本文（プロンプト・応答・ツールの入出力）を横断検索
  transcript  単一セッションの会話を時系列で抽出（--tool-detail でツールの入力と結果も）

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
import shutil
import subprocess
import sys
from collections import Counter
from collections.abc import Iterable, Iterator, Sequence
from dataclasses import dataclass, field, fields
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

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


# 秘密情報の伏せ字パターン（kind, 正規表現, 置換）。上から順に適用する。
# 過剰に伏せる側へ倒す（コード中の `token = get_token()` なども伏せうる）。
# 網羅はできないので、レポートへの引用を最小限にする運用（SKILL.md の制約）と併用する。
_REDACT_RULES: list = [
    (
        "private_key",
        re.compile(
            r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)",
            re.DOTALL,
        ),
        None,
    ),
    ("github_token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})"), None),
    ("anthropic_key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"), None),
    ("openai_key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}"), None),
    ("slack_token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}"), None),
    ("aws_access_key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"), None),
    ("google_api_key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}"), None),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"), None),
    ("bearer", re.compile(r"(?i)(\bauthorization:\s*(?:bearer|basic)\s+)[^\s\"']+"), r"\1"),
    ("url_credential", re.compile(r"(://)[^/\s:@]+:[^/\s@]+(@)"), r"\1{}\2"),
    (
        "assignment",
        re.compile(
            r"(?i)(\b[\w.-]*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key)[\w.-]*"
            r"[\"']?\s*[:=]\s*[\"']?)[^\s\"',;]{4,}"
        ),
        r"\1",
    ),
]

REDACTED_RE = re.compile(r"\[REDACTED:[a-z_]+\]")


def redact(text: str) -> str:
    """秘密情報らしき文字列を `[REDACTED:<kind>]` に置き換える。

    key=value 形式・Authorization ヘッダはキー名側を残し、値だけを伏せる。
    切り詰めより前に適用すること（途中で切れたトークンは照合できず断片が漏れる）。
    """
    if not isinstance(text, str) or not text:
        return text
    for kind, pattern, keep in _REDACT_RULES:
        mark = f"[REDACTED:{kind}]"
        if keep is None:
            repl = mark
        elif "{}" in keep:
            repl = keep.format(mark)
        else:
            repl = keep + mark
        # 既に伏せた箇所（`[REDACTED:…]`）を後段のルールが再度食わないよう、
        # 伏せ字の目印を値として拾う一致は置き換えない
        text = pattern.sub(
            lambda m, r=repl: m.group(0) if REDACTED_RE.search(m.group(0)) else m.expand(r),
            text,
        )
    return text


def clip(text: str, max_chars: int) -> str:
    """伏せ字 → 切り詰めの順で出力用テキストを作る。"""
    return truncate(redact(text), max_chars)


def truncate_head_tail(text: str, max_chars: int, head_ratio: float = 0.6) -> str:
    """先頭と末尾を残して中央を省く。失敗メッセージや確認結果は末尾に出やすいため。"""
    if max_chars <= 0 or len(text) <= max_chars:
        return text
    head = int(max_chars * head_ratio)
    tail = max_chars - head
    return f"{text[:head]}…(中略 {len(text) - max_chars}字)…{text[len(text) - tail:]}"


def clip_head_tail(text: str, max_chars: int) -> str:
    """伏せ字 → 先頭末尾を残す切り詰め。"""
    return truncate_head_tail(redact(text), max_chars)


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


@dataclass(frozen=True)
class ToolResult:
    """tool_use に対応する tool_result の解釈結果。

    status: ok / exit / hook_blocked / permission_denied / user_rejected /
            interrupted / error。exit_code は失敗時に `Exit code N` から取れた
            ときだけ入る（成功時は記録が無いので 0 と推定せず None）。
    body は伏せ字・切り詰め前の生テキスト。persisted は大きな出力が
    tool-results/ へ退避されたときの {path, size}。
    """

    status: str
    exit_code: int | None
    body: str
    persisted: dict | None = None


@dataclass(frozen=True)
class ToolDetailOptions:
    """transcript --tool-detail の上限値。0 は無制限。"""

    input_chars: int = 300
    result_chars: int = 600
    budget: int = 30000


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
            return clip(v.replace("\n", " "), 100)
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


EXIT_CODE_RE = re.compile(r"(?:Error: )?Exit code (-?\d+)")
PERMISSION_RE = re.compile(r"(?:Error: )?Permission\b")


def tool_result_text(block: dict) -> str:
    """tool_result ブロックの content をテキストに（list なら text を連結）。"""
    raw = block.get("content")
    if isinstance(raw, list):
        return "\n".join(
            x.get("text", "") for x in raw if isinstance(x, dict) and x.get("type") == "text"
        )
    return raw if isinstance(raw, str) else ""


def classify_tool_result(block: dict, tool_use_result) -> tuple:
    """tool_result と record の toolUseResult から (status, exit_code) を決める。

    成功時の Bash は toolUseResult に exit code を持たないので exit_code は None。
    失敗時は toolUseResult が文字列（`Error: Exit code N` 等）になる。
    """
    if not block.get("is_error"):
        if isinstance(tool_use_result, dict) and tool_use_result.get("interrupted"):
            return "interrupted", None
        return "ok", None
    err = tool_use_result if isinstance(tool_use_result, str) else tool_result_text(block)
    err = err.strip()
    m = EXIT_CODE_RE.match(err)
    if m:
        return "exit", int(m.group(1))
    first_line = err.split("\n", 1)[0]
    if "PreToolUse:" in first_line:
        return "hook_blocked", None
    if PERMISSION_RE.match(err):
        return "permission_denied", None
    if "User rejected" in first_line or "doesn't want to proceed" in first_line:
        return "user_rejected", None
    if isinstance(tool_use_result, dict) and tool_use_result.get("interrupted"):
        return "interrupted", None
    return "error", None


def result_body(tool: str, block: dict, tool_use_result) -> str:
    """結果本文として見せるテキストをツール別に選ぶ（伏せ字・切り詰め前）。

    Read はファイル全文、Write/Edit は書いた内容を持つが、それらを出すと
    1 回で本文が溢れるため、パスと量だけにする。
    """
    tur = tool_use_result if isinstance(tool_use_result, dict) else None
    if block.get("is_error") or tur is None:
        return tool_result_text(block)
    if tool == "Bash" and "stdout" in tur:
        out = tur.get("stdout") or ""
        err = tur.get("stderr") or ""
        return f"{out}\n[stderr]\n{err}" if err else out
    if tool == "Read" and isinstance(tur.get("file"), dict):
        f = tur["file"]
        return f"{f.get('filePath', '?')}（{f.get('numLines', '?')}行を読み込み）"
    if tool == "Write" and "filePath" in tur:
        return f"{tur['filePath']}（{len(tur.get('content') or '')}字を書き込み）"
    if tool == "Edit" and "filePath" in tur:
        patch = tur.get("structuredPatch")
        hunks = len(patch) if isinstance(patch, list) else 0
        return f"{tur['filePath']}（{hunks} hunk を変更）"
    return tool_result_text(block)


def tool_input_text(tool: str, tool_input) -> str:
    """tool_use の入力を表示用テキストに（Bash はコマンド全文、他は JSON）。"""
    if not isinstance(tool_input, dict):
        return ""
    if tool == "Bash" and isinstance(tool_input.get("command"), str):
        return tool_input["command"]
    return json.dumps(tool_input, ensure_ascii=False)


def index_tool_results(records: Iterable[dict]) -> dict:
    """tool_use_id -> ToolResult。tool_result は後続の user 行にあるため先に索引化する。"""
    names: dict = {}
    out: dict = {}
    for rec in records:
        if not isinstance(rec, dict):
            continue
        for b in iter_assistant_blocks(rec):
            if b.get("type") == "tool_use":
                names[b.get("id")] = b.get("name") or "?"
        if rec.get("type") != "user":
            continue
        content = (rec.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        tur = rec.get("toolUseResult")
        for b in content:
            if not (isinstance(b, dict) and b.get("type") == "tool_result"):
                continue
            status, code = classify_tool_result(b, tur)
            persisted = None
            if isinstance(tur, dict) and tur.get("persistedOutputPath"):
                persisted = {
                    "path": tur["persistedOutputPath"],
                    "size": tur.get("persistedOutputSize"),
                }
            out[b.get("tool_use_id")] = ToolResult(
                status=status,
                exit_code=code,
                body=result_body(names.get(b.get("tool_use_id"), "?"), b, tur),
                persisted=persisted,
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


def prompts_report(
    stats: list,
    filters: SessionFilters,
    limit: int,
    max_chars: int,
    matcher: Matcher | None = None,
) -> dict:
    """matcher 指定時は一致したプロンプトだけを、一致箇所を中心に切り詰めて返す。"""
    items = []
    total = 0
    matched = 0
    for s in stats:
        for p in s.prompts:
            total += 1
            if matcher is not None and matcher.search(p.text) is None:
                continue
            matched += 1
            if limit > 0 and len(items) >= limit:
                continue
            text = clip(p.text, max_chars) if matcher is None else clip_around(p.text, matcher, max_chars)
            items.append(
                {
                    "ts": jst_str(p.ts),
                    "session_id": s.session_id[:8],
                    "project": s.project,
                    "chars": len(p.text),
                    "text": text,
                }
            )
    out = {"filters": filters.as_dict()}
    if matcher is not None:
        out["query"] = matcher.as_dict()
    out["total_prompts"] = total
    if matcher is not None:
        out["matched"] = matched
    out["shown"] = len(items)
    out["prompts"] = items
    return out


def tool_detail_entry(block: dict, result: ToolResult | None, opts: ToolDetailOptions) -> dict:
    """--tool-detail 用に 1 ツール呼び出しの入力と結果を整形する。"""
    name = block.get("name") or "?"
    entry = {
        "tool": name,
        "brief": tool_brief(block.get("input")),
        "input": clip(tool_input_text(name, block.get("input")), opts.input_chars),
        "result": None,  # セッション中断等で結果が無いこともある
    }
    if result is not None:
        entry["result"] = {
            "status": result.status,
            "exit_code": result.exit_code,
            "body": clip_head_tail(result.body, opts.result_chars),
            "persisted": result.persisted,
        }
    return entry


def transcript_turns(
    records: Sequence[dict],
    max_chars: int,
    include_tools: bool,
    tool_detail: ToolDetailOptions | None = None,
) -> list:
    """レコード列を表示用ターン列に変換する（順序保存）。

    tool_detail 指定時は tool_use と後続の tool_result を突き合わせるため、
    records は 2 回走査する（Sequence で受ける）。
    """
    results = index_tool_results(records) if tool_detail else {}
    include_tools = include_tools or tool_detail is not None
    turns = []
    for rec in records:
        if not isinstance(rec, dict):
            continue
        ts = jst_str(parse_ts(rec.get("timestamp")), seconds=True)
        text = prompt_text(rec)
        if text is not None:
            turns.append({"role": "user", "ts": ts, "text": clip(text, max_chars)})
            continue
        if rec.get("type") == "assistant" and not rec.get("isSidechain"):
            texts, tool_uses = [], []
            for b in iter_assistant_blocks(rec):
                if b.get("type") == "text" and b.get("text", "").strip():
                    texts.append(b["text"].strip())
                elif b.get("type") == "tool_use" and tool_detail:
                    tool_uses.append(tool_detail_entry(b, results.get(b.get("id")), tool_detail))
                elif b.get("type") == "tool_use":
                    tool_uses.append({"tool": b.get("name"), "brief": tool_brief(b.get("input"))})
            if texts:
                turns.append(
                    {"role": "assistant", "ts": ts, "text": clip("\n".join(texts), max_chars)}
                )
            if tool_uses and include_tools:
                turns.append({"role": "assistant:tools", "ts": ts, "tools": tool_uses})
        elif rec.get("type") == "system" and rec.get("subtype") == "compact_boundary":
            turns.append({"role": "system", "ts": ts, "text": "--- compact 発生 ---"})
    return turns


def apply_detail_budget(turns: list, budget: int) -> tuple:
    """ツール詳細の合計文字数が budget を超えたら、以降を {tool, brief} に戻す。

    先頭から数える（--tail 適用後のターン列に掛ける）。戻り値は
    (新しいターン列, brief に戻した件数)。budget <= 0 は無制限。
    """
    if budget <= 0:
        return turns, 0
    used = 0
    omitted = 0
    out = []
    for t in turns:
        if t.get("role") != "assistant:tools":
            out.append(t)
            continue
        tools = []
        for e in t["tools"]:
            if "input" not in e:
                tools.append(e)
                continue
            size = len(e["input"]) + len((e.get("result") or {}).get("body") or "")
            if used + size > budget:
                tools.append({"tool": e["tool"], "brief": e["brief"]})
                omitted += 1
                continue
            used += size
            tools.append(e)
        out.append({**t, "tools": tools})
    return out, omitted


# ============================================================
# 純粋層: 本文検索（search / prompts --grep）
# ============================================================

SEARCH_FIELDS = ("prompt", "assistant", "tool-input", "tool-result")
TOOL_FIELDS = ("tool-input", "tool-result")
REDACTED_MATCH_NOTE = "[一致箇所は伏せ字の対象]"


@dataclass(frozen=True)
class Matcher:
    """検索語の照合規則。既定は固定文字列・大文字小文字を区別しない。

    不正な正規表現は構築時に re.error を送出する（CLI 側でエラー報告）。
    """

    pattern: str
    regex: bool = False
    case_sensitive: bool = False
    _re: re.Pattern = field(init=False, repr=False, compare=False)

    def __post_init__(self):
        src = self.pattern if self.regex else re.escape(self.pattern)
        flags = 0 if self.case_sensitive else re.IGNORECASE
        object.__setattr__(self, "_re", re.compile(src, flags))

    def search(self, text: str) -> re.Match | None:
        return self._re.search(text) if text else None

    def as_dict(self) -> dict:
        return {"pattern": self.pattern, "regex": self.regex, "case_sensitive": self.case_sensitive}


def snippet_around(text: str, matcher: Matcher, context: int) -> str:
    """伏せ字を掛けた本文で一致箇所の前後 context 文字を切り出す。

    照合を伏せ字後にやり直すので、切り出し窓の端で秘密情報が途中から漏れることは
    ない。伏せ字後に一致しない（一致箇所が秘密情報の中にあった）ときは目印を返す。
    """
    red = redact(text)
    m = matcher.search(red)
    if m is None:
        return REDACTED_MATCH_NOTE
    start = max(0, m.start() - context)
    end = min(len(red), m.end() + context)
    body = red[start:end].replace("\n", " ")
    return ("…" if start > 0 else "") + body + ("…" if end < len(red) else "")


@dataclass(frozen=True)
class SearchUnit:
    """検索対象の本文 1 件（JSONL の行番号と由来つき）。"""

    line: int
    ts: datetime | None
    field: str
    tool: str | None
    text: str


@dataclass(frozen=True)
class SessionScan:
    title: str | None
    spawned_as_agent: bool
    hits: list  # list[dict]（行番号順）


def iter_search_units(numbered: Iterable[tuple]) -> Iterator[SearchUnit]:
    """(行番号, レコード) 列から検索対象の本文を列挙する。

    prompt は prompt_text の判定規則に従い、assistant は text ブロック（thinking は
    含めない）、tool-input は tool_input_text、tool-result は result_body。
    sidechain 行は対象外。
    """
    names: dict = {}
    for line, rec in numbered:
        if not isinstance(rec, dict) or rec.get("isSidechain"):
            continue
        ts = parse_ts(rec.get("timestamp"))
        text = prompt_text(rec)
        if text is not None:
            yield SearchUnit(line, ts, "prompt", None, text)
            continue
        if rec.get("type") == "assistant":
            texts = []
            for b in iter_assistant_blocks(rec):
                if b.get("type") == "text" and b.get("text", "").strip():
                    texts.append(b["text"])
                elif b.get("type") == "tool_use":
                    name = b.get("name") or "?"
                    names[b.get("id")] = name
                    yield SearchUnit(line, ts, "tool-input", name, tool_input_text(name, b.get("input")))
            if texts:
                yield SearchUnit(line, ts, "assistant", None, "\n".join(texts))
        elif rec.get("type") == "user":
            content = (rec.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    name = names.get(b.get("tool_use_id"), "?")
                    body = result_body(name, b, rec.get("toolUseResult"))
                    yield SearchUnit(line, ts, "tool-result", name, body)


def scan_session(
    numbered: Iterable[tuple],
    matcher: Matcher,
    fields_: tuple,
    tools: tuple | None,
    context: int,
) -> SessionScan:
    """1 セッション分の (行番号, レコード) 列を照合する。照合は生の本文に対して行う。"""
    records = list(numbered)
    title = None
    spawned = False
    for _, rec in records:
        if rec.get("type") == "ai-title" and rec.get("aiTitle"):
            title = rec["aiTitle"]
        elif rec.get("type") in ("agent-setting", "agent-name"):
            spawned = True
    hits = []
    for u in iter_search_units(records):
        if u.field not in fields_:
            continue
        if tools and u.field in TOOL_FIELDS and u.tool not in tools:
            continue
        if matcher.search(u.text) is None:
            continue
        hits.append(
            {
                "ts": jst_str(u.ts, seconds=True),
                "line": u.line,
                "field": u.field,
                "tool": u.tool,
                "snippet": snippet_around(u.text, matcher, context),
            }
        )
    return SessionScan(title=title, spawned_as_agent=spawned, hits=hits)


def search_report(
    scans: list,
    filters: SessionFilters,
    matcher: Matcher,
    fields_: tuple,
    tools: tuple | None,
    limit: int,
    per_session: int,
    by_session_top: int = 30,
) -> dict:
    """scans: list[(session_id, project, SessionScan)]（新しい順・走査した全セッション）。"""
    matched = [(sid, proj, sc) for sid, proj, sc in scans if sc.hits]
    # 件数の多い順。sort は安定なので同数なら新しい順が保たれる
    ranked = sorted(matched, key=lambda x: -len(x[2].hits))
    by_session = [
        {"session_id": sid[:8], "title": sc.title, "project": proj, "hits": len(sc.hits)}
        for sid, proj, sc in ranked[:by_session_top]
    ]
    shown = []
    for sid, _, sc in matched:
        for h in sc.hits[: per_session if per_session > 0 else None]:
            if limit > 0 and len(shown) >= limit:
                break
            shown.append({"session_id": sid[:8], **h})
    return {
        "filters": filters.as_dict(),
        "query": {**matcher.as_dict(), "in": list(fields_), "tool": list(tools) if tools else None},
        "scanned_sessions": len(scans),
        "sessions_matched": len(matched),
        "total_hits": sum(len(sc.hits) for _, _, sc in matched),
        "shown": len(shown),
        "by_session": by_session,
        "hits": shown,
    }


def clip_around(text: str, matcher: Matcher, max_chars: int) -> str:
    """伏せ字後の本文を、一致箇所が max_chars の窓に入るよう切り詰める。

    省いた側には `…(+N字)` を付ける。一致箇所が伏せ字の中なら先頭から切り詰める。
    """
    red = redact(text)
    if max_chars <= 0 or len(red) <= max_chars:
        return red
    m = matcher.search(red)
    if m is None:
        return truncate(red, max_chars)
    start = m.start() - (max_chars - (m.end() - m.start())) // 2
    start = max(0, min(start, len(red) - max_chars))
    end = start + max_chars
    head = f"(+{start}字)…" if start > 0 else ""
    tail = f"…(+{len(red) - end}字)" if end < len(red) else ""
    return head + red[start:end] + tail


def ccusage_argv(since: str | None, until: str | None, session: str | None) -> list:
    """フィルタ条件から ccusage の引数列を組み立てる（純粋）。

    金額（USD）の算出は ccusage だけが持つ（モデル別価格表と重複レコードの排除）。
    cclens はトークン量・コンテキスト増加は出すが USD 換算を持たないため、
    コスト観点はここから ccusage へ移譲する。Claude Code のみを対象にするため
    `claude` サブコマンド群を使い、日付グルーピングは JST に合わせる。
    モデル別内訳は daily の modelBreakdowns に含まれる。
    """
    if session:
        argv = ["claude", "session", "--id", session]
    else:
        argv = ["claude", "daily"]
    argv += ["--json", "--timezone", "Asia/Tokyo"]
    if since:
        argv += ["--since", since]
    if until:
        argv += ["--until", until]
    return argv


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


def iter_numbered_records(path: Path) -> Iterator[tuple]:
    """JSONL を1行ずつ寛容に読み、(1 始まりの物理行番号, レコード) を返す。壊れた行は捨てる。"""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for lineno, line in enumerate(f, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(obj, dict):
                    yield lineno, obj
    except OSError:
        return


def iter_records(path: Path) -> Iterator[dict]:
    """JSONL を1行ずつ寛容に読む。壊れた行は捨てる。"""
    for _, rec in iter_numbered_records(path):
        yield rec


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


def find_ccusage() -> list | None:
    """ccusage の起動コマンドを探す。直インストール → bunx → npx の順。"""
    if shutil.which("ccusage"):
        return ["ccusage"]
    if shutil.which("bunx"):
        return ["bunx", "ccusage"]
    if shutil.which("npx"):
        return ["npx", "-y", "ccusage"]
    return None


def run_ccusage(runner: list, argv: list, config_dir: Path) -> Any | None:
    """ccusage を実行して JSON を返す。失敗時は None（呼び出し側で報告）。

    --config-dir 上書き時も同じデータを見るよう CLAUDE_CONFIG_DIR を子プロセスに
    引き渡す（ccusage は同環境変数を尊重する）。
    """
    env = dict(os.environ)
    env["CLAUDE_CONFIG_DIR"] = str(config_dir)
    try:
        proc = subprocess.run(
            runner + argv, capture_output=True, text=True, timeout=180, env=env, check=False
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


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
    matcher = build_matcher(args) if args.grep else None
    stats = load_sessions(config_dir, filters)
    emit(prompts_report(stats, filters, args.limit, args.max_chars, matcher))


def cmd_cost(config_dir: Path, args) -> None:
    """金額（USD）を ccusage から取る。トークン量・skill 単位の内訳は cclens の領分。"""
    runner = find_ccusage()
    argv = ccusage_argv(args.since, args.until, args.session)
    if runner is None:
        emit(
            {
                "error": "ccusage が見つからない（金額算出は ccusage のみが持つ）",
                "hint": "npx -y ccusage / bunx ccusage / インストールのいずれかを用意する",
                "command": " ".join(["ccusage", *argv]),
            }
        )
        sys.exit(1)
    data = run_ccusage(runner, argv, config_dir)
    if data is None:
        emit({"error": "ccusage の実行に失敗", "command": " ".join(runner + argv)})
        sys.exit(1)
    emit(
        {
            "command": " ".join(runner + argv),
            "note": (
                "金額（USD）とトークン総量は ccusage の値を正とする"
                "（重複レコードの排除とモデル別価格計算済み）。"
                "skill 単位の消費・コンテキスト増加は cclens usage を使う"
            ),
            "data": data,
        }
    )


def split_csv(value: str | None) -> tuple:
    return tuple(x.strip() for x in value.split(",") if x.strip()) if value else ()


def build_matcher(args) -> Matcher:
    """CLI 引数から Matcher を作る（search は pattern、prompts は --grep）。

    不正な正規表現はエラーを出して終了する。
    """
    pattern = getattr(args, "pattern", None) or args.grep
    try:
        return Matcher(pattern, regex=args.regex, case_sensitive=args.case_sensitive)
    except re.error as e:
        emit({"error": f"正規表現が不正: {e}", "pattern": pattern})
        sys.exit(1)


def cmd_search(config_dir: Path, args) -> None:
    """全セッションの本文を横断検索し、ヒット位置（行番号）とスニペットを返す。"""
    matcher = build_matcher(args)
    tools = split_csv(args.tool) or None
    # --tool だけ指定されたらツールの入出力に絞る（prompt/assistant のヒットで埋もれないように）
    fields_ = split_csv(args.in_) or (TOOL_FIELDS if tools else SEARCH_FIELDS)
    unknown = [f for f in fields_ if f not in SEARCH_FIELDS]
    if unknown:
        emit({"error": f"--in に未知の対象: {unknown}", "choices": list(SEARCH_FIELDS)})
        sys.exit(1)
    filters = SessionFilters.from_args(args)
    scans = []
    for f in find_session_files(config_dir, filters):
        sc = scan_session(iter_numbered_records(f), matcher, fields_, tools, args.context)
        if not filters.include_agents and sc.spawned_as_agent:
            continue
        scans.append((f.stem, f.parent.name, sc))
    emit(search_report(scans, filters, matcher, fields_, tools, args.limit, args.per_session))


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
    records = list(iter_records(path))
    s = reduce_session(path.stem, path.parent.name, records)
    s.subagent_files = subagent_file_count(path)
    detail = (
        ToolDetailOptions(
            input_chars=args.input_chars,
            result_chars=args.result_chars,
            budget=args.detail_budget,
        )
        if args.tool_detail
        else None
    )
    turns = transcript_turns(records, args.max_chars, args.include_tools, detail)
    if args.tail > 0:
        turns = turns[-args.tail :]
    out = {"session": summarize_session(s), "turn_count": len(turns)}
    if detail:
        turns, omitted = apply_detail_budget(turns, detail.budget)
        out["detail_omitted"] = omitted
    out["turns"] = turns
    emit(out)


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
    sp.add_argument("--grep", help="本文にこの語を含むプロンプトだけを出す（一致箇所を中心に切り詰める）")
    sp.add_argument("--regex", action="store_true", help="--grep を正規表現として扱う")
    sp.add_argument("--case-sensitive", action="store_true", help="--grep で大文字小文字を区別する")

    sp = sub.add_parser("cost", help="トークン消費と金額（USD）を ccusage から取得")
    sp.add_argument("--since", help="JST日付 YYYY-MM-DD")
    sp.add_argument("--until", help="JST日付 YYYY-MM-DD（その日を含む）")
    sp.add_argument("--session", help="セッションID（指定時は日次でなくセッション単位）")

    sp = sub.add_parser("search", help="全セッションの本文を横断検索（ヒット位置とスニペット）")
    sp.add_argument("pattern", help="検索語（既定は固定文字列・大文字小文字を区別しない）")
    sp.add_argument("--regex", action="store_true", help="pattern を正規表現として扱う")
    sp.add_argument("--case-sensitive", action="store_true", help="大文字小文字を区別する")
    sp.add_argument(
        "--in",
        dest="in_",
        help=f"検索対象（カンマ区切り: {','.join(SEARCH_FIELDS)}。既定は全部、--tool 指定時は tool-input,tool-result）",
    )
    sp.add_argument("--tool", help="tool-input / tool-result を指定ツールに絞る（カンマ区切り。例: Bash,Edit）")
    add_filter_args(sp)
    sp.add_argument("--limit", type=int, default=40, help="表示するヒットの最大件数（既定40、0で無制限）")
    sp.add_argument(
        "--per-session", type=int, default=3, help="1 セッションあたりの表示件数（既定3、0で無制限）"
    )
    sp.add_argument("--context", type=int, default=80, help="スニペットの前後文字数（既定80）")

    sp = sub.add_parser("transcript", help="単一セッションの会話抽出")
    sp.add_argument("--session", required=True, help="セッションIDの前方一致（一意になる長さで）")
    sp.add_argument(
        "--max-chars", type=int, default=400, help="各発話の切り詰め文字数（既定400、0で無制限）"
    )
    sp.add_argument("--tail", type=int, default=0, help="末尾Nターンのみ表示（既定0=全部）")
    sp.add_argument("--include-tools", action="store_true", help="ツール呼び出し行も含める")
    sp.add_argument(
        "--tool-detail",
        action="store_true",
        help="ツールの入力全文と結果（status・exit_code・本文抜粋）も含める（--include-tools を含意）",
    )
    sp.add_argument(
        "--input-chars", type=int, default=300, help="ツール入力の切り詰め文字数（既定300、0で無制限）"
    )
    sp.add_argument(
        "--result-chars",
        type=int,
        default=600,
        help="ツール結果の切り詰め文字数。先頭と末尾を残す（既定600、0で無制限）",
    )
    sp.add_argument(
        "--detail-budget",
        type=int,
        default=30000,
        help="ツール詳細の合計文字数の上限。超えた分は brief に戻す（既定30000、0で無制限）",
    )
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
        "cost": lambda: cmd_cost(config_dir, args),
        "search": lambda: cmd_search(config_dir, args),
        "transcript": lambda: cmd_transcript(config_dir, args),
    }
    handlers[args.cmd]()
    return 0


if __name__ == "__main__":
    sys.exit(main())
