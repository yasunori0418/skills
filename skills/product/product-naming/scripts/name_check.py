#!/usr/bin/env python3
"""プロダクト名の候補が、既存のパッケージや GitHub と重なるかを確かめる。

使い方:
    name_check.py [--registry crates,npm,pypi] [--delay 秒] [--no-header] 名前...

出力は 1 候補 1 行の TSV。列は次のとおり。

    name               候補の名前
    repology           同名のパッケージを持つリポジトリ（ディストリビューション等）の数
    <レジストリ名>     free（同名なし）/ taken（同名あり）。--registry で選んだ分だけ出る
    gh_user            同名の GitHub アカウントの種類（User / Organization / none）
    gh_inname_total    名前に候補を含むリポジトリの総数
    gh_exact           上位 100 件のうち、名前が完全に一致するリポジトリの数
    gh_exact_maxstars  そのうち最大のスター数
    gh_exact_top       そのうちスターが最大のリポジトリ（無ければ -）

確かめられなかった列には `error:<理由>` を入れ、ほかの列とほかの候補の確認は続ける。
GitHub の確認は gh CLI を呼び、認証は gh に任せる。

終了コード: 0 = すべて確かめた / 1 = error の列が 1 つ以上ある / 2 = 引数の誤り
"""
from __future__ import annotations

import argparse
import functools
import json
import os
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Callable, Sequence

# crates.io は User-Agent の無いリクエストを拒む。利用者を特定する情報は入れない。
USER_AGENT = "name-check-client"
TIMEOUT_SECONDS = 20

REGISTRY_URLS = {
    "crates": "https://crates.io/api/v1/crates/{name}",
    "npm": "https://registry.npmjs.org/{name}",
    "pypi": "https://pypi.org/pypi/{name}/json",
}
REPOLOGY_URL = "https://repology.org/api/v1/project/{name}"

# 候補は URL と検索クエリにそのまま入れるので、パッケージ名に使える文字だけを受け付ける。
NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]*$")

GITHUB_SEARCH_PAGE_SIZE = 100

# uv が入れる Python は、OS によっては既定の場所で CA 証明書を見つけられない
# （NixOS など）。そのときに順に試す場所。証明書の検証そのものは無効にしない。
CA_BUNDLE_ENV_VARS = ("SSL_CERT_FILE", "NIX_SSL_CERT_FILE")
CA_BUNDLE_PATHS = (
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/cert.pem",
)


@dataclass(frozen=True)
class HttpResult:
    """status が None のときは接続できなかった（reason に理由）。"""

    status: int | None
    body: bytes = b""
    reason: str = ""


@dataclass(frozen=True)
class GhResult:
    returncode: int
    stdout: str
    stderr: str


HttpGet = Callable[[str], HttpResult]
GhRun = Callable[[Sequence[str]], GhResult]


def ca_bundle_candidates(environ=os.environ) -> list[str]:
    from_env = [environ[name] for name in CA_BUNDLE_ENV_VARS if environ.get(name)]
    return [*from_env, *CA_BUNDLE_PATHS]


@functools.cache
def ssl_context() -> ssl.SSLContext:
    context = ssl.create_default_context()
    if context.cert_store_stats()["x509_ca"] > 0:
        return context
    for path in ca_bundle_candidates():
        if os.path.isfile(path):
            context.load_verify_locations(cafile=path)
            break
    return context


def http_get(url: str) -> HttpResult:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(
            request, timeout=TIMEOUT_SECONDS, context=ssl_context()
        ) as response:
            return HttpResult(status=response.status, body=response.read())
    except urllib.error.HTTPError as e:
        return HttpResult(status=e.code)
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return HttpResult(status=None, reason=type(e).__name__)


def gh_run(args: Sequence[str]) -> GhResult:
    try:
        completed = subprocess.run(
            ["gh", *args],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS * 2,
            check=False,
        )
    except FileNotFoundError:
        return GhResult(returncode=127, stdout="", stderr="gh not found")
    except subprocess.TimeoutExpired:
        return GhResult(returncode=124, stdout="", stderr="timeout")
    return GhResult(completed.returncode, completed.stdout, completed.stderr)


def error_value(reason: object) -> str:
    """TSV の 1 セルに収まる error の値を作る。"""
    text = re.sub(r"\s+", "_", str(reason).strip()) or "unknown"
    return f"error:{text[:40]}"


def is_error(value: str) -> bool:
    return value.startswith("error:")


def check_registry(name: str, registry: str, get: HttpGet) -> str:
    result = get(REGISTRY_URLS[registry].format(name=name))
    if result.status == 404:
        return "free"
    if result.status == 200:
        return "taken"
    return error_value(result.status if result.status is not None else result.reason)


def check_repology(name: str, get: HttpGet) -> str:
    result = get(REPOLOGY_URL.format(name=name))
    if result.status != 200:
        return error_value(result.status if result.status is not None else result.reason)
    try:
        packages = json.loads(result.body)
        return str(len({package["repo"] for package in packages}))
    except (ValueError, KeyError, TypeError):
        return error_value("bad_json")


