# AGENTS.md

複数の AI エージェント（Claude Code / Codex 等）共通の作業ガイド。
`CLAUDE.md` は本ファイルへの symlink であり、**編集は常に `AGENTS.md` に対して行う**
（二重管理・乖離を防ぐため）。利用者向けの説明は [README.md](./README.md) を参照。

## このリポジトリは何か

AI エージェント向けスキルを管理するリポジトリ。3 つのレイヤーを併用する。

| レイヤー | 担当 | 実体 |
| --- | --- | --- |
| スキルの中身 | [agentskills.io](https://agentskills.io/specification) 標準 | `<category>/<skill-name>/SKILL.md` |
| 配布・パッケージング | Claude Code plugin | `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` |
| Codex 連携 | 本リポジトリの慣習 | per-skill `agents/openai.yaml` |

## ディレクトリ規約

- スキルは `<category>/<skill-name>/` 形式でカテゴリ配下に置く。
- `SKILL.md` の frontmatter `name` は **親ディレクトリ名（`<skill-name>`）と一致**させる。
- インフラ（`flake.nix` / `dev/` / `schema/` / `scripts/` / `.github/` / `.claude-plugin/`）は
  リポジトリ直下。スキルのカテゴリディレクトリと混在する。

## スキルを作成・編集するときのルール

1. `example/example-skill/` を雛形としてコピーし `<category>/<skill-name>/` にリネームする。
2. `SKILL.md` の frontmatter は agentskills.io 標準に従う。
   - 必須: `name`（1-64文字 / 小文字英数とハイフン / 先頭末尾・連続ハイフン不可 / ディレクトリ名と一致）、
     `description`（1-1024文字 / 何をする・いつ使うか）。
   - 任意: `license` / `compatibility`（≤500文字）/ `metadata`（string→string）/
     `allowed-tools`（スペース区切り文字列）。
   - Claude Code 拡張 `disable-model-invocation` / `argument-hint` も許可。
   - スキーマ正本: `schema/skill-frontmatter.schema.json`。
3. 本文は ~500 行以内に収め、詳細は `references/` に分割する（progressive disclosure）。
4. Codex 連携が必要なら `agents/openai.yaml` を置く（`interface.display_name` /
   `interface.short_description` 必須。スキーマ: `schema/openai-agent.schema.json`）。不要なら削除。
5. **新しいカテゴリを追加したら `.claude-plugin/plugin.json` の `skills` 配列に必ず追記する**
   （例: `"skills": ["./example", "./aws"]`）。カテゴリ別配置のため Claude Code の
   デフォルト探索（`skills/<name>/`）に乗らず、明示登録が必要。

## 検証（コミット前に必須）

新規ファイルは `git add` してから検証する（`nix flake check` は git tracked のみ参照する）。

```sh
nix fmt                              # treefmt 整形（nixfmt + prettier）
nix flake check                     # スキルスキーマ検証 + 整形チェック
claude plugin validate . --strict   # plugin.json / marketplace.json 検証
```

スキル検証だけを手早く回すなら `bash scripts/validate-skills.sh .`。

## コミット規約

- [Conventional Commits](https://www.conventionalcommits.org/) 形式
  （`feat` / `fix` / `refactor` / `test` / `docs` / `chore` / `build` / `ci` / `perf` / `style` / `revert`）。
- **論理的に独立した修正は都度・適切な粒度でコミットする**。行数で機械的に割らない。
- `flake.nix` は `schema/`・`scripts/`・`example/` を参照するため、それらを先行コミットして
  各コミットが自己整合（bisect 可能）になる順序を保つ。

## 開発環境

direnv 経由で `dev/flake.nix` を読み込む。

```sh
cp example.envrc .envrc && direnv allow
```

## 参考

- [agentskills.io specification](https://agentskills.io/specification)
- [Claude Code Plugins reference](https://code.claude.com/docs/en/plugins-reference)
- [AGENTS.md / CLAUDE.md の symlink 運用](https://zenn.dev/explaza/articles/33f1dd2003c981)
