#!/usr/bin/env python3
"""collect_conventions.py の単体テスト(純粋関数)。

実行: uv run --project "<skill-dir>" pytest
(unittest 形式なので `uv run --project "<skill-dir>" python <このファイル>` でも可)

探索・照合の end-to-end は scripts/tests/collect-conventions.test.sh(bash)が担う。
ここでは出力整形と見出し抽出の純粋層だけを見る。
"""
from __future__ import annotations

import unittest

import collect_conventions as cc


class ExtractHeadingsTest(unittest.TestCase):
    def test_h1_h2_only_and_fence_ignored(self) -> None:
        body = "# Top\n\n```\n# in fence\n```\n\n## Sub\n\n### h3 ignored\n"
        self.assertEqual(cc.extract_headings(body), "h1: Top; h2: Sub")

    def test_truncated_at_limit(self) -> None:
        body = "\n".join(f"## {'見' * 50}{i}" for i in range(10))
        out = cc.extract_headings(body)
        self.assertEqual(len(out), cc.HEADING_LIMIT)
        self.assertTrue(out.endswith("…"))


class FormatSectionTest(unittest.TestCase):
    def test_none_status_has_header_and_lint_placeholder(self) -> None:
        out = cc.format_section("none", [], [])
        self.assertIn(cc.SECTION_HEADER, out)
        self.assertIn("status: none", out)
        self.assertIn("lint: (なし)", out)

    def test_overflow_is_truncated_with_hint(self) -> None:
        entries = [cc.Entry(f"docs/{i}.md", "[contributing]", "", (4, 0, 0, str(i))) for i in range(cc.MAX_ENTRIES + 3)]
        out = cc.format_section("found", ["ruff.toml"], entries)
        self.assertIn("lint: ruff.toml", out)
        self.assertEqual(out.count("- docs/"), cc.MAX_ENTRIES)
        self.assertIn(f"残り 3 件は省略。{cc.ENV_VAR}", out)


if __name__ == "__main__":
    unittest.main()
