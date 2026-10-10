---
name: project-session
description: "指定したプロジェクト（ghq 管理下の部分一致キー、または直接パス）のディレクトリでブランチを変えずに claude を detached セッション（herdr 管理下なら workspace か専用 session、それ以外は tmux）として起動する。`/project-session` の明示実行専用。"
user-invocable: true
disable-model-invocation: true
argument-hint: "[--session] [プロジェクト名(部分一致可)|パス] [claudeへ渡す引数...]"
allowed-tools: Bash, Read, AskUserQuestion
---

# project-session

指定されたプロジェクトのディレクトリで（**ブランチを変えず・worktree も作らず**）claude を
**detached セッション**として起動する。呼び出し＝起動意図とみなし、追加の承認ゲートは挟まない。
ただし**対象プロジェクトが未指定なら一覧から選ばせる**。これは承認ゲートではなく起動対象を
確定させる必須手順で、省くことはできない（後述のフロー exit 4）。

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
| `session` | `--session` | プロジェクト専用の herdr session を detached で立て、その中に workspace を作る | 起動した claude を親に、**そのプロジェクトの作業を 1 セッション内で完結**させたいとき |

環境変数 `PROJECT_SESSION_TOPOLOGY` でも指定できるが（フラグが優先）、remote-control 越しでは
環境変数を前置できないため**通常はフラグを使う**。

`session` を選ぶ理由は隔離ではなく**到達性**にある。herdr のソケットは session ごとに分かれるため、
起動した claude が他の pane を監視・操縦するには、その claude と対象が同じ session に居る必要がある。
プロジェクト専用 session の中で立てれば、その claude を親とする一連の作業がその session 内で閉じる。

## 起動引数

`/project-session [--session] [プロジェクト名(部分一致可)] [claudeへ渡す引数...]`

- **`--session`**（任意・**先頭に置く**）: プロジェクト専用の herdr session を立てて起動する
  （topology=session）。省略時は現在の session に workspace を足す。
- **次の 1 トークン**: プロジェクト指定（省略可）。既定は **ghq list への部分一致キー**だが、
  `/...` `~...` `./...` `../...` の形なら **ghq 解決を飛ばしてそのディレクトリを直接使う**
  （ghq 管理外のリポジトリ用）。裸の名前は常に ghq キー扱いで、
  カレント配下に同名ディレクトリがあっても掴まない。
- **残り全部**: claude への passthrough 引数（`--model opus` / `-p '...'` / `--remote-control` 等、素通し）。

**省略の判定は AI が行わない**。ARGUMENTS をそのまま `launch.sh launch` に渡し、`launch.sh` が
「`--session` を除いた先頭トークンが無い、または `-` 始まり」を省略と判定して exit 4 で一覧を返す。
`ARGUMENTS: --remote-control nput` のように passthrough 引数だけが渡されたケースは**省略**であり
（`--remote-control` は claude のフラグ、`nput` はその値）、`nput` をプロジェクト名として拾わない。

例:

```
/project-session --session <プロジェクト名> --remote-control
```

そのプロジェクト専用の herdr session を立て、中の claude を `--remote-control <セッション名>` 付きで起動する
（値なしの `--remote-control` にはセッション名が自動で入る）。

```
/project-session ~/<ディレクトリ名> --remote-control
```

ghq 管理外のディレクトリを直接指定して起動する（セッション名は basename から作る）。

```
/project-session --remote-control nput        # プロジェクト未指定（exit 4 → 一覧提示）
/project-session nput --remote-control        # nput を起動（正しい書き順）
```

## 決定論ツール（scripts/launch.sh）

ghq 照合・セッション名決定・backend 判定・セッション起動は `bash <SKILL>/scripts/launch.sh` に委譲する
（`<SKILL>` はプラグイン実行時 `${CLAUDE_PLUGIN_ROOT}/project-session`、個人 skill 配置時は
この SKILL.md があるディレクトリ）。3 サブコマンドと exit code 契約:

- **`launch.sh list`** — `ghq list` をそのまま 1 行 1 件で出力（「一覧を見せて」と明示されたとき用。
  引数省略時の一覧は `launch` 自身が exit 4 で返すので、省略判定のために先に叩かない）。
