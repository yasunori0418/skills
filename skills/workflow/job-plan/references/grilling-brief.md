# grilling-brief — 対話の brief 雛形と「閉じるまで終われない項目」

job-plan の対話は `grilling` スキルに委ねる（feature-spec / product-spec と同じ流儀）。grilling は
設計木のフロンティアを回ごとに問い、事実は自分で調べ、決定だけをユーザーへ渡す。job-plan が足すのは
**何を閉じないと成果物が書けないか**の固定リストと、**コード調査ラウンドの置き方**だけ。

## brief 雛形（Skill("grilling") に渡す）

```
対象: <job 候補名 / 入力の要約（自由記述 / docs/dev/<対象>/spec.md / issue #N）>
目的: job-graph が手放しで走らせられる計画（tmp-agents/<job>/plan.md + job-graph/spec.json）を確定する。
      成果物の章立ては references/plan-template.md、spec との対応は references/plan-spec-mapping.md。

閉じるまで終われない項目（全て決まるまでフロンティアを空にしない）:
1. <job> 名（tmp-agents/<job>/ のディレクトリ名。kebab-case）
2. タスク分割と各 task の id / branch / 依存辺（stacked か並列か。基準は job-graph dependency-analysis.md）
3. task ごとの boundary（触ってよい glob）
4. task ごとの expected_files（触るはずの実パス。巻き添えファイル込み）と expected_scale（行数）
5. task ごとの完了条件（第三者が検証できる形）
6. task ごとのコミット計画（commit-plan 準拠）
7. 事前裁定（lane-ops 判定基準表の「常にユーザー裁定」に当たる論点を洗い、裁定を取るか「該当なし」を明言）
8. スコープ外（検討して落としたもの）
9. [入力が spec.md のとき] REQ-# → task の対応付け（全 REQ-# がどれかの task に載る）
10. [入力が issue のとき] 既存 sub-issue の振り分け（task にする / 対象外にする / まとめる）

進め方の制約:
- 事実（既存コードの構造・呼び出し元・テスト配置・lockfile の有無）はユーザーに訊かず自分で調べる
- 3〜4 は、タスク分割（2）が確定した直後に 1 回まとめてコード調査し、叩き台を提示して確認する
  ラウンドを必ず置く（下記）
- 決定はユーザーのもの。推奨案を添えて問う
```

## 閉じる項目のチェックリスト（終了判定）

grilling のフロンティアが空になったら、書き始める前にこの表で確認する。1 つでも「未」なら
その項目だけ grilling へ戻す（全体をやり直さない）。

| # | 項目 | 「閉じた」と言える状態 |
| --- | --- | --- |
| 1 | `<job>` 名 | 既存 `tmp-agents/<job>/` との衝突を確認済み（あれば改訂か別名かを問うた） |
| 2 | 分割・branch・依存 | 全 task に一意な id と branch、`depends_on` が明示（空 = 並列） |
| 3 | boundary | 全 task に glob 配列（宣言漏れは正当作業のブロックになるので、テスト・生成物の置き場も含む） |
| 4 | expected_files / scale | 全 task に実パス一覧（glob 不可）と整数の行数 |
| 5 | 完了条件 | 全 task に検証手段が書かれた条件（曖昧語なし） |
| 6 | コミット計画 | 全 task に Conventional Commits の番号付きリスト |
| 7 | 事前裁定 | 「常にユーザー裁定」候補を提示し、裁定を得たか「該当なし」を明言した |
| 8 | スコープ外 | 最低 1 項目（無い場合はユーザーに「本当に無いか」を問うた） |
| 9 | REQ-# 対応 | 入力の全 REQ-# がいずれかの task の `- 対応要求:` に載る |
| 10 | 既存 sub-issue | 入力 issue の各 sub-issue に「task X にする / 対象外」の振り分けがある |

## コード調査ラウンドの置き方

`expected_files` / `boundary` / `expected_scale` は「憶測で埋めるとゲートが縮退する」項目で、
かつ**事実**なので、ユーザーに訊くものではない。タスク分割（項目 2）が固まった直後に:

1. task ごとに触るファイルを調べる（`rg` / `fd` / 既存テストの配置 / lockfile・`plugin.json` 等の
   巻き添え）。調査は 1 回にまとめる（task ごとに往復しない）
2. 結果を **叩き台として 1 ラウンドで提示**する: task ごとの `変更対象` / `境界` / `規模目安` の案と、
   その根拠（「`foo.py` の呼び出し元 3 箇所が `bar/` にある」等）
3. ユーザーは案を承認するか修正する。修正された場合は該当 task だけ再調査する

叩き台を出さずに「変更対象は何ですか」と訊くのは grilling の原則（事実は自分で調べる）違反。
逆に叩き台を出さずに書き始めると、job-graph の Phase 4 計画突合が FAIL して手放しが止まる。

## 入力別の補足

- **自由記述**: 項目 1 から順に。`<job>` 名はユーザーの語彙から提案する
- **`docs/dev/<対象>/spec.md`（feature-spec の成果物）**: `REQ-#` を第 1 章に全列挙し、項目 9 を
  必ず閉じる。事前裁定は REQ-# の解釈が割れる箇所（「AC-# の条件をどこまで厳密に見るか」）から
  候補を出す。「該当なし」で終わることは稀
- **issue 番号**: `gh issue view <N> --json title,body` と
  `gh api repos/{owner}/{repo}/issues/<N>/sub_issues` で本文と既存 sub-issue を読む。sub-issue は
  タスク候補として並べ、項目 10 で振り分けを問う。`--issue` 出力時はこの issue が epic になり、
  spec の `issue` に既存番号を入れた task は新規作成されない
- **改訂（既存 `tmp-agents/<job>/` あり）**: 既存 plan.md / spec.json を読み、差分だけを grilling する
  （「タスクを 1 つ足す」なら項目 2〜6 を新 task についてのみ、既存 task は変更の有無を 1 問で確認）。
  既存 task の spec を書き換えない限り `issue` 番号は保つ
