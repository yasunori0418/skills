# pipeline.toml スキーマ

`docs/dev/<対象>/pipeline.toml` は、**成果物と git/gh から導出できない意図情報だけ**を
置く最小宣言ファイル。人が書く設定であり、工程遷移のたびに更新される状態ファイルではない
（現在フェーズは記録しない。SSOT は成果物そのもの）。

無くても dev-pipeline は動く（既定パス・全工程実施として導出する）。宣言があると
導出精度が上がる。TOML を採る理由は Python 3.12+ の標準 `tomllib` で依存ゼロ・コメント可・
必要な構造がテーブル 1 段 + フラットなキーと配列だけで足りるため。

## スキーマ（正本）

```toml
target = "<対象>"                  # docs/dev/<対象>/・docs/test/<対象>/ と一致

[spec]
path = "docs/dev/<対象>/spec.md"   # 既定パス通りなら省略可

[design]
path = "docs/dev/<対象>/basic-design.md"

[scope]
skip = ["test-monitor"]            # 回さない工程の宣言（既定は全工程）

[implementation]
plan_file = "..."                  # parallel-worktree 計画ファイルへの参照（任意）
branches = ["feat-a", "feat-b"]    # 実装レーンの導出補助（任意）

[integration]
targets = ["docs/architecture.md"] # doc-integrate の統合先（任意。無ければ対話で確認）
```

## キーごとの扱い

| キー | 型 | 導出への効き方 |
| --- | --- | --- |
| `target` | string | 指定対象と一致しなければレポートに警告を出す（導出は続行する） |
| `[spec].path` | string | spec.md の探索先を既定パスから差し替える |
| `[design].path` | string | basic-design.md の探索先を既定パスから差し替える |
| `[scope].skip` | string[] | 列挙された工程を「スキップ宣言済み」として扱い、次の一手の提案から外す |
| `[implementation].plan_file` | string | parallel-worktree の計画ファイル所在。レポートに転記する |
| `[implementation].branches` | string[] | ローカルブランチと突合し、一致があれば実装フェーズ（工程 4）の導出根拠にする |
| `[integration].targets` | string[] | doc-integrate の統合先候補。レポートに転記する |

## fail-open の扱い（NFR-04）

- ファイルが無い: 宣言なしとして既定値で導出する（警告も出さない）
- TOML が壊れている: パース失敗の理由をレポートに書いたうえで、宣言なしとして導出を続ける
- 型が想定と違う値（例: `skip` が文字列）: その項目だけ黙って無視し既定値にする

いずれもクラッシュさせない。宣言ファイルの不備でパイプラインの現在地が分からなくなるのは
本末転倒であるため、宣言は常に「あれば精度が上がる任意入力」として扱う。

## 置き場と寿命

`docs/dev/<対象>/` 配下に置くため、doc-integrate が作業ディレクトリを削除した時点で
一緒に消える。恒久ドキュメントである `docs/dev/definition-of-done.md` とは寿命が違う。
