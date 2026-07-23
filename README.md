# skills

AI エージェント(Claude Code)向けスキルを管理するリポジトリ。
各スキルは [agentskills.io](https://agentskills.io/specification) のオープン標準に従い、
**カテゴリごとに独立した Claude Code プラグイン**として、1 つのマーケットプレイスから
個別に install できる。

スキルは 3 つのレイヤーを併用している。加えて Claude Code 限定で、
スキルに紐づくサブエージェントと運用 hook も plugin として同梱する:

| レイヤー                          | 担当                | 実体                                                                |
| --------------------------------- | ------------------- | ------------------------------------------------------------------- |
| スキルの中身                      | agentskills.io 標準 | `skills/<category>/<skill-name>/SKILL.md`(frontmatter)+ `references/` 等 |
| 配布・パッケージング              | Claude Code plugin  | per-category `skills/<category>/.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` |
| Codex 連携                        | 本リポジトリの慣習  | per-skill `agents/openai.yaml`                                      |
| サブエージェント(任意)          | Claude Code plugin  | per-skill `agents/<name>.md`                                        |
| 運用 hook                         | Claude Code plugin  | skill 非依存: hook 単位プラグイン `hooks/<plugin>/hooks/hooks.json` / skill 連動: `skills/<category>/hooks/hooks.json` |

## ディレクトリ構成

```
.
├── .claude-plugin/
│   └── marketplace.json              # マーケットプレイス定義(12 プラグインを列挙)
├── flake.nix                         # 成果物 + treefmt(formatter) + checks(検証)
├── dev/flake.nix                     # 開発用 devShell (default / ci)
├── pkgs/
│   └── skills-ref.nix                # 公式 skills-ref validator の Nix ビルド式(callPackage)
├── schema/
│   └── openai-agent.schema.json      # agents/openai.yaml の JSON Schema
├── scripts/
│   └── validate-skills.sh            # 全スキルの検証 (nix flake check / CI から呼ばれる)
├── hooks/                            # skill 非依存 hook = hook 単位の独立プラグイン
│   └── <plugin>/                     # 各 hook プラグイン root (source: "./hooks/<plugin>")
│       ├── .claude-plugin/plugin.json  # プラグイン定義(name: yasunori0418-<hook名>-hooks)
│       ├── hooks/hooks.json          # plugin hooks 定義(PreToolUse guard・通知等)
│       └── hooks/<name>/main.sh + tests/  # hook の実体 (checks.hooks で実行)
└── skills/
    └── <category>/                   # 各カテゴリ = 独立プラグイン (source: "./skills/<category>")
        ├── .claude-plugin/plugin.json  # プラグイン定義(name: <category>-skills / skills 配列)
        ├── hooks/                      # 任意: skill 連動 hook (例: git/hooks/git-guard)
        │   ├── hooks.json
        │   └── <name>/main.sh + tests/
        └── <skill-name>/               # 各スキル(agentskills.io 標準)
            ├── SKILL.md                # 必須: frontmatter (name/description …) + 本文
            ├── README.md               # 人間向け説明
            ├── agents/openai.yaml      # 任意: Codex(OpenAI) 連携
            ├── agents/<name>.md        # 任意: Claude Code ワーカーサブエージェント
            ├── references/             # 任意: 必要時に読む詳細資料
            ├── scripts/                # 任意: 実行可能スクリプト
            └── assets/                 # 任意: テンプレ・画像など
```

スキルは `skills/<category>/<skill-name>/` 形式でカテゴリ配下に置く。
`SKILL.md` の `name` は **親ディレクトリ名と一致**させること。

## Claude Code プラグインとして使う

1 マーケットプレイス(`marketplace.json`)に **12 のプラグイン**(カテゴリ 8 + hook 4)を
列挙している。利用者は必要なカテゴリ・hook だけを選んで install できる。

| プラグイン                                   | source                                | 内容                                                         |
| -------------------------------------------- | ------------------------------------- | ------------------------------------------------------------ |
| `git-skills`                                 | `./skills/git`                        | commit-flow / diff-review / rebase-flow / reset-flow / parallel-worktree + git-guard hook |
| `github-skills`                              | `./skills/github`                     | gh-ci-investigate / gh-fetch / gh-push / pr-create           |
| `nix-skills`                                 | `./skills/nix`                        | nix-cache-check / nix-devenv                                 |
| `claude-skills`                              | `./skills/claude`                     | Claude Code 固有: latency-triage / response-format / session-insights / tmp-output / project-session |
| `workflow-skills`                            | `./skills/workflow`                   | エージェント非依存: external-writes / test-targeted          |
| `product-skills`                             | `./skills/product`                    | biz-translate / product-spec                                 |
| `testing-skills`                             | `./skills/testing`                    | ISTQB/JSTQB テストプロセス: test-plan / test-monitor / test-analyze / test-design / test-implement / test-execute / test-report |
| `learning-skills`                            | `./skills/learning`                   | 学習・理解支援: quizzing(AI 利用で生じた理解負債の返済)     |
| `yasunori0418-askuserquestion-hooks`         | `./hooks/askuserquestion`             | AskUserQuestion のセッション単位無効化(#aq-off/#aq-on)と発火時のデスクトップ通知 |
| `yasunori0418-webfetch-github-guard-hooks`   | `./hooks/webfetch-github-guard-plugin` | github.com への WebFetch を差し戻し gh へ誘導                 |
| `yasunori0418-sudo-guard-hooks`              | `./hooks/sudo-guard-plugin`           | Bash の sudo 実行を禁止                                       |
| `yasunori0418-notify-stop-hooks`             | `./hooks/notify-stop-plugin`          | Stop 時のデスクトップ通知                                     |

> **hook の分離方針**: git rebase/reset をスキル経由へ強制する `git-guard` は、
> rebase-flow/reset-flow スキルとペアで機能するため `git-skills` プラグインに同梱する。
> それ以外の skill 非依存 hook は **hook 単位で独立プラグイン化**し(まとめて有効化しない)、
> 利用者が関心事ごとに個別 install / on-off できる。

**ローカルパス運用(推奨)**: 手元の checkout を marketplace として登録すると、
push せずにローカル編集を配信できる。marketplace add は 1 回、install は欲しい
カテゴリごとに行う。

```
/plugin marketplace add ~/src/github.com/yasunori0418/skills
/plugin install git-skills@yasunori0418-skills
/plugin install github-skills@yasunori0418-skills
/plugin install yasunori0418-sudo-guard-hooks@yasunori0418-skills
```

編集の反映手順(実測): plugin はキャッシュ
(`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`)への **version 単位のコピー**で
ロードされるため、symlink 時代のような即時反映はされない。ローカル編集を反映するには

1. 対象カテゴリの `plugin.json` の `version` を bump(同一 version のままだと `plugin update` が
   「already at the latest version」でスキップし再コピーされない)
2. `claude plugin update <plugin>@yasunori0418-skills`(オフライン可・push 不要)
3. セッションを再起動(hooks / skills はセッション開始時にロードされる)

GitHub から直接登録する場合(反映に push が必要):

```
/plugin marketplace add https://github.com/yasunori0418/skills.git
/plugin install git-skills@yasunori0418-skills
```

ローカル検証:

```sh
claude plugin validate . --strict
```

> カテゴリ別配置のため、Claude Code のデフォルト探索(`skills/<name>/`)には乗らない
> (実体は `skills/<category>/<skill-name>/` で 1 段深い)。各カテゴリプラグインの
> `plugin.json` の `skills` 配列で所属スキルを明示登録する。**新しいカテゴリを追加したら
> 新しいプラグインを立てる**(下記「新しいスキルの追加」参照)。

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

1. `skills/<category>/<skill-name>/` を作成し `SKILL.md` を置く(`name` はディレクトリ名と一致、
   `description` は「何をする・いつ使うか」)
2. Codex 連携が必要なら `agents/openai.yaml` を置く(不要なら置かない)
3. 既存カテゴリなら、そのカテゴリの `skills/<category>/.claude-plugin/plugin.json` の
   `skills` 配列に `./<skill-name>` を追記する(サブエージェントを足したら `agents` 配列にも)
4. **新カテゴリなら新しいプラグインを立てる**:
   - `skills/<category>/.claude-plugin/plugin.json` を作成(`name: "<category>-skills"`、
     `skills` は category root 相対 `./<skill-name>`)
   - `.claude-plugin/marketplace.json` の `plugins` 配列に
     `{ "name": "<category>-skills", "source": "./skills/<category>", … }` を追記
   - skill 連動 hook を同梱するなら `skills/<category>/hooks/hooks.json` +
     `skills/<category>/hooks/<name>/main.sh`(git-guard を参照)
