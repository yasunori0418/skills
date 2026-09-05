#!/usr/bin/env bash
# Verifies converge_state.py (review-converge の収束ループ制御):
#   - 閾値以上の指摘ゼロ           -> converged
#   - 閾値未満のみ / 境界外のみ    -> converged(修正対象から除外される)
#   - improvement のみ             -> converged(見送り一覧 improvements へ蓄積)
#   - 指摘が残る                   -> continue
#   - 周回上限(既定 5)到達        -> limit-reached
#   - 同一指摘が 2 周連続で未解消  -> oscillation (stuck)
#   - 一度消えた指摘の再出現       -> oscillation (reappeared)
#   - 解消数 <= 新規数が 2 周連続  -> diverging (自己増殖)
#   - prev-head / status / reset   -> 前周回 sha の取得・再出力・初期化
#   - --changed-lines              -> 周回ごとの変更行数の系列と増分(未指定は null)
#   - lens 併記タグ               -> next_lenses でレンズ単位に分割
#   - keep / suppress              -> 保持した指摘の除外・ガード・再指摘禁止リスト
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
F_IMPROVE='[{"file":"src/a.py","line":30,"summary":"bool を enum に型化すべき","severity":"want+","kind":"improvement"}]'
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

# improvement は severity が閾値以上でも修正対象にならない(見送り一覧へ)
S="$WORK/converged-improvement.json"
OUT=$(record "$S" "$F_IMPROVE" --head aaa111)
check "converged-improvement-only" "converged" "$(verdict "$OUT")"
has "improvements-listed" "$OUT" '"improvements_count": 1'
has "improvements-detail" "$OUT" "bool を enum に型化すべき"

# improvement は周回横断で union される(後の周回で再報告されなくても残る)
S="$WORK/improvements-union.json"
record "$S" "$F_IMPROVE" --head aaa111 >/dev/null
OUT=$(record "$S" "$F_EMPTY" --head bbb222)
check "improvements-union-verdict" "converged" "$(verdict "$OUT")"
has "improvements-union-kept" "$OUT" '"improvements_count": 1'

# improvement は振動検知の対象外(同じ improvement が 2 周続いても oscillation にしない)
S="$WORK/improvement-no-stuck.json"
record "$S" "$F_IMPROVE" --head aaa111 >/dev/null
check "improvement-not-stuck" "converged" "$(verdict "$(record "$S" "$F_IMPROVE" --head bbb222)")"

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

# --- 自己増殖(解消数 <= 新規数 が 2 周連続) -> diverging ---
# 周回ごとに全て入れ替えて stuck / reappeared を避け、発散判定だけを見る
D1='[{"file":"src/a.py","line":1,"summary":"seed","severity":"must"}]'
D2='[{"file":"src/a.py","line":2,"summary":"grow-b","severity":"must"},
     {"file":"src/a.py","line":3,"summary":"grow-c","severity":"must"}]'
D3='[{"file":"src/a.py","line":4,"summary":"grow-d","severity":"must"},
     {"file":"src/a.py","line":5,"summary":"grow-e","severity":"must"}]'
S="$WORK/diverging.json"
record "$S" "$D1" --head r1 >/dev/null
record "$S" "$D2" --head r2 >/dev/null   # 解消 1 <= 新規 2
OUT=$(record "$S" "$D3" --head r3)       # 解消 2 <= 新規 2 -> 2 周連続
check "diverging" "diverging" "$(verdict "$OUT")"
has "diverging-window" "$OUT" '"new_count": 2'
has "diverging-new-findings" "$OUT" "grow-d"

# 1 周だけの膨張では発散にしない(解消が上回る周回を挟む)
S="$WORK/diverging-single.json"
record "$S" "$D2" --head r1 >/dev/null   # A,B の 2 件から開始
record "$S" "$D1" --head r2 >/dev/null   # 解消 2 > 新規 1
OUT=$(record "$S" "$D3" --head r3)       # 解消 1 <= 新規 2(単発)
check "diverging-needs-two-windows" "continue" "$(verdict "$OUT")"

# 発散パターンでも remaining ゼロなら収束が優先される
S="$WORK/diverging-but-clean.json"
record "$S" "$D1" --head r1 >/dev/null
record "$S" "$D2" --head r2 >/dev/null
check "diverging-but-converged" "converged" "$(verdict "$(record "$S" "$F_EMPTY" --head r3)")"

# --- 周回上限 ---
S="$WORK/limit.json"
FINDINGS_1='[{"file":"src/a.py","line":1,"summary":"one","severity":"must"},
             {"file":"src/a.py","line":2,"summary":"two","severity":"must"},
             {"file":"src/a.py","line":3,"summary":"three","severity":"must"}]'
FINDINGS_2='[{"file":"src/a.py","line":4,"summary":"four","severity":"must"},
             {"file":"src/a.py","line":5,"summary":"five","severity":"must"}]'
