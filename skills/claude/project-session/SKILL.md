---
name: project-session
description: "ghq 管理下のプロジェクトを 1 つ選び、そのディレクトリでブランチを変えずに claude を detached セッション（herdr 管理下なら新しい workspace、それ以外は tmux）として起動する。`/project-session` の明示実行専用。"
user-invocable: true
disable-model-invocation: true
argument-hint: "[プロジェクト名(部分一致可)] [claudeへ渡す引数...]"
allowed-tools: Bash, Read, AskUserQuestion
---

# project-session

ghq 管理下のプロジェクトを 1 つ選び、そのディレクトリで（**ブランチを変えず・worktree も作らず**）
claude を **detached セッション**として起動する単発オーケストレーション。セッション起動という
外部影響を伴うため、`disable-model-invocation: true` とし `/project-session` の明示実行時のみ動作する
（明示実行＝起動意図とみなし、追加の承認ゲートは挟まない）。

マルチプレクサ backend は実行環境から自動判定する（**AI が選ばない**。判定は `launch.sh` の責務）:

| backend | 条件 | 起動先 |
| --- | --- | --- |
| `herdr` | `HERDR_ENV=1`（herdr 管理下の pane から実行） | プロジェクト用の新しい workspace を作成し、その root pane で claude を起動 |
| `tmux` | それ以外 | detached な tmux セッション |

`PROJECT_SESSION_BACKEND` に `herdr` / `tmux` を設定すれば明示的に上書きもできる（通常は不要）。

herdr backend で**何を作るか**（topology）は起動引数の `--session` フラグで切り替える:

| topology | 指定方法 | 作るもの | 使いどころ |
| --- | --- | --- | --- |
| `workspace`（既定） | フラグ無し | 起動元 pane と同じ session に workspace を足す | 通常。別プロジェクトを開くだけ |
| `session` | `--session` | プロジェクト専用の herdr session を detached で立て、その中に workspace を作る | 起動した claude から `/job-graph` や lane-ops を回し、**そのプロジェクトの並列作業を 1 セッション内で完結**させたいとき |

環境変数 `PROJECT_SESSION_TOPOLOGY` でも指定できる（フラグが優先）。ただし remote-control 越しでは
環境変数を前置できないため、**通常はフラグを使う**。

`session` を選ぶ理由は隔離ではなく**到達性**にある。lane-ops は `$HERDR_SOCKET_PATH`
（＝自分が属する session のソケット）でレーンを監視するため、親も子も同じ session に居る必要がある。
プロジェクト専用 session の中で claude を立てれば、その claude が親となってレーンを張り、
監視・承認代行までその session 内で閉じる。

worktree を切って複数セッションを並列・stacked に回す `/parallel-worktree` と対をなす**単発・非 worktree 版**:
現在のブランチのまま 1 つの claude を立てるだけ。

## 起動引数

`/project-session [--session] [プロジェクト名(部分一致可)] [claudeへ渡す引数...]`

- **`--session`**（任意・**先頭に置く**）: プロジェクト専用の herdr session を立てて起動する
  （topology=session）。省略時は現在の session に workspace を足す。
- **次の 1 トークン**: プロジェクト指定（省略可）。既定は **ghq list への部分一致キー**だが、
  `/...` `~...` `./...` `../...` の形なら **ghq 解決を飛ばしてそのディレクトリを直接使う**
  （ghq 管理外のリポジトリ用。例 `~/dotfiles`）。裸の名前は常に ghq キー扱いで、
  カレント配下に同名ディレクトリがあっても掴まない。
- **残り全部**: claude への passthrough 引数（`--model opus` / `-p '...'` / `--remote-control` 等、素通し）。

`--session` は**プロジェクト名より前**にのみ置ける。それ以降は claude への passthrough 領域なので、
そこに書かれた `--session` は claude の引数としてそのまま渡す（抜き取らない）。

例:

```
/project-session --session nput --remote-control
```

nput 専用の herdr session を立て、その中の claude を `--remote-control nput` 付きで起動する。

```
/project-session ~/dotfiles --remote-control
```

ghq 管理外の `~/dotfiles` を直接指定して起動する（セッション名は basename の `dotfiles`）。

## 決定論ツール（scripts/launch.sh）

ghq 照合・セッション名決定・backend 判定・セッション起動は `bash <SKILL>/scripts/launch.sh` に委譲する
（`<SKILL>` はプラグイン実行時 `${CLAUDE_PLUGIN_ROOT}/project-session`、個人 skill 配置時は
この SKILL.md があるディレクトリ）。3 サブコマンドと exit code 契約:

- **`launch.sh list`** — `ghq list` をそのまま 1 行 1 件で出力（引数省略時の一覧提示用）。
- **`launch.sh resolve <query>`** — 部分一致解決の結果で分岐:
  - 一意: stdout に relpath 1 行、**exit 0**
  - 複数: stdout に候補一覧、stderr に `ambiguous`、**exit 2**
  - 0 件: stdout に全一覧、stderr に `not found`、**exit 3**
  - **パス指定**（`/...` `~...` `./...` `../...`）は ghq を引かず、存在すれば絶対パス 1 行で **exit 0**、
    存在しなければ stderr にエラーで **exit 3**
- **`launch.sh launch [--session] <query> [claude引数...]`** — 本体。`--session` は `<query>` より前に
  置いたときだけ topology フラグとして解釈し、それ以降は claude への passthrough として素通しする。
  ツール欠落は exit 1、`<query>` 欠落は usage を出して exit 1、解決が一意でなければ
  `resolve` と同じ出力・exit code（2/3）で中断する。成功時は起動して次を stdout へ出力する:

  ```
  SESSION: nput
  BACKEND: herdr | tmux
  TOPOLOGY: workspace | session   （herdr backend のときだけ出る）
  PROJECT: github.com/yasunori0418/nput
  PATH: /home/yasunori/src/github.com/yasunori0418/nput
  BRANCH: main
  DIRTY: clean | N files
  CLAUDE_ARGS: (無し | 実際に渡した引数列)
  ATTACH: tmux attach -t nput | herdr（workspace ラベル: nput）に切り替える | herdr session attach nput
  ```