- **`launch.sh resolve [query]`** — 部分一致解決の結果で分岐:
  - 省略（無し / `-` 始まり）: stdout に全一覧、stderr に `no query`、**exit 4**
  - 一意: stdout に relpath 1 行、**exit 0**
  - 複数: stdout に候補一覧、stderr に `ambiguous`、**exit 2**
  - 0 件: stdout に全一覧、stderr に `not found`、**exit 3**
  - **パス指定**（`/...` `~...` `./...` `../...`）は ghq を引かず、存在すれば絶対パス 1 行で **exit 0**、
    存在しなければ stderr にエラーで **exit 3**
- **`launch.sh launch [--session] [query] [claude引数...]`** — 本体。`--session` は `<query>` より前に
  置いたときだけ topology フラグとして解釈し、それ以降は claude への passthrough として素通しする。
  `<query>` 省略（フラグを除いた先頭が無い / `-` 始まり）は stdout に全一覧・stderr に `no query` で
  **exit 4**（passthrough に `--remote-control <値>` があり、その値が ghq に一意一致するなら
  stderr に書き順のヒントも 1 行出る）。ツール欠落は exit 1、解決が一意でなければ
  `resolve` と同じ出力・exit code（2/3）で中断する。成功時は起動して次を stdout へ出力する:

  ```
  SESSION: <セッション名>
  BACKEND: herdr | tmux
  TOPOLOGY: workspace | session   （herdr backend のときだけ出る）
  PROJECT: <ghq relpath | 絶対パス>
  PATH: <起動ディレクトリの絶対パス>
  BRANCH: <現在ブランチ | (detached)>
  DIRTY: clean | N files
  CLAUDE_ARGS: (無し | 実際に渡した引数列)
  ATTACH: tmux attach -t <名前> | herdr（workspace ラベル: <名前>）に切り替える | herdr session attach <名前>
  ```

## フロー

1. **ARGUMENTS をそのまま `launch.sh launch [--session] [query] [claude引数...]` に渡す**。
   省略か指定かを読解しない。ユーザーが `--session` を付けていたら**そのまま `<query>` の前へ引き渡す**
   （claude 引数側へ回さない）。ARGUMENTS が空でも `launch.sh launch` を引数無しで実行する。
2. exit code で分岐する:
   - **exit 0**: 起動成功。出力の SESSION/BACKEND/PROJECT/PATH/BRANCH/DIRTY/ATTACH を整形して報告する。
     `DIRTY: N files` でも**止めない**（未コミット変更は情報提供のみ）。
   - **exit 4（プロジェクト未指定）**: stdout の全一覧を**番号付きで提示して選択させる**。
     AskUserQuestion は選択肢 4 個上限なので、候補が多いときは本文に番号付きで列挙し自由記述で受ける。
     stderr に `hint:` 行があればそのまま添える（書き順の取り違えの可能性をユーザーに知らせる）。
     選ばれた relpath（または basename）を query にし、元の `--session` と passthrough 引数を
     そのまま保って `launch` を再実行する。ghq 管理外のディレクトリを開きたいと言われたら、一覧から選ばせず
     **そのパスをそのまま query にする**。
   - **exit 2（曖昧）**: stdout の候補一覧を提示して選択させ、選んだ relpath で `launch` を再実行する。
   - **exit 3（0 件）**: stdout の全一覧を提示して選び直させる。ユーザーが挙げた名前が ghq 管理外の
     ディレクトリを指していそうなら、一覧から選ばせる前に**パス指定（`~/<名前>` 等）を提案する**。
   - **exit 1**: backend に必要なコマンド（`herdr` または `tmux`／`ghq`／`claude`）の欠落など。
     stderr のメッセージをそのまま伝える。
3. **query の出所はユーザーのトークンか、一覧からのユーザーの選択だけ**。exit 4 / 2 / 3 で候補を
   提示する局面では、次を query にして `launch` し直すことを禁止する:
   - カレントディレクトリ（「今いるのが dotfiles だから dotfiles」）
   - 会話の文脈（「直前に skills の話をしていたから skills」）
   - `--remote-control` など passthrough 引数の値（`--remote-control nput` の `nput`）
   「確認を挟まず起動」は対象が確定しているときだけ許され、未確定なら一覧提示は省けない。
4. 起動後は `ATTACH:` 行を添えて結果を報告する。`TOPOLOGY: session` のときは、合流が
   `herdr session attach <名前>` である点と、**使い終わったら後始末が要る**点も併せて伝える
   （手順は `references/behavior.md`）。

## 参照

- `references/behavior.md`: セッション名の決定規則・backend 別の起動手順など、`launch.sh` の挙動解説
  （**フローの実行には不要**。ユーザーから挙動を問われたときだけ読む）。
