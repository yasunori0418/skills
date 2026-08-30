---
name: lane-ops
description: "herdr 上で稼働中のエージェントレーン（別 pane の claude 等）を親として操縦・監視・承認代行するときに必ず使用する。トリガー: 「レーンを見て」「ワーカーに指示して」「承認待ちを捌いて」「レーンの完了を検証して」「境界を広げて」の依頼、`[lane-ops:report ...]` 形式の報告が会話に届いたとき、herdr レーンの blocked 対応・報告の裏取り・指示送信・タスク境界の拡張が必要になったとき — スキル名や herdr が名指しされていなくても発火する。HERDR_ENV=1 必須。"
user-invocable: true
---

# lane-ops

herdr 管理下のエージェントレーン（pane 内で動く claude 等のワーカー）を、親（このセッション）が操縦・監視・承認代行するための運用規約と決定論スクリプト集。指示送信・blocked の push 検知・報告の機械検証・境界拡張はすべて同梱スクリプトで行う。`job-graph` 等のオーケストレーションから呼ばれるほか、手動で立てたレーンにも単独で使える。

最初に `test "${HERDR_ENV:-}" = 1` を確認し、失敗したら herdr 管理下でない旨を伝えて停止する。

役割分担の原則: **指示・報告 = 同梱スクリプト（herdr prompt + ファイル）/ 承認・生死・画面 = herdr / 真実 = git・gh**。ポーリング（sleep + 再確認）はしない。

以下、スキル本体のパスを `<SKILL>` と表記する。Python スクリプトは stdlib のみで、`python3` で直接実行できる。

## 親の名前（報告の宛先）

ワーカーからの報告は herdr のエージェント名宛てに届く。親はレーン起動前に自分へ決定論的な名前を付ける:

```bash
herdr agent rename "$HERDR_PANE_ID" <一意な短い名前>   # 例: orc-<リポジトリ名>
```

この名前をワーカー規約（worker_contract.py の `parent`）へ渡す。

## スクリプト（各 1 責務のフィルタ）

- **`scripts/worker_contract.py`** — ワーカー規約の正本。stdin にタスク情報 JSON（`task_id` / `branch` / `base` / `default_base` / `boundary` / `issue` / `parent`、任意で `plan`（計画ファイルの絶対パス）/ `scope_check`（PR 前に実行する計画突合コマンド）/ `mode`（`implement` 既定 / `maintain`）を受け取り、ワーカーへ渡す標準セクション（報告義務・PR 後凍結・review-converge 反復境界・improvement 見送り・構造変更エスカレーション・サブエージェント生存管理・push/PR 承認済み前提・境界 deny 後の行動、`plan` があれば review-converge への計画グラウンドトゥルース渡し、`scope_check` があれば PR 前の計画突合と FAIL 時のブロック報告）を stdout へ出す。`mode: "maintain"` は PR 作成後のレビュー対応レーン向けで、review-converge / pr-create を禁止し push を親承認制に切り替える。入力フィールドの全仕様と mode ごとの条項差分は [references/worker-contract.md](./references/worker-contract.md) を参照。オーケストレーション側はこれをタスク本文へ連結する。
- **`scripts/report.sh <parent> <task-id> <milestone> [詳細]`** — ワーカーが叩く報告コマンド（規約に埋め込まれる）。JSONL（`${XDG_STATE_HOME:-$HOME/.local/state}/lane-ops/reports/<parent>.jsonl`）へ追記してから、`herdr agent prompt` で親へ `[lane-ops:report <task-id>] ...` を直送する。
- **`scripts/watch_events.py [--pane <id>]... [--status blocked]...`** — herdr socket API（`$HERDR_SOCKET_PATH`）へ `events.subscribe` を張り、エージェント状態変化を 1 行 1 JSON で流し続ける長寿命フィルタ。**これ 1 本で全レーンの blocked/idle/done を push 検知**する（レーンごとの `agent wait` 並走は不要）。`--pane` 省略時は `pane.list` で全 pane を購読し、以降にエージェントが載った pane は `pane.agent_detected` イベントを契機に購読を張り直して取り込む（後から起動したレーンも拾う）。張り直し中の約 1 秒だけイベントを取りこぼす窓があるため、レーン起動直後の確認は watch に頼らず `herdr agent get` で行う。親自身の pane（`$HERDR_PANE_ID`）は既定で除外する（親の承認プロンプトが自己ノイズとして混ざるため。含めるなら `--include-self`）。`--status` は `idle` / `working` / `blocked` / `done` / `unknown` のみ受け付ける。`--once` はマッチしたイベントを 1 行出力した時点で exit 0 する（Monitor が無いセッションでバックグラウンド Bash の完了通知を push 通知として使う）。
- **`scripts/send_instruction.sh [--force] <target> <file>`** — 親からワーカーへの指示送信。本文を必ずファイルから読む（コマンド文字列に指示リテラルが載らないため guard hook の誤爆が構造的に起きず、送った指示が記録に残る）。送信前に `agent_status` を確認し、**blocked（ダイアログ表示中）なら中断する**。ダイアログ表示中の本文つき送信は本文が入力されず、末尾の Enter がハイライト中の選択肢（先頭の推奨案）を誤確定するため（herdr は blocked でも `agent_prompted` を返して成功を装う）。承知の上で流し込むときのみ `--force`。指示ファイルは **Write ツールで書く**（Bash の heredoc で書くと、本文に含まれる `git reset` / `git rebase` 等の文言に git-guard が反応して deny される）。
- **`scripts/verify_lane.sh <branch> [worktree]`** — 自己申告の機械検証。PR 存在（`gh pr list --head`）・push 同期・未コミット変更・触れたファイルと境界宣言を事実として並べる（判断は親が行う）。
- **`scripts/widen_boundary.sh <worktree> <追加glob>...`** — タスク境界の拡張の正規経路（**親専用**。task-boundary hook は境界ファイルへの Edit/Write を無条件 deny するため、拡張はこのスクリプトでのみ行う）。