## フロー

1. **引数省略**（プロジェクト未指定）→ `launch.sh list` を実行し、番号付き一覧を提示して選択させる。
   AskUserQuestion は選択肢 4 個上限なので、候補が多いときは本文に番号付きで列挙し自由記述で受ける。
   選ばれた relpath（または basename）を query にして次へ。ghq 管理外のディレクトリを開きたいと
   言われたら、一覧から選ばせず**パス（`~/dotfiles` 等）をそのまま query にする**。
2. **指定あり** → いきなり `launch.sh launch [--session] <query> [claude引数...]` を実行。
   ユーザーが `--session` を付けていたら**そのまま `<query>` の前へ引き渡す**（claude 引数側へ回さない）:
   - **exit 0**: 起動成功。出力の SESSION/BACKEND/PROJECT/PATH/BRANCH/DIRTY/ATTACH を整形して報告する。
     `DIRTY: N files` でも**止めない**（未コミット変更は情報提供のみ）。
   - **exit 2（曖昧）**: stdout の候補一覧を提示して選択させ、選んだ relpath で `launch` を再実行する。
   - **exit 3（0 件）**: stdout の全一覧を提示して選び直させる。ユーザーが挙げた名前が ghq 管理外の
     ディレクトリを指していそうなら、一覧から選ばせる前に**パス指定（`~/<名前>` 等）を提案する**。
   - **exit 1**: backend に必要なコマンド（`herdr` または `tmux`／`ghq`／`claude`）の欠落など。
     stderr のメッセージをそのまま伝える。
3. 起動後は `ATTACH:` 行を添えて結果を報告する。`TOPOLOGY: session` のときは、合流が
   `herdr session attach <名前>` である点と、**使い終わったら後始末が要る**点も併せて伝える
   （`herdr --session <名前> server stop` → `herdr session delete <名前>`。停止中の session 名も
   衝突判定に含まれるため、消さないと次回同名で立てたとき suffix が付く）。

## 挙動の要点（ユーザー説明用。規則の正はスクリプト。ここで再現しない）

- **セッション名**: repo 名を sanitize（`[^A-Za-z0-9_-]+`→`-`、前後 `-` 除去。例 `arto.vim`→`arto-vim`）。
  ghq list 内で repo 名（basename）が重複する場合のみ `owner-repo`（例 `NixOS-nixpkgs`）。
  パス指定のときは ghq の重複規則が効かないので **basename 一択**（例 `~/dotfiles` → `dotfiles`）。
- **パス指定**: `/...` `~...` `./...` `../...` は ghq 解決を飛ばし、そのディレクトリを直接使う
  （`ghq` コマンド自体も要求しない）。存在しなければ exit 1 で中断する。先頭の `~` のみ `$HOME` へ
  展開し、`~otheruser/...` は展開規則を持たないので ghq キー扱いにする。
- **同名セッション**: 使用中なら `<base>-2`, `<base>-3`… の最初の空き番号を suffix する。
  既存名は backend と topology から引く（tmux はセッション名、herdr は topology=workspace なら
  現在 session の workspace ラベル、topology=session なら herdr の session 名（**停止中も含む**。
  同名 session を作ると既存の状態に相乗りしてしまうため））。
- **`--remote-control` 補完**: 値なしの `--remote-control`（末尾、または直後が `-` 始まり）のときだけ、
  実セッション名（suffix 込み）を値として自動注入する。ユーザーが値を書いた場合は触らない（最初の 1 個のみ）。
- **事前チェック**: backend に必要なコマンド（`herdr` または `tmux`）と `claude` の欠落のみ中断。
  `ghq` は ghq キー解決を使うときだけ必須（パス指定では要求しない）。
  現在ブランチ・dirty は報告するだけで止めない。
- **herdr backend（topology=workspace・既定）**: プロジェクトごとに新しい workspace を作る
  （workspace はリポジトリ単位の長寿命コンテナ）。`--no-focus` で起動するので画面は奪われない。
  herdr 呼び出しには常に `--session "${HERDR_SESSION:-default}"` を明示し、**起動元 pane と同じ session**
  に workspace を作る（CLI の env 依存な暗黙解決に任せると、env が失われた環境から呼んだとき
  既定 session へ流れ込む）。
- **herdr backend（topology=session）**: `herdr --session <名前> server` を detached で起動し、socket API が
  応答してから workspace を作る。socket API 自体に server を起こす力は無く（未起動なら
  `server_not_running`）、`herdr session attach` は TUI に入る対話コマンドなので、この 2 段構えを取る。
  起動した session はユーザーが attach するまで画面に現れないため、**現在の TUI は奪わない**。
  合流方法は `ATTACH:` 行がそのまま案内する（`herdr session attach <名前>`）。

## 連携スキル

- `parallel-worktree`: worktree を分けて複数セッションを並列・stacked に回したいときはこちら（本スキルは単発版）。
- `lane-ops`: herdr backend で起動した workspace を親から監視・操縦したいときはこちら（起動は本スキル、
  起動後の操縦・承認代行は lane-ops の領分）。
- `job-graph`: 起動した claude にプロジェクトの並列作業を任せるなら `PROJECT_SESSION_TOPOLOGY=session`
  で立てる。lane-ops / job-graph は自分が属する session のソケットで完結するため、親となる claude が
  そのプロジェクト専用 session の中に居る必要がある。
