# タスク境界の宣言 — 生成方式と deny 後のフロー

タスク境界は、レーンのワーカーが当初タスクの範囲から逸脱してファイルを編集する**スコープドリフト**を止める仕組み。**指示と機械ブロックの二重化**で構成される:

| 層 | 担い手 | 効果 |
| --- | --- | --- |
| 指示 | lane-ops の `worker_contract.py` が生成するワーカー規約 | ワーカーが境界を自覚し、deny 後の正しい行動（親へ報告）を知る |
| 機械ブロック | `task-boundary` hook（併用推奨・別プラグイン） | 境界外への `Edit`/`Write`/`NotebookEdit` を PreToolUse で deny する |

両者は**境界ファイルという契約だけで結合**する（スキルと hook は互いを呼ばない）。hook が未 install でも指示層は機能する。

## 境界ファイル

worktree ルートの `.claude/task-boundary.json`（hook の公開契約書式）:

```json
{"task_id": "B2", "branch": "feat-client-retry", "allow": ["src/client/**", "tests/client/**", "tmp_claude/**"]}
```

- spec の task に `boundary` を書いた場合のみ生成される（未宣言の task では hook は沈黙し、従来動作のまま）
- `tmp_claude/**` は `plan_orchestration.py` が自動で追加する（PR 本文ドラフト等の一時出力先が境界外だと PR 作成フェーズで必ず deny に当たるため）
- herdr pane へ 1 コマンドで流し込むため 1 行 JSON で生成される（契約は構造であって整形ではない）

## 生成方式（`wt switch -x bash` の bootstrap 経由）

worktree のパスは `wt` の設定で決まり事前に確定できないため、`boundary` ありの task は起動コマンドが `-x claude` ではなく `-x bash` の bootstrap 経由になる。bootstrap は **worktree 生成後・claude 起動前**に境界ファイルを置き、`exec claude "$@"` へ繋ぐ。

- 境界ファイルは gitignored にする（`git rev-parse --git-path info/exclude` へ 1 行追記）。linked worktree からでも common dir へ正しく解決され、追跡ファイルを汚さず、冪等で、`wt remove` で worktree ごと消える
- bootstrap は `set -e` の **fail-closed**。境界の無い状態でガードレール無しに claude を起動するより、起動せず pane に失敗を残す方が安全（hook 側の fail-open とは役割が逆）

## deny 後のフロー（境界の拡張）

hook は境界ファイル自身への Edit/Write を**誰であっても**無条件 deny する（自己解錠の防止）。正当な拡張の正規経路は lane-ops の `widen_boundary.sh`（親専用）:

1. ワーカーが deny に当たる → 規約に従い `report.sh` で親へ「境界の不足」を報告して停止する（境界ファイルに触ろうとしない・回避策を探さない）
2. 親は報告の内容を計画と突き合わせる:
   - **計画の範囲内**（完了条件に必要なパスの宣言漏れ等）→ `bash <lane-ops>/scripts/widen_boundary.sh <worktree> <追加glob>...` で拡張し、`send_instruction.sh` で「境界を広げたので再開してよい」と伝える
   - **計画の範囲外**（スコープ逸脱）→ ユーザーへ上げる（勝手に承認も却下もしない）。別タスク・別 PR で扱うべき変更なら「見送り」として記録させる
3. コミット数が計画を超えたレーンは `verify_lane.sh` の CHANGED と BOUNDARY を突き合わせ、境界外変更が紛れていないか確認する（hook は Bash 経由の書き込みを止められない）