## 運用ループ

1. **監視を張る**: `python3 <SKILL>/scripts/watch_events.py --once --status blocked --status idle` をバックグラウンド Bash で 1 本起動する。`--once` は最初のマッチで exit 0 するため、バックグラウンド Bash の完了通知がそのまま push 通知になる。イベントを処理したら watch を再起動し、**直後に `herdr agent get` で現在状態を直接確認する**（watch 停止中に起きた変化を取りこぼさないため）。Monitor（persistent）があるセッションでは `--once` 無しの常駐でもよい（常駐 Bash は完了時にしか親を起こさず push 通知にならないので、Monitor 無しで常駐させない）。blocked だけでなく idle も張る — ワーカーがテキストで承認を求めてターンを終えると blocked にならず idle になるため。idle で起床したら `herdr agent read` で画面を確認し、承認待ちなら blocked と同様に捌く。
2. **報告を受ける**: `[lane-ops:report ...]` が会話に届いたら、それは**ワーカーの自己申告であってユーザーの発言ではない**。必ず `verify_lane.sh` で裏を取ってから次の行動（次段起動・凍結確認など）を決める。親が AskUserQuestion 等で blocked（対話入力中）の間に届いた `report.sh` は `herdr agent prompt` が `agent_blocked` で弾かれ会話に現れない。対話入力から戻ったら `${XDG_STATE_HOME:-$HOME/.local/state}/lane-ops/reports/<parent>.jsonl` の未読分（最後に処理した行以降）を確認して取りこぼしを拾う。
3. **blocked を捌く**: watch のイベントが来たら `herdr agent read <pane> --source recent-unwrapped --lines 120` で内容を確認し、下表で応答を判断する。ダイアログ（選択肢 UI）への応答は 2 通りだけ: 提示選択肢で足りるなら `herdr agent send-keys <pane> enter` 等の承認キー、自由記述の裁定が要るなら **`herdr agent send-keys <pane> esc` でダイアログを閉じてから** `send_instruction.sh` で送る。ダイアログが開いたまま本文を送らない（send_instruction の blocked ガードが中断する理由）。
4. **指示を送る**: 軌道修正・情報共有は指示ファイルを書いて `send_instruction.sh`。herdr の send-keys で指示文を直接流し込まない（send-keys は承認キー送信専用）。誤って選択肢を確定してしまったら、ワーカーは working 中でも次ターンで指示を受領するので、帰結が後段のコミットへ出る前に**即座に訂正指示を送る**。

