---
name: project-session
description: "ghq 管理下のプロジェクトを 1 つ選び、そのディレクトリでブランチを変えずに claude を detached tmux セッションとして起動する。`/project-session` の明示実行専用。"
user-invocable: true
disable-model-invocation: true
argument-hint: "[プロジェクト名(部分一致可)] [claudeへ渡す引数...]"
allowed-tools: Bash, Read, AskUserQuestion
---

# project-session

ghq 管理下のプロジェクトを 1 つ選び、そのディレクトリで（**ブランチを変えず・worktree も作らず**）
claude を **detached tmux セッション**として起動する単発オーケストレーション。tmux セッション起動という
外部影響を伴うため、`disable-model-invocation: true` とし `/project-session` の明示実行時のみ動作する
（明示実行＝起動意図とみなし、追加の承認ゲートは挟まない）。

worktree を切って複数セッションを並列・stacked に回す `/parallel-worktree` と対をなす**単発・非 worktree 版**:
現在のブランチのまま 1 つの claude を立てるだけ。

## 起動引数

`/project-session [プロジェクト名(部分一致可)] [claudeへ渡す引数...]`

- **先頭 1 トークン**: プロジェクト指定（ghq list への部分一致キー。省略可）。
- **残り全部**: claude への passthrough 引数（`--model opus` / `-p '...'` / `--remote-control` 等、素通し）。

## 決定論ツール（scripts/launch.sh）

ghq 照合・セッション名決定・tmux 起動は `bash <SKILL>/scripts/launch.sh` に委譲する
（`<SKILL>` はプラグイン実行時 `${CLAUDE_PLUGIN_ROOT}/project-session`、個人 skill 配置時は
この SKILL.md があるディレクトリ）。3 サブコマンドと exit code 契約:

- **`launch.sh list`** — `ghq list` をそのまま 1 行 1 件で出力（引数省略時の一覧提示用）。
- **`launch.sh resolve <query>`** — 部分一致解決の結果で分岐:
  - 一意: stdout に relpath 1 行、**exit 0**
  - 複数: stdout に候補一覧、stderr に `ambiguous`、**exit 2**
  - 0 件: stdout に全一覧、stderr に `not found`、**exit 3**
- **`launch.sh launch <query> [claude引数...]`** — 本体。ツール欠落は exit 1、解決が一意でなければ
  `resolve` と同じ出力・exit code（2/3）で中断する。成功時は起動して次を stdout へ出力する:

  ```
  SESSION: nput
  PROJECT: github.com/yasunori0418/nput
  PATH: /home/yasunori/src/github.com/yasunori0418/nput
  BRANCH: main
  DIRTY: clean | N files
  CLAUDE_ARGS: (無し | 実際に渡した引数列)
  ATTACH: tmux attach -t nput
  ```

## フロー

1. **引数省略**（プロジェクト未指定）→ `launch.sh list` を実行し、番号付き一覧を提示して選択させる。
   AskUserQuestion は選択肢 4 個上限なので、候補が多いときは本文に番号付きで列挙し自由記述で受ける。
   選ばれた relpath（または basename）を query にして次へ。
2. **指定あり** → いきなり `launch.sh launch <query> [claude引数...]` を実行:
   - **exit 0**: 起動成功。出力の SESSION/PROJECT/PATH/BRANCH/DIRTY/ATTACH を整形して報告する。
     `DIRTY: N files` でも**止めない**（未コミット変更は情報提供のみ）。
   - **exit 2（曖昧）**: stdout の候補一覧を提示して選択させ、選んだ relpath で `launch` を再実行する。
   - **exit 3（0 件）**: stdout の全一覧を提示して選び直させる。
   - **exit 1**: `tmux`/`ghq`/`claude` 欠落など。stderr のメッセージをそのまま伝える。
3. 起動後は `ATTACH:` 行（`tmux attach -t <sess>`）を添えて結果を報告する。

## 挙動の要点（ユーザー説明用。規則の正はスクリプト。ここで再現しない）

- **セッション名**: repo 名を sanitize（`[^A-Za-z0-9_-]+`→`-`、前後 `-` 除去。例 `arto.vim`→`arto-vim`）。
  ghq list 内で repo 名（basename）が重複する場合のみ `owner-repo`（例 `NixOS-nixpkgs`）。
- **同名 tmux セッション**: 使用中なら `<base>-2`, `<base>-3`… の最初の空き番号を suffix する。
- **`--remote-control` 補完**: 値なしの `--remote-control`（末尾、または直後が `-` 始まり）のときだけ、
  実セッション名（suffix 込み）を値として自動注入する。ユーザーが値を書いた場合は触らない（最初の 1 個のみ）。
- **事前チェック**: `tmux`/`ghq`/`claude` の欠落のみ中断。現在ブランチ・dirty は報告するだけで止めない。

## 連携スキル

- `parallel-worktree`: worktree を分けて複数セッションを並列・stacked に回したいときはこちら（本スキルは単発版）。