FINDINGS_3='[{"file":"src/a.py","line":6,"summary":"six","severity":"must"}]'
# 毎周回別の指摘へ入れ替えて stuck / reappeared を避けつつ、
# 指摘数を減衰させて(解消 > 新規)diverging も避け、上限判定だけを見る
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

# improvement しか出さなかったレンズは次周回で回さない
S="$WORK/lens-improvement.json"
F_LENS_IMPROVE='[{"file":"src/a.py","line":10,"summary":"境界値が未処理","severity":"must","lens":"logic"},
                 {"file":"src/b.py","line":20,"summary":"enum に型化すべき","severity":"want+","kind":"improvement","lens":"design"}]'
OUT=$(record "$S" "$F_LENS_IMPROVE" --head aaa111 --max-rounds 5)
check "lens-excludes-improvement-only-lens" "logic" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["next_lenses"]))')"

# 最終周回の直前(次が上限周回)でも徹底パスへ戻さず絞り込みを維持する
# (上限周回でレンズを広げると新規指摘が上限到達と同時に出て修正バーストになる)
S="$WORK/lens-final.json"
F_OTHER_LENS='[{"file":"src/b.py","line":20,"summary":"命名が不明瞭","severity":"must","lens":"design"}]'
record "$S" "$F_MUST" --head r1 --max-rounds 3 >/dev/null
OUT=$(record "$S" "$F_OTHER_LENS" --head r2 --max-rounds 3)
check "lens-final-round-keeps-narrowing" "design" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["next_lenses"]))')"

# 続行しないとき(収束・上限・振動)は次周回が無いので null
S="$WORK/lens-converged.json"
OUT=$(record "$S" "$F_EMPTY" --head aaa111)
check "lens-none-when-not-continue" "None" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["next_lenses"])')"

# 複数レンズが 1 件に併記された "design,test" 形式のタグはレンズ単位に分割して集計する
# (併記のまま返すと呼び出し元が解釈できず、残指摘に無いレンズまで起動した実例への対策)
S="$WORK/lens-combined.json"
F_LENS_COMBINED='[{"file":"src/a.py","line":10,"summary":"境界値が未処理","severity":"must","lens":"design,test"},
                  {"file":"src/b.py","line":20,"summary":"過剰な防御","severity":"want","lens":" yagni "}]'
OUT=$(record "$S" "$F_LENS_COMBINED" --head aaa111 --max-rounds 5)
check "lens-combined-tag-is-split" "design,test,yagni" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["next_lenses"]))')"

# lens 未指定(diff-review がレンズタグを出さない場合)は絞り込めないので null
S="$WORK/lens-absent.json"
OUT=$(record "$S" "$F_MUST" --head aaa111 --max-rounds 5)
check "lens-absent-falls-back-to-full" "None" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["next_lenses"])')"

# --- 差分推移(--changed-lines) ---
# 周回ごとの変更行数を系列で出し、最初と最後の差を増分として出す(verdict には影響しない)
S="$WORK/changed-lines.json"
record "$S" "$F_MUST" --head r1 --changed-lines 100 >/dev/null
OUT=$(record "$S" "$F_OTHER" --head r2 --changed-lines 130)
check "changed-lines-series" "100,130" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(map(str, json.load(sys.stdin)["changed_lines"])))')"
has "changed-lines-delta" "$OUT" '"changed_lines_delta": 30'
check "changed-lines-verdict-unaffected" "continue" "$(verdict "$OUT")"

# 未指定の周回は null。非 null が 2 点無ければ増分も null
S="$WORK/changed-lines-absent.json"
record "$S" "$F_MUST" --head r1 >/dev/null
OUT=$(record "$S" "$F_OTHER" --head r2 --changed-lines 130)
check "changed-lines-null-when-absent" "None,130" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(",".join(map(str, json.load(sys.stdin)["changed_lines"])))')"
has "changed-lines-delta-null" "$OUT" '"changed_lines_delta": null'

# --- kind_reason(分類根拠)は判定に使わずそのまま残す ---
S="$WORK/kind-reason.json"
F_REASON='[{"file":"src/a.py","line":10,"summary":"境界値が未処理","severity":"must","kind":"fix","kind_reason":"in-diff"},
           {"file":"src/b.py","line":20,"summary":"enum に型化すべき","severity":"want+","kind":"improvement","kind_reason":"typing"}]'
OUT=$(record "$S" "$F_REASON" --head aaa111)
check "kind-reason-verdict" "continue" "$(verdict "$OUT")"
has "kind-reason-kept-in-remaining" "$OUT" '"kind_reason": "in-diff"'
has "kind-reason-kept-in-improvements" "$OUT" '"kind_reason": "typing"'
has "kind-reason-saved-in-state" "$(cat "$S")" '"kind_reason": "typing"'

