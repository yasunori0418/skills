# skills

AI エージェント（Claude Code / Codex）向けスキルを管理するリポジトリ。
各スキルは [agentskills.io](https://agentskills.io/specification) のオープン標準に従い、
リポジトリ全体を **Claude Code プラグイン兼マーケットプレイス**として配布できる。

3 つのレイヤーを併用している:

| レイヤー             | 担当                | 実体                                                                |
| -------------------- | ------------------- | ------------------------------------------------------------------- |
| スキルの中身         | agentskills.io 標準 | `<category>/<skill-name>/SKILL.md`（frontmatter）+ `references/` 等 |
| 配布・パッケージング | Claude Code plugin  | `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`    |
| Codex 連携           | 本リポジトリの慣習  | per-skill `agents/openai.yaml`                                      |

## ディレクトリ構成

```
.
├── .claude-plugin/
│   ├── plugin.json                   # プラグイン定義（name/version/skills 配列）
│   └── marketplace.json              # マーケットプレイス定義（単一プラグイン, source: "./"）
├── flake.nix                         # 成果物 + treefmt(formatter) + checks.skills(検証)
├── dev/flake.nix                     # 開発用 devShell (default / ci)
├── schema/
│   ├── skill-frontmatter.schema.json # SKILL.md frontmatter の JSON Schema
│   └── openai-agent.schema.json      # agents/openai.yaml の JSON Schema
├── scripts/
│   └── validate-skills.sh            # 全スキルの検証 (nix flake check / CI から呼ばれる)
├── <category>/<skill-name>/          # 各スキル（agentskills.io 標準）
│   ├── SKILL.md                      # 必須: frontmatter (name/description …) + 本文
│   ├── README.md                     # 人間向け説明
│   ├── agents/openai.yaml            # 任意: Codex(OpenAI) 連携
│   ├── references/                   # 任意: 必要時に読む詳細資料
│   ├── scripts/                      # 任意: 実行可能スクリプト
│   └── assets/                       # 任意: テンプレ・画像など
└── example/example-skill/            # テンプレート例
```

スキルは `<category>/<skill-name>/` 形式でカテゴリ配下に置く（`mizchi/skills` の構成を踏襲）。
`SKILL.md` の `name` は **親ディレクトリ名と一致**させること。

## Claude Code プラグインとして使う

リポジトリ全体が 1 プラグイン = 1 マーケットプレイス（`marketplace.json` の `source: "./"`）。

```
/plugin marketplace add https://github.com/yasunori0418/skills.git
/plugin install yasunori0418-skills@yasunori0418-skills
```

ローカル検証:

```sh
claude plugin validate . --strict
```

> カテゴリ別配置のため、Claude Code のデフォルト探索（`skills/<name>/`）ではなく
> `plugin.json` の `skills` 配列で各カテゴリを登録している。**新しいカテゴリを追加したら
> `plugin.json` の `skills` 配列にも追記**すること（例: `"skills": ["./example", "./aws"]`）。

## メタデータ仕様

### SKILL.md frontmatter（agentskills.io 標準）

| フィールド      | 必須 | 制約                                                                             |
| --------------- | ---- | -------------------------------------------------------------------------------- |
| `name`          | Yes  | 1-64文字、小文字英数とハイフン、先頭末尾・連続ハイフン不可。ディレクトリ名と一致 |
| `description`   | Yes  | 1-1024文字。何をする/いつ使うかを記述                                            |
| `license`       | No   | ライセンス名 or バンドルファイル参照                                             |
| `compatibility` | No   | 1-500文字。環境要件                                                              |
| `metadata`      | No   | string→string マップ（author, version 等）                                       |
| `allowed-tools` | No   | スペース区切り文字列（実験的）                                                   |

Claude Code 拡張として `disable-model-invocation` / `argument-hint` も許可。

### agents/openai.yaml（Codex 連携・本リポジトリの慣習）

`interface.display_name` / `interface.short_description` が必須。
`default_prompt` / `icon_small` / `icon_large` は任意。

## 開発環境

direnv 経由で `dev/flake.nix` を読み込む。

```sh
cp example.envrc .envrc && direnv allow
```

devShell には Nix 系（statix / nixd / formatter）、スキル検証系
（check-jsonschema / yamllint / markdownlint-cli2）、データ処理（yq-go / jq）、
リンク切れ検出（lychee）、検索（ripgrep / fd）を同梱。

## 検証

| 対象                                                     | コマンド                            |
| -------------------------------------------------------- | ----------------------------------- |
| SKILL.md frontmatter + agents/openai.yaml（JSON Schema） | `nix flake check`                   |
| 同上を手動実行                                           | `bash scripts/validate-skills.sh .` |
| treefmt 整形チェック                                     | `nix flake check`（同時に実行）     |
| plugin.json / marketplace.json                           | `claude plugin validate . --strict` |

`nix flake check` は git tracked なファイルのみを参照するため、新規スキルは
`git add` してから実行すること。

> 公式の検証ツール [`skills-ref`](https://github.com/agentskills/agentskills/tree/main/skills-ref)
> （`skills-ref validate ./my-skill`）も併用できる。本リポジトリの検証は
> JSON Schema ベースで自己完結している。

## 新しいスキルの追加

1. `example/example-skill/` をコピーして `<category>/<skill-name>/` にリネーム
2. `SKILL.md` の `name`（=ディレクトリ名）と `description` を書き換える
3. Codex 連携が必要なら `agents/openai.yaml` を編集、不要なら削除
4. 新しいカテゴリなら `.claude-plugin/plugin.json` の `skills` 配列に追記
5. `git add` して `nix flake check` と `claude plugin validate . --strict` で検証