def gh_failure_reason(result: GhResult) -> str:
    if result.returncode == 127:
        return "gh_not_found"
    if result.returncode == 124:
        return "timeout"
    match = re.search(r"HTTP (\d{3})", result.stderr)
    if match:
        return f"http_{match.group(1)}"
    return f"gh_exit_{result.returncode}"


def check_gh_user(name: str, gh: GhRun) -> str:
    result = gh(["api", f"users/{name}", "--jq", ".type"])
    if result.returncode == 0:
        return result.stdout.strip() or error_value("empty")
    # 同名のアカウントが無いのは 404。認証切れやレート制限と区別する。
    if "HTTP 404" in result.stderr:
        return "none"
    return error_value(gh_failure_reason(result))


def check_gh_repos(name: str, gh: GhRun) -> tuple[str, str, str, str]:
    """(gh_inname_total, gh_exact, gh_exact_maxstars, gh_exact_top) を返す。"""
    result = gh(
        [
            "api",
            "-X",
            "GET",
            "search/repositories",
            "-f",
            f"q={name} in:name",
            "-f",
            f"per_page={GITHUB_SEARCH_PAGE_SIZE}",
            "-f",
            "sort=stars",
        ]
    )
    if result.returncode != 0:
        value = error_value(gh_failure_reason(result))
        return value, value, value, value
    try:
        data = json.loads(result.stdout)
        total = int(data["total_count"])
        exact = [
            (int(item["stargazers_count"]), str(item["full_name"]))
            for item in data["items"]
            if str(item["name"]).lower() == name
        ]
    except (ValueError, KeyError, TypeError):
        value = error_value("bad_json")
        return value, value, value, value
    if not exact:
        return str(total), "0", "0", "-"
    top_stars, top_name = max(exact, key=lambda pair: pair[0])
    return str(total), str(len(exact)), str(top_stars), top_name


def header(registries: Sequence[str]) -> list[str]:
    return [
        "name",
        "repology",
        *registries,
        "gh_user",
        "gh_inname_total",
        "gh_exact",
        "gh_exact_maxstars",
        "gh_exact_top",
    ]


def check_name(
    name: str, registries: Sequence[str], get: HttpGet, gh: GhRun
) -> list[str]:
    return [
        name,
        check_repology(name, get),
        *(check_registry(name, registry, get) for registry in registries),
        check_gh_user(name, gh),
        *check_gh_repos(name, gh),
    ]


def parse_registries(value: str) -> list[str]:
    if value in ("", "none"):
        return []
    registries = [part.strip() for part in value.split(",") if part.strip()]
    unknown = [registry for registry in registries if registry not in REGISTRY_URLS]
    if unknown:
        raise argparse.ArgumentTypeError(
            f"対応していないレジストリ: {', '.join(unknown)}"
            f"（対応: {', '.join(REGISTRY_URLS)}, none）"
        )
    return list(dict.fromkeys(registries))


def normalize_names(raw_names: Sequence[str]) -> list[str]:
    names = list(dict.fromkeys(name.strip().lower() for name in raw_names))
    invalid = [name for name in names if not NAME_PATTERN.match(name)]
    if invalid:
        raise ValueError(
            "名前に使えるのは英小文字・数字・`.`・`_`・`-` だけ: " + ", ".join(invalid)
        )
    return names


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="プロダクト名の候補が既存のパッケージや GitHub と重なるかを確かめる"
    )
    parser.add_argument("names", nargs="+", metavar="名前", help="確かめる候補")
    parser.add_argument(
        "--registry",
        type=parse_registries,
        default=[],
        metavar="LIST",
        help=(
            "確かめるパッケージレジストリ（カンマ区切り: "
            f"{', '.join(REGISTRY_URLS)}。既定は無し）。"
            "repology と GitHub は指定に関係なく確かめる"
        ),
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=2.0,
        metavar="秒",
        help="候補ごとの待ち時間。GitHub の検索 API の制限（毎分 30 回）に合わせた既定値 2.0",
    )
    parser.add_argument(
        "--no-header", action="store_true", help="見出しの行を出さない（追記するとき用）"
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    get: HttpGet = http_get,
    gh: GhRun = gh_run,
    sleep: Callable[[float], None] = time.sleep,
    out=None,
) -> int:
    out = out if out is not None else sys.stdout
    args = build_parser().parse_args(argv)
    try:
        names = normalize_names(args.names)
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 2

    if not args.no_header:
        print("\t".join(header(args.registry)), file=out)
    failed = False
    for index, name in enumerate(names):
        if index > 0 and args.delay > 0:
            sleep(args.delay)
        row = check_name(name, args.registry, get, gh)
        failed = failed or any(is_error(cell) for cell in row[1:])
        print("\t".join(row), file=out, flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
