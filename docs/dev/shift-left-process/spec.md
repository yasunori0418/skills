# shift-left-process 設計仕様

作成日: 2026-07-25 JST
形式: 本仕様は feature-spec スキル（REQ-02）が生成する spec.md テンプレートの先行適用（dogfooding）である。

## 目的

`parallel-worktree` 運用中に観測された「diff-review の指摘が機能開発を退行させる」現象を根本解消し、
ISTQB/JSTQB 準拠の testing 8 スキルを核としたシフトレフト開発プロセスを、
スキル・hook・決定論スクリプトの組み合わせとして体系化する。

観測された退行の 3 メカニズム（2026-07-25 のセッション分析より）:

1. **仕様グラウンドトゥルース不在**: diff-review は diff しか見ないため、仕様上意図的な実装を
   「過剰・不要」と指摘し、ワーカーが従って機能を削る
2. **指摘同士の振動**: 収束ループの周回間で、前周回の修正を次周回の指摘が打ち消す
3. **スコープドリフト**: ワーカーが指摘対応に没頭し、当初タスクの境界から逸脱する

メカニズム 1 の根本対策は、実装より先に仕様・テスト成果物を確定させて
レビューの判断基準にすること（シフトレフト）であり、本体系の存在理由である。

## スコープ

- `yasunori0418/skills` リポジトリへの新規スキル 6 個・既存スキル拡張 3 件・hook 1 個・
  バンドルプラグイン 1 個の追加
- 対象プロセス: 要求整理 → 仕様 → テスト計画/分析 ⇄ 仕様見直し → テスト設計 ⇄ 基本設計 →
  テスト実装 → 実装 ⇄ レビュー → PR・テスト評価 → ドキュメント統合、の 5 工程

## 横断原則

本体系の全コンポーネントが従う設計原則。個別要求より優先する。

1. **単体動作**: 全スキルは単体で動く。パイプラインの前後成果物は「あれば精度が上がる任意入力」
   であり、必須依存にしない（graceful degradation）。入力ソースは疎結合とし、
   テスト成果物・ユーザーの直接指示・任意のレビュードキュメントのいずれでも成立させる
2. **決定論と推論の分離**: 検出・検査・導出・ループ制御・スケジュールは決定論スクリプト、
   内容の作成・レビュー・意味判定はスキル/エージェント（AI）が担う
3. **意味検証とゲートの二層**: 仕様・設計の意味的な欠陥検出はテスト工程との往復
   （early testing）が正式な担い手。ゲート（機械検査）は形式契約
   （必須セクション・ID 規約・参照整合）のみを検査し、意味には踏み込まない
4. **最終判断は常にユーザー**: マージ・工程遷移の決定は人間が行う。AI の推論と決定論の導出は
   判断材料の提示まで。自動マージは組み込まない
5. **UNIX 哲学**: 一つのことを上手くやるスキルを、パイプ役（dev-pipeline）と
   ファイル契約（成果物規約・境界ファイル書式）で疎結合に組み合わせる

## 全体アーキテクチャ

### 5 工程と担い手

| 工程 | 担い手 | 成果物 | ゲート / 節目 |
| --- | --- | --- | --- |
| 0. 完成の定義 | def-done（新設） | `docs/dev/definition-of-done.md`（恒久） | セルフ機械検査 |
| 1. 要求整理 → 仕様 | feature-spec（新設）/ 既存 product-spec | `docs/dev/<対象>/spec.md`（REQ-# 契約） | セルフ検査 + test-review `spec`。収束点 PR #1 |
| 2. テスト計画/分析 ⇄ 仕様見直し | test-plan / test-analyze ⇄ feature-spec 改訂モード。test-plan 収束後に test-monitor 開始 | 既存 testing 規約 + 仕様改訂 | 既存 test-review + 孤児参照検査。収束点 PR #2（ADR 同梱） |
| 3. テスト設計 ⇄ 基本設計 | test-design ⇄ basic-design（新設） | `docs/dev/<対象>/basic-design.md` | セルフ検査 + test-review `design-doc`。収束点 PR #3（ADR 同梱） |
| 4. テスト実装 → 実装 ⇄ レビュー | test-implement + parallel-worktree（拡張） + review-converge（新設） + diff-review（拡張） | 実装レーン（feature ブランチ） | 三層ドリフト防御 + 収束ループ |
| 5. PR・テスト評価 → 統合 | test-execute / test-report + doc-integrate（新設） | 本体ドキュメント反映後、`docs/dev/<対象>/` を削除 | CI 検査（required check 化は任意） + マージはユーザー |

