---
name: agent-teams
description: Claude Code の並列エージェント(agent teams・teammate)の後始末と無応答時の打ち切りルール。`name` を付けて Agent を起動するとき、TeamCreate でチームを組むとき、teammate から `idle_notification` が届いたとき、評価ループ等で次のイテレーションのエージェントを起動する前、エージェントの返信が届かないときに参照する。`name` を付けない通常のサブエージェント起動だけなら対象外。
---

# agent teams 運用ルール

## 使い終わった teammate は明示的に停止する

`idle_notification`(`idleReason: "available"`)は「作業が終了した」ではなく「空いて待機中」の意味で、放置すると teammate が滞留し続ける。

- 成果物を回収し、その teammate への追加依頼が無いと判断した時点で `TaskStop` を呼ぶ
- 反復作業(評価ループ等)で次のイテレーションのエージェントを起動する前に、`TaskList` で前イテレーションの残留を棚卸しし、停止済みにしてから起動する
- 応答終了時の取りこぼしは teammate-leak-guard hook が `decision: block` で差し戻すが、hook はターン終端でしか発火しない。ターン内での棚卸しはこのルールで担保する

## 返信が来ないときの再送は 1 回まで

`idle_notification` だけが届いて成果物本体が来ない状態は、返信経路の障害とみなす。

- 1 回再送しても届かなければ `TaskStop` で打ち切る
- 自分で代替検証できるなら実施し、できないならその旨をユーザーへ報告して指示を仰ぐ
- 応答を待ち続けるポーリングはしない