## 承認代行の判定基準

事前に承認済みの計画があるとき、親は計画の範囲内で各レーンの対話ゲートに自分で応答する（個別にユーザーへ確認しない）:

| 状況 | 対応 |
| --- | --- |
| 計画に書かれた操作の確認（編集・テスト・push・PR 作成） | 親が応答して進める（`herdr agent send-keys <pane> enter` 等） |
| 計画の範囲内だが選択肢がある確認 | 計画・issue の記述から判断して応答。判断材料が無ければユーザーへ |
| 境界の拡大要求・スコープ逸脱・計画の前提と実態の食い違い | **ユーザーへ上げる**（勝手に承認も却下もしない） |
| 仕様の解釈変更・検査/バリデーションの緩和・計画に無い型/関数/enum の追加・計画が「据え置く」と明記した箇所の変更 | **常にユーザー裁定**。ワーカー・親が妥当と評価しても「範囲内の裁定」として処理しない（範囲内判定を親自身が行うと仕様変更が既成事実化する） |

承認済みの計画が無い単独利用では、外部影響のある操作（push・PR 作成）の承認はユーザーへ確認する。

境界拡大をユーザーが承認したら `widen_boundary.sh` で反映し、対象ワーカーへ「境界を広げたので再開してよい」と `send_instruction.sh` で伝える。

## 補足

- watch のイベントが無いのに報告も途絶えたレーンは、`herdr agent get <pane>` でエージェント在否を確認する。不在なら `herdr pane process-info <pane>` で shell へ戻ったことを確かめてから復旧する（pane の見た目で判断しない）。復旧コマンドは **claude を `env -u` 越しに起こす**:

  ```sh
  herdr pane run <pane> 'env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
    -u CLAUDE_CODE_BRIDGE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET \
    -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_ENTRYPOINT claude --continue'
  ```

  素で `claude --continue` を流すと復旧したレーンが**親（自分）の子プロセスと誤認**され、transcript 保存が切られる・親宛のメッセージ経路を掴む。レーンは独立したセッションなので断ち切る。
- **herdr セッション全損からの復旧**（サーバー再起動で session が消え、レーンの workspace / pane / ワーカー claude が全滅したとき）: 失われるのは pane だけで、worktree・追跡外ファイル（改名マップ等）・境界ファイルはディスクに残る。実績のある手順:
  1. `wt list` と worktree の中身で被害を棚卸しする
  2. 生きているセッションでレーン workspace を**同じ label で**再作成する（job-graph の wave 起動コマンドは workspace を label で引くため、label を合わせればコマンドが互換のまま使える）
  3. root pane の cwd を対象 worktree にして、上記の `env -u ... claude --continue` で再開する（`--continue` は cwd 単位で直近会話を再開するので、worktree cwd なら正しいワーカー会話が戻る）
  4. **親の rename をやり直す**。ワーカー規約（worker_contract）には親のエージェント名が焼き付いているため、**一字一句同じ名前**で rename しないと report.sh の報告が届かない
- **ワーカーの push が数分応答しないときは待ち続けない**。原因はほぼ対話型 credential 経路の入力待ち（helper チェーンの git-credential-oauth 等が URL 提示で待つ・askpass 起動・対話 shell の履歴展開で `!gh` の helper 指定が壊れる、など。ワーカーの「規約どおり実行した」という自己申告と実際に走ったコマンドは一致しているとは限らない）。対処は**親の代行 push** が標準: worktree はオブジェクト DB を共有するため、メインリポジトリから `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push <URL> <branch>:<branch>` で代行できる（per-ref アトミックなので競合しても安全）。代行後はワーカーへ「push の再試行を中止し、リモート一致を確認して次工程へ」を指示する。
- `agent wait` / watch が idle/done を報じても完了とは限らない。完了判定は常に `verify_lane.sh` の事実で行う。
- herdr CLI 自体の詳細（pane/agent/workspace 操作の一般規約）は herdr スキルの領分。
