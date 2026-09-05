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


class ParseFrontmatterTest(unittest.TestCase):
    """paths の受け方(python-frontmatter 委譲後も自前実装の意味論を保つ)。"""

    def test_missing_frontmatter_or_key_means_always_apply(self) -> None:
        self.assertEqual(cc.parse_frontmatter("# body only\n"), (None, "# body only"))
        self.assertEqual(cc.parse_frontmatter("---\nname: x\n---\n# H\n")[0], None)

    def test_string_inline_and_block_lists(self) -> None:
        self.assertEqual(cc.parse_frontmatter('---\npaths: "src/**"\n---\n')[0], ["src/**"])
        self.assertEqual(cc.parse_frontmatter("---\npaths: [a/**, 'b/*.md']\n---\n")[0], ["a/**", "b/*.md"])
        paths, body = cc.parse_frontmatter('---\npaths:\n  - a/**\n  - "b/*.md"  # comment\n---\n# H1\n')
        self.assertEqual(paths, ["a/**", "b/*.md"])
        self.assertEqual(body, "# H1")

    def test_empty_paths_matches_nothing(self) -> None:
        # キーはあるが値が無い / 空リスト → [](常時適用の None とは区別する)
        self.assertEqual(cc.parse_frontmatter("---\npaths:\n---\n")[0], [])
        self.assertEqual(cc.parse_frontmatter("---\npaths: []\n---\n")[0], [])

    def test_non_string_value_is_warned_and_matches_nothing(self) -> None:
        import contextlib
        import io

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(cc.parse_frontmatter("---\npaths: {a: 1}\n---\n")[0], [])
        self.assertIn("WARN", err.getvalue())

    def test_malformed_yaml_falls_back_to_no_frontmatter(self) -> None:
        import contextlib
        import io

        err = io.StringIO()
        text = "---\nbad: [\n---\n# H\n"
        with contextlib.redirect_stderr(err):
            paths, body = cc.parse_frontmatter(text)
        self.assertIsNone(paths)
        self.assertEqual(body, text)
        self.assertIn("frontmatter を解析できない", err.getvalue())


class GlobMatchTest(unittest.TestCase):
    """wcmatch 委譲後の照合意味論(公式仕様に合わせた点)。"""

    def test_root_only_without_slash(self) -> None:
        self.assertTrue(cc.glob_match("*.md", "README.md"))
        self.assertFalse(cc.glob_match("*.md", "docs/README.md"))

    def test_globstar_and_single_star(self) -> None:
        self.assertTrue(cc.glob_match("src/**/*.kt", "src/a.kt"))
        self.assertTrue(cc.glob_match("src/**/*.kt", "src/deep/er/a.kt"))
        self.assertFalse(cc.glob_match("src/*.kt", "src/deep/a.kt"))
        self.assertFalse(cc.glob_match("src/?.kt", "src/ab.kt"))

    def test_leading_slash_and_dot_slash_are_root_relative(self) -> None:
        self.assertTrue(cc.glob_match("/src/*.py", "src/a.py"))
        self.assertTrue(cc.glob_match("./src/*.py", "src/a.py"))

    def test_dotfiles_match(self) -> None:
        self.assertTrue(cc.glob_match("docs/*", "docs/.hidden"))
        self.assertTrue(cc.glob_match("**/.github/**", "a/.github/x.yml"))

    def test_case_sensitive_regardless_of_platform(self) -> None:
        self.assertFalse(cc.glob_match("*.MD", "a.md"))

    def test_char_class_and_negation(self) -> None:
        self.assertTrue(cc.glob_match("src/[a-c].kt", "src/b.kt"))
        self.assertFalse(cc.glob_match("src/[!a-c].kt", "src/b.kt"))


class ExpandBracesTest(unittest.TestCase):
    def test_nested_and_literal_single(self) -> None:
        budget = [cc.BRACE_BUDGET]
        self.assertEqual(sorted(cc.expand_braces("s{a,{b,c}}/x", budget)), ["sa/x", "sb/x", "sc/x"])
        self.assertEqual(cc.expand_braces("{x}/a", budget), ["{x}/a"])

    def test_budget_is_shared_per_rule_and_not_consumed_without_braces(self) -> None:
        big = "{" + ",".join("abcdefghij") + "}"
        budget = [cc.BRACE_BUDGET]
        cc.expand_braces("src/*.kt", budget)
        self.assertEqual(budget[0], cc.BRACE_BUDGET)  # ブレース無しは消費しない
        self.assertEqual(len(cc.expand_braces(f"src/{big}/{big}/{big}/**", budget)), 1000)
        self.assertEqual(budget[0], 0)  # ちょうど上限は許容
        with self.assertRaises(cc.BraceBudgetExceeded):
            cc.expand_braces("{a,b}", budget)  # 同じルールの次のパターンで超過

    def test_over_budget_single_pattern(self) -> None:
        big = "{" + ",".join("abcdefghij") + "}"
        with self.assertRaises(cc.BraceBudgetExceeded):
            cc.expand_braces(f"src/{big}/{big}/{big}/{big}/**", [cc.BRACE_BUDGET])
