---
name: commit-flow
description: '`git commit` / `git commit --amend` を実行する前、または「commit」「amend」「コミット」「コミットして」の一語・短文だけを渡された時点で必ず発火する git コミット実施ルール。理由や差分の説明が一切無くても、ファイル全文を読んでメッセージを組み立てる前に先に参照する。主目的は論理的に独立した修正を都度・適切な粒度でコミットすること。メッセージは Conventional Commits 形式、素材は同梱の決定論スクリプト commit-context.sh が出す staged diff のみ。「コミット分けて」と依頼される、独立した複数修正をまとめるか分けるか判断する、レビューコメント対応をコミットする、rebase / squash / cherry-pick 後のメッセージを整える、`gh pr create` の PR タイトルをコミット流儀へ揃える場面でも参照する。plan モードでのコミット計画の立案は commit-plan スキルの領分。'
---

# コミット実施ルール

## このスキルの目的

優先度順:

1. **論理的に独立した修正は都度コミットする**（最重要）
2. メッセージの素材は `scripts/commit-context.sh` が出す **staged diff のみ**（§4）
3. コミットメッセージは Conventional Commits 形式で書く

メッセージ書式より**粒度と都度コミット**が本質。plan モードでのコミット計画の立案は commit-plan スキルの責務（本スキルはその計画を実施する側）。

## 1. 実装時の都度コミット

plan のコミット計画（commit-plan スキルで立案）に従い、各単位で **編集 → テスト → `git commit`** を 1 サイクルとして繰り返す。次の作業に進む前に必ず前のコミットを確定させ、一括編集→`git stash`/部分 add での後分割はしない。

plan にコミット計画が無くても、**論理的に独立した複数の修正**（複数レビューコメント対応・複数の独立バグ修正など）は原則として個別コミット。例外はユーザーから「一括でやって」「後でまとめて」と明示指示された場合のみ。

## 2. コミット粒度の判断基準

**分割する**: 別の関心事／片方だけ revert したくなる可能性／別 discussion・別 issue の対応。
**統合する**: 同じ論理変更を機械的に行数で割っただけ／片方だけ戻すと壊れる／同じ discussion 内の一連の修正。

「コミット数が増えるから 1 つにまとめる」は採用しない。同じ基準を計画段階で適用するのは commit-plan スキル。

## 3. 適用判断

- 単独コミット・PR 内コミット・squash 前のコミット全てに本ルール（特に §1〜§2）を適用
- マージコミット（`Merge branch ...`）は Git 自動生成のため対象外
- リバートコミット（`git revert` 自動生成）は接頭辞 `revert:` のまま使える
- rebase / squash / cherry-pick で履歴を整える際も、結果のメッセージは §5 に揃える

## 4. コミット実行ワークフロー（メッセージ作成前に必須）

`git commit` / `git commit --amend` のメッセージを書く前に、素材収集を同梱スクリプトに任せる。`git status` / `git diff` / `git log` を手で並べ直さない（staged / unstaged の取り違え・見落としの元）。

```bash
bash <skill-dir>/scripts/commit-context.sh [max-diff-lines]
```

`=== SECTION ===` 区切りの出力を読み、以下を厳守する:

- **メッセージの素材は `STAGED DIFF` セクションのみ**。ファイル全文の Read・過去の記憶・会話に残る別リポジトリの文脈を根拠にしない。
- **diff の `+` 行だけが「追加した」、`-` 行だけが「削除した」**。無印のコンテキスト行は今回の変更ではないので、メッセージに書かない（既存行を「追加した」と書く事故の直接対策）。
- `STAGED FILES` が「(なし)」なら素材が無い。`UNSTAGED / UNTRACKED` から何をステージするかを決め（ユーザーの明示指示があればそれに従い、無ければ候補を提示して確認）、ステージ後にスクリプトを**再実行してから**書く。
- `RECENT COMMITS` と `SCOPE CANDIDATES` で type / scope をリポジトリ慣習に揃える。**type は種別（`feat` / `fix` …）、scope は括弧内の対象領域** — 混同しない。
- `IN-PROGRESS OPERATION` に WARNING（merge / rebase 等の進行中）が出たら、通常コミットせず状況をユーザーに報告する。
- `STAGED DIFF` が行数上限で省略されたときだけ、`git diff --cached -- <path>` で範囲を絞って直接補完してよい。

## 5. メッセージフォーマット（Conventional Commits）

[Conventional Commits 1.0.0](https://www.conventionalcommits.org/) に従う。形式:

```
<type>(<scope>): <description>
```

主要 type: `feat` / `fix` / `refactor` / `test` / `docs` / `chore` / `build` / `ci` / `perf` / `style` / `revert`

詳細（type 一覧の解説、body／footer、破壊的変更の書き方、例、アンチパターン）は `references/conventional-commits.md` を参照。type 選択に迷う・破壊的変更を含む・PR タイトル整形時など、書式判断が必要な場面で読み込む。

## 6. セッションURLを含めない

Claude Code の既定動作はコミットメッセージ末尾に `Claude-Session: <URL>` のようなセッションへのリンク行を付与するが、**このリポジトリでは付与しない**。ローカル CLI・remote-control のどちらのセッションでも、コミットメッセージは本文（type/scope/description・必要な body・footer）のみで完結させ、セッションURLの行は書かない。

## 関連スキル

- commit-plan: plan モードでのコミット計画立案（plan 本文への計画セクション明示・粒度の事前判定）
- rebase-flow: 履歴整理（squash / fixup）の安全運用。整理後のメッセージは本スキル §5 に揃える
- pr-create: PR タイトルを本スキルの Conventional Commits 流儀に揃える
