# skills

AI エージェント(Claude Code / Codex)向けスキルを管理するリポジトリ。
各スキルは [agentskills.io](https://agentskills.io/specification) のオープン標準に従い、
リポジトリ全体を **Claude Code プラグイン兼マーケットプレイス**として配布できる。

スキルは 3 つのレイヤーを併用している。加えて Claude Code 限定で、
スキルに紐づくサブエージェントと運用 hook も plugin として同梱する:

| レイヤー                          | 担当                | 実体                                                                |
| --------------------------------- | ------------------- | ------------------------------------------------------------------- |
| スキルの中身                      | agentskills.io 標準 | `<category>/<skill-name>/SKILL.md`(frontmatter)+ `references/` 等 |
| 配布・パッケージング              | Claude Code plugin  | `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`    |
| Codex 連携                        | 本リポジトリの慣習  | per-skill `agents/openai.yaml`                                      |
| サブエージェント(任意)          | Claude Code plugin  | per-skill `agents/<name>.md`                                        |
| 運用 hook                         | Claude Code plugin  | `hooks/hooks.json` + `hooks/scripts/<name>/`                        |

## ディレクトリ構成

```
.
├── .claude-plugin/
│   ├── plugin.json                   # プラグイン定義(name/version/skills 配列)
│   └── marketplace.json              # マーケットプレイス定義(単一プラグイン, source: "./")
├── flake.nix                         # 成果物 + treefmt(formatter) + checks.skills(検証)
├── dev/flake.nix                     # 開発用 devShell (default / ci)
├── pkgs/
│   └── skills-ref.nix                # 公式 skills-ref validator の Nix ビルド式(callPackage)
├── schema/
│   └── openai-agent.schema.json      # agents/openai.yaml の JSON Schema
├── scripts/
│   └── validate-skills.sh            # 全スキルの検証 (nix flake check / CI から呼ばれる)
├── hooks/
│   ├── hooks.json                    # plugin hooks 定義(PreToolUse guard・通知等)
│   └── scripts/<name>/               # 各 hook の実体 + tests/(checks.hooks で実行)
└── <category>/<skill-name>/          # 各スキル(agentskills.io 標準)
    ├── SKILL.md                      # 必須: frontmatter (name/description …) + 本文
    ├── README.md                     # 人間向け説明
    ├── agents/openai.yaml            # 任意: Codex(OpenAI) 連携
    ├── agents/<name>.md              # 任意: Claude Code ワーカーサブエージェント
    ├── references/                   # 任意: 必要時に読む詳細資料
    ├── scripts/                      # 任意: 実行可能スクリプト
    └── assets/                       # 任意: テンプレ・画像など
```

スキルは `<category>/<skill-name>/` 形式でカテゴリ配下に置く。
`SKILL.md` の `name` は **親ディレクトリ名と一致**させること。

## Claude Code プラグインとして使う

リポジトリ全体が 1 プラグイン = 1 マーケットプレイス(`marketplace.json` の `source: "./"`)。
install するとスキルに加えて、同梱のサブエージェント(diff-reviewer / product-researcher)と
運用 hook(git rebase/reset のスキル経由強制、raw force push・sudo の拒否、
github.com への WebFetch の gh 誘導、AskUserQuestion の #aq-off/#aq-on トグル、
Stop 時デスクトップ通知など)がまとめて有効になる。

**ローカルパス運用(推奨)**: 手元の checkout を marketplace として登録すると、
push せずにローカル編集を配信できる。

```
/plugin marketplace add ~/src/github.com/yasunori0418/skills
/plugin install yasunori0418-skills@yasunori0418-skills
```

編集の反映手順(実測): plugin はキャッシュ
(`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`)への **version 単位のコピー**で
ロードされるため、symlink 時代のような即時反映はされない。ローカル編集を反映するには

1. `plugin.json` の `version` を bump(同一 version のままだと `plugin update` が
   「already at the latest version」でスキップし再コピーされない)
2. `claude plugin update yasunori0418-skills@yasunori0418-skills`(オフライン可・push 不要)
3. セッションを再起動(hooks / skills はセッション開始時にロードされる)

GitHub から直接登録する場合(反映に push が必要):

```
/plugin marketplace add https://github.com/yasunori0418/skills.git
/plugin install yasunori0418-skills@yasunori0418-skills
```

ローカル検証:

```sh
claude plugin validate . --strict
```

> カテゴリ別配置のため、Claude Code のデフォルト探索(`skills/<name>/`)ではなく
> `plugin.json` の `skills` 配列で各カテゴリを登録している。**新しいカテゴリを追加したら
> `plugin.json` の `skills` 配列にも追記**すること(例: `"skills": ["./git", "./aws"]`)。

## メタデータ仕様

### SKILL.md frontmatter(agentskills.io 標準)

| フィールド      | 必須 | 制約                                                                             |
| --------------- | ---- | -------------------------------------------------------------------------------- |
| `name`          | Yes  | 1-64文字、小文字英数とハイフン、先頭末尾・連続ハイフン不可。ディレクトリ名と一致 |
| `description`   | Yes  | 1-1024文字。何をする/いつ使うかを記述                                            |
| `license`       | No   | ライセンス名 or バンドルファイル参照                                             |
| `compatibility` | No   | 1-500文字。環境要件                                                              |
| `metadata`      | No   | string→string マップ(author, version 等)                                       |
| `allowed-tools` | No   | スペース区切り文字列(実験的)                                                   |

Claude Code 拡張として `disable-model-invocation` / `argument-hint` / `user-invocable` も許可
(upstream の skills-ref は拡張を弾くため、`pkgs/skills-ref.nix` の `postPatch` で許可している)。

### agents/openai.yaml(Codex 連携・本リポジトリの慣習)

`interface.display_name` / `interface.short_description` が必須。
`default_prompt` / `icon_small` / `icon_large` は任意。

## 開発環境

direnv 経由で `dev/flake.nix` を読み込む。

```sh
cp example.envrc .envrc && direnv allow
```

devShell には Nix 系(statix / nixd / formatter)、スキル検証系
(skills-ref / check-jsonschema / yamllint / markdownlint-cli2)、データ処理(yq-go / jq)、
リンク切れ検出(lychee)、検索(ripgrep / fd)を同梱。

## 検証

| 対象                           | コマンド                            |
| ------------------------------ | ----------------------------------- |
| SKILL.md(公式 skills-ref)      | `nix flake check`                   |
| agents/openai.yaml(JSON Schema)| `nix flake check`                   |
| 上記を手動実行                 | `bash scripts/validate-skills.sh .` |
| hook スクリプトのテスト        | `nix flake check`(checks.hooks)     |
| treefmt 整形チェック           | `nix flake check`(同時に実行)       |
| plugin.json / marketplace.json | `claude plugin validate . --strict` |

SKILL.md の検証は公式 [`skills-ref`](https://github.com/agentskills/agentskills/tree/main/skills-ref)
(`pkgs/skills-ref.nix` で `buildPythonApplication` を使ってビルド)に委譲している。
`agents/openai.yaml` だけは公式スキーマが存在しないため `schema/openai-agent.schema.json` で検証する。

`nix flake check` は git tracked なファイルのみを参照するため、新規スキルは
`git add` してから実行すること。devShell 内では `skills-ref validate <dir>` を直接実行できる。

## 新しいスキルの追加

1. `<category>/<skill-name>/` を作成し `SKILL.md` を置く(`name` はディレクトリ名と一致、
   `description` は「何をする・いつ使うか」)
2. Codex 連携が必要なら `agents/openai.yaml` を置く(不要なら置かない)
3. 新カテゴリなら `plugin.json` の `skills` 配列に追記する
