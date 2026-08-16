# 挙動の要点（ユーザー説明用）

`launch.sh` が内部で何をしているかの解説。**規則の正はスクリプトであり、ここを読んで挙動を再現しない。**
ユーザーから「セッション名はどう決まるのか」「なぜ session が消えないのか」等を問われたときに参照する。

- **セッション名**: repo 名を sanitize（`[^A-Za-z0-9_-]+`→`-`、前後 `-` 除去。例 `foo.vim`→`foo-vim`）。
  ghq list 内で repo 名（basename）が重複する場合のみ `owner-repo`。
  パス指定のときは ghq の重複規則が効かないので **basename 一択**。
- **パス指定**: `/...` `~...` `./...` `../...` は ghq 解決を飛ばし、そのディレクトリを直接使う
  （`ghq` コマンド自体も要求しない）。存在しなければ exit 1 で中断する。先頭の `~` のみ `$HOME` へ
  展開し、`~otheruser/...` は展開規則を持たないので ghq キー扱いにする。
- **同名セッション**: 使用中なら `<base>-2`, `<base>-3`… の最初の空き番号を suffix する。
  既存名は backend と topology から引く（tmux はセッション名、herdr は topology=workspace なら
  現在 session の workspace ラベル、topology=session なら herdr の session 名（**停止中も含む**。
  同名 session を作ると既存の状態に相乗りしてしまうため））。
- **`--remote-control` 補完**: 値なしの `--remote-control`（末尾、または直後が `-` 始まり）のときだけ、
  実セッション名（suffix 込み）を値として自動注入する。ユーザーが値を書いた場合は触らない（最初の 1 個のみ）。
- **親セッションのマーカー除去**: 起動する claude は独立したセッションなので、`env -u` で親セッション
  固有の環境変数を断ち切ってから exec する（放置すると親の子と誤認され transcript 保存が切られる）。
  対象は `launch.sh` の `inherited_session_vars` が正。
  断ち切る先は claude の起動コマンドだけではない。multiplexer の **server**（`herdr --session <name> server` /
  tmux の暗黙起動）は自分の environ を配下の**全 pane の shell へ継承させる**ため、server を起こす
  呼び出しも `env_unset_prefix` 越しにする。これを怠ると root pane の claude は無事でも、ユーザーが
  後から同 session に開いた tab/pane で claude を立てたとき
  `⚠ Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker` が出る。
  逆に pane の環境を決めるのは server の environ **だけ**で、CLI クライアント側の環境は伝播しない
  （実測で確認済み）。既存 server へ繋ぐだけの `workspace create` / `pane run` に `env -u` は付けない。
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
- **topology=session の後始末**: 使い終わったら `herdr --session <名前> server stop` →
  `herdr session delete <名前>`。停止中の session 名も衝突判定に含まれるため、消さないと
  次回同名で立てたとき suffix が付く。
