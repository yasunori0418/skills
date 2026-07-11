#!/usr/bin/env bash
# precompact-note/main.sh — PreCompact hook（matcher: auto）。
# 自動圧縮の直前に、何を圧縮対象から守るかの指示をコンテキストへ添える。
set -euo pipefail

cat >/dev/null # stdin の JSON は使わない（読み捨てて SIGPIPE を避ける）
echo "直前の作業内容と最初の依頼内容は圧縮しないこと。過去の作業途中の内容を圧縮"
