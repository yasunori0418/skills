#!/usr/bin/env bash
# Verifies converge_state.py (review-converge の収束ループ制御):
#   - 閾値以上の指摘ゼロ           -> converged
#   - 閾値未満のみ / 境界外のみ    -> converged(修正対象から除外される)
#   - 指摘が残る                   -> continue
#   - 周回上限(既定 5)到達        -> limit-reached
#   - 同一指摘が 2 周連続で未解消  -> oscillation (stuck)
#   - 一度消えた指摘の再出現       -> oscillation (reappeared)
#   - prev-head / status / reset   -> 前周回 sha の取得・再出力・初期化
#   - 壊れた入力                   -> exit 2
# python3 が無い環境では SKIP して exit 0。
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATE_PY="$SCRIPT_DIR/../converge_state.py"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: $(basename "$0") python3 が無い環境のためスキップ"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then
        echo "PASS: $(basename "$0")[$1] -> '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] expected '$2', got '$3'"
        fail=1
    fi
}
has() { # label haystack needle
    if printf '%s' "$2" | grep -qF -- "$3"; then
        echo "PASS: $(basename "$0")[$1] contains '$3'"
    else
        echo "FAIL: $(basename "$0")[$1] missing '$3'"
        fail=1
    fi
}

# record: state findings-json [extra args...] -> stdout(判定 JSON)
record() {
    local state="$1" findings="$2"
    shift 2
    printf '%s' "$findings" | python3 "$STATE_PY" record --state "$state" "$@" 2>&1
}
verdict() { # 判定 JSON -> verdict 文字列
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verdict"])' 2>/dev/null
}

F_MUST='[{"file":"src/a.py","line":10,"summary":"境界値が未処理","severity":"must"}]'
F_OTHER='[{"file":"src/b.py","line":20,"summary":"命名が不明瞭","severity":"must"}]'
F_NIT='[{"file":"src/a.py","line":10,"summary":"空白の揺れ","severity":"nit"}]'
F_OUT='[{"file":"other/x.py","line":1,"summary":"別タスクの問題","severity":"must","scope":"out"}]'
F_EMPTY='[]'

# --- 収束 ---
S="$WORK/converged.json"
check "converged-empty" "converged" "$(verdict "$(record "$S" "$F_EMPTY" --head aaa111)")"

S="$WORK/converged-below-threshold.json"
OUT=$(record "$S" "$F_NIT" --head aaa111 --threshold want)
check "converged-below-threshold" "converged" "$(verdict "$OUT")"

S="$WORK/converged-out-of-scope.json"
OUT=$(record "$S" "$F_OUT" --head aaa111)
check "converged-out-of-scope" "converged" "$(verdict "$OUT")"
has "deferred-listed" "$OUT" '"deferred_count": 1'
has "deferred-detail" "$OUT" "別タスクの問題"

# nit 閾値なら nit も修正対象になる
S="$WORK/nit-threshold.json"
check "continue-nit-threshold" "continue" "$(verdict "$(record "$S" "$F_NIT" --head aaa111 --threshold nit)")"

# --- 継続 ---
S="$WORK/continue.json"
OUT=$(record "$S" "$F_MUST" --head aaa111)
check "continue-first-round" "continue" "$(verdict "$OUT")"
has "continue-remaining" "$OUT" '"remaining_count": 1'
has "continue-round" "$OUT" '"round": 1'

# --- 同一指摘が 2 周連続で未解消 -> oscillation (stuck) ---
S="$WORK/stuck.json"
record "$S" "$F_MUST" --head aaa111 >/dev/null
OUT=$(record "$S" "$F_MUST" --head bbb222)
check "stuck-oscillation" "oscillation" "$(verdict "$OUT")"
has "stuck-kind" "$OUT" '"kind": "stuck"'
has "stuck-which" "$OUT" "境界値が未処理"

# 要旨の空白・記号の揺れは同一指摘と見なす(正規化ハッシュ)
S="$WORK/stuck-normalized.json"
record "$S" '[{"file":"src/a.py","line":10,"summary":"境界値が未処理","severity":"must"}]' --head aaa111 >/dev/null
OUT=$(record "$S" '[{"file":"src/a.py","line":10,"summary":"境界値が　未処理。","severity":"must"}]' --head bbb222)
check "stuck-normalized" "oscillation" "$(verdict "$OUT")"

# 別の指摘に入れ替わっていれば振動ではない
S="$WORK/no-stuck.json"
record "$S" "$F_MUST" --head aaa111 >/dev/null
check "different-finding-continues" "continue" "$(verdict "$(record "$S" "$F_OTHER" --head bbb222)")"

