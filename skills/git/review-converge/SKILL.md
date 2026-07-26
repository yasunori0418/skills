---
name: review-converge
description: diff-review を指摘ゼロまで繰り返し、修正と再レビューの収束ループを回す `/review-converge [--until <閾値>]` の明示実行専用スキル。
user-invocable: true
disable-model-invocation: true
argument-hint: "[--until <must|want+|want|nit>]"
license: MIT
---

# review-converge: diff-review 収束ループ

diff-review を**呼ぶだけ**のパイプスキル。レビュー本体(差分収集・レンズ・reviewer 起動・統合報告)は
diff-review の責務で、こちらはその read-only 単発設計に手を触れず、**修正と再レビューの繰り返し**と
**停止判断**だけを担う。

修正はメインセッション(あなた)が行う。ループ制御の決定論部分は `scripts/converge_state.py` が担い、
続行・収束・上限・振動の判定はスクリプトの verdict に従う(自分で判断しない)。

以下、`<SKILL_DIR>` はこのスキルの base directory(スキル起動時に表示される絶対パス)を指す。

## 引数

`/review-converge [--until <must|want+|want|nit>]`

- `--until`: 収束閾値。**この重み以上の指摘がゼロ**になったら収束とする。既定 `want`
- severity の語彙と意味論(must / want+ / want / nit・実害ベースの判定)は **diff-review 側の定義が正**。
  こちらで再定義しない
- 閾値 `want` なら nit は残っていても収束。`must` なら want 系も残せる

## 事前準備

1. 状態ファイルのパスを決める。セッションの scratchpad ディレクトリ配下(無ければ
   `$(git rev-parse --show-toplevel)/tmp_claude/`)に `review-converge-state.json` を置く。
   以降 `<STATE>` と呼ぶ
2. 途中から再開ではなく新規に回す場合、既存の状態を消す:
   `python3 <SKILL_DIR>/scripts/converge_state.py reset --state <STATE>`

## ループ手順

以下を verdict が `continue` である限り繰り返す。**1 周 = レビュー 1 回 + 修正 1 回**。

### 1. diff-review を起動する

diff-review スキルを起動してレビューさせる。

- **2 周目以降(差分レビュー最適化)**: 先に
  `python3 <SKILL_DIR>/scripts/converge_state.py prev-head --state <STATE>` で前周回の head sha を取得し、
  diff-review へ「前周回 head は `<sha>`。そこからの差分が今回の修正であり、レビューの重点はそこに置く」
  と伝える。全体の manifest 範囲は変えない(退行を見落とさないため)が、reviewer の精読対象を
  前周回差分に寄せることでトークン消費を抑える
- レンズ指定はユーザーの依頼をそのまま引き継ぐ。無指定なら diff-review の既定に任せる
  (グラウンドトゥルース検出時は `spec` レンズが既定に昇格する)
- **レンズ段階戦略(2 周目以降)**: 前周回の `record` 出力にある `next_lenses` に従う。
  配列が入っていればそのレンズだけを diff-review に指定して起動し、`null` なら
  レンズ絞り込みをせず通常どおり起動する(徹底パス)。**自分でレンズを足し引きしない**

### 2. 指摘を JSON へ落として記録する

diff-review の統合報告から指摘を抜き、JSON 配列にして `record` へ渡す:

```sh
python3 <SKILL_DIR>/scripts/converge_state.py record \
  --state <STATE> --head "$(git rev-parse HEAD)" \
  --threshold <--until で指定された閾値。既定 want> --max-rounds 5 <<'JSON'
[
  {"file": "src/a.py", "line": 42, "summary": "境界値が未処理", "severity": "must", "scope": "in", "lens": "design"},
  {"file": "other/x.py", "line": 7, "summary": "別タスクの問題", "severity": "want", "scope": "out", "lens": "test"}
]
JSON
```

- `summary` は指摘の**要旨**を短く。周回間の同一性はこれと `file:line` の正規化ハッシュで判定されるため、
  同じ指摘は同じ趣旨の要旨で書く(言い回しの揺れ・句読点・空白は正規化で吸収される)
- `scope`: diff-review が付けたスコープ分類をそのまま写す。「境界外」なら `"out"`、それ以外は `"in"`。
  diff-review が分類を付けていない(タスク境界ファイルが無い)場合は全件 `"in"`
- `lens`: 統合報告のレンズタグ(`[design]` 等)をそのまま写す。複数レンズが 1 件に統合されていたら
  最も重い severity を出したレンズを 1 つ選ぶ。タグが無ければ省略してよい(その場合はレンズ絞り込みが働かず、
  次周回は全レンズでの起動になる)
- 指摘ゼロの周回は `[]` を渡す

### 3. verdict に従う

`record` の出力 JSON の `verdict` で分岐する。**自分で判断を上書きしない**。

| verdict | 対応 |
| --- | --- |
| `continue` | `remaining` の指摘を修正し、次の周回へ戻る(手順 1 へ) |
| `converged` | ループ終了。最終報告へ進む |
| `limit-reached` | 周回上限に到達。**ユーザーへエスカレーション**して停止する |
| `oscillation` | 振動を検出。**ユーザーへエスカレーション**して停止する |

`continue` のときの修正対象は `remaining`(閾値以上・境界内)のみ。`deferred`(境界外)は**修正しない**。
次周回のレンズは同じ出力の `next_lenses` に従う(手順 1 のレンズ段階戦略)。中間周回は前周回で
指摘を出したレンズだけを回し、最終周回は全レンズの徹底パスに戻る判定をスクリプトが行うので、
**周回ごとのレンズ数を自分で決めない**。

### 4. エスカレーション(limit-reached / oscillation)

自動で回し続けない。次を提示してユーザーの判断を仰ぐ:

- `oscillation`: `oscillating` 配列の各件について、どの指摘が何周目と何周目で問題になったか
  (`kind` が `stuck` なら 2 周連続で未解消、`reappeared` なら消えた後に再出現)を示し、
  **打ち消し合いの構図**(前周回の修正を次の指摘が戻させている等)を 1〜2 文で説明する
- `limit-reached`: 残っている指摘一覧と、収束しない理由の見立てを示す
- 選択肢: 閾値を緩めて再開 / 特定の指摘を見送りに回す / 手で方針を決める / 打ち切って現状で PR に進む

## 最終報告

収束・上限・振動のいずれで止まっても、必ず次を報告する:

1. **結果**: verdict・周回数・適用閾値
2. **残指摘**(収束以外のとき): `remaining` を severity 順で
3. **見送り一覧**: `deferred`(境界外指摘)を「ファイル:行 / 要旨 / 見送り理由(タスク境界外のため
   別タスク・別 PR で対応)」の形で列挙する。**1 件も落とさない**。境界ファイルが無かった場合は
   この節を「なし」とする
4. **完成の定義の残項目**: `docs/dev/definition-of-done.md` があれば Read し、**人判定節**の
   チェックリストを未チェックのまま転記する(機械判定節は転記しない)。ファイルが無ければ節ごと省略する

## 制約

- diff-review の設計・出力形式を変更しない(呼ぶだけ)。レンズ段階戦略も
  diff-review の read-only 単発設計には触れず、**こちらの呼び出し方だけ**で実現する
- コミット・push はこのスキルの範囲外。修正のコミット粒度は commit-flow に従う
- 状態ファイル以外への書き込みは、指摘に対する**コードの修正**のみ
