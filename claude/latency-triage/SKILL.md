---
name: latency-triage
description: Claude Code 自体の応答遅延・長考・作業中断のトリアージ。「応答が遅い」「回答が返ってこない」「思考が長すぎる」「固まった」「反応がない」「作業が中断された」「タイムアウトで止まった」「opus(モデル)が重い」と報告されたとき、遅延・中断の再発防止策を求められたとき、長時間セッションで応答性の低下を指摘されたときに必ず参照する。thinking/effort 設定・コンテキスト肥大・Bash タイムアウト・API 障害の切り分け手順と、既知の根本原因を含む。
---

# Claude Code 応答遅延・中断のトリアージ

## このスキルの目的

ユーザーから「Claude Code が遅い・固まった・中断された」と報告されたとき、**サーバー障害と即断せず**、決定論的な測定で原因を切り分けて対処を提案する。

## 既知の根本原因(2026-07-12 の実測分析)

過去の全セッション分析で確定した事実。診断の事前確率として使う:

1. **「5〜10分応答なし」の最有力原因は拡張思考(extended thinking)の長時間化**。
   `alwaysThinkingEnabled: true` × `effortLevel: xhigh` × 巨大コンテキスト(peak 300k+)の組合せで、opus 系は**1回8〜10分の思考ブロック**を実測(例: セッション 3e3c06d8 で6回)。プロンプト送信→初回応答の gap 自体は 5分超がほぼゼロで、API は遅くない。
2. **サーバー障害はまれ**。transcript 上の Overloaded / 529 / 接続断は過去実績ゼロ。`isApiErrorMessage` の大半は「You've hit your limit」= 利用上限到達で、障害ではない。
3. **「ツール出力が壊れて中断」は長考後の生成破損**(`tool call could not be parsed` / `AskUserQuestion InputValidationError`)。同じ思考設定の問題に帰着する。
4. **Bash の Exit 143 は既定2分タイムアウト**による打ち切り。API とは無関係の別要因。
5. 推奨構成は **adaptive thinking(`alwaysThinkingEnabled: false`)× `effortLevel: xhigh`**。公式プロンプティングガイド(opus 4.8 / sonnet 5)の推奨と一致する。xhigh を下げる前に、まず thinking の発動頻度を疑う。

`effort` と `alwaysThinkingEnabled` は別の軸: effort = 思考・作業の**深さのダイヤル**(`output_config.effort`)、alwaysThinking = 思考の**発動頻度スイッチ**(毎ターン強制 or adaptive)。

## 診断フロー

### 1. 設定確認(最初にやる)

```bash
grep -nE '"alwaysThinkingEnabled"|"effortLevel"|"model"' ~/.claude/settings.json
```

- `alwaysThinkingEnabled: true` × `effortLevel: xhigh|max` なら、それが第一容疑。
- `~/.claude/settings.json` は dotfiles 実体への symlink(このマシンでは `~/dotfiles/home/.claude/settings.linux.json`)。編集提案は実体パスで示す。

### 2. 定量測定(同梱スクリプト)

生の JSONL を Read/Grep で漁らない。同梱の自己完結スクリプトで測る(依存は Python stdlib のみ、python3 直実行可):

```bash
python3 <skill-dir>/scripts/latency_probe.py --since <YYYY-MM-DD>
```

出力の読み方:

| 指標 | 意味 | 遅延の解釈 |
|---|---|---|
| turn_duration 分布 | ターン総時間(**離席・承認待ちを含む**) | 大きくても単独では遅延の証拠にならない |
| 実プロンプト→初回応答 gap | 承認待ちを挟まない応答開始まで | ここが5分超なら API/思考が本当に遅い |
| thinking 直前 gap | 思考ブロック1回の所要時間の近似 | 5分超が opus に偏っていれば thinking 設定起因 |
| isApiErrorMessage | API エラーレコード | 「limit」なら上限到達。500/529 なら障害 |

### 3. 個別セッションの深掘り

gap が大きいセッションを特定したら、タイムラインで「どこで時間が消えたか」を見る:

```bash
python3 <skill-dir>/scripts/latency_probe.py --session <ID前方一致>
```

`asst[think]` 単体の大 gap = 思考時間。`queue-operation` / `away_summary` 前後の gap = 人間側の離席で、遅延ではない。

### 4. 判定と対処

| 症状 | 原因 | 対処 |
|---|---|---|
| thinking 直前 gap が5分超・opus に集中 | 常時思考 × 高 effort × 巨大コンテキスト | `alwaysThinkingEnabled: false`(adaptive)を確認・提案。effort は下げずに済むことが多い |
| adaptive でも特定セッションだけ長考 | コンテキスト肥大(peak 250k超) | 中間結果のファイル退避・トピック単位の新セッションを提案 |
| Bash Exit 143 で作業中断 | 既定2分タイムアウト | `run_in_background: true` か `timeout` 明示延長 |
| ツール入力の parse エラー | 長考後の生成破損 | 上記 thinking 対処と同じ。単発なら continue で復帰 |
| isApiErrorMessage に limit 表示 | 利用上限到達 | リセット時刻まで待つ/プラン確認。障害ではないと報告 |
| 500/529 が実在 | 本物の API 障害 | status.anthropic.com を確認し、リトライ待ち |

セッション実行中の一時変更は `/effort <level>` で可能(ユーザーに案内する。モデル切替 `/model` と effort は連動しない)。

## 制約

- `settings.json`・CLAUDE.md の変更は**提案止まり**。ユーザーの承認なしに書き換えない。
- 時刻の報告は JST。