# --- 一度消えた指摘の再出現 -> oscillation (reappeared) ---
S="$WORK/reappear.json"
record "$S" "$F_MUST" --head aaa111 >/dev/null  # 1 周目: あり
record "$S" "$F_OTHER" --head bbb222 >/dev/null # 2 周目: 消えた(別指摘のみ)
OUT=$(record "$S" "$F_MUST" --head ccc333)      # 3 周目: 再出現
check "reappear-oscillation" "oscillation" "$(verdict "$OUT")"
has "reappear-kind" "$OUT" '"kind": "reappeared"'
has "reappear-which" "$OUT" "境界値が未処理"

# --- 周回上限 ---
S="$WORK/limit.json"
FINDINGS_1='[{"file":"src/a.py","line":1,"summary":"one","severity":"must"}]'
FINDINGS_2='[{"file":"src/a.py","line":2,"summary":"two","severity":"must"}]'
FINDINGS_3='[{"file":"src/a.py","line":3,"summary":"three","severity":"must"}]'
# 毎周回別の指摘にして stuck / reappeared を避け、上限判定だけを見る
record "$S" "$FINDINGS_1" --head r1 --max-rounds 3 >/dev/null
record "$S" "$FINDINGS_2" --head r2 --max-rounds 3 >/dev/null
OUT=$(record "$S" "$FINDINGS_3" --head r3 --max-rounds 3)
check "limit-reached" "limit-reached" "$(verdict "$OUT")"
has "limit-round" "$OUT" '"round": 3'

# 上限到達でも指摘ゼロなら収束が優先される
S="$WORK/limit-but-clean.json"
record "$S" "$FINDINGS_1" --head r1 --max-rounds 2 >/dev/null
check "limit-but-converged" "converged" "$(verdict "$(record "$S" "$F_EMPTY" --head r2 --max-rounds 2)")"

# --- prev-head / status / reset ---
S="$WORK/heads.json"
python3 "$STATE_PY" prev-head --state "$S" >/dev/null 2>&1
check "prev-head-missing-state" 1 $?
record "$S" "$F_MUST" --head sha-round-1 >/dev/null
check "prev-head-after-round1" "sha-round-1" "$(python3 "$STATE_PY" prev-head --state "$S")"
record "$S" "$F_OTHER" --head sha-round-2 >/dev/null
check "prev-head-after-round2" "sha-round-2" "$(python3 "$STATE_PY" prev-head --state "$S")"

OUT=$(python3 "$STATE_PY" status --state "$S")
check "status-verdict" "continue" "$(verdict "$OUT")"
has "status-prev-head" "$OUT" '"prev_head": "sha-round-1"'

python3 "$STATE_PY" reset --state "$S"
check "reset-removes-state" "absent" "$([ -f "$S" ] && echo present || echo absent)"
python3 "$STATE_PY" status --state "$S" >/dev/null 2>&1
check "status-after-reset" 1 $?

# --- レンズ段階戦略(next_lenses) ---
# 中間周回: 前周回で閾値以上・境界内の指摘を出したレンズだけを次周回の対象にする
S="$WORK/lens-narrow.json"
F_LENS='[{"file":"src/a.py","line":10,"summary":"境界値が未処理","severity":"must","lens":"design"},
         {"file":"src/b.py","line":20,"summary":"nit だけのレンズ","severity":"nit","lens":"docs"}]'
OUT=$(record "$S" "$F_LENS" --head aaa111 --max-rounds 5)
has "lens-narrow-picked" "$OUT" '"design"'
check "lens-narrow-excludes-nit-only-lens" "design" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["next_lenses"]))')"

# 最終周回の直前(次が上限周回)は徹底パスへ戻す -> null(= 全レンズ)
S="$WORK/lens-final.json"
record "$S" "$F_MUST" --head r1 --max-rounds 3 >/dev/null
OUT=$(record "$S" "$F_OTHER" --head r2 --max-rounds 3)
check "lens-final-round-is-full-pass" "None" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["next_lenses"])')"

# 続行しないとき(収束・上限・振動)は次周回が無いので null
S="$WORK/lens-converged.json"
OUT=$(record "$S" "$F_EMPTY" --head aaa111)
check "lens-none-when-not-continue" "None" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["next_lenses"])')"

# lens 未指定(diff-review がレンズタグを出さない場合)は絞り込めないので null
S="$WORK/lens-absent.json"
OUT=$(record "$S" "$F_MUST" --head aaa111 --max-rounds 5)
check "lens-absent-falls-back-to-full" "None" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["next_lenses"])')"

# --- 入力エラー ---
S="$WORK/bad.json"
printf 'not json' | python3 "$STATE_PY" record --state "$S" >/dev/null 2>&1
check "invalid-json" 2 $?
printf '[{"file":"a","line":1,"summary":"s","scope":"nowhere"}]' | python3 "$STATE_PY" record --state "$S" >/dev/null 2>&1
check "invalid-scope" 2 $?

exit $fail
