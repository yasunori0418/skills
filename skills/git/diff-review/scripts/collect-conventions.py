#!/usr/bin/env python3
"""diff-review: 変更ファイルに適用されるコーディング規約の決定論的列挙(読み取り専用)。

usage:
    collect-conventions.py --root <repo-root> < changed-files.txt

stdin  : 変更ファイルのパス(1 行 1 パス、リポジトリルート相対)。削除ファイルは含めない
stdout : manifest に同梱する `== CONVENTIONS ==` 節
stderr : WARN(存在しない明示パス・ブレース展開の上限超過)

探索対象(決定論):
    .claude/rules/**/*.md      frontmatter `paths:` を変更ファイルに照合。paths 無しは常時適用。
                               変更ファイルの祖先ディレクトリ配下の .claude/rules/ も拾う
                               (paths はそのディレクトリ起点と root 起点の両方で照合)
    <祖先>/CLAUDE.md, AGENTS.md 変更ファイルの祖先ディレクトリを root まで遡る(CLAUDE.local.md は除外)
    CONTRIBUTING.md            ルート / .github/ / docs/
    DIFF_REVIEW_CONVENTIONS    ':' 区切りの追加パス。トークン `none` で自動探索を停止(明示分のみ)

git は叩かない。標準ライブラリのみ(python3.12+)。
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

SECTION_HEADER = "== CONVENTIONS (規約。レビューの第 1 基準。一致した規約は Read して照合する) =="
ENV_VAR = "DIFF_REVIEW_CONVENTIONS"
MAX_ENTRIES = 20
HEADING_LIMIT = 200
BRACE_BUDGET = 1000  # 1 ルールの paths リスト全体で共有する展開後パターン数の上限(公式仕様に合わせる)

RULES_DIR = Path(".claude/rules")
ROOT_INSTRUCTION_FILES = ("CLAUDE.md", "AGENTS.md", ".claude/CLAUDE.md")
ANCESTOR_INSTRUCTION_FILES = ("CLAUDE.md", "AGENTS.md")
CONTRIBUTING_PATHS = ("CONTRIBUTING.md", ".github/CONTRIBUTING.md", "docs/CONTRIBUTING.md")

# 機械 lint / formatter の設定ファイル。存在検出のみで内容は解析しない。
LINT_CONFIG_GLOBS = (
    "detekt.yml",
    "detekt.yaml",
    ".editorconfig",
    ".eslintrc*",
    "eslint.config.*",
    "biome.json",
    "biome.jsonc",
    ".prettierrc*",
    "prettier.config.*",
    ".stylelintrc*",
    "ruff.toml",
    ".ruff.toml",
    ".flake8",
    "setup.cfg",
    ".golangci.yml",
    ".golangci.yaml",
    "rustfmt.toml",
    ".rustfmt.toml",
    "clippy.toml",
    ".scalafmt.conf",
    "checkstyle.xml",
    ".swiftlint.yml",
    ".rubocop.yml",
    ".clang-format",
    "treefmt.toml",
    "treefmt.nix",
    ".ktlint",
)
PYPROJECT_LINT_TABLES = ("[tool.ruff", "[tool.black]", "[tool.isort]", "[tool.flake8]", "[tool.pylint")


def warn(msg: str) -> None:
    print(f"WARN: {msg}", file=sys.stderr)


# --- glob -> regex ---------------------------------------------------------


class BraceBudgetExceeded(Exception):
    pass


def expand_braces(pattern: str, budget: list[int]) -> list[str]:
    """`{a,b}` をブレース展開する(ネスト可)。展開結果は budget[0] から差し引く。

    ブレースを含まないパターンは予算を消費しない(公式仕様)。
    """
    depth = 0
    start = -1
    for i, ch in enumerate(pattern):
        if ch == "\\":
            continue
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}" and depth > 0:
            depth -= 1
            if depth == 0:
                inner = pattern[start + 1 : i]
                alternatives = split_top_level(inner)
                if len(alternatives) < 2:
                    # `{x}` は展開せずリテラル扱い(下で '{' をエスケープする)
                    break
                results: list[str] = []
                for alt in alternatives:
                    for expanded in expand_braces(pattern[:start] + alt + pattern[i + 1 :], budget):
                        results.append(expanded)
                return results
    # ここに来るのはブレース無し・`{x}` 単独・対応の取れないブレース(いずれもリテラル扱い)
    budget[0] -= 1
    if budget[0] < 0:
        raise BraceBudgetExceeded
    return [pattern]


def split_top_level(s: str) -> list[str]:
    parts: list[str] = []
    depth = 0
    cur = []
    i = 0
    while i < len(s):
        ch = s[i]
        if ch == "\\" and i + 1 < len(s):
            cur.append(ch)
            cur.append(s[i + 1])
            i += 2
            continue
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    parts.append("".join(cur))
    return parts


def glob_to_regex(pattern: str) -> re.Pattern[str]:
    """単一(ブレース展開済み)glob を root 起点の正規表現へ変換する。

    `**` は 0 個以上のディレクトリを跨ぐ / `*` `?` は `/` を跨がない / `[...]` は文字集合 /
    `\\x` はリテラル。`*.kt` のような `/` を含まないパターンは root 直下にのみ一致する(公式仕様)。
    """
    pattern = pattern.lstrip("/")
    if pattern.startswith("./"):
        pattern = pattern[2:]
    out: list[str] = []
    i = 0
    n = len(pattern)
    while i < n:
        ch = pattern[i]
        if ch == "\\" and i + 1 < n:
            out.append(re.escape(pattern[i + 1]))
            i += 2
        elif ch == "*":
            if pattern.startswith("**", i):
                j = i + 2
                if (i == 0 or pattern[i - 1] == "/") and j < n and pattern[j] == "/":
                    out.append("(?:.*/)?")  # `**/` : 0 個以上のディレクトリ
                    i = j + 1
                elif (i == 0 or pattern[i - 1] == "/") and j == n:
                    out.append(".*")  # 末尾の `**`
                    i = j
                else:
                    out.append(".*")  # `a**b` のような非標準位置は貪欲一致
                    i = j
            else:
                out.append("[^/]*")
                i += 1
        elif ch == "?":
            out.append("[^/]")
            i += 1
        elif ch == "[":
            j = i + 1
            if j < n and pattern[j] in "!^":
                j += 1
            if j < n and pattern[j] == "]":
                j += 1
            while j < n and pattern[j] != "]":
                j += 1
            if j >= n:
                out.append(re.escape("["))
                i += 1
            else:
                body = pattern[i + 1 : j]
                if body and body[0] in "!^":
                    body = "^" + body[1:]
                body = body.replace("\\", "\\\\")
                out.append(f"[{body}]")
                i = j + 1
        else:
            out.append(re.escape(ch))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def specificity(pattern: str) -> tuple[int, int, str]:
    """並び順キー: `**` が少なく `/` が多いほど具体的(上位)。"""
    return (pattern.count("**"), -pattern.count("/"), pattern)


# --- frontmatter -----------------------------------------------------------


def parse_frontmatter(text: str) -> tuple[list[str] | None, str]:
    """先頭の `---` ... `---` だけを簡易解析し (paths, body) を返す。

    paths は単一文字列・インラインリスト・ブロックリストを受ける。frontmatter が無い /
    paths キーが無いときは None(常時適用)。
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, text
    end = None
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            end = idx
            break
    if end is None:
        return None, text
    fm = lines[1:end]
    body = "\n".join(lines[end + 1 :])
    paths: list[str] | None = None
    i = 0
    while i < len(fm):
        line = fm[i]
        m = re.match(r"^paths\s*:\s*(.*)$", line)
        if not m:
            i += 1
            continue
        rest = m.group(1).strip()
        if rest.startswith("#"):
            rest = ""
        if rest == "":
            items: list[str] = []
            j = i + 1
            while j < len(fm):
                lm = re.match(r"^\s+-\s*(.*)$", fm[j])
                if not lm:
                    if fm[j].strip() == "" or fm[j].startswith("#"):
                        j += 1
                        continue
                    break
                items.append(unquote(lm.group(1)))
                j += 1
            paths = items
        elif rest.startswith("["):
            inner = rest.strip()
            if inner.endswith("]"):
                inner = inner[1:-1]
            else:
                inner = inner[1:]
            paths = [unquote(p) for p in split_top_level(inner) if p.strip()]
        else:
            paths = [unquote(rest)]
        break
    return paths, body


