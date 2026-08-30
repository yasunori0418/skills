# worker_contract.py の入力仕様と条項差分

`scripts/worker_contract.py` はワーカー規約の正本。stdin にタスク情報 JSON を受け取り、
ワーカーへ渡す標準セクション（Markdown）を stdout へ出す。

## 入力 JSON

| フィールド | 型 | 既定 | 意味 |
| --- | --- | --- | --- |
| `task_id` | string | `""` | タスク識別子。報告コマンドに埋め込む（空なら `<task-id>` プレースホルダ） |
| `branch` | string | `""` | ワーカーの feature ブランチ。push 条項に埋め込む（空なら `<branch>`） |
| `base` | string | `"main"` | PR のベースブランチ。`default_base` と異なるとき `/pr-create <base>` になる |
| `default_base` | string | `"main"` | リポジトリの既定ベース。`base` と同じなら `/pr-create` を引数なしで出す |
| `boundary` | string[] | `[]` | 編集可能範囲の glob。空なら「担当範囲に限る」の汎用文言にフォールバック |
| `issue` | int (≥0) | `0` | 対応する GH issue 番号。0/未指定なら issue 参照の条項を出さない |
| `parent` | string | `""` | 報告先の herdr エージェント名。空なら報告を省略してよい旨の条項になる。**maintain では必須**（空だと `ContractError`。push 承認待ちの報告先が無いため） |
| `plan` | string | `""` | 計画ファイルの絶対パス。空なら計画参照の条項を出さない（implement のみ） |
| `scope_check` | string | `""` | PR 前に実行する計画突合コマンド完全形。空なら突合の条項を出さない（implement のみ） |
| `mode` | string | `"implement"` | `implement` / `maintain` のいずれか。他の値は `ContractError` |

型・値が不正なら `ContractError` を送出し、CLI は stderr へ `ERROR: ...` を出して exit 1。

## mode

- **`implement`** — 実装 → `/review-converge` 収束 → `/pr-create` までを担うレーン（既定）。
- **`maintain`** — PR 作成後のレビュー対応レーン。PR は既に存在するため
  `/review-converge`・`/pr-create` を実行せず、push は親の承認制にする。

## 条項差分

### 両モードに出る（文言も同じ）

境界 / issue 参照 / コミット粒度 / 停止時の通知 / 報告（マイルストーン一覧を除く）/
サブエージェント委任 / サブエージェントの生存管理 / 進捗ナレーション。

**停止時の通知**は報告条項から独立させ、その直前に置く（`parent` が空なら報告と同様に出さない）。
進捗の記録である報告と違い、停止の通知は怠ると親が気付けないため、同じ列挙に混ぜない。
条項には次の 2 点を含める:

- **他スキル（rebase-flow / pr-create 等）の承認ゲートで止まる場合も含む** — 実運用では
  rebase-flow の承認ゲートで停止した際に報告が漏れた。ワーカーはそのスキルの手順書に
  忠実に従うが、そこに lane-ops への報告は書かれておらず、射程外に見えるため明示する。
- **親はこの通知でしか停止を知れない** — 理由を書いた規約の方が守られる。

報告条項のマイルストーン一覧にも「親の承認・裁定待ちで停止する直前」は残す。独立条項は
「停止するとき何をするか」、マイルストーン一覧は報告コマンドの `<マイルストーン>` に渡す
語彙表であり、役割が異なる。

### implement にだけ出る

| 条項 | maintain で落とす理由 |
| --- | --- |
| PR 作成前ゲート | PR は既に存在する |
| review-converge の反復境界 | review-converge を実行しない |
| PR 作成後の凍結 | レビュー対応は実装変更が目的。maintain 専用の「PR の状態」条項で状態を提示する |
| 計画の参照（`plan`） | レビュー対応の差分は元計画に無く、グラウンドトゥルースが成立しない |
| 計画との突合（`scope_check`） | 同上。突合対象が成立しない |

`plan` / `scope_check` は maintain の入力にあっても無視され、条項は出ない。

### maintain にだけ出る

| 条項 | 内容 |
| --- | --- |
| PR の状態 | この PR は既に作成済みでレビュー段階にある。実装変更はレビュー指摘への対応に限る |
| 対応対象の限定 | 対応対象はレビュー指摘・親の指示に限る。対象は親から与えられ、自分で追加の指摘を探しに行かない |
| review-converge / pr-create の禁止 | `/review-converge`・`/pr-create` は実行しない。PR は既に存在し、修正は既存 PR のブランチへの追加コミットとして反映される（push すれば PR に載る） |

禁止条項に理由まで書くのは、`pr-create` の description が push 後に自動発火しやすく、
禁止だけでは呼ぶ動機が残るため。

### mode で文言が変わる

| 条項 | implement | maintain |
| --- | --- | --- |
| TDD 順序 | テストを先に実装し（失敗を確認）、その後アプリケーション実装で通す | 振る舞いが変わる修正はテストを先に書く。typo・コメント・ドキュメントのみの修正はテスト不要 |
| 構造変更エスカレーション | 「計画に無い」既存コードの構造変更 | 「指摘の範囲を超える」既存コードの構造変更 |
| push | 計画承認済みの前提であり、個別の確認へ回さず実行する | push・force-push は親の承認を得てから実行する（計画承認済み扱いにしない）。push 前に「push 承認待ち」を報告し、親の応答を待つ |
| 報告のマイルストーン | 最初のコミット完了 / review-converge 収束 / push 完了 / PR 作成（番号付き）/ ブロック / 承認待ち | 最初のコミット完了 / push 承認待ち / push 完了 / ブロック / 承認待ち |
| スコープ | 「このスコープ規約は review-converge の指摘にも優先して適用される」を含む | 同文を含まない（review-converge を実行しないため） |

## 呼び出し例

implement（job-graph からの実装レーン）:

```sh
printf '%s' '{
  "task_id": "B2",
  "branch": "feat-client-retry",
  "base": "feat-config-retry",
  "default_base": "main",
  "boundary": ["internal/client/**"],
  "issue": 123,
  "parent": "orc-myrepo",
  "plan": "/abs/path/to/plan.md",
  "scope_check": "python3 /abs/check_scope.py --base main --expected-file a.py"
}' | python3 <SKILL>/scripts/worker_contract.py
```

maintain（PR 作成後のレビュー対応レーン）:

```sh
printf '%s' '{
  "task_id": "d1",
  "branch": "feat-client-retry",
  "boundary": ["internal/client/**"],
  "issue": 123,
  "parent": "orc-myrepo",
  "mode": "maintain"
}' | python3 <SKILL>/scripts/worker_contract.py
```

出力はタスク本文へ連結して `send_instruction.sh` でワーカーへ渡す。
