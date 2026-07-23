# AGENTS.md

複数の AI エージェント（Claude Code / Codex 等）共通の作業ガイド。
`CLAUDE.md` は本ファイルへの symlink であり、**編集は常に `AGENTS.md` に対して行う**
（二重管理・乖離を防ぐため）。利用者向けの説明は [README.md](./README.md) を参照。

## このリポジトリは何か

AI エージェント向けスキルを管理するリポジトリ。スキルは 3 つのレイヤーを併用する。
加えて Claude Code 限定で、スキルに紐づく任意のサブエージェント層を持てる。

| レイヤー | 担当 | 実体 |
| --- | --- | --- |
| スキルの中身 | [agentskills.io](https://agentskills.io/specification) 標準 | `skills/<category>/<skill-name>/SKILL.md` |
| 配布・パッケージング | Claude Code plugin | per-category `skills/<category>/.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json`（12 プラグイン） |
| Codex 連携 | 本リポジトリの慣習 | per-skill `agents/openai.yaml` |
| claude-code サブエージェント（任意） | Claude Code plugin | per-skill `agents/<name>.md` |
| 運用 hook | Claude Code plugin | skill 非依存: hook 単位プラグイン `hooks/<plugin>/hooks/hooks.json` / skill 連動: `skills/<category>/hooks/hooks.json` |

## プラグイン構成（カテゴリ別 N plugins）

1 マーケットプレイス（`.claude-plugin/marketplace.json`）に 12 プラグインを列挙し、
利用者はカテゴリ単位・hook 単位で install できる。

- **カテゴリプラグイン**（8 個）: `skills/<category>/` が各プラグイン root。
  `skills/<category>/.claude-plugin/plugin.json`（`name: "<category>-skills"`）を置き、
  marketplace の `source` は `./skills/<category>`。`skills` / `agents` 参照は
  **category root からの相対**（`./<skill-name>` / `./<skill-name>/agents/<name>.md`）。
- **hook プラグイン**（4 個）: skill 非依存の guard/通知 hook を **hook 単位**で
  独立プラグイン化し、利用者が個別に install / on-off できる。各プラグイン root は
  `hooks/<plugin>/`（`yasunori0418-askuserquestion-hooks` /
  `yasunori0418-webfetch-github-guard-hooks` / `yasunori0418-sudo-guard-hooks` /
  `yasunori0418-notify-stop-hooks`）。root 直下に `.claude-plugin/plugin.json` と
  `hooks/hooks.json` を置き、実体は `hooks/<name>/main.sh`。marketplace の `source` は
  `./hooks/<plugin>`。skill は含まない。
- **hook の所属**: skill に依存しない guard/通知 hook は上記の hook 単位プラグインへ置く
  （関心事ごとに分離し、まとめて有効化しない）。skill とペアで機能する hook
  （例 `git-guard` は rebase-flow/reset-flow の arm marker とペア）は、その skill の
  カテゴリプラグインに `skills/<category>/hooks/` として同居させる。

## ディレクトリ規約

- スキルは `skills/<category>/<skill-name>/` 形式でカテゴリ配下に置く。
- `SKILL.md` の frontmatter `name` は **親ディレクトリ名（`<skill-name>`）と一致**させる。
- スキルに紐づく claude-code サブエージェントは `skills/<category>/<skill-name>/agents/<name>.md` に置く。
  `agents/` は「そのスキルのエージェント連携置き場」で、Codex 用 `openai.yaml` と
  Claude 用 `*.md` が同居する。`.md` の frontmatter `name` はファイル名 stem と一致させる。
- 公開スキルは `skills/` 配下に隔離する。インフラ（`flake.nix` / `dev/` / `pkgs/` /
  `schema/` / `scripts/` / `hooks/` / `.github/` / `.claude-plugin/`）はリポジトリ直下。
- plugin hooks は `hooks.json` に定義し、実体は `<name>/main.sh`
  （テストは `<name>/tests/*.test.sh`、`checks.hooks` が実行）。skill 非依存 hook は
  hook 単位プラグイン `hooks/<plugin>/hooks/` 配下、skill 連動 hook は
  `skills/<category>/hooks/` 配下。スクリプト参照は各プラグイン root を
  起点に `${CLAUDE_PLUGIN_ROOT}/hooks/<name>/main.sh` の形で書く。
- 追加の Nix パッケージは callPackage パターンで `pkgs/<pkg>.nix` に置き、`flake.nix` から
  `pkgs.callPackage ./pkgs/<pkg>.nix { }` で取り込む。
  （カテゴリ `skills/nix/`（Nix 系スキル置き場）との衝突を避けるため、インフラ側は `pkgs/`。）

## スキルを作成・編集するときのルール

1. `skills/<category>/<skill-name>/` ディレクトリを新規作成し `SKILL.md` を置く（雛形ディレクトリは
   置いていない。frontmatter は次項に従う）。
2. `SKILL.md` の frontmatter は agentskills.io 標準に従う。
   - 必須: `name`（1-64文字 / 小文字英数とハイフン / 先頭末尾・連続ハイフン不可 / ディレクトリ名と一致）、
     `description`（1-1024文字 / 何をする・いつ使うか）。
   - 任意: `license` / `compatibility`（≤500文字）/ `metadata`（string→string）/
     `allowed-tools`（スペース区切り文字列）。
   - Claude Code 拡張 `disable-model-invocation` / `argument-hint` / `user-invocable` も許可。
   - 検証は公式 `skills-ref`（`pkgs/skills-ref.nix` でビルド）に委譲する。独自の
     frontmatter スキーマは持たない。upstream は Claude Code 拡張フィールドを
     許可しないため、`pkgs/skills-ref.nix` の `postPatch` で `ALLOWED_FIELDS` に
     上記 3 フィールドを追加している（rev 更新時はパッチの追従を確認する）。
3. 本文は ~500 行以内に収め、詳細は `references/` に分割する（progressive disclosure）。
4. Codex 連携が必要なら `agents/openai.yaml` を置く（`interface.display_name` /
   `interface.short_description` 必須。スキーマ: `schema/openai-agent.schema.json`）。不要なら削除。
5. Claude Code のワーカーサブエージェントが必要なら `agents/<name>.md` を置く
   （frontmatter: `name`（ファイル名 stem と一致）/ `description` 必須、任意で
   `tools` / `model` / `color` / `hooks`（agent 専用の PreToolUse 等。スクリプトは
   `${CLAUDE_PLUGIN_ROOT}` 起点で参照する））。**claude-code 専用**で Codex 側に
   等価物は無い（`agents/openai.yaml` とは別物）。不要なら置かない。
6. **既存カテゴリにスキルを足したら、そのカテゴリの
   `skills/<category>/.claude-plugin/plugin.json` の `skills` 配列に `./<skill-name>` を
   追記する**（category root 相対）。カテゴリ別配置のため Claude Code のデフォルト探索
   （`skills/<name>/`）に乗らず、明示登録が必要。**サブエージェント `.md` を追加したら
   同 plugin.json の `agents` 配列に `"./<skill-name>/agents/<name>.md"` を追記する**。
7. **新しいカテゴリを追加したら新しいプラグインを立てる**:
   - `skills/<category>/.claude-plugin/plugin.json` を作成（`name: "<category>-skills"`、
     `skills` / `agents` は category root 相対、`version` / `author` / `license` は既存に揃える）。
   - `.claude-plugin/marketplace.json` の `plugins` 配列へ
     `{ "name": "<category>-skills", "source": "./skills/<category>", … }` を追記
     （`name` は plugin.json と一致させる。`claude plugin validate` が整合を見る）。
   - skill 連動 hook を同梱するなら `skills/<category>/hooks/hooks.json` +
     `skills/<category>/hooks/<name>/main.sh` を置く（root=`skills/<category>` なので
     `hooks/hooks.json` が規約検出される）。
8. **skill 非依存の hook を新設するときは hook 単位で独立プラグインを立てる**（まとめて
   有効化させない）:
   - `hooks/<plugin>/` を新しいプラグイン root にし、`hooks/<plugin>/.claude-plugin/plugin.json`
     （`name: "yasunori0418-<hook名>-hooks"`、`version` / `author` / `license` は既存に揃える）と
     `hooks/<plugin>/hooks/hooks.json` を置く。実体は `hooks/<plugin>/hooks/<name>/main.sh`、
     テストは同 `<name>/tests/*.test.sh`。`command` は `${CLAUDE_PLUGIN_ROOT}/hooks/<name>/main.sh`。
   - `.claude-plugin/marketplace.json` の `plugins` 配列へ
     `{ "name": "yasunori0418-<hook名>-hooks", "source": "./hooks/<plugin>", "category": "hooks", … }`
     を追記（`name` は plugin.json と一致させる）。

## 検証（コミット前に必須）

新規ファイルは `git add` してから検証する（`nix flake check` は git tracked のみ参照する）。

```sh
nix fmt                              # treefmt 整形（nixfmt + prettier、markdown は対象外）
nix flake check                     # skills-ref 検証 + openai.yaml スキーマ検証 + 整形チェック
claude plugin validate . --strict   # plugin.json / marketplace.json 検証
```

- SKILL.md は公式 `skills-ref validate <dir>` で検証（`checks.skills` / `scripts/validate-skills.sh`）。
- `agents/openai.yaml` は `schema/openai-agent.schema.json` で検証（公式スキーマが無いため独自）。
- サブエージェント `agents/*.md` は独自スキーマを持たず、`claude plugin validate . --strict`
  （参照整合）+ レビューで担保する（frontmatter 検証の公式スキーマが無いため最小限に保つ）。
- hook スクリプトのユニットテストは `checks.hooks`（`nix flake check`）で実行する。
  対象は `hooks/` と `skills/` の両ツリーから再帰探索した `*/tests/*.test.sh`
  （skill 非依存 hook の `hooks/<plugin>/hooks/<name>/tests/` と skill 連動 hook の
  `skills/<category>/hooks/<name>/tests/` の両方）。
- devShell では `skills-ref validate <dir>` を直接実行できる。

## コミット規約

- [Conventional Commits](https://www.conventionalcommits.org/) 形式
  （`feat` / `fix` / `refactor` / `test` / `docs` / `chore` / `build` / `ci` / `perf` / `style` / `revert`）。
- **論理的に独立した修正は都度・適切な粒度でコミットする**。行数で機械的に割らない。
- `flake.nix` は `schema/`・`scripts/`・`hooks/`・`skills/` を参照するため、それらを先行
  コミットして各コミットが自己整合（bisect 可能）になる順序を保つ。

## 開発環境

direnv 経由で `dev/flake.nix` を読み込む。

```sh
cp example.envrc .envrc && direnv allow
```

## 参考

- [agentskills.io specification](https://agentskills.io/specification)
- [Claude Code Plugins reference](https://code.claude.com/docs/en/plugins-reference)
- [AGENTS.md / CLAUDE.md の symlink 運用](https://zenn.dev/explaza/articles/33f1dd2003c981)