def unquote(s: str) -> str:
    s = s.strip()
    # 行末コメント(引用符外)を落とす
    if s and s[0] not in "\"'":
        s = re.split(r"\s+#", s, maxsplit=1)[0].strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        s = s[1:-1]
    return s


def extract_headings(body: str) -> str:
    """h1・h2 を列挙して 1 文字列にする(フェンス内は無視、HEADING_LIMIT で切る)。"""
    heads: list[str] = []
    in_fence = False
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        m = re.match(r"^(#{1,2})\s+(.+?)\s*#*\s*$", line)
        if m:
            heads.append(f"h{len(m.group(1))}: {m.group(2)}")
    joined = "; ".join(heads)
    if len(joined) > HEADING_LIMIT:
        joined = joined[: HEADING_LIMIT - 1] + "…"
    return joined


# --- discovery -------------------------------------------------------------


class Entry:
    def __init__(self, path: str, tag: str, headings: str, order: tuple) -> None:
        self.path = path
        self.tag = tag
        self.headings = headings
        self.order = order


def read_text(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def rel(root: Path, p: Path) -> str:
    return p.relative_to(root).as_posix()


def relative_to_root(root: Path, p: Path) -> str:
    """絶対パスを root 相対にする(symlink を含む root 差を realpath で吸収)。root 外ならそのまま。"""
    real_root = os.path.realpath(root)
    real_p = os.path.realpath(p)
    if real_p == real_root or real_p.startswith(real_root + os.sep):
        return Path(os.path.relpath(real_p, real_root)).as_posix()
    return str(p)


def ancestor_dirs(changed: list[str]) -> list[str]:
    """変更ファイルの祖先ディレクトリ(root を除く)。深い方を先に返す。"""
    dirs: set[str] = set()
    for f in changed:
        parent = Path(f).parent
        while parent != Path("."):
            dirs.add(parent.as_posix())
            parent = parent.parent
    return sorted(dirs, key=lambda s: (-s.count("/"), s))


def discover_rules(root: Path, changed: list[str]) -> list[Entry]:
    """`.claude/rules/**/*.md` を root と変更ファイルの祖先ディレクトリから拾い、paths を照合する。

    サブディレクトリ配下の `.claude/rules/` は公式ドキュメントで「nested」として言及されるが、
    その paths の起点は文書化されていない。そのディレクトリ起点と root 起点の両方で照合し、
    どちらかに当たれば一致とする。
    """
    entries: list[Entry] = []
    for base in [""] + ancestor_dirs(changed):
        rules_dir = root / base / RULES_DIR if base else root / RULES_DIR
        if not rules_dir.is_dir():
            continue
        scoped = [c[len(base) + 1 :] for c in changed if c.startswith(base + "/")] if base else changed
        for rule in sorted(rules_dir.rglob("*.md")):
            if not rule.is_file():
                continue
            entries.extend(match_rule(root, rule, base, changed, scoped))
    return entries


def match_rule(root: Path, rule: Path, base: str, changed: list[str], scoped: list[str]) -> list[Entry]:
    """1 つのルールファイルを照合して Entry を 0 or 1 件返す。base は所属ディレクトリ(root は空)。"""
    paths, body = parse_frontmatter(read_text(rule))
    relpath = rel(root, rule)
    where = f" @ {base}/" if base else ""
    if paths is None:
        # paths 無し: root なら常時適用、nested ならそのディレクトリ配下の変更に適用(祖先として拾われた時点で該当)
        tag = "[paths: なし (常時適用)]" if not base else f"[paths: なし ({base}/ 配下に常時適用)]"
        return [Entry(relpath, tag, extract_headings(body), (1, -base.count("/") - (1 if base else 0), 0, relpath))]
    budget = [BRACE_BUDGET]
    matched: list[str] = []
    effective: list[str] = []  # 具体度比較用の root 起点の実効パターン
    try:
        for raw in paths:
            for expanded in expand_braces(raw, budget):
                regex = glob_to_regex(expanded)
                if any(regex.match(f) for f in changed):
                    matched.append(expanded)
                    effective.append(expanded)
                elif base and any(regex.match(f) for f in scoped):
                    matched.append(expanded)
                    effective.append(f"{base}/{expanded}")
    except BraceBudgetExceeded:
        warn(f"{relpath} の paths はブレース展開が {BRACE_BUDGET} パターンを超えるため不一致扱い")
        return []
    if not matched:
        return []
    spec = min(specificity(e) for e in effective)
    shown = ", ".join(dict.fromkeys(matched))
    return [Entry(relpath, f"[paths: {shown}{where}]", extract_headings(body), (0, spec[0], spec[1], relpath))]


def discover_instruction_files(root: Path, changed: list[str]) -> list[Entry]:
    """祖先 CLAUDE.md / AGENTS.md(root は注入済み扱い)。symlink は realpath で重複除去。"""
    seen: dict[str, Entry] = {}  # realpath -> Entry

    def add(p: Path, tag: str, order: tuple) -> None:
        if not p.is_file():
            return
        key = os.path.realpath(p)
        relpath = rel(root, p)
        existing = seen.get(key)
        if existing is not None:
            # 表記は CLAUDE.md 側を優先する
            if existing.path.endswith("AGENTS.md") and relpath.endswith("CLAUDE.md"):
                existing.path = relpath
                existing.tag = tag
                existing.order = order
            return
        seen[key] = Entry(relpath, tag, extract_headings(parse_frontmatter(read_text(p))[1]), order)

    # モジュール階層(root を除く祖先、深い方を上位)
    for d in ancestor_dirs(changed):
        for name in ANCESTOR_INSTRUCTION_FILES:
            depth = d.count("/") + 1
            add(root / d / name, f"[ancestor of {d}/]", (2, -depth, 0, f"{d}/{name}"))

    # root。CLAUDE.md 系は起動時に注入済み。AGENTS.md は Claude Code が読まないため、
    # CLAUDE.md と同一実体(symlink)でなければ注入済みではない
    for name in ROOT_INSTRUCTION_FILES:
        p = root / name
        if not p.is_file():
            continue
        injected = name != "AGENTS.md" or os.path.realpath(p) in seen
        add(p, "[root, injected]" if injected else "[root]", (3, 0, 0, name))
    return list(seen.values())


def discover_contributing(root: Path) -> list[Entry]:
    entries: list[Entry] = []
    seen: set[str] = set()
    for relpath in CONTRIBUTING_PATHS:
        p = root / relpath
        if not p.is_file():
            continue
        key = os.path.realpath(p)
        if key in seen:
            continue
        seen.add(key)
        entries.append(Entry(relpath, "[contributing]", extract_headings(read_text(p)), (4, 0, 0, relpath)))
    return entries


def parse_env(root: Path) -> tuple[bool, list[Entry]]:
    """(auto_disabled, explicit_entries) を返す。存在しないパスは WARN して落とす。"""
    raw = os.environ.get(ENV_VAR, "")
    auto_disabled = False
    entries: list[Entry] = []
    seen: set[str] = set()
    for idx, token in enumerate(t.strip() for t in raw.split(":")):
        if not token:
            continue
        if token == "none":
            auto_disabled = True
            continue
        p = Path(token)
        if not p.is_absolute():
            p = root / token
        if not p.is_file():
            warn(f"{ENV_VAR} のパスが存在しない: {token}")
            continue
        key = os.path.realpath(p)
        if key in seen:
            continue
        seen.add(key)
        shown = token if not Path(token).is_absolute() else relative_to_root(root, p)
        entries.append(Entry(shown, f"[explicit: {ENV_VAR}]", extract_headings(read_text(p)), (5, idx, 0, shown)))
    return auto_disabled, entries


def detect_lint(root: Path) -> list[str]:
    found: list[str] = []
    for g in LINT_CONFIG_GLOBS:
        for p in sorted(root.glob(g)):
            if p.is_file():
                found.append(p.name)
    pyproject = root / "pyproject.toml"
    if pyproject.is_file():
        text = read_text(pyproject)
        if any(t in text for t in PYPROJECT_LINT_TABLES):
            found.append("pyproject.toml")
    return list(dict.fromkeys(found))


# --- output ----------------------------------------------------------------


def format_section(status: str, lint: list[str], entries: list[Entry]) -> str:
    lines = [SECTION_HEADER, f"status: {status}"]
    if lint:
        lines.append(f"lint: {', '.join(lint)}   (書式系は lint に委ね指摘しない)")
    else:
        lines.append("lint: (なし)")
    shown = entries[:MAX_ENTRIES]
    width_path = max((len(e.path) for e in shown), default=0)
    width_tag = max((len(e.tag) for e in shown), default=0)
    for e in shown:
        line = f"- {e.path.ljust(width_path)}  {e.tag.ljust(width_tag)}"
        if e.headings:
            line += f"  ({e.headings})"
        lines.append(line.rstrip())
    if len(entries) > MAX_ENTRIES:
        lines.append(f"  (残り {len(entries) - MAX_ENTRIES} 件は省略。{ENV_VAR} で対象を明示すること)")
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True, help="リポジトリルート")
    args = ap.parse_args()
    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"ERROR: --root が存在しない: {args.root}", file=sys.stderr)
        return 2

    changed = [ln.strip() for ln in sys.stdin.read().splitlines() if ln.strip()]
    changed = [c[2:] if c.startswith("./") else c for c in changed]

    auto_disabled, explicit = parse_env(root)
    entries: list[Entry] = []
    if not auto_disabled:
        entries.extend(discover_rules(root, changed))
        entries.extend(discover_instruction_files(root, changed))
        entries.extend(discover_contributing(root))
    # 明示注入と自動探索の重複は自動探索側の表記を残す
    known = {os.path.realpath(root / e.path) for e in entries}
    entries.extend(e for e in explicit if os.path.realpath(root / e.path) not in known)
    entries.sort(key=lambda e: e.order)

    if auto_disabled:
        status = "explicit-only"
    elif entries:
        status = "found"
    else:
        status = "none"
    sys.stdout.write(format_section(status, detect_lint(root), entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
