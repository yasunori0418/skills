#!/usr/bin/env bash
# job-plan の skill-creator 評価用ダミーリポジトリを生成する。
#
#   bash make_fixture.sh <eval名> <出力先ディレクトリ>
#   eval名: two-lane-stacked | feature-spec-input | revise-existing
#
# フィクスチャ実体をスキル内に置かない理由: checks.pytest は skills/ 配下の pyproject.toml を、
# validate-skills.sh は SKILL.md を再帰探索するため、ダミーの中身次第で CI が壊れる。
# 出力先は tmp_claude/job-plan-workspace/fixtures/<eval>/<run>/ を想定（グローバル gitignore 済み）。
# with_skill / without_skill の各ランに別コピーを与える（同じ cwd だと tmp_claude/<job>/ を奪い合う）。
set -euo pipefail

eval_name="${1:?eval 名（two-lane-stacked | feature-spec-input | revise-existing）}"
out="${2:?出力先ディレクトリ}"

if [[ -e "$out" ]]; then
  echo "出力先が既に存在する: $out（別ランには別ディレクトリを渡す）" >&2
  exit 1
fi
mkdir -p "$out"
cd "$out"

# ---------- 共通のダミープロジェクト（小さな Python サービス） ----------
mkdir -p pkg/logger internal/config internal/client tests/config tests/client docs/dev

cat > README.md <<'EOF'
# demo-service

HTTP クライアントと設定読み込みを持つ小さなサービス。テストは `pytest`。
EOF

cat > pyproject.toml <<'EOF'
[project]
name = "demo-service"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = []

[tool.pytest.ini_options]
testpaths = ["tests", "pkg"]
EOF

cat > pkg/logger/__init__.py <<'EOF'
from .logger import Logger, get_logger

__all__ = ["Logger", "get_logger"]
EOF

cat > pkg/logger/logger.py <<'EOF'
"""簡易ロガー。フォーマットと出力先を持つ。"""
from __future__ import annotations

import sys
from typing import TextIO


class Logger:
    def __init__(self, name: str, stream: TextIO | None = None) -> None:
        self.name = name
        self.stream = stream or sys.stderr

    def info(self, msg: str) -> None:
        self.stream.write(f"[{self.name}] INFO {msg}\n")

    def error(self, msg: str) -> None:
        self.stream.write(f"[{self.name}] ERROR {msg}\n")


_loggers: dict[str, Logger] = {}


def get_logger(name: str) -> Logger:
    if name not in _loggers:
        _loggers[name] = Logger(name)
    return _loggers[name]
EOF

cat > pkg/logger/test_logger.py <<'EOF'
import io

from pkg.logger import Logger, get_logger


def test_info_writes_prefixed_line() -> None:
    buf = io.StringIO()
    Logger("x", buf).info("hello")
    assert buf.getvalue() == "[x] INFO hello\n"


def test_get_logger_caches() -> None:
    assert get_logger("a") is get_logger("a")
EOF

cat > internal/__init__.py <<'EOF'
EOF
cat > internal/config/__init__.py <<'EOF'
from .settings import Settings, load_settings

__all__ = ["Settings", "load_settings"]
EOF

cat > internal/config/settings.py <<'EOF'
"""環境変数から設定を読む。"""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    base_url: str
    timeout_sec: float


def load_settings(env: dict[str, str] | None = None) -> Settings:
    e = env if env is not None else dict(os.environ)
    return Settings(
        base_url=e.get("DEMO_BASE_URL", "http://localhost:8080"),
        timeout_sec=float(e.get("DEMO_TIMEOUT_SEC", "5")),
    )
EOF

cat > tests/__init__.py <<'EOF'
EOF
cat > tests/config/__init__.py <<'EOF'
EOF
cat > tests/config/test_settings.py <<'EOF'
from internal.config import load_settings


def test_defaults() -> None:
    s = load_settings({})
    assert s.base_url == "http://localhost:8080"
    assert s.timeout_sec == 5.0


def test_env_override() -> None:
    s = load_settings({"DEMO_TIMEOUT_SEC": "1.5"})
    assert s.timeout_sec == 1.5
EOF

cat > internal/client/__init__.py <<'EOF'
from .client import Client

__all__ = ["Client"]
EOF

cat > internal/client/client.py <<'EOF'
"""HTTP クライアント（送信は差し替え可能な transport に委譲）。"""
from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from internal.config import Settings
from pkg.logger import get_logger

Transport = Callable[[str, str], tuple[int, str]]


@dataclass(frozen=True)
class Response:
    status: int
    body: str


class Client:
    def __init__(self, settings: Settings, transport: Transport) -> None:
        self.settings = settings
        self.transport = transport
        self.log = get_logger("client")

    def get(self, path: str) -> Response:
        status, body = self.transport("GET", self.settings.base_url + path)
        if status >= 500:
            self.log.error(f"GET {path} -> {status}")
        return Response(status=status, body=body)
