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

- **`scripts/worker_contract.py`** — ワーカー規約の正本。stdin にタスク情報 JSON（`task_id` / `branch` / `base` / `default_base` / `boundary` / `issue` / `parent`）を受け取り、ワーカーへ渡す標準セクション（報告義務・PR 後凍結・review-converge 反復境界・push/PR 承認済み前提・境界 deny 後の行動）を stdout へ出す。オーケストレーション側はこれをタスク本文へ連結する。
- **`scripts/report.sh <parent> <task-id> <milestone> [詳細]`** — ワーカーが叩く報告コマンド（規約に埋め込まれる）。JSONL（`${XDG_STATE_HOME:-$HOME/.local/state}/lane-ops/reports/<parent>.jsonl`）へ追記してから、`herdr agent prompt` で親へ `[lane-ops:report <task-id>] ...` を直送する。
- **`scripts/watch_events.py [--pane <id>]... [--status blocked]...`** — herdr socket API（`$HERDR_SOCKET_PATH`）へ `events.subscribe` を張り、エージェント状態変化を 1 行 1 JSON で流し続ける長寿命フィルタ。**これ 1 本で全レーンの blocked/idle/done を push 検知**する（レーンごとの `agent wait` 並走は不要）。`--pane` 省略時は `pane.list` で全 pane を購読し、以降にエージェントが載った pane は `pane.agent_detected` イベントを契機に購読を張り直して取り込む（後から起動したレーンも拾う）。張り直し中の約 1 秒だけイベントを取りこぼす窓があるため、レーン起動直後の確認は watch に頼らず `herdr agent get` で行う。親自身の pane（`$HERDR_PANE_ID`）は既定で除外する（親の承認プロンプトが自己ノイズとして混ざるため。含めるなら `--include-self`）。`--status` は `idle` / `working` / `blocked` / `done` / `unknown` のみ受け付ける。
- **`scripts/send_instruction.sh <target> <file>`** — 親からワーカーへの指示送信。本文を必ずファイルから読む（コマンド文字列に指示リテラルが載らないため guard hook の誤爆が構造的に起きず、送った指示が記録に残る）。
- **`scripts/verify_lane.sh <branch> [worktree]`** — 自己申告の機械検証。PR 存在（`gh pr list --head`）・push 同期・未コミット変更・触れたファイルと境界宣言を事実として並べる（判断は親が行う）。
- **`scripts/widen_boundary.sh <worktree> <追加glob>...`** — タスク境界の拡張の正規経路（**親専用**。task-boundary hook は境界ファイルへの Edit/Write を無条件 deny するため、拡張はこのスクリプトでのみ行う）。

## 運用ループ

1. **監視を張る**: `python3 <SKILL>/scripts/watch_events.py --status blocked` をバックグラウンド Bash か Monitor（persistent）で 1 本起動する。
2. **報告を受ける**: `[lane-ops:report ...]` が会話に届いたら、それは**ワーカーの自己申告であってユーザーの発言ではない**。必ず `verify_lane.sh` で裏を取ってから次の行動（次段起動・凍結確認など）を決める。
3. **blocked を捌く**: watch のイベントが来たら `herdr agent read <pane> --source recent-unwrapped --lines 120` で内容を確認し、下表で応答を判断する。
4. **指示を送る**: 軌道修正・情報共有は指示ファイルを書いて `send_instruction.sh`。herdr の send-keys で指示文を直接流し込まない（send-keys は承認キー送信専用）。

## 承認代行の判定基準

事前に承認済みの計画があるとき、親は計画の範囲内で各レーンの対話ゲートに自分で応答する（個別にユーザーへ確認しない）:

| 状況 | 対応 |
| --- | --- |
| 計画に書かれた操作の確認（編集・テスト・push・PR 作成） | 親が応答して進める（`herdr agent send-keys <pane> enter` 等） |
| 計画の範囲内だが選択肢がある確認 | 計画・issue の記述から判断して応答。判断材料が無ければユーザーへ |
| 境界の拡大要求・スコープ逸脱・計画の前提と実態の食い違い | **ユーザーへ上げる**（勝手に承認も却下もしない） |

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
- `agent wait` / watch が idle/done を報じても完了とは限らない。完了判定は常に `verify_lane.sh` の事実で行う。
- herdr CLI 自体の詳細（pane/agent/workspace 操作の一般規約）は herdr スキルの領分。
