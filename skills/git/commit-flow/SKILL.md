---
name: commit-flow
description: '`git commit` / `git commit --amend` を 1 回でも実行する前に必ず参照する git コミット運用ルール。ユーザーの入力が「commit」「amend」「コミット」の一語だけでも、理由や差分の説明が無くても必ず発火する。主目的は論理的に独立した修正を都度・適切な粒度でコミットすること、および plan モードの実装計画に必ずコミット計画を含めること。メッセージは Conventional Commits 形式で、素材収集は同梱の決定論スクリプト commit-context.sh に従う（staged diff のみを根拠にする）。「コミットして」「コミット分けて」「分けてコミット」「コミット計画を立てて」「実装計画を立てて」「planを立てて」「実行計画を作って」「リファクタリング計画」と依頼される、ExitPlanMode 前に plan を提示する、複数の独立した修正をまとめるか分けるか判断する、レビューコメント対応をコミットする、rebase/squash で履歴を整える、`gh pr create` 時に PR タイトルをコミット流儀に揃える等の場面でも必ず参照する。'
---

# コミット運用ルール

## このスキルの目的

優先度順:

1. **論理的に独立した修正は都度コミットする**（最重要）
2. **plan モードで実装計画を立てる際は、plan 本文に必ずコミット計画を含める**
3. コミットメッセージは Conventional Commits 形式で書く
4. メッセージの素材は `scripts/commit-context.sh` が出す **staged diff のみ**（§5）

メッセージ書式より**粒度と都度コミット**が本質。

## 1. plan モードでの責務

plan モードで実装計画／リファクタリング計画／レビュー対応計画を立てる際は、以下を必ず行う。

### 1.1 コミット計画を plan 本文に明示する

実装ステップと対になる「コミット計画」セクションを plan に組み込む。`ExitPlanMode` で提示する plan に**含まれていない状態で実装に入らない**。

```markdown
## 実装ステップ
1. ドメインモデルに `Foo` を追加
2. リポジトリ層に永続化メソッドを追加
3. ユースケース層から呼び出し
4. テスト追加

## コミット計画
1. `feat(domain): Foo モデルを追加`
2. `feat(infra): FooRepository に永続化メソッドを追加`
3. `feat(usecase): Foo 永続化ユースケースから呼び出し`
4. `test(usecase): Foo 永続化のユースケーステストを追加`
```

### 1.2 粒度判定は plan 段階で済ませる

§3 の基準を立案時に適用する。「実装してみないと粒度が分からない」と先送りしない。

### 1.3 コミット数を理由に統合しない

分割か統合か未確定で残す場合、粒度に意味があるなら分割を推奨案として書く。コミット数増加はレビュアー追跡性・ロールバック容易性を確保するメリットの方が大きい。

## 2. 実装時の都度コミット

plan のコミット計画に従い、各単位で **編集 → テスト → `git commit`** を 1 サイクルとして繰り返す。次の作業に進む前に必ず前のコミットを確定させ、一括編集→`git stash`/部分 add での後分割はしない。

plan にコミット計画が無くても、**論理的に独立した複数の修正**（複数レビューコメント対応・複数の独立バグ修正など）は原則として個別コミット。例外はユーザーから「一括でやって」「後でまとめて」と明示指示された場合のみ。

## 3. コミット粒度の判断基準

**分割する**: 別の関心事／片方だけ revert したくなる可能性／別 discussion・別 issue の対応。
**統合する**: 同じ論理変更を機械的に行数で割っただけ／片方だけ戻すと壊れる／同じ discussion 内の一連の修正。

「コミット数が増えるから 1 つにまとめる」は採用しない。

## 4. 適用判断

- 単独コミット・PR 内コミット・squash 前のコミット全てに本ルール（特に §1〜§3）を適用
- マージコミット（`Merge branch ...`）は Git 自動生成のため対象外
- リバートコミット（`git revert` 自動生成）は接頭辞 `revert:` のまま使える
- rebase / squash / cherry-pick で履歴を整える際も、結果のメッセージは §6 に揃える

## 5. コミット実行ワークフロー（メッセージ作成前に必須）

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

## 6. メッセージフォーマット（Conventional Commits）

[Conventional Commits 1.0.0](https://www.conventionalcommits.org/) に従う。形式:

```
<type>(<scope>): <description>
```

主要 type: `feat` / `fix` / `refactor` / `test` / `docs` / `chore` / `build` / `ci` / `perf` / `style` / `revert`

詳細（type 一覧の解説、body／footer、破壊的変更の書き方、例、アンチパターン）は `references/conventional-commits.md` を参照。type 選択に迷う・破壊的変更を含む・PR タイトル整形時など、書式判断が必要な場面で読み込む。

## 7. セッションURLを含めない

Claude Code の既定動作はコミットメッセージ末尾に `Claude-Session: <URL>` のようなセッションへのリンク行を付与するが、**このリポジトリでは付与しない**。ローカル CLI・remote-control のどちらのセッションでも、コミットメッセージは本文（type/scope/description・必要な body・footer）のみで完結させ、セッションURLの行は書かない。