EOF

cat > tests/client/__init__.py <<'EOF'
EOF
cat > tests/client/test_client.py <<'EOF'
from internal.client import Client
from internal.config import Settings


def test_get_returns_response() -> None:
    calls: list[tuple[str, str]] = []

    def transport(method: str, url: str) -> tuple[int, str]:
        calls.append((method, url))
        return 200, "ok"

    c = Client(Settings(base_url="http://x", timeout_sec=1), transport)
    r = c.get("/ping")
    assert r.status == 200 and r.body == "ok"
    assert calls == [("GET", "http://x/ping")]
EOF

# ---------- eval 別の追加物 ----------
case "$eval_name" in
  two-lane-stacked)
    cat > answers.md <<'EOF'
# 模擬ユーザー回答集（two-lane-stacked）

grilling の各問いには、ここに書かれた方針で答えたものとして扱う。書かれていない問いは推奨案を採用する。

- job 名: `retry-and-logger`
- 分割は 3 タスク。A: ロガーに `warn` レベルを足す（独立）。B1: 設定にリトライ回数 `DEMO_RETRY_MAX` を足す。B2: クライアントの `get` を B1 のリトライ回数で 5xx 時に再試行する（B1 に依存）
- branch: A = `feat-logger-warn`、B1 = `feat-config-retry`、B2 = `feat-client-retry`
- 境界はモジュールとそのテストディレクトリ。A は `pkg/logger/**`、B1 は `internal/config/**` と `tests/config/**`、B2 は `internal/client/**` と `tests/client/**`
- 完了条件は各モジュールの pytest が通ること。B2 は「5xx が続いたら最大回数で諦め、成功したら即返す」テストを含む
- 規模: 叩き台の見積りで良い
- 事前裁定: 「リトライ間隔（バックオフ）は固定 0 秒。指数バックオフは今回入れない」をユーザー確認済みの裁定として記録する
- スコープ外: 指数バックオフ、ロガーのファイル出力、タイムアウトの見直し
- issue は出さない（ローカルのみ）
EOF
    ;;
  feature-spec-input)
    mkdir -p docs/dev/retry-policy
    cat > docs/dev/retry-policy/spec.md <<'EOF'
# retry-policy 仕様

## 目的

5xx 応答で失敗する API 呼び出しを、設定された回数まで自動で再試行し、一時障害での失敗を減らす。

## スコープ

`internal/client` の `Client.get` と `internal/config` の設定読み込み。

## 機能要求

### REQ-01: リトライ回数の設定

- 環境変数 `DEMO_RETRY_MAX` からリトライ回数を読む。未設定なら 0（リトライしない）
- 負の値・整数でない値は `ValueError` にする

### REQ-02: 5xx 応答での再試行

- `Client.get` は応答が 5xx のとき、`Settings.retry_max` 回まで同じリクエストを再試行する
- 2xx〜4xx を受け取った時点で即座に返す

### REQ-03: 再試行のログ

- 再試行のたびに `WARN` レベルで `retry <n>/<max> GET <path>` を記録する

## 非機能要求

- NFR-01: 再試行の待ち時間は固定 0 秒（バックオフは本仕様の対象外）

## 受け入れ条件

| ID | 対象 | 条件 |
| --- | --- | --- |
| AC-01 | REQ-01 | `DEMO_RETRY_MAX=3` で `retry_max == 3`、未設定で `0` |
| AC-02 | REQ-01 | `DEMO_RETRY_MAX=-1` と `abc` で `ValueError` |
| AC-03 | REQ-02 | transport が 503, 503, 200 を返すと 3 回呼ばれ status 200 を返す |
| AC-04 | REQ-02 | transport が常に 503 を返すと `retry_max + 1` 回呼ばれ status 503 を返す |
| AC-05 | REQ-03 | 上記 AC-03 で WARN 行が 2 本出る |

## スコープ外

- 指数バックオフ・ジッター
- POST 等の非冪等メソッドの再試行
EOF
    cat > answers.md <<'EOF'
# 模擬ユーザー回答集（feature-spec-input）

grilling の各問いには、ここに書かれた方針で答えたものとして扱う。書かれていない問いは推奨案を採用する。

- job 名: `retry-policy`
- 入力は `docs/dev/retry-policy/spec.md`。REQ-01〜03 を全て task に対応付ける
- 分割は 3 タスク。A: ロガーに WARN レベルを足す（REQ-03 の前提。独立）。B1: 設定に `retry_max` を足す（REQ-01。独立）。B2: クライアントの再試行とログ（REQ-02, REQ-03。A と B1 の両方に依存するが、job-graph の stacked は単一親なので B1 を親にし、A は wave 0 で先にマージされる前提を第 2 章に書く。依存は `B1` だけにする）
- branch: A = `feat-logger-warn`、B1 = `feat-config-retry-max`、B2 = `feat-client-retry`
- 境界はモジュールとテストディレクトリ単位
- 事前裁定はユーザー確認済みとして 2 つ記録する: (1) AC-02 の `ValueError` は `load_settings` 内で送出し、`Settings` の型は `int` にする。(2) REQ-03 の WARN は既存 `Logger` に `warn` メソッドを足して出す（新規ロガークラスは作らない）
- スコープ外: 指数バックオフ、非冪等メソッドの再試行、`Client.post` の新設
- issue は出さない
EOF
    ;;
  revise-existing)
    mkdir -p tmp_claude/retry-policy/job-graph
    cat > tmp_claude/retry-policy/plan.md <<'EOF'