パイプ役は dev-pipeline（新設）。工程スキルは互いを呼ばず（testing 横断原則 4 を維持）、
dev-pipeline が現在地と次の一手を提案し、実行はユーザーが行う。

### 状態管理: 導出型 + 最小宣言

現在フェーズは状態ファイルに記録せず、決定論スクリプトが毎回導出する（SSOT は成果物そのもの）:

- **ファイル系統**: `docs/dev/<対象>/`（spec.md / basic-design.md / pipeline.toml）と
  `docs/test/<対象>/`（testing 8 スキルの成果物 + `test-review-*.md` の判定）のスキャン
- **git/gh 系統**: 収束点 docs PR のマージ状態、実装レーンのブランチ・PR 状態
  （`wt list` / `gh pr list`）

導出不能な意図情報だけを宣言ファイル `docs/dev/<対象>/pipeline.toml` に置く。
宣言は人が書く設定であり、遷移のたびに更新される状態ではない。

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

TOML を採用する（Python 3.12+ の標準 `tomllib` で依存ゼロ、コメント可、
必要な構造はテーブル 1 段 + フラットなキーと配列のみ）。

### ブランチ運用: docs 先行マージ

工程 0〜3 の成果物は、実装開始前に docs PR として main へ先行マージする。
実装レーンは docs を含んだ main から分岐するため、全レーンと diff-review が
同一の仕様スナップショットを base 経由で参照できる。

docs PR の粒度は収束点ごとに 1 本（計 3 本前後）:

1. 仕様初版（spec.md + pipeline.toml。def-done 未整備ならここで同梱）
2. 工程 2 収束（test-plan + test-analysis + 仕様改訂 + ADR）
3. 工程 3 収束（test-design + test-case + basic-design + ADR）

PR マージ = フェーズゲート通過という機械イベントになり、導出スクリプトが gh で判定できる。
ADR は決定が起きた工程 2・3 の収束点 PR に同梱する（事後にまとめて書かない）。

### ドキュメントライフサイクル

- `docs/dev/<対象>/` は機能単位の作業ドキュメント。開発完了後、doc-integrate が
  本体ドキュメント（正式仕様・アーキテクチャ設計書・コンセプト文書）へ反映し、
  作業ディレクトリは**削除**する（アーカイブはしない。読み返されないため）
- `docs/dev/definition-of-done.md` はプロジェクトに 1 つの恒久ドキュメントで、削除対象外
- 対象特化の監視設定（test-monitor 構築物）を残すか外すかは doc-integrate がユーザーに確認する
- `docs/dev/<対象>/` の削除をもって dev-pipeline はパイプライン終了と導出する

### マージゲート: 二軸判定

マージ可否 = **受け入れ基準**（spec.md の REQ-# 単位、機能の有効性）×
**完成の定義**（プロジェクト横断、作業の完成状態）の二軸。

- **CI 層（機械ブロック）**: test-monitor が構築する CI に、exit criteria のうち機械判定可能な
  検査（テスト green・カバレッジ閾値・REQ→TC→CASE トレーサビリティ網羅）を含める。
  required check 化はリポジトリごとのユーザー判断（無くても他が劣化しない）
- **パイプ役層（判定報告）**: dev-pipeline が `test-summary-report.md` の総合判定と
  完成の定義の機械判定節を読み、項目別判定 + 人判定の残チェックリストを報告する
- ローカル hook でのマージブロックは作らない（Web UI マージで素通りするため、
  機械ブロックは GitHub 側が唯一確実な位置）

## 機能要求

### REQ-01: def-done スキル（新設）

- プロジェクトに 1 つの「完成の定義」を対話で構築・改訂するスキル。
  成果物は `docs/dev/definition-of-done.md`
