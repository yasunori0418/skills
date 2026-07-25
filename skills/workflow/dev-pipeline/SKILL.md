---
name: dev-pipeline
description: "シフトレフト開発プロセスの現在フェーズ・ゲート通過状況・マージ可否の判定材料を成果物と git/gh から決定論的に導出し、次に実行すべき工程スキルを提案する読み取り専用のパイプ役。/dev-pipeline [対象名] の明示実行専用。"
license: MIT
user-invocable: true
disable-model-invocation: true
argument-hint: "[対象名]"
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

# dev-pipeline

シフトレフト開発プロセス（工程 0〜5）の**パイプ役**。現在地を毎回導出して報告し、
次の一手を提案する。工程スキルは互いを呼ばず、実行はユーザーが行う。

## 読み取り専用（厳守）

このスキルは**一切書き込まない**。以下を行わない。

- ファイルの作成・編集・削除（`pipeline.toml` すら書かない。書式は提示するだけ）
- worktree の生成、tmux セッションの起動、サブエージェントの起動
- git の状態変更（commit / branch / push / PR 作成）
- 工程スキルの起動（`/feature-spec` 等を自分で呼ばない）

やるのは「導出結果の報告」と「次の一手の提案」まで。**最終判断は常にユーザー**
（横断原則 4）であり、工程遷移もマージも人が決める。

## 起動と引数

`/dev-pipeline <対象名>` — 対象のパイプライン状態を導出して報告する。

`/dev-pipeline`（引数なし）— **対象一覧モード**。`docs/dev/*/` と `docs/test/*/` から
対象候補を列挙し、どれを見るかユーザーに選んでもらう。宣言ファイル（`pipeline.toml`）が
無い対象でも一覧には出す（一覧の提示に留め、勝手に 1 件へ決め打ちしない）。

## 決定論スクリプト（scripts/derive_state.py）

導出（スキャン・パース・フェーズ計算・判定）は全て決定論スクリプトが行う。
AI 側は**その出力を読んで報告文にまとめ、次の一手を提案する**だけで、
フェーズ判定ロジックを SKILL.md 上で再現しない。

スクリプトは Python プロジェクト（`pyproject.toml` + `uv.lock`）として梱包され、
`uv` が `requires-python`（>=3.12）に沿った venv を構築して実行する。venv は skill 配下
ではなく **`UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/dev-pipeline"` に必ず逃がす**
（skill ディレクトリは read-only の nix store / plugin cache に配置され得るため）。
以下、skill 本体のパスを `<SKILL>` と表記する（プラグイン実行時は
`${CLAUDE_PLUGIN_ROOT}/dev-pipeline`、個人 skill 実行時はこの SKILL.md があるディレクトリ）。

```bash
# 対象一覧モード
UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/dev-pipeline" \
  uv run --project "<SKILL>" python "<SKILL>/scripts/derive_state.py"

# 対象指定（フェーズ導出 + ゲート + マージ判定材料）
UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/dev-pipeline" \
  uv run --project "<SKILL>" python "<SKILL>/scripts/derive_state.py" <対象名>

# 対象リポジトリを明示する場合（既定は cwd から git で解決）
UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/dev-pipeline" \
  uv run --project "<SKILL>" python "<SKILL>/scripts/derive_state.py" <対象名> -C <リポジトリルート>
```

出力は人が読める Markdown レポート。**そのまま報告の素材に使う**（数字や判定を書き換えない）。

### 導出しているもの

| 系統 | 入力 | 用途 |
| --- | --- | --- |
| ファイル | `docs/dev/<対象>/`（spec.md / basic-design.md / pipeline.toml） | 工程 1・3 の到達判定 |
| ファイル | `docs/test/<対象>/`（testing 8 スキルの成果物） | 工程 2〜5 の到達判定 |
| ファイル | `docs/test/<対象>/test-review-*.md` の `- 判定:` 行 | ゲート通過（通過 / 条件付き通過 / 差し戻し） |
| ファイル | `docs/dev/definition-of-done.md` | マージ可否（機械判定テーブル + 人判定チェックリスト） |
| git/gh | `git branch` / `gh pr list` / `gh api` の check-runs | 収束点 docs PR のマージ状態・実装レーン・CI 判定 |
| 宣言 | `docs/dev/<対象>/pipeline.toml` | 導出補助（スキップ工程・実装レーン・統合先） |

### fail-open（NFR-04）

`gh` が無い・git リポジトリでない・API が失敗した場合、スクリプトは**静かにスキップして
「導出不能（理由）」と報告する**。成果物が一つも無い状態、宣言ファイルが壊れている状態、
docs/dev と docs/test の任意の組み合わせでもクラッシュせず、その状態から言える範囲を出す。