# 計画: retry-policy

## 1. 目的・背景

5xx 応答で失敗する API 呼び出しを設定回数まで再試行する。

## 2. タスク一覧と依存グラフ

| id | 概要 | branch | 依存 |
| --- | --- | --- | --- |
| B1 | 設定に retry_max を足す | feat-config-retry-max | なし |
| B2 | クライアントの 5xx 再試行 | feat-client-retry | B1 |

wave 0: B1 / wave 1: B2

## 3. タスク詳細

### B1: 設定に retry_max を足す
- branch: `feat-config-retry-max`
- 依存: なし
- 完了条件: `tests/config` の pytest が通り、`DEMO_RETRY_MAX` 未設定で 0、`3` で 3 になる
- 変更対象:
  ```
  internal/config/settings.py
  tests/config/test_settings.py
  ```
- 規模目安: 30 行
- 境界:
  ```
  internal/config/**
  tests/config/**
  ```
- コミット計画:
  1. `feat(config): DEMO_RETRY_MAX から retry_max を読む`

### B2: クライアントの 5xx 再試行
- branch: `feat-client-retry`
- 依存: `B1`
- 完了条件: `tests/client` の pytest が通り、503,503,200 で 3 回呼ばれ 200 を返す
- 変更対象:
  ```
  internal/client/client.py
  tests/client/test_client.py
  ```
- 規模目安: 60 行
- 境界:
  ```
  internal/client/**
  tests/client/**
  ```
- コミット計画:
  1. `feat(client): 5xx 応答を retry_max 回まで再試行する`

## 4. 事前裁定

- 裁定: 再試行の待ち時間は固定 0 秒（バックオフは入れない） / 承認: ユーザー確認済み

## 5. スコープ外

- 指数バックオフ
- 再試行のログ出力

## 6. 引き渡し

- 起動: `/job-graph tmp_claude/retry-policy/plan.md`
EOF
    cat > tmp_claude/retry-policy/job-graph/spec.json <<'EOF'
{
  "default_base": "main",
  "plan": "tmp_claude/retry-policy/plan.md",
  "tasks": [
    {
      "id": "B1",
      "branch": "feat-config-retry-max",
      "depends_on": [],
      "prompt": "設定に retry_max を足す。完了条件: tests/config の pytest が通り、DEMO_RETRY_MAX 未設定で 0、3 で 3 になる。\nコミット計画:\n1. feat(config): DEMO_RETRY_MAX から retry_max を読む",
      "boundary": ["internal/config/**", "tests/config/**"],
      "expected_files": ["internal/config/settings.py", "tests/config/test_settings.py"],
      "expected_scale": 30
    },
    {
      "id": "B2",
      "branch": "feat-client-retry",
      "depends_on": ["B1"],
      "prompt": "クライアントの 5xx 再試行。完了条件: tests/client の pytest が通り、503,503,200 で 3 回呼ばれ 200 を返す。\nコミット計画:\n1. feat(client): 5xx 応答を retry_max 回まで再試行する",
      "boundary": ["internal/client/**", "tests/client/**"],
      "expected_files": ["internal/client/client.py", "tests/client/test_client.py"],
      "expected_scale": 60
    }
  ]
}
EOF
    cat > answers.md <<'EOF'
# 模擬ユーザー回答集（revise-existing）

grilling の各問いには、ここに書かれた方針で答えたものとして扱う。書かれていない問いは推奨案を採用する。

- 既存の `tmp_claude/retry-policy/` は改訂する（別名にしない）
- 追加するタスクは 1 つ: A: ロガーに `warn` レベルを足す（独立。branch `feat-logger-warn`、境界 `pkg/logger/**`）。B2 の再試行ログはスコープ外のまま（A は将来の前提整備）
- 既存の B1 / B2 は変更しない（依存・境界・変更対象・規模は据え置き）
- 事前裁定は既存のものを保つ。追加なし
- スコープ外に「再試行のログ出力」を残す
- issue は出さない
EOF
    ;;
  *)
    echo "未知の eval 名: $eval_name" >&2
    exit 1
    ;;
esac

git init -q
git add -A
git -c user.name=fixture -c user.email=fixture@example.com commit -q -m "fixture: $eval_name"
echo "fixture ready: $out ($eval_name)"
