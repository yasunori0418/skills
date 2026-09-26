#!/usr/bin/env python3
"""collect_sessions.py のテスト。

実行: uv run --project "<skill-dir>" pytest
（unittest 形式なので `uv run --project "<skill-dir>" python <このファイル>` でも可）

純粋層（レコード解釈・reduce_session・レポート整形）は合成レコードで検証し、
副作用層（ファイル走査・CLI）は一時ディレクトリに合成 JSONL を置いて
end-to-end で検証する。実環境の ~/.claude には一切触れない。
"""
from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

import collect_sessions as cs

# ============================================================
# 合成レコードのヘルパ
# ============================================================


def user_rec(text, ts="2026-07-01T03:00:00.000Z", **extra):
    rec = {
        "type": "user",
        "timestamp": ts,
        "cwd": "/home/u/proj",
        "gitBranch": "main",
        "version": "2.1.200",
        "message": {"role": "user", "content": text},
    }
    rec.update(extra)
    return rec


def assistant_rec(blocks, usage=None, model="claude-fable-5", ts="2026-07-01T03:01:00.000Z"):
    return {
        "type": "assistant",
        "timestamp": ts,
        "message": {"role": "assistant", "model": model, "content": blocks, "usage": usage or {}},
    }


def tool_use(name, tool_input, tool_id="tu_1"):
    return {"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}


# ============================================================
# 純粋層: 基本変換
# ============================================================


class TestBasics(unittest.TestCase):
    def test_parse_ts_valid(self):
        dt = cs.parse_ts("2026-06-27T13:13:23.686Z")
        assert dt is not None
        self.assertEqual(dt.tzinfo, timezone.utc)
        self.assertEqual(dt.year, 2026)

    def test_parse_ts_invalid(self):
        self.assertIsNone(cs.parse_ts(None))
        self.assertIsNone(cs.parse_ts(12345))
        self.assertIsNone(cs.parse_ts("not-a-date"))

    def test_jst_str_converts_to_jst(self):
        dt = cs.parse_ts("2026-06-27T15:00:00.000Z")  # UTC 15:00 → JST 翌0:00
        self.assertEqual(cs.jst_str(dt), "2026-06-28 00:00 JST")
        self.assertEqual(cs.jst_str(dt, seconds=True), "2026-06-28 00:00:00 JST")
        self.assertIsNone(cs.jst_str(None))

    def test_parse_jst_date(self):
        dt = cs.parse_jst_date("2026-07-01")
        assert dt is not None
        self.assertEqual((dt.year, dt.month, dt.day), (2026, 7, 1))
        self.assertEqual(dt.tzinfo, cs.JST)
        self.assertIsNone(cs.parse_jst_date(None))
        self.assertIsNone(cs.parse_jst_date("07/01"))

    def test_human_duration(self):
        self.assertEqual(cs.human_duration(5), "5s")
        self.assertEqual(cs.human_duration(65), "1m05s")
        self.assertEqual(cs.human_duration(3665), "1h01m")
        self.assertIsNone(cs.human_duration(None))
        self.assertIsNone(cs.human_duration(-1))

    def test_truncate(self):
        self.assertEqual(cs.truncate("abc", 10), "abc")
        self.assertEqual(cs.truncate("abcdef", 3), "abc…(+3字)")
        self.assertEqual(cs.truncate("abcdef", 0), "abcdef")  # 0 = 無制限

    def test_in_range_until_inclusive(self):
        since = cs.parse_jst_date("2026-07-01")
        until = cs.parse_jst_date("2026-07-02")
        inside = datetime(2026, 7, 2, 23, 59, tzinfo=cs.JST)
        outside = datetime(2026, 7, 3, 0, 0, tzinfo=cs.JST)
        self.assertTrue(cs.in_range(inside, since, until))
        self.assertFalse(cs.in_range(outside, since, until))
        self.assertFalse(cs.in_range(datetime(2026, 6, 30, tzinfo=cs.JST), since, until))


class TestRedact(unittest.TestCase):
    """秘密情報の伏せ字。

    テスト用の偽トークンは連結で組み立てる（リポジトリの secret scanning に
    実トークンと誤認させないため）。
    """

    def test_token_kinds(self):
        cases = {
            "github_token": "ghp_" + "a1" * 18,
            "anthropic_key": "sk-ant-" + "x" * 30,
            "openai_key": "sk-proj-" + "y" * 30,
            "slack_token": "xox" + "b-" + "1234567890-abc",
            "aws_access_key": "AKIA" + "ABCDEFGH12345678",
            "google_api_key": "AIza" + "z" * 35,
            "jwt": "eyJ" + "hbGc.eyJzdWIi.sig_Nature",
        }
        for kind, token in cases.items():
            with self.subTest(kind=kind):
                out = cs.redact(f"value {token} end")
                self.assertEqual(out, f"value [REDACTED:{kind}] end")

    def test_private_key_block(self):
        pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIE\nabc\n-----END RSA PRIVATE KEY-----"
        self.assertEqual(cs.redact(f"a\n{pem}\nb"), "a\n[REDACTED:private_key]\nb")
        # END が無い（途中で切れた）鍵も末尾まで伏せる
        self.assertEqual(cs.redact("x -----BEGIN PRIVATE KEY-----\nMIIE"), "x [REDACTED:private_key]")

    def test_keeps_key_name(self):
        self.assertEqual(cs.redact("DB_PASSWORD=hunter22"), "DB_PASSWORD=[REDACTED:assignment]")
        self.assertEqual(cs.redact('"api_key": "abcd1234"'), '"api_key": "[REDACTED:assignment]"')
        self.assertEqual(
            cs.redact("Authorization: Bearer abc.def"), "Authorization: Bearer [REDACTED:bearer]"
        )
        self.assertEqual(
            cs.redact("https://user:pa55@example.com/x"),
            "https://[REDACTED:url_credential]@example.com/x",
        )

    def test_assignment_does_not_swallow_earlier_mark(self):
        token = "ghp_" + "b" * 36
        self.assertEqual(cs.redact(f"GH_TOKEN={token}"), "GH_TOKEN=[REDACTED:github_token]")

    def test_plain_text_untouched_and_idempotent(self):
        text = "git check-ignore -v tmp_claude/ ; echo $?\ntoken: 0"
        self.assertEqual(cs.redact(text), text)
        once = cs.redact("PASSWORD=hunter22 " + "sk-ant-" + "x" * 30)
        self.assertEqual(cs.redact(once), once)

    def test_clip_redacts_before_truncate(self):
        """切り詰め位置をまたぐ秘密情報の断片が漏れない。"""
        token = "ghp_" + "c" * 36
        out = cs.clip("abc " + token, 20)
        self.assertNotIn("ghp_ccc", out)
        self.assertTrue(out.startswith("abc [REDACTED:github"))


class TestTokenUsage(unittest.TestCase):
    def test_from_api_usage(self):
        u = cs.TokenUsage.from_api_usage(
            {
                "input_tokens": 10,
                "output_tokens": 20,
                "cache_read_input_tokens": 30,
                "cache_creation_input_tokens": 40,
                "extra_field": "ignored",
            }
        )
        self.assertEqual((u.input, u.output, u.cache_read, u.cache_creation), (10, 20, 30, 40))
        self.assertEqual(u.context_size, 80)

    def test_from_api_usage_tolerant(self):
        self.assertEqual(cs.TokenUsage.from_api_usage(None), cs.TokenUsage())
        self.assertEqual(cs.TokenUsage.from_api_usage({"input_tokens": "bad"}).input, 0)

    def test_add_is_immutable(self):
        a = cs.TokenUsage(input=1)
        b = cs.TokenUsage(input=2, output=5)
        c = a + b
        self.assertEqual(c.input, 3)
        self.assertEqual(c.output, 5)
        self.assertEqual(a.input, 1)  # 元は不変

    def test_as_dict(self):
        d = cs.TokenUsage(input=1, output=2).as_dict()
        self.assertEqual(d, {"input": 1, "output": 2, "cache_read": 0, "cache_creation": 0})


# ============================================================
# 純粋層: レコード解釈
# ============================================================


class TestPromptText(unittest.TestCase):
    def test_plain_prompt(self):
        self.assertEqual(cs.prompt_text(user_rec("バグを直して")), "バグを直して")

    def test_excludes_meta_and_sidechain_and_compact(self):
        self.assertIsNone(cs.prompt_text(user_rec("x", isMeta=True)))
        self.assertIsNone(cs.prompt_text(user_rec("x", isSidechain=True)))
        self.assertIsNone(cs.prompt_text(user_rec("x", isCompactSummary=True)))

    def test_excludes_command_echo_and_stdout(self):
        self.assertIsNone(cs.prompt_text(user_rec("<command-name>/mcp</command-name>")))
        self.assertIsNone(cs.prompt_text(user_rec("<local-command-stdout>ok</local-command-stdout>")))

    def test_excludes_caveat_and_notifications(self):
        self.assertIsNone(cs.prompt_text(user_rec("Caveat: the messages below...")))
        self.assertIsNone(cs.prompt_text(user_rec("<task-notification>done</task-notification>")))
        self.assertIsNone(cs.prompt_text(user_rec("<system-reminder>x</system-reminder>")))

    def test_excludes_tool_result_only(self):
        rec = user_rec([{"type": "tool_result", "tool_use_id": "tu_1", "content": "ok"}])
        self.assertIsNone(cs.prompt_text(rec))

    def test_text_blocks_joined(self):
        rec = user_rec([{"type": "text", "text": "a"}, {"type": "text", "text": "b"}])
        self.assertEqual(cs.prompt_text(rec), "a\nb")

    def test_non_user_record(self):
        self.assertIsNone(cs.prompt_text({"type": "assistant"}))


class TestRecordHelpers(unittest.TestCase):
    def test_extract_command_names(self):
        text = "<command-name>/commit-flow</command-name> x <command-name>/mcp</command-name>"
        self.assertEqual(cs.extract_command_names(text), ["/commit-flow", "/mcp"])
        self.assertEqual(cs.extract_command_names(None), [])

    def test_tool_brief_priority_and_truncation(self):
        self.assertEqual(cs.tool_brief({"command": "ls -la"}), "ls -la")
        self.assertEqual(cs.tool_brief({"description": "説明", "command": "ls"}), "説明")
        self.assertEqual(cs.tool_brief("not-a-dict"), "")
        long = cs.tool_brief({"command": "x" * 200})
        self.assertTrue(long.startswith("x" * 100))

    def test_tool_result_errors_maps_tool_name(self):
        rec = user_rec(
            [
                {"type": "tool_result", "tool_use_id": "tu_9", "is_error": True, "content": "boom\nline2"},
                {"type": "tool_result", "tool_use_id": "tu_x", "content": "fine"},
            ]
        )
        errs = cs.tool_result_errors(rec, {"tu_9": "Bash"})
        self.assertEqual(len(errs), 1)
        self.assertEqual(errs[0].tool, "Bash")
        self.assertEqual(errs[0].message, "boom line2")

    def test_tool_result_errors_content_list(self):
        rec = user_rec(
            [
                {
                    "type": "tool_result",
                    "tool_use_id": "tu_1",
                    "is_error": True,
                    "content": [{"type": "text", "text": "err"}],
                }
            ]
        )
        errs = cs.tool_result_errors(rec, {})
        self.assertEqual(errs[0].message, "err")
        self.assertEqual(errs[0].tool, "?")


# ============================================================
# 純粋層: セッション畳み込み
# ============================================================


def synthetic_records():
    """代表的なレコード型を一通り含む合成セッション。"""
    return [
        {"type": "permission-mode", "permissionMode": "acceptEdits", "sessionId": "s1"},
        {"type": "ai-title", "aiTitle": "テストセッション", "sessionId": "s1"},
        user_rec("最初の依頼", ts="2026-07-01T03:00:00.000Z"),
        assistant_rec(
            [
                {"type": "text", "text": "了解"},
                tool_use("Bash", {"command": "ls"}, "tu_1"),
                tool_use("Skill", {"skill": "commit-flow"}, "tu_2"),
                tool_use("Task", {"subagent_type": "Explore"}, "tu_3"),
            ],
            usage={
                "input_tokens": 100,
                "output_tokens": 50,
                "cache_read_input_tokens": 1000,
                "cache_creation_input_tokens": 200,
            },
            ts="2026-07-01T03:01:00.000Z",
        ),
        user_rec(
            [{"type": "tool_result", "tool_use_id": "tu_1", "is_error": True, "content": "exit 1"}],
            ts="2026-07-01T03:02:00.000Z",
        ),
        {
            "type": "system",
            "subtype": "compact_boundary",
            "timestamp": "2026-07-01T03:03:00.000Z",
            "compactMetadata": {"trigger": "auto", "preTokens": 150000},
        },
        {"type": "system", "subtype": "turn_duration", "durationMs": 60000},
        {
            "type": "system",
            "subtype": "local_command",
            "content": "<command-name>/mcp</command-name>",
            "timestamp": "2026-07-01T03:04:00.000Z",
        },
        {"type": "pr-link", "prUrl": "https://github.com/o/r/pull/1", "sessionId": "s1"},
        user_rec("<command-name>/commit-flow</command-name>", ts="2026-07-01T03:05:00.000Z"),
        assistant_rec(
            [{"type": "text", "text": "完了"}],
            usage={"input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 2000},
            ts="2026-07-01T03:06:00.000Z",
        ),
    ]


class TestReduceSession(unittest.TestCase):
    def setUp(self):
        self.s = cs.reduce_session("s1", "-home-u-proj", synthetic_records())

    def test_metadata(self):
        self.assertEqual(self.s.session_id, "s1")
        self.assertEqual(self.s.title, "テストセッション")
        self.assertEqual(self.s.cwd, "/home/u/proj")
        self.assertEqual(self.s.git_branch, "main")
        self.assertFalse(self.s.spawned_as_agent)
        self.assertEqual(self.s.permission_modes, {"acceptEdits"})
        self.assertEqual(self.s.pr_links, ["https://github.com/o/r/pull/1"])

    def test_time_range(self):
        self.assertEqual(cs.jst_str(self.s.first), "2026-07-01 12:00 JST")
        self.assertEqual(cs.jst_str(self.s.last), "2026-07-01 12:06 JST")
        self.assertEqual(self.s.duration_sec, 360)

    def test_prompts_exclude_command_echo(self):
        self.assertEqual([p.text for p in self.s.prompts], ["最初の依頼"])

    def test_tools_skills_agents(self):
        self.assertEqual(self.s.tools, {"Bash": 1, "Skill": 1, "Task": 1})
        self.assertEqual(self.s.skills, {"commit-flow": 1})
        self.assertEqual(self.s.agents, {"Explore": 1})

    def test_commands_from_user_and_system(self):
        self.assertEqual(self.s.commands, {"/commit-flow": 1, "/mcp": 1})

    def test_usage_and_peak(self):
        self.assertEqual(self.s.usage.input, 110)
        self.assertEqual(self.s.usage.output, 55)
        self.assertEqual(self.s.usage.cache_read, 3000)
        # peak = max(100+1000+200, 10+2000+0)
        self.assertEqual(self.s.peak_context, 2010)

    def test_error_maps_to_tool(self):
        self.assertEqual(len(self.s.errors), 1)
        self.assertEqual(self.s.errors[0].tool, "Bash")

    def test_compaction_and_turns(self):
        self.assertEqual(len(self.s.compactions), 1)
        self.assertEqual(self.s.compactions[0].trigger, "auto")
        self.assertEqual(self.s.turn_ms, [60000])

    def test_agent_spawned_session(self):
        recs = [{"type": "agent-setting", "agentSetting": "Explore"}]
        s = cs.reduce_session("s2", "p", recs)
        self.assertTrue(s.spawned_as_agent)
        self.assertEqual(s.agent_type, "Explore")

    def test_tolerant_of_garbage(self):
        garbage: list = [None, "str", {}, {"type": "unknown-future-type"}]
        s = cs.reduce_session("s3", "p", garbage)
        self.assertEqual(s.assistant_msgs, 0)
        self.assertEqual(len(s.prompts), 0)


# ============================================================
# 純粋層: レポート整形
# ============================================================


class TestReports(unittest.TestCase):
    def setUp(self):
        self.stats = cs.reduce_session("abcdef12-3456", "-home-u-proj", synthetic_records())
        self.filters = cs.SessionFilters(project="proj")

    def test_summarize_session_fields(self):
        self.stats.subagent_files = 2
        d = cs.summarize_session(self.stats)
        self.assertEqual(d["session_id"], "abcdef12-3456")
        self.assertEqual(d["prompts"], 1)
        self.assertEqual(d["subagent_files"], 2)
        self.assertEqual(d["errors"], 1)
        self.assertEqual(d["duration"], "6m00s")
        self.assertIsNone(d["spawned_as_agent"])
        self.assertEqual(d["usage"]["input"], 110)

    def test_sessions_report_limit_and_aggregate(self):
        rep = cs.sessions_report([self.stats, self.stats], self.filters, limit=1)
        self.assertEqual(rep["total_matched"], 2)
        self.assertEqual(rep["shown"], 1)
        self.assertEqual(rep["aggregate"]["prompts"], 1)
        self.assertEqual(rep["aggregate"]["usage"]["input"], 110)

    def test_prompts_report_truncation(self):
        rep = cs.prompts_report([self.stats], self.filters, limit=10, max_chars=3)
        self.assertEqual(rep["total_prompts"], 1)
        self.assertTrue(rep["prompts"][0]["text"].startswith("最初の"))
        self.assertEqual(rep["prompts"][0]["chars"], len("最初の依頼"))

    def test_transcript_turns(self):
        turns = cs.transcript_turns(synthetic_records(), max_chars=100, include_tools=True)
        roles = [t["role"] for t in turns]
        self.assertEqual(
            roles, ["user", "assistant", "assistant:tools", "system", "assistant"]
        )
        self.assertEqual(turns[0]["text"], "最初の依頼")
        self.assertEqual(turns[2]["tools"][0], {"tool": "Bash", "brief": "ls"})
        self.assertIn("compact", turns[3]["text"])


def tool_result_rec(tool_id, content, tool_use_result, is_error=False, ts="2026-07-01T03:02:00.000Z"):
    block = {"type": "tool_result", "tool_use_id": tool_id, "content": content}
    if is_error:
        block["is_error"] = True
    rec = user_rec([block], ts=ts)
    rec["toolUseResult"] = tool_use_result
    return rec


def detail_records():
    """ツールの入力と結果を突き合わせる検証用の合成セッション。"""
    return [
        user_rec("ignore 状態を確認して"),
        assistant_rec(
            [
                tool_use("Bash", {"command": "git check-ignore -v tmp_claude/", "description": "確認"}, "tu_ok"),
                tool_use("Bash", {"command": "false"}, "tu_ng"),
                tool_use("Read", {"file_path": "/x/a.py"}, "tu_rd"),
            ]
        ),
        tool_result_rec(
            "tu_ok",
            ".gitignore:3:tmp_claude/\ttmp_claude/",
            {"stdout": ".gitignore:3:tmp_claude/\ttmp_claude/", "stderr": "", "interrupted": False},
        ),
        tool_result_rec("tu_ng", "Exit code 1\nboom", "Error: Exit code 1\nboom", is_error=True),
        tool_result_rec(
            "tu_rd",
            "1\tprint(1)",
            {"type": "text", "file": {"filePath": "/x/a.py", "content": "print(1)", "numLines": 1}},
        ),
    ]


class TestToolResults(unittest.TestCase):
    def test_classify(self):
        ok = {"type": "tool_result", "content": "x"}
        err = {"type": "tool_result", "content": "x", "is_error": True}
        cases = [
            (ok, {"stdout": "x", "interrupted": False}, ("ok", None)),
            (ok, {"stdout": "", "interrupted": True}, ("interrupted", None)),
            (err, "Error: Exit code 2\nno such file", ("exit", 2)),
            (err, "Error: PreToolUse:Bash hook error: 🚫 blocked", ("hook_blocked", None)),
            (err, "Error: Permission for this action was denied", ("permission_denied", None)),
            (err, "User rejected tool use", ("user_rejected", None)),
            (err, "Error: File has not been read yet.", ("error", None)),
        ]
        for block, tur, expected in cases:
            with self.subTest(tur=tur):
                self.assertEqual(cs.classify_tool_result(block, tur), expected)

    def test_classify_falls_back_to_block_content(self):
        block = {"type": "tool_result", "content": "Exit code 127\ncmd: not found", "is_error": True}
        self.assertEqual(cs.classify_tool_result(block, None), ("exit", 127))

    def test_result_body_per_tool(self):
        ok = {"type": "tool_result", "content": "raw"}
        self.assertEqual(cs.result_body("Bash", ok, {"stdout": "out", "stderr": ""}), "out")
        self.assertEqual(
            cs.result_body("Bash", ok, {"stdout": "out", "stderr": "warn"}), "out\n[stderr]\nwarn"
        )
        read = {"file": {"filePath": "/a", "content": "SECRET BODY", "numLines": 9}}
        body = cs.result_body("Read", ok, read)
        self.assertNotIn("SECRET BODY", body)
        self.assertIn("/a", body)
        edit = {"filePath": "/b", "structuredPatch": [{}, {}], "oldString": "o", "newString": "n"}
        self.assertEqual(cs.result_body("Edit", ok, edit), "/b（2 hunk を変更）")
        agent = {"type": "tool_result", "content": [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]}
        self.assertEqual(cs.result_body("Agent", agent, {"status": "completed"}), "a\nb")
        err = {"type": "tool_result", "content": "Exit code 1\nboom", "is_error": True}
        self.assertEqual(cs.result_body("Bash", err, "Error: Exit code 1\nboom"), "Exit code 1\nboom")

    def test_index_tool_results_and_persisted(self):
        recs = detail_records()
        recs.append(
            tool_result_rec(
                "tu_big",
                "…",
                {"stdout": "x", "stderr": "", "persistedOutputPath": "/t/r.txt", "persistedOutputSize": 99999},
            )
        )
        idx = cs.index_tool_results(recs)
        self.assertEqual(idx["tu_ok"].status, "ok")
        self.assertIsNone(idx["tu_ok"].exit_code)
        self.assertEqual((idx["tu_ng"].status, idx["tu_ng"].exit_code), ("exit", 1))
        self.assertEqual(idx["tu_big"].persisted, {"path": "/t/r.txt", "size": 99999})

    def test_truncate_head_tail(self):
        self.assertEqual(cs.truncate_head_tail("abc", 10), "abc")
        self.assertEqual(cs.truncate_head_tail("abcdef", 0), "abcdef")
        out = cs.truncate_head_tail("0123456789", 5)
        self.assertEqual(out, "012…(中略 5字)…89")


class TestTranscriptToolDetail(unittest.TestCase):
    def test_include_tools_stays_brief(self):
        """--include-tools だけなら従来どおり {tool, brief}。"""
        turns = cs.transcript_turns(detail_records(), max_chars=100, include_tools=True)
        tools = next(t for t in turns if t["role"] == "assistant:tools")["tools"]
        self.assertEqual(tools[0], {"tool": "Bash", "brief": "確認"})

    def test_detail_joins_input_and_result(self):
        turns = cs.transcript_turns(
            detail_records(), max_chars=100, include_tools=False, tool_detail=cs.ToolDetailOptions()
        )
        tools = next(t for t in turns if t["role"] == "assistant:tools")["tools"]
        ok, ng, rd = tools
        self.assertEqual(ok["input"], "git check-ignore -v tmp_claude/")
        self.assertEqual(ok["result"]["status"], "ok")
        self.assertIn(".gitignore:3", ok["result"]["body"])
        self.assertEqual((ng["result"]["status"], ng["result"]["exit_code"]), ("exit", 1))
        self.assertNotIn("print(1)", rd["result"]["body"])

    def test_detail_redacts_and_clips(self):
        token = "ghp_" + "d" * 36
        recs = [
            assistant_rec([tool_use("Bash", {"command": f"echo {token}"}, "tu_s")]),
            tool_result_rec("tu_s", token, {"stdout": "A" * 50 + token + "Z" * 50, "stderr": ""}),
        ]
        opts = cs.ToolDetailOptions(input_chars=300, result_chars=40)
        turns = cs.transcript_turns(recs, max_chars=100, include_tools=False, tool_detail=opts)
        e = turns[0]["tools"][0]
        self.assertEqual(e["input"], "echo [REDACTED:github_token]")
        self.assertNotIn("ghp_", e["result"]["body"])
        self.assertTrue(e["result"]["body"].endswith("Z" * 16))

    def test_missing_result_is_none(self):
        recs = [assistant_rec([tool_use("Bash", {"command": "sleep 9"}, "tu_x")])]
        turns = cs.transcript_turns(recs, 100, False, cs.ToolDetailOptions())
        self.assertIsNone(turns[0]["tools"][0]["result"])

    def test_budget_falls_back_to_brief(self):
        turns = cs.transcript_turns(detail_records(), 100, False, cs.ToolDetailOptions())
        first = turns[1]["tools"][0]
        budget = len(first["input"]) + len(first["result"]["body"])
        limited, omitted = cs.apply_detail_budget(turns, budget)
        self.assertEqual(omitted, 2)
        self.assertIn("input", limited[1]["tools"][0])
        self.assertEqual(limited[1]["tools"][1], {"tool": "Bash", "brief": "false"})
        self.assertEqual(cs.apply_detail_budget(turns, 0), (turns, 0))


def numbered(records):
    return list(enumerate(records, start=1))


class TestMatcher(unittest.TestCase):
    def test_fixed_string_ignores_case_and_metachars(self):
        m = cs.Matcher("TMP_CLAUDE (x)")
        self.assertIsNotNone(m.search("see tmp_claude (x) here"))
        self.assertIsNone(m.search("tmp_claude x"))

    def test_regex_and_case_sensitive(self):
        self.assertIsNotNone(cs.Matcher(r"check-ignore\s+-v", regex=True).search("git check-ignore  -v a"))
        self.assertIsNone(cs.Matcher("ABC", case_sensitive=True).search("abc"))

    def test_invalid_regex_raises(self):
        with self.assertRaises(cs.re.error):
            cs.Matcher("(", regex=True)

    def test_snippet_around(self):
        m = cs.Matcher("needle")
        self.assertEqual(cs.snippet_around("aaaa needle bbbb", m, 2), "…a needle b…")
        self.assertEqual(cs.snippet_around("needle\nx", m, 10), "needle x")

    def test_snippet_never_leaks_secret_fragment(self):
        token = "ghp_" + "e" * 36
        out = cs.snippet_around(f"export GH={token} # needle", cs.Matcher("needle"), 10)
        self.assertNotIn("eeee", out)
        # 一致箇所そのものが秘密情報の中にある
        self.assertEqual(cs.snippet_around(token, cs.Matcher("eeee"), 10), cs.REDACTED_MATCH_NOTE)


class TestSearch(unittest.TestCase):
    def scan(self, pattern="tmp_claude", fields_=cs.SEARCH_FIELDS, tools=None, records=None):
        recs = detail_records() if records is None else records
        return cs.scan_session(numbered(recs), cs.Matcher(pattern), fields_, tools, 20)

    def test_hits_all_fields_with_line_numbers(self):
        sc = self.scan()
        got = [(h["line"], h["field"], h["tool"]) for h in sc.hits]
        self.assertEqual(
            got,
            [(2, "tool-input", "Bash"), (3, "tool-result", "Bash")],
        )
        self.assertFalse(sc.spawned_as_agent)

    def test_field_and_tool_filters(self):
        self.assertEqual([h["field"] for h in self.scan("ignore", ("prompt",)).hits], ["prompt"])
        sc = self.scan("a", cs.TOOL_FIELDS, ("Read",))
        self.assertTrue(sc.hits)
        self.assertTrue(all(h["tool"] == "Read" for h in sc.hits))

    def test_excludes_sidechain_and_meta(self):
        recs = [
            user_rec("needle meta", isMeta=True),
            user_rec("needle side", isSidechain=True),
            {**assistant_rec([{"type": "text", "text": "needle"}]), "isSidechain": True},
            user_rec("<system-reminder>needle</system-reminder>"),
        ]
        self.assertEqual(self.scan("needle", records=recs).hits, [])

    def test_title_and_spawned(self):
        recs = [{"type": "ai-title", "aiTitle": "T"}, {"type": "agent-setting", "agentSetting": "Explore"}]
        sc = self.scan(records=recs)
        self.assertEqual((sc.title, sc.spawned_as_agent), ("T", True))

    def test_report_limits_keep_totals(self):
        def scan_with(n):
            return cs.SessionScan(title=None, spawned_as_agent=False, hits=[{"line": i} for i in range(n)])

        scans = [("s-new", "p", scan_with(2)), ("s-none", "p", scan_with(0)), ("s-old", "p", scan_with(5))]
        rep = cs.search_report(
            scans, cs.SessionFilters(), cs.Matcher("x"), cs.SEARCH_FIELDS, None, limit=3, per_session=2
        )
        self.assertEqual(
            (rep["scanned_sessions"], rep["sessions_matched"], rep["total_hits"], rep["shown"]), (3, 2, 7, 3)
        )
        self.assertEqual([h["session_id"] for h in rep["hits"]], ["s-new", "s-new", "s-old"])
        self.assertEqual([b["session_id"] for b in rep["by_session"]], ["s-old", "s-new"])
        self.assertEqual(rep["by_session"][0]["hits"], 5)


class TestCcusageArgv(unittest.TestCase):
    def test_daily_with_range(self):
        argv = cs.ccusage_argv("2026-07-01", "2026-07-08", None)
        self.assertEqual(
            argv,
            [
                "claude",
                "daily",
                "--json",
                "--timezone",
                "Asia/Tokyo",
                "--since",
                "2026-07-01",
                "--until",
                "2026-07-08",
            ],
        )

    def test_session_id_takes_precedence(self):
        argv = cs.ccusage_argv(None, None, "abc123")
        self.assertEqual(argv[:4], ["claude", "session", "--id", "abc123"])
        self.assertIn("--json", argv)

    def test_no_filters(self):
        self.assertEqual(
            cs.ccusage_argv(None, None, None),
            ["claude", "daily", "--json", "--timezone", "Asia/Tokyo"],
        )


class TestSessionFilters(unittest.TestCase):
    def test_as_dict_omits_empty(self):
        f = cs.SessionFilters(project="x")
        self.assertEqual(f.as_dict(), {"project": "x"})
        self.assertEqual(cs.SessionFilters().as_dict(), {})

    def test_include_agents_visible(self):
        f = cs.SessionFilters(include_agents=True)
        self.assertEqual(f.as_dict(), {"include_agents": True})


class TestResolveConfigDir(unittest.TestCase):
    def test_priority(self):
        d, src = cs.resolve_config_dir("/tmp/x", env={"CLAUDE_CONFIG_DIR": "/tmp/y"})
        self.assertEqual((str(d), src), ("/tmp/x", "cli:--config-dir"))
        d, src = cs.resolve_config_dir(None, env={"CLAUDE_CONFIG_DIR": "/tmp/y"})
        self.assertEqual((str(d), src), ("/tmp/y", "env:CLAUDE_CONFIG_DIR"))
        d, src = cs.resolve_config_dir(None, env={})
        self.assertEqual(src, "default:~/.claude")
        self.assertTrue(str(d).endswith("/.claude"))


# ============================================================
# 副作用層: 一時ディレクトリでの end-to-end
# ============================================================


class TestCli(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        proj = root / "projects" / "-home-u-proj"
        proj.mkdir(parents=True)
        with open(proj / "aaaa1111-0000-0000-0000-000000000000.jsonl", "w") as f:
            f.writelines(json.dumps(rec, ensure_ascii=False) + "\n" for rec in synthetic_records())
        # Agent 起動由来のセッション（既定で除外されるべき）
        with open(proj / "bbbb2222-0000-0000-0000-000000000000.jsonl", "w") as f:
            recs = [{"type": "agent-setting", "agentSetting": "Explore"}] + synthetic_records()
            f.writelines(json.dumps(rec, ensure_ascii=False) + "\n" for rec in recs)
        # paths サブコマンドが配置を列挙できることの確認用
        (root / "skills" / "demo").mkdir(parents=True)
        self.root = root

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *argv) -> dict:
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = cs.main(["--config-dir", str(self.root), *argv])
        self.assertEqual(code, 0)
        return json.loads(buf.getvalue())

    def test_sessions_excludes_agent_spawned_by_default(self):
        rep = self.run_cli("sessions")
        self.assertEqual(rep["total_matched"], 1)
        self.assertEqual(rep["sessions"][0]["session_id"], "aaaa1111-0000-0000-0000-000000000000")

    def test_sessions_include_agents(self):
        rep = self.run_cli("sessions", "--include-agents")
        self.assertEqual(rep["total_matched"], 2)

    def test_prompts(self):
        rep = self.run_cli("prompts")
        self.assertEqual(rep["total_prompts"], 1)
        self.assertEqual(rep["prompts"][0]["text"], "最初の依頼")

    def test_prompts_are_redacted(self):
        proj = self.root / "projects" / "-home-u-proj"
        with open(proj / "cccc3333-0000-0000-0000-000000000000.jsonl", "w") as f:
            f.write(json.dumps(user_rec("この鍵で試して API_KEY=abcd1234efgh")) + "\n")
        rep = self.run_cli("prompts", "--session", "cccc3333")
        self.assertEqual(rep["prompts"][0]["text"], "この鍵で試して API_KEY=[REDACTED:assignment]")

    def test_transcript_by_prefix(self):
        rep = self.run_cli("transcript", "--session", "aaaa1111")
        self.assertEqual(rep["session"]["session_id"], "aaaa1111-0000-0000-0000-000000000000")
        self.assertEqual(rep["turns"][0]["text"], "最初の依頼")

    def test_transcript_tool_detail(self):
        proj = self.root / "projects" / "-home-u-proj"
        with open(proj / "dddd4444-0000-0000-0000-000000000000.jsonl", "w") as f:
            f.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in detail_records())
        rep = self.run_cli("transcript", "--session", "dddd4444", "--tool-detail")
        self.assertEqual(rep["detail_omitted"], 0)
        tools = next(t for t in rep["turns"] if t["role"] == "assistant:tools")["tools"]
        self.assertEqual(tools[1]["result"]["exit_code"], 1)

    def test_search(self):
        proj = self.root / "projects" / "-home-u-proj"
        with open(proj / "dddd4444-0000-0000-0000-000000000000.jsonl", "w") as f:
            f.writelines(json.dumps(r, ensure_ascii=False) + "\n" for r in detail_records())
        rep = self.run_cli("search", "gitignore:3", "--tool", "Bash")
        self.assertEqual(rep["query"]["in"], ["tool-input", "tool-result"])
        self.assertEqual(rep["sessions_matched"], 1)
        self.assertEqual(rep["hits"][0]["session_id"], "dddd4444")
        self.assertEqual(rep["hits"][0]["field"], "tool-result")
        # Agent 起動由来（bbbb2222）は既定で走査対象外
        self.assertEqual(rep["scanned_sessions"], 2)

    def test_search_rejects_bad_input(self):
        for argv in (["search", "(", "--regex"], ["search", "x", "--in", "bogus"]):
            with self.subTest(argv=argv):
                buf = io.StringIO()
                with redirect_stdout(buf), self.assertRaises(SystemExit) as cm:
                    cs.main(["--config-dir", str(self.root), *argv])
                self.assertEqual(cm.exception.code, 1)
                self.assertIn("error", json.loads(buf.getvalue()))

    def test_paths_runs(self):
        rep = self.run_cli("paths")
        self.assertEqual(rep["projects"]["session_files"], 2)
        self.assertTrue(rep["entries"]["skills/"]["exists"])

    def test_cost_reports_missing_ccusage(self):
        """ccusage 不在時は理由と導入方法を返して非ゼロ終了する（黙って 0 円にしない）。"""
        with mock.patch.object(cs, "find_ccusage", return_value=None):
            buf = io.StringIO()
            with redirect_stdout(buf), self.assertRaises(SystemExit) as cm:
                cs.main(["--config-dir", str(self.root), "cost"])
        self.assertEqual(cm.exception.code, 1)
        rep = json.loads(buf.getvalue())
        self.assertIn("ccusage", rep["error"])
        self.assertIn("hint", rep)

    def test_cost_passes_through_ccusage_json(self):
        payload = {"daily": [{"date": "2026-07-01", "totalCost": 1.23}]}
        with (
            mock.patch.object(cs, "find_ccusage", return_value=["ccusage"]),
            mock.patch.object(cs, "run_ccusage", return_value=payload) as runner,
        ):
            rep = self.run_cli("cost", "--since", "2026-07-01")
        self.assertEqual(rep["data"], payload)
        self.assertIn("--since", runner.call_args.args[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
