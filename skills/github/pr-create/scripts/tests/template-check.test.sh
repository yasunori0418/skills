#!/usr/bin/env bash
# template-check.sh を検証する（一時ファイルのみ。ネットワーク不要）。
#
# 検証内容:
#   - 骨組み一致・[ ]→[x]                 -> OK
#   - 見出しの欠落 / 固定項目の追加 / 並べ替え -> DRIFT
#   - 仮項目（空・連番だけ・<…>・xxx 等）を同じ見出しの中で実際の項目へ置き換え -> OK（REPLACED を表示）
#   - 仮項目をそのまま残す                -> DRIFT（PLACEHOLDER）
#   - 仮項目を置き換えずに消す            -> OK
#   - 仮項目のある節でも固定項目の欠落は DRIFT、仮項目の無い節への追加は DRIFT
#   - TODO 等を含むだけの通常項目は仮項目とみなさない
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CHECK="$SCRIPT_DIR/../template-check.sh"

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

run() { # template-body draft-body -> sets OUT / RC
    printf '%s\n' "$1" >|"$WORK/tmpl.md"
    printf '%s\n' "$2" >|"$WORK/draft.md"
    OUT=$(bash "$CHECK" "$WORK/tmpl.md" "$WORK/draft.md" 2>&1)
    RC=$?
}

FIXED='## 概要

## チェック
- [ ] テストを追加した
- [ ] TODO コメントを残していない'

# --- 従来の照合 ---
run "$FIXED" "$FIXED"
check "identical" 0 "$RC"

run "$FIXED" '## 概要
本文
## チェック
- [x] テストを追加した
- [ ] TODO コメントを残していない'
check "checked-and-filled" 0 "$RC"

run "$FIXED" '## チェック
- [ ] テストを追加した
- [ ] TODO コメントを残していない'
check "missing-heading" 1 "$RC"
has "missing-heading-msg" "$OUT" "MISSING"

run "$FIXED" "$FIXED
- [ ] 勝手な項目"
check "extra-item" 1 "$RC"
has "extra-item-msg" "$OUT" "EXTRA"

run "$FIXED" '## 概要

## チェック
- [ ] TODO コメントを残していない
- [ ] テストを追加した'
check "reorder" 1 "$RC"
has "reorder-msg" "$OUT" "REORDER"

# --- 仮項目 ---
PH='## 概要

## テスト
- [ ] テストケース1
- [ ] テストケース2
- [ ] テストケース3

## チェック
- [ ] テストを追加した'

run "$PH" '## 概要
本文
## テスト
- [x] make test が通る
- [x] 実機で設定が反映される

## チェック
- [x] テストを追加した'
check "placeholder-replaced" 0 "$RC"
has "placeholder-replaced-msg" "$OUT" "REPLACED"

run "$PH" '## 概要
本文
## テスト
- [x] make test が通る
- [ ] テストケース2

## チェック
- [x] テストを追加した'
check "placeholder-left" 1 "$RC"
has "placeholder-left-msg" "$OUT" "PLACEHOLDER"

run "$PH" '## 概要
本文
## テスト
該当なし

## チェック
- [x] テストを追加した'
check "placeholder-removed" 0 "$RC"

run "$PH" '## 概要
本文
## テスト
- [x] make test が通る

## チェック
- [x] テストを追加した
- [x] 仮項目の無い節への追加'
check "extra-in-fixed-section" 1 "$RC"
has "extra-in-fixed-section-msg" "$OUT" "EXTRA"

MIXED='## テスト
- [ ] 既存テストが通る
- [ ] Test case 1
- [ ]
- [ ] <確認内容>
- [ ] xxx'

run "$MIXED" '## テスト
- [x] 既存テストが通る
- [x] 新しいケースを追加した'
check "mixed-replaced" 0 "$RC"

run "$MIXED" '## テスト
- [x] 新しいケースを追加した'
check "mixed-fixed-missing" 1 "$RC"
has "mixed-fixed-missing-msg" "$OUT" "既存テストが通る"

run "$MIXED" '## テスト
- [x] 新しいケースを追加した
- [x] 既存テストが通る'
check "mixed-fixed-order-free" 0 "$RC"

exit "$fail"
