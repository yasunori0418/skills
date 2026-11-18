"""name_check.py のテスト。

実行: uv run --project "<skill-dir>" pytest

外部の API と gh は呼ばない。HTTP の応答と gh の結果を差し替えて分岐を確かめる。
"""
from __future__ import annotations

import io
import json

import pytest

import name_check as nc


def fake_get(responses: dict[str, nc.HttpResult]):
    """URL に含まれる文字列で応答を選ぶ。該当が無ければ 404。"""

    def get(url: str) -> nc.HttpResult:
        for key, result in responses.items():
            if key in url:
                return result
        return nc.HttpResult(status=404)

    return get


def repology_body(*repos: str) -> nc.HttpResult:
    return nc.HttpResult(
        status=200, body=json.dumps([{"repo": repo} for repo in repos]).encode()
    )


def search_result(total: int, items: list[tuple[str, str, int]]) -> nc.GhResult:
    body = {
        "total_count": total,
        "items": [
            {"name": name, "full_name": full_name, "stargazers_count": stars}
            for name, full_name, stars in items
        ],
    }
    return nc.GhResult(0, json.dumps(body), "")


def fake_gh(user: nc.GhResult, search: nc.GhResult):
    def gh(args):
        return user if args[1].startswith("users/") else search

    return gh


NOT_FOUND = nc.GhResult(1, '{"message":"Not Found","status":"404"}', "gh: Not Found (HTTP 404)")
NO_REPOS = search_result(0, [])


class TestRegistry:
    def test_404_is_free(self):
        assert nc.check_registry("foo", "crates", fake_get({})) == "free"

    def test_200_is_taken(self):
        get = fake_get({"registry.npmjs.org": nc.HttpResult(status=200)})
        assert nc.check_registry("foo", "npm", get) == "taken"

    def test_other_status_is_error(self):
        get = fake_get({"pypi.org": nc.HttpResult(status=503)})
        assert nc.check_registry("foo", "pypi", get) == "error:503"

    def test_connection_failure_is_error(self):
        get = fake_get({"crates.io": nc.HttpResult(status=None, reason="URLError")})
        assert nc.check_registry("foo", "crates", get) == "error:URLError"

    def test_url_contains_name(self):
        seen = []

        def get(url):
            seen.append(url)
            return nc.HttpResult(status=404)

        nc.check_registry("foo", "crates", get)
        assert seen == ["https://crates.io/api/v1/crates/foo"]


class TestRepology:
    def test_counts_unique_repos(self):
        get = fake_get({"repology.org": repology_body("nix_unstable", "aur", "aur")})
        assert nc.check_repology("foo", get) == "2"

    def test_empty_list_is_zero(self):
        get = fake_get({"repology.org": repology_body()})
        assert nc.check_repology("foo", get) == "0"

    def test_failure_is_error(self):
        assert nc.check_repology("foo", fake_get({})) == "error:404"

    def test_bad_json_is_error(self):
        get = fake_get({"repology.org": nc.HttpResult(status=200, body=b"<html>")})
        assert nc.check_repology("foo", get) == "error:bad_json"


class TestGhUser:
    def test_existing_account_returns_type(self):
        gh = fake_gh(nc.GhResult(0, "Organization\n", ""), NO_REPOS)
        assert nc.check_gh_user("foo", gh) == "Organization"

    def test_missing_account_is_none_not_error_json(self):
        # gh は 404 のときもエラーの JSON を stdout に出す。列に入れてはいけない。
        assert nc.check_gh_user("foo", fake_gh(NOT_FOUND, NO_REPOS)) == "none"

    def test_other_failure_is_error(self):
        rate_limited = nc.GhResult(1, "", "gh: API rate limit exceeded (HTTP 403)")
        assert nc.check_gh_user("foo", fake_gh(rate_limited, NO_REPOS)) == "error:http_403"

    def test_gh_missing_is_error(self):
        missing = nc.GhResult(127, "", "gh not found")
        assert nc.check_gh_user("foo", fake_gh(missing, NO_REPOS)) == "error:gh_not_found"