- 成果物は**二部構成を強制**する:
  - 機械判定節: 各項目に判定手段を宣言（CI check 名・参照する成果物パスと判定条件）。
    dev-pipeline の導出スクリプトがパースして項目別判定を報告する
  - 人判定節: 機械化できない項目のみを列挙。人間のチェックリストになる唯一の部分
- 項目総数は二部合わせて**最大 5 件**（機械検査で強制）。項目が多いほど各項目のクリアが
  重くなり完成が遠のくため、超過時は統合か削除で絞らせる
- 作成 + 改訂モード（既存ファイル検出で分岐）+ 終了時セルフ機械検査
- 消費点は 4 か所（いずれも任意入力）: dev-pipeline のマージ可否導出（主）、
  review-converge 最終報告の残項目表示、test-plan 完了基準との突合、
  pr-create の PR 本文チェックリスト生成

### REQ-02: feature-spec スキル（新設）

- 既存プロダクトへの機能追加向けの仕様作成スキル。grilling スキルを内部で呼んで要求を固め、
  `docs/dev/<対象>/spec.md` をテンプレートで書き出す
- product-spec（新規プロダクト立ち上げ用）とは住み分け。競合調査の代わりに
  既存コード・既存仕様との整合調査を持つ
- テンプレート必須セクション: 目的 / スコープ / 機能要求 / 非機能要求 / 受け入れ条件 / スコープ外
- **REQ-# 契約**: 全要求に一意 ID を付与。受け入れ条件は REQ-# に紐づける。
  ID は ISTQB 側の鎖（R# → TC-# → CASE-# → D#）の上流起点となる
- **改訂モード**: 既存 spec.md を検出したら分岐。未反映の改善提案
  （テスト成果物の改善提案セクション・ユーザー指示・任意のレビュードキュメント）を収集して
  提示 → 対話で取捨選択 → 反映（REQ-# は追番、既存 ID は変更しない）→ セルフ機械検査。
  テスト成果物側の提案削除は既存の testing 横断原則 3 に委ね、改訂モードは触らない
- 曖昧語の排除・記述品質は本スキルの責務（ゲートに委ねない）
- 終了時セルフ機械検査（REQ-08 のスクリプトを共有）

### REQ-03: basic-design スキル（新設）

- feature-spec と対をなす基本設計書の作成スキル。出力は `docs/dev/<対象>/basic-design.md`
- 入力: `spec.md`（REQ-# を参照して機能一覧を導出）+ `test-analysis.md` / `test-case.md`
  （あれば整合を取る任意入力）
- 必須セクション: 機能一覧 / モジュール構成 / インターフェース / データフロー。
  機能一覧の各項は REQ-# を参照する（要求に紐づかない機能 = スコープ外混入の機械検出を可能にする）
- 改訂モード + 終了時セルフ機械検査は feature-spec と同型

### REQ-04: doc-integrate スキル（新設）

- パイプライン終端のドキュメント統合スキル。`docs/dev/<対象>/` の仕様・基本設計を
  本体ドキュメントへ反映し、作業ディレクトリを削除する
- 統合先は `pipeline.toml` の `[integration] targets`（任意宣言）を優先し、
  無ければ対話で確認する
- 対象特化の監視設定を残すか外すかをユーザーに確認する
- `definition-of-done.md` は削除対象外

### REQ-05: dev-pipeline スキル（新設・パイプ役）

- `/dev-pipeline <対象>` で明示起動（`disable-model-invocation: true`）。
  引数なしなら `docs/dev/` / `docs/test/` から対象一覧を導出して選択を求める
- 決定論スクリプト（Python 3.12+、uv 梱包、parallel-worktree と同じ
  `UV_PROJECT_ENVIRONMENT` 退避方式）が導出する内容:
  - 現在フェーズ（ファイル系統 + git/gh 系統のスキャンから計算）
  - ゲート通過状況（`test-review-*.md` の判定・収束点 PR のマージ状態）
  - マージ可否の判定材料（test-summary-report 総合判定 + 完成の定義の項目別判定 +
    人判定の残チェックリスト）
- スキル（推論側）は導出結果を報告し、次工程スキルの実行を**提案するまで**。
  工程スキルの起動はユーザーが行う。実装フェーズ入口では「基本設計・test-case から
  実装計画ファイルを作成して /parallel-worktree を起動する」流れを提案する