# --- 保持(keep)と再指摘禁止リスト(suppress) ---
keep() { # state file line reason [extra args...] -> stdout
    local state="$1" file="$2" line="$3" reason="$4"
    shift 4
    python3 "$STATE_PY" keep --state "$state" --file "$file" --line "$line" --reason "$reason" "$@" 2>&1
}
S="$WORK/keep.json"
F_KEEP='[{"file":"README.md","line":603,"summary":"失敗モードの説明が過剰","severity":"want","lens":"yagni"},
         {"file":"README.md","line":599,"summary":"言い換えの重複","severity":"nit","lens":"yagni"}]'
OUT=$(record "$S" "$F_KEEP" --head r1 --max-rounds 5)
check "keep-before-verdict" "continue" "$(verdict "$OUT")"
# 閾値未満の nit は suppress に載る(保持しなくても次周回で再指摘させない)
has "suppress-has-below-threshold" "$OUT" '閾値未満(nit)のため見送り'

# want の保持: remaining から外れて収束し、kept / suppress に理由付きで載る
OUT=$(keep "$S" README.md 603 "test レンズが 2 周目に要求した失敗モードの記述")
check "keep-want-exit" 0 $?
check "keep-want-converges" "converged" "$(verdict "$OUT")"
has "keep-in-kept" "$OUT" '"kept_count": 1'
has "keep-in-suppress" "$OUT" '保持: test レンズが 2 周目に要求した失敗モードの記述'
has "keep-saved-in-state" "$(cat "$S")" '"reason": "test レンズが 2 周目に要求した失敗モードの記述"'

# 保持した箇所を次周回で言い換えて再指摘されても stuck / reappeared にならず、修正対象にも戻らない
OUT=$(record "$S" '[{"file":"README.md","line":603,"summary":"帰結の連鎖が長すぎる","severity":"want","lens":"yagni"}]' --head r2 --max-rounds 5)
check "keep-reworded-restatement-ignored" "converged" "$(verdict "$OUT")"
check "keep-no-oscillation" "0" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["oscillating"]))')"

# must は保持できない / want+ は --user-confirmed が要る / 直近周回に無い指摘は保持できない / 理由必須
S="$WORK/keep-guard.json"
F_GUARD='[{"file":"src/a.py","line":10,"summary":"境界値が未処理","severity":"must"},
          {"file":"src/b.py","line":20,"summary":"命名が不明瞭","severity":"want+"}]'
record "$S" "$F_GUARD" --head r1 >/dev/null
keep "$S" src/a.py 10 "同意しない" >/dev/null 2>&1
check "keep-refuses-must" 2 $?
keep "$S" src/b.py 20 "呼び出し元の命名規約に合わせている" >/dev/null 2>&1
check "keep-refuses-want-plus-without-confirm" 2 $?
keep "$S" src/b.py 20 "呼び出し元の命名規約に合わせている" --user-confirmed >/dev/null 2>&1
check "keep-accepts-want-plus-with-confirm" 0 $?
keep "$S" src/zzz.py 1 "存在しない指摘" >/dev/null 2>&1
check "keep-refuses-unknown-location" 2 $?
keep "$S" src/b.py 20 "   " --user-confirmed >/dev/null 2>&1
check "keep-refuses-empty-reason" 2 $?

# 停止系 verdict 中の keep は裁定(--user-confirmed)無しでは拒否する(keep 連打で収束扱いにする迂回を防ぐ)
S="$WORK/keep-stop.json"
F_STOP='[{"file":"src/a.py","line":10,"summary":"境界値が未処理","severity":"want"}]'
record "$S" "$F_STOP" --head r1 --max-rounds 2 >/dev/null
OUT=$(record "$S" '[{"file":"src/a.py","line":11,"summary":"別の未処理","severity":"want"}]' --head r2 --max-rounds 2)
check "keep-stop-precondition" "limit-reached" "$(verdict "$OUT")"
keep "$S" src/a.py 11 "呼び出し元で保証済み" >/dev/null 2>&1
check "keep-refuses-under-stop-verdict" 2 $?
OUT=$(keep "$S" src/a.py 11 "呼び出し元で保証済み(ユーザー裁定)" --user-confirmed)
check "keep-accepts-under-stop-verdict-with-confirm" "converged" "$(verdict "$OUT")"

# --- 入力エラー ---
S="$WORK/bad.json"
printf 'not json' | python3 "$STATE_PY" record --state "$S" >/dev/null 2>&1
check "invalid-json" 2 $?
printf '[{"file":"a","line":1,"summary":"s","scope":"nowhere"}]' | python3 "$STATE_PY" record --state "$S" >/dev/null 2>&1
check "invalid-scope" 2 $?
printf '[{"file":"a","line":1,"summary":"s","kind":"refactor"}]' | python3 "$STATE_PY" record --state "$S" >/dev/null 2>&1
check "invalid-kind" 2 $?

exit $fail