class TestGhRepos:
    def test_no_exact_match(self):
        search = search_result(3, [("foobar", "a/foobar", 9)])
        assert nc.check_gh_repos("foo", fake_gh(NOT_FOUND, search)) == ("3", "0", "0", "-")

    def test_exact_match_ignores_case_and_picks_top(self):
        search = search_result(
            34,
            [("Foo", "a/Foo", 3), ("foo", "b/foo", 7), ("foo-cli", "c/foo-cli", 99)],
        )
        assert nc.check_gh_repos("foo", fake_gh(NOT_FOUND, search)) == (
            "34",
            "2",
            "7",
            "b/foo",
        )

    def test_failure_fills_all_columns(self):
        failed = nc.GhResult(1, "", "gh: validation failed (HTTP 422)")
        assert nc.check_gh_repos("foo", fake_gh(NOT_FOUND, failed)) == (
            "error:http_422",
        ) * 4

    def test_bad_json_fills_all_columns(self):
        broken = nc.GhResult(0, "not json", "")
        assert nc.check_gh_repos("foo", fake_gh(NOT_FOUND, broken)) == (
            "error:bad_json",
        ) * 4

    def test_query_is_passed_to_gh(self):
        seen = []

        def gh(args):
            seen.append(list(args))
            return NO_REPOS

        nc.check_gh_repos("foo", gh)
        assert "q=foo in:name" in seen[0]
        assert "per_page=100" in seen[0]


class TestCaBundle:
    def test_env_vars_come_before_fixed_paths(self):
        candidates = nc.ca_bundle_candidates({"NIX_SSL_CERT_FILE": "/x/ca.crt"})
        assert candidates[0] == "/x/ca.crt"
        assert candidates[1:] == list(nc.CA_BUNDLE_PATHS)

    def test_empty_env_var_is_ignored(self):
        assert nc.ca_bundle_candidates({"SSL_CERT_FILE": ""}) == list(nc.CA_BUNDLE_PATHS)


class TestArguments:
    def test_registries_are_parsed_and_deduplicated(self):
        assert nc.parse_registries("crates, npm,crates") == ["crates", "npm"]

    def test_none_and_empty_mean_no_registry(self):
        assert nc.parse_registries("none") == []
        assert nc.parse_registries("") == []

    def test_unknown_registry_is_rejected(self):
        with pytest.raises(Exception, match="rubygems"):
            nc.parse_registries("crates,rubygems")

    def test_names_are_lowercased_and_deduplicated(self):
        assert nc.normalize_names(["Foo", "foo", "bar"]) == ["foo", "bar"]

    @pytest.mark.parametrize("name", ["foo/bar", "foo bar", "-foo", "foo?x=1", "ふー"])
    def test_invalid_names_are_rejected(self, name):
        with pytest.raises(ValueError):
            nc.normalize_names([name])


class TestMain:
    def run(self, argv, get=None, gh=None):
        out = io.StringIO()
        sleeps = []
        code = nc.main(
            argv,
            get=get or fake_get({"repology.org": repology_body()}),
            gh=gh or fake_gh(NOT_FOUND, NO_REPOS),
            sleep=sleeps.append,
            out=out,
        )
        rows = [line.split("\t") for line in out.getvalue().splitlines()]
        return code, rows, sleeps

    def test_columns_follow_selected_registries(self):
        code, rows, _ = self.run(["--registry", "crates,pypi", "foo"])
        assert code == 0
        assert rows[0] == [
            "name",
            "repology",
            "crates",
            "pypi",
            "gh_user",
            "gh_inname_total",
            "gh_exact",
            "gh_exact_maxstars",
            "gh_exact_top",
        ]
        assert rows[1] == ["foo", "0", "free", "free", "none", "0", "0", "0", "-"]

    def test_without_registry_only_common_columns(self):
        _, rows, _ = self.run(["foo"])
        assert rows[0][:3] == ["name", "repology", "gh_user"]
        assert len(rows[1]) == len(rows[0])

    def test_no_header(self):
        _, rows, _ = self.run(["--no-header", "foo"])
        assert [row[0] for row in rows] == ["foo"]

    def test_error_in_one_column_keeps_other_rows_and_exits_1(self):
        get = fake_get(
            {
                "repology.org": repology_body(),
                "crates/bad": nc.HttpResult(status=500),
            }
        )
        code, rows, _ = self.run(["--registry", "crates", "bad", "good"], get=get)
        assert code == 1
        assert rows[1][2] == "error:500"
        assert rows[2] == ["good", "0", "free", "none", "0", "0", "0", "-"]

    def test_every_row_has_same_number_of_columns_on_gh_failure(self):
        broken = nc.GhResult(1, '{"message":"Bad credentials"}', "gh: Bad credentials (HTTP 401)")
        code, rows, _ = self.run(["--registry", "npm", "foo"], gh=fake_gh(broken, broken))
        assert code == 1
        assert len(rows[1]) == len(rows[0])
        assert all("{" not in cell for cell in rows[1])

    def test_delay_between_names_only(self):
        _, _, sleeps = self.run(["--delay", "1.5", "a", "b", "c"])
        assert sleeps == [1.5, 1.5]

    def test_invalid_name_exits_2_without_requests(self, capsys):
        def get(_url):
            raise AssertionError("リクエストしてはいけない")

        code, rows, _ = self.run(["foo/bar"], get=get)
        assert code == 2
        assert rows == []
        assert "foo/bar" in capsys.readouterr().err