- 読み取り専用（worktree 生成・エージェント起動・ファイル書き込みをしない）

### REQ-06: review-converge スキル（新設）

- diff-review 収束ループの専用パイプスキル。`/review-converge [--until <must|want+|want|nit>]`
  （既定 `want`）。閾値の語彙と意味論は diff-review 側の定義を正とする
- 動作: diff-review 起動 → 指摘をメインセッションが修正 → 再起動 → 閾値以上の指摘ゼロで収束。
  diff-review 本体の read-only 単発設計は変更しない
- ループ制御の決定論部分（スクリプト）:
  - 周回上限: 既定 5 周
  - **振動検出**: 各周回の指摘一覧（file:line + 要旨ハッシュ）を scratchpad に記録し、
    同一指摘が 2 周連続で未解消、または一度消えた指摘の再出現を機械検出して
    ユーザーへエスカレーション
  - **差分レビュー最適化**: 前周回の head sha を記録し、2 周目以降は前周回からの差分を
    manifest に明示してトークン消費を抑える
- 境界外指摘（REQ-07 の分類）は修正対象から機械的に除外し、
  「見送り一覧（理由つき）」として最終報告に残す
- 最終報告に完成の定義の残項目を表示する（任意入力）

### REQ-07: diff-review 拡張

- **グラウンドトゥルース検出（決定論）**: `collect-diff.sh` を拡張し、diff のパスから対象を
  特定して `docs/dev/<対象>/`（spec.md・basic-design.md）と
  `docs/test/<対象>/test-case.md` の存在を機械検出、manifest に
  「グラウンドトゥルース節」（パス一覧）を追記する。無ければ節ごと出さない（従来動作）
- **全レンズ共通ガード**: グラウンドトゥルース節があるとき、全レンズの reviewer prompt に
  追加 —「仕様・テストケースに根拠のある実装を『過剰・不要』と指摘しない。削除・簡略化を
  提案する場合は REQ-# / CASE-# に抵触しないことを確認してから」
- **`spec` レンズ新設**: グラウンドトゥルース検出時のみ既定レンズに昇格。
  spec.md / test-case.md を読み、「diff は宣言された REQ / CASE を満たしているか・
  仕様に無い挙動変更を持ち込んでいないか」を積極方向で検査する
  （既存レンズが「悪い変更を見つける」のに対し「あるべき変更の欠落を見つける」レンズ）
- **指摘のスコープ分類**: 境界ファイル（REQ-10 の契約）があるとき、各指摘に
  「タスク境界内 / 境界外（別タスク・別 PR で対応すべき）」の分類を付ける。
  無ければ全指摘を境界内として扱う（従来動作）

### REQ-08: test-review 拡張

- 工程引数に `spec` / `design-doc` を追加。この 2 工程は**軽量ゲート**
  （機械検査 + 利用者判定のみ。test-reviewer サブエージェントの定性レビューは起動しない）
- `review-check.sh` の拡張（feature-spec / basic-design のセルフ検査と同一スクリプトを共有):
  - `spec` モード: 必須セクション存在 / REQ-# の一意性・形式・重複欠番 /
    受け入れ条件の空欄と REQ-# 紐づけ /
    **下流参照の破壊検査**（既存 `test-analysis.md` の TC-# が参照する REQ-# を
    仕様改訂で消していないか — 孤児参照検出）
  - `design-doc` モード: 必須セクション存在 / 機能一覧の各項の REQ-# 参照必須と実在 /
    `test-case.md` があれば CASE-# との対応突合
- 意味の検査（矛盾・テスト可能性・検証可能性）はしない。工程 2〜3 の往復の領分
- レビュー結果は `test-review-spec.md` / `test-review-design-doc.md` として既存運用に乗る
  （通過記録が導出スクリプトの機械イベントになる）

### REQ-09: parallel-worktree 拡張

- **境界宣言の生成**: spec の各タスクに境界 glob（触ってよいパス）を宣言させ、
  `plan_orchestration.py` が worktree 作成時に境界ファイル
  `.claude/task-boundary.json`（REQ-10 の契約書式）を各 worktree へ生成する。
  worktree ローカル・gitignored・`wt remove` で worktree ごと消える