報告では「導出不能」を**推測で埋めない**。判定できなかった項目はそのまま「判定不能（理由）」
として提示する。

## 報告フォーマット

スクリプト出力をもとに、次の 4 ブロックで報告する。

### 1. 現在フェーズ

工程番号と名前、**導出根拠**（どの成果物・どのゲート記録から そう判断したか）を添える。
根拠を添えるのは、ユーザーが「その導出は違う」と即座に訂正できるようにするため。
`[scope].skip` に列挙された工程は「スキップ宣言済み」として明示する。

| 工程 | 内容 | 主な成果物 |
| --- | --- | --- |
| 0 | 完成の定義 | `docs/dev/definition-of-done.md`（恒久） |
| 1 | 要求整理 → 仕様 | `docs/dev/<対象>/spec.md` |
| 2 | テスト計画/分析 ⇄ 仕様見直し | `test-plan.md` / `test-analysis.md` |
| 3 | テスト設計 ⇄ 基本設計 | `test-design.md` / `test-case.md` / `basic-design.md` |
| 4 | テスト実装 → 実装 ⇄ レビュー | `test-procedures.md` / 実装レーン |
| 5 | PR・テスト評価 → 統合 | `test-execution-log.md` / `test-summary-report.md` |

### 2. ゲート通過状況

- `test-review-*.md` の工程別判定（通過 / 条件付き通過 / 差し戻し / 判定不明）
- 収束点 docs PR のマージ状態・オープン PR・実装レーン候補ブランチ
- 差し戻しが残っている工程があれば、それが次の一手の最優先になる

### 3. マージ可否の判定材料

> 判定材料の提示までで、マージ可否そのものは宣言しない。

- **受け入れ基準**: `test-summary-report.md` の「総合判定」行（完了 / 未完了 / 中間評価）
- **完成の定義（機械判定）**: `definition-of-done.md` の機械判定テーブルの項目別判定
  （OK / NG / 判定不能）と集計
- **人判定の残チェックリスト**: 人判定節のチェックリストをそのまま転記

### 4. 次の一手（提案）

次に実行すべき**工程スキルのコマンド行**を提示する。**呼び出しはしない。提案だけ**。

| フェーズ | 提案する工程スキル |
| --- | --- |
| 完成の定義が未整備 | `/def-done` |
| 工程 1 | `/feature-spec <対象>` → `/test-review <対象> spec` |
| 工程 2 | `/test-plan <対象>` → `/test-analyze <対象>` → `/test-review <対象> test-analysis`（`/test-monitor <対象>` は test-plan 収束後に開始可） |
| 工程 3 | `/test-design <対象>` / `/basic-design <対象>` → `/test-review <対象> design-doc` |
| 工程 4 | `/test-implement <対象>` → **実装計画ファイルを作成** → `/parallel-worktree <計画ファイル>` → 各レーンで `/review-converge` → `/pr-create [base]` |
| 工程 5 | `/test-execute <対象>` → `/test-report <対象>` → `/doc-integrate <対象>` |

**実装フェーズ入口（工程 4）の提案は定型**にする: 「基本設計（`basic-design.md`）と
`test-case.md` からタスク分解した実装計画ファイルを作り、`/parallel-worktree <計画ファイル>`
を起動する」。計画ファイルの作成自体は dev-pipeline の仕事ではない（このスキルは書き込まない）
ため、作成をユーザーに促すか、ユーザーが別途 plan モードで作る。

複数の提案が並ぶときは**推奨を先頭**に置き、選択を求めるなら AskUserQuestion を使う。

## 宣言ファイル（pipeline.toml）

現在フェーズは状態ファイルに書かない。導出不能な**意図情報だけ**を
`docs/dev/<対象>/pipeline.toml` に置く（人が書く設定であり、遷移のたびに更新しない）。

スキーマの正本は [`references/pipeline-toml.md`](references/pipeline-toml.md)。
無ければ既定パス・全工程実施として導出するため、宣言は任意。
**dev-pipeline はこのファイルを書かない**。必要なら書式を提示してユーザーに書いてもらう。

## 単体動作（横断原則 1）

パイプラインの他コンポーネント（def-done / feature-spec / testing 8 スキル /
parallel-worktree）が一つも導入されていないリポジトリでも動く。成果物は全て
「あれば精度が上がる任意入力」で、無ければ「無い」と報告して、そこから始める手順を提案する。

## 終了条件

1. 決定論スクリプトを実行し、出力を得た（推測でフェーズを決めていない）。
2. 現在フェーズ・ゲート通過状況・マージ可否の判定材料・次の一手の 4 ブロックを報告した。
3. 導出不能だった項目は理由つきで「導出不能」と明示した（埋めていない）。
4. 工程スキルを起動していない・ファイルを書いていない（読み取り専用を守った）。