- **ワーカー指示テンプレの常設**: ワーカーへ渡す指示の標準セクションに以下を常設し、
  手書き指示を廃止する:
  - 実装範囲の境界（境界ファイルの内容と一致）
  - TDD 順序（テスト実装 → アプリケーション実装)
  - PR 作成前ゲート: `/review-converge` を実行し収束させてから `/pr-create [base]`
  - コミット粒度（commit-flow 準拠、既存）

### REQ-10: task-boundary hook（新設・独立 hook プラグイン）

- 配置: `hooks/task-boundary-plugin/`（プラグイン名 `yasunori0418-task-boundary-hooks`）。
  git カテゴリには置かない（結合は境界ファイル書式という契約のみ）
- 対象イベント: PreToolUse の `Edit | Write | NotebookEdit`
- **fail-open 設計**（git-guard の fail-closed と逆向き）:
  1. 書き込み対象パスから worktree ルートへ遡って `.claude/task-boundary.json` を探す。
     **無ければ即 exit 0**（プロセスに則らない通常セッションへの影響ゼロ）
  2. あれば対象パスを worktree ルート相対に解決し、宣言 glob と照合。不一致で deny
- deny メッセージの自己説明性: どのタスクの境界か・境界ファイルのパス・宣言 glob・
  正当に広げる手順を全て出力する（プロセスを知らないセッションでも状況を理解できる）
- **自己解錠の封じ**: 境界ファイル自身への書き込みも hook がブロックする。
  拡張はユーザーが手で編集するか、ユーザーの明示指示のもとで行う
- 既知の抜け穴: `Bash` 経由の書き込みは対象外。本 hook は勢いによるドリフトを止める
  ガードレールであり、敵対的エージェントへのセキュリティ境界ではない（git-guard と同格）
- 境界ファイル書式（公開契約。生成者は parallel-worktree に限定されない）:

  ```json
  {
    "task_id": "B2",
    "branch": "feat-client-retry",
    "allow": ["src/client/**", "tests/client/**", "docs/dev/<対象>/**"]
  }
  ```

- ユニットテストを `hooks/task-boundary-plugin/hooks/task-boundary/tests/*.test.sh` に置く
  （`checks.hooks` が実行）

### REQ-11: shift-left-process バンドルプラグイン（新設）

- 新設 6 スキル（def-done / feature-spec / basic-design / doc-integrate / dev-pipeline /
  review-converge）を symlink で束ねるミニマルバンドル。marketplace 内 symlink の
  実体解決（dereference）は公式サポート機構
- testing-skills / git-skills / task-boundary hook は「併用推奨」として
  バンドル説明と README で案内する（同梱しない）
- 同名スキルが複数 install 済みプラグインに含まれた場合の挙動は公式未定義のため、
  「バンドルと product / workflow / git 単体プラグインの併用不可」を説明文に明記する

## 非機能要求

- **NFR-01**: 新規スクリプトは Python 3.12 以上（`requires-python >= 3.12`）。
  TOML パースは標準 `tomllib` を使い外部依存を持たない。uv 梱包・
  `UV_PROJECT_ENVIRONMENT` 退避は parallel-worktree の既存方式に従う
- **NFR-02**: 全コンポーネントはリポジトリ既存規約に従う（agentskills.io frontmatter・
  カテゴリ別プラグイン構成・hook 単位プラグイン・`nix flake check` /
  `claude plugin validate . --strict` 通過）
- **NFR-03**: 収束ループのトークン消費を差分レビュー最適化で抑える
  （観測値: 12 回の reviewer 起動で output 335k tokens が現状の上限級）
- **NFR-04**: hook・導出スクリプトは対象外環境で沈黙する（fail-open、
  成果物が無いリポジトリでの誤作動ゼロ）

## 受け入れ条件

| ID | 対象 | 条件 |
| --- | --- | --- |
| AC-01 | REQ-01 | def-done が生成した definition-of-done.md の機械判定節を dev-pipeline がパースし、項目別判定を報告できる |
| AC-02 | REQ-02 | feature-spec が REQ-# 付き spec.md を生成し、セルフ機械検査が PASS する。改訂モードで既存 TC-# の参照先 REQ-# を消すと孤児参照検査が FAIL する |
| AC-03 | REQ-03 | basic-design が REQ-# 参照付き basic-design.md を生成し、REQ-# に紐づかない機能一覧項目を機械検査が検出する |
| AC-04 | REQ-04 | doc-integrate 実行後、`docs/dev/<対象>/` が消え、definition-of-done.md が残り、dev-pipeline が終了状態を導出する |
| AC-05 | REQ-05 | 成果物・git/gh の任意の組み合わせ状態から、dev-pipeline が現在フェーズと次の一手を導出報告する。宣言ファイルが無い対象では対象一覧の提示に留まる |
| AC-06 | REQ-06 | review-converge が閾値収束・周回上限・振動検出のいずれかで必ず停止し、振動時はエスカレーションする。境界外指摘は見送り一覧に残る |
| AC-07 | REQ-07 | グラウンドトゥルースが無いリポジトリで diff-review の挙動が従来と完全一致する。ある場合は manifest に節が追記され spec レンズが起動する |
| AC-08 | REQ-08 | 既存 7 工程の test-review の挙動が不変。spec / design-doc 工程はサブエージェントを起動しない |
| AC-09 | REQ-09/10 | 境界ファイルが無いセッションで hook が exit 0 する。境界外への Edit / Write / NotebookEdit と境界ファイル自身への書き込みが deny され、deny メッセージに解錠手順が含まれる |
| AC-10 | REQ-11 | バンドルを marketplace から install すると 6 スキルが実体として配置され、`claude plugin validate . --strict` が通る |

## スコープ外

- 自動マージ・自動工程遷移（判断は常にユーザー）
- `Bash` 経由の書き込みに対する境界ブロック（決定論での確実なパースが不可能。許容済み残余リスク）
- ローカル hook による `gh pr merge` / `pr-create` のブロック（Web UI マージで素通りするため）
- required check / branch protection の設定自体（リポジトリごとのユーザー判断）
- 手動テストの AI 代行実施・外部 issue 化（testing スキル既存方針を維持）
- testing 8 スキルの工程責務の変更（拡張は test-review のみ）

## 実装順序

上流から 9 塊。各塊は独立に自己整合（bisect 可能）とし、実装セッションごとに
commit-plan 準拠の詳細コミット計画を立てる。

1. **def-done**（REQ-01。最上流の土台。dev-pipeline 側の消費は塊 4 で実装）
2. **feature-spec + test-review `spec` 拡張**（REQ-02 + REQ-08 前半。review-check.sh 共有）
3. **basic-design + test-review `design-doc` 拡張**(REQ-03 + REQ-08 後半)
4. **dev-pipeline**（REQ-05。pipeline.toml スキーマ + 導出スクリプト + def-done 消費）
5. **diff-review 拡張**（REQ-07）
6. **review-converge**（REQ-06）
7. **parallel-worktree 拡張 + task-boundary hook**（REQ-09 + REQ-10。境界契約の両側を同塊で）
8. **doc-integrate**（REQ-04）
9. **shift-left-process バンドル + 検証実験**（REQ-11）

## 検証項目（実装フェーズで実験確認）

- 同名スキルが複数 install 済みプラグインに含まれた場合の Claude Code の実挙動
  （公式未定義。バンドル公開前に必須）
- `claude plugin validate . --strict` の symlink 追従挙動
- 境界 glob 照合の実装方式（bash の glob / Python の pathlib.match）と
  シンボリックリンク解決の一貫性

## 配置一覧

| コンポーネント | 配置 |
| --- | --- |
| def-done / feature-spec / basic-design / doc-integrate | `skills/product/` |
| dev-pipeline | `skills/workflow/` |
| review-converge | `skills/git/`（diff-review と同一プラグインに閉じる） |
| task-boundary hook | `hooks/task-boundary-plugin/`（独立 hook プラグイン） |
| shift-left-process バンドル | symlink 集約（配置ディレクトリは塊 9 で確定。候補: `bundles/shift-left-process/`） |
| test-review / diff-review / parallel-worktree 拡張 | 既存位置のまま |
