---
name: session-insights
description: "Claude Code の過去セッション（transcript JSONL）・設定・運用パターンを cclens と同梱スクリプトで収集し、指定された分析観点に沿って傾向分析と改善案を出す。/session-insights で明示起動されたときのみ使用する。キーワードマッチによる自動起動はしない。起動時に分析観点の指定が必須。"
disable-model-invocation: true
argument-hint: "<分析観点（必須）> [--project <名前>] [--since YYYY-MM-DD]"
---

# session-insights — Claude Code 利用実態の分析と改善提案

## このスキルの目的

`$CLAUDE_CONFIG_DIR`（未設定なら `~/.claude`）に蓄積されたセッション transcript・設定を機械的に読み出し、**ユーザーが指定した分析観点**に沿って利用傾向を分析し、設定・スキル・プロンプトの運用改善案を出す。

分析対象は本人の全会話履歴という機微なデータであり、量も巨大（数百セッション・100MB超）なので、次の2つを設計上の前提にしている:

1. **収集は決定論**。
    - 読み出しは [cclens](https://github.com/lambdalisue/cclens) と同梱スクリプト経由で行い、AI が生の JSONL を Read/Grep で無作為に漁ることはしない。
    - 巨大ファイルの直読みはコンテキストを浪費するだけでなく、走査範囲が毎回変わり分析の再現性を失うため。
2. **観点駆動**。
    - 「なんとなく全部見る」は禁止。
    - 観点が先、収集は観点に必要なものだけ。

## 収集の三系統（どれを使うか先に決める）

道具は 3 つあり、**それぞれにしか無い情報がある**。同じ指標を二重に集計せず、観点に応じて使い分ける。

| 担当 | ここにしか無いもの |
|---|---|
| **cclens** | ツール/スキル使用頻度・skill 単位のトークン消費とコンテキスト増加・常時コスト（overhead）・ツールエラーのカテゴリ分類・設定の棚卸しと未使用検出・プロンプト種別の分布・繰り返し失敗・再編集ループ |
| **ccusage** | **金額（USD）**。モデル別価格表と重複レコード排除を持つ。cclens はトークン量は出すが USD 換算を持たない |
| **同梱スクリプト** | プロンプト**本文**・生 transcript の時系列・**compaction の発生記録**・分析対象範囲の明示 |

境界の理由:

- cclens は SQLite ストアへ抽出済みで、カテゴリ分類・静的トークンコスト・任意 SQL を備える。横断集計はここが最も速く正確
- cclens には価格表が無い（ソースにコスト計算が存在しない）。金額を問われたら必ず ccusage 系（`cost` サブコマンド）へ回す
- cclens はプロンプトを `instruct` / `steer` / `correct` / `question` の 4 ラベルへ集約して**本文を保持しない**。「どう書いたか」を読む観点はスクリプト側でしか扱えない
- cclens は compaction を差分計算時に補正する**ノイズとしてしか扱わない**（発生回数・トリガーを残さない）

## 起動チェック（必須）

起動引数に**分析観点が含まれていなければ、収集を始めずに停止して確認する**。
観点とは「何を知りたいか／何を改善したいか」が判別できる指示のこと。例:

- 「コンテキストを浪費している操作パターンを見つけたい」
- 「スキルが想定通り使われているか、死にスキルがないか」
- 「意図が伝わらず手戻りしたプロンプトの傾向を知りたい」
- 「compact が多発するセッションの共通点は」

`/session-insights` 単体や「分析して」だけの起動は観点不足。その場合は上の例を提示し、観点・期間・対象プロジェクトを確認してから始める。

## データ収集の鉄則

**共通**: 生のセッション JSONL・`history.jsonl` を Read/Grep/head で直接開かない。必要な読み出し方が無ければ、それはスクリプトに足すべき機能（ユーザーに提案する）。

### cclens（横断集計）

```bash
DB="${XDG_CACHE_HOME:-$HOME/.cache}/cclens/cclens.db"
cclens <subcommand> --db "$DB" [--scope <scope>] [--frozen]
```

- **バイナリ解決**: `command -v cclens` で見つからなければ `nix run github:lambdalisue/cclens -- <subcommand …>` を使う。どちらも無ければ、そのぶんの観点は cclens 不在として報告し、スクリプト側で取れる範囲に切り替える（分析全体を止めない）
- **ストア**: プロジェクト直下に `./cclens.db` があればそれを使い `--db` を省く。無ければ上記の per-user ストアを使う（カレントプロジェクトへ db を落とさない）
- 各レポートは実行前に自動で `analyze`（増分・高速）を走らせる。同一分析中に何度も引くときは `--frozen` で固定してよい
- 出力は `table`（既定）/ `markdown`。`doctor` のみ `json` も持つ。`sql` は JSON を持たないので、構造化して受けたいときは `doctor --format json` か、素直に表を読む

**`--scope` で分析軸を切る**（`doctor` / `inventory` / `waste` / `failures` が対応）:

| scope | 意味 |
|---|---|
| `global` | `~/.claude` の設定レイヤ。`failures` では**プロジェクトを跨いで繰り返す失敗**＝習慣・グローバル設定の問題 |
| `project` | 各プロジェクト自身の設定。`failures` では各プロジェクト固有の失敗 |
| `project:<slug>` | 特定プロジェクトに限定（slug は `-home-user-src-…` 形式） |

「自分の癖なのか、特定プロジェクトの事情なのか」を切り分けるための軸なので、改善提案の宛先（`~/.claude` かプロジェクトの `.claude/` か）を決めるときは必ず通す。

### 同梱スクリプト（本文・時系列・compaction）

依存は stdlib のみ・Python バージョンは skill 直下の pyproject.toml から uv が解決・出力は JSON・時刻は JST:

```bash
UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/session-insights" uv run --project "<skill-dir>" python "<skill-dir>/scripts/collect_sessions.py" <subcommand> [オプション]
```

- `UV_PROJECT_ENVIRONMENT` は必ず付ける。スキルディレクトリは read-only（nix store / plugin cache）に配置され得るため、venv をスキル配下に作れない
- `CLAUDE_CONFIG_DIR` はスクリプトが自動で解決する。手で `~/.claude` をハードコードしない
- サブコマンドは `paths` / `sessions` / `prompts` / `cost` / `transcript` の 5 つだけ。横断集計を求められたら cclens へ回す
- `cost` は ccusage への薄い移譲（`ccusage claude daily|session --json --timezone Asia/Tokyo`）。ccusage が無ければ理由を返して停止するので、その観点だけ落として分析は続ける
- 各サブコマンドの limit / max-chars 既定値はコンテキスト保護のための意図的な制約。
  - 外すときは範囲を十分絞ってから
- レコード形式・ディレクトリ配置の詳細（公式ドキュメント準拠の一覧、「実プロンプト」の判定規則、cclens スキーマとの対応）は`references/data-model.md` を参照

## 分析フロー

### 1. 環境確認

```bash
UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/session-insights" uv run --project "<skill-dir>" python "<skill-dir>/scripts/collect_sessions.py" paths
command -v cclens; command -v ccusage   # 使える道具の確認
```

設定ディレクトリの解決結果（`CLAUDE_CONFIG_DIR` の有無）、セッション数、設定・スキル類の配置を把握し、レポート冒頭に「分析対象の範囲」として明記する。**cclens / ccusage が使えるかもここで確認**し、欠けていれば対応する観点を範囲外として明記する。

### 2. 観点に応じた一次収集（集計層）

観点をサブコマンドに写像する。複数併用してよいが、観点に関係ない収集はしない:

| 観点 | サブコマンド |
|---|---|
| コンテキスト効率・compact 多発・トークン消費・コスト | `usage`（`--by day/project`）+ `sessions` の `peak_context`/`compactions` |
| プロンプトの書き方・依頼の傾向・手戻り | `prompts` + `errors`、深掘りは `transcript` |
| スキル・コマンドの活用度（死にスキル検出） | `tools` + `commands` + `config`（定義一覧と突き合わせ） |
| ツール運用（MCP・サブエージェント・並列化） | `tools`（`--by-project`）+ `sessions` の `agents`/`subagent_files` |
| 設定の妥当性（permissions・hooks・モデル選択） | `config` + `sessions` の `models`/`permission_modes` |
| エラー・摩擦ポイント | `errors` + 該当セッションの `transcript` |
| 特定プロジェクトの運用 | 各サブコマンドに `--project` |

共通オプション: `--project <部分一致>` / `--since` / `--until`（JST日付）/ `--session <ID前方一致>`。Agent/Task 起動由来のセッションは既定で除外される（人間の運用分析を歪めるため）。
含めるなら `--include-agents`。

トークン総量とコスト（USD）の算出は、`usage` が [ccusage](https://github.com/ryoppippi/ccusage)に移譲する（既定 `--engine auto`: ccusage があれば `ccusage claude daily/session --json` を実行して `ccusage` キーに添付、無ければ builtin 合算のみ）。
**絶対量・金額は ccusage の値を正とする**（重複レコード排除とモデル別価格計算済み）。
builtin の `usage_total` は `peak_context`・`compactions` などセッション内訳分析用の生合算。

### 3. 深掘り（個別セッション）

集計から仮説を立ててから、該当セッションだけを読む:

```bash
UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/session-insights" uv run --project "<skill-dir>" python "<skill-dir>/scripts/collect_sessions.py" transcript --session <ID> --tail 40
UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/session-insights" uv run --project "<skill-dir>" python "<skill-dir>/scripts/collect_sessions.py" transcript --session <ID> --include-tools
```

深掘りは**仮説の検証に必要なセッションに絞る**（目安: 1観点あたり3〜5件まで）。
全セッションの transcript を順に読むような使い方はこのスキルの禁止事項。

cclens の固定レポートで足りない切り口は、`cclens sql --db "$DB" "<SELECT …>"` で直接引く。`SELECT sql FROM sqlite_master` でスキーマを確認してから書き、想定した encoding が本当に入っているかを少量サンプルして確かめる（`tool_errors` ビューは友好的な列名を与えるが、`events` 側は列を多重利用している）。ストアは read-only で開かれるためクエリが状態を壊すことはない。

### 4. レポートと改善案

分析結果は以下の構成でまとめる（ファイル出力を求められたら [[tmp-output]] の規約に従う。時刻表記は常に JST）:

```markdown
# セッション分析: <観点>
## 分析対象の範囲（期間・プロジェクト・セッション数・除外条件）
## 観測された事実（数値・セッションIDつき）
## 傾向と解釈
## 改善案
```

改善案の書き方:

- **事実と対にする**。「compact が直近30日で12回、うち9回が loglass の長時間セッション（例: abcd1234）」→「そのプロジェクトの CLAUDE.md に調査結果の中間ファイル化を指示する」のように、観測に紐づかない一般論は書かない
- **変更対象は具体パスで**。この環境の `~/.claude/*` は dotfiles(`~/dotfiles/home/.claude/...`)への symlink なので、編集提案は dotfiles 側の実体パスで示す
- 設定・スキルの変更はあくまで**提案**として提示する。ユーザーの承認なしにCLAUDE.md・settings.json・既存スキルを書き換えない

## 制約

- **明示起動のみ**（frontmatter で自動起動無効化済み）。分析観点なしでは動かない
- 分析結果・transcript の内容を外部システム（Slack・Notion・Issue 等）へ送らない。求められた場合も [[external-writes]] の確認手順に従う
- transcript には過去の業務情報・秘匿情報が含まれうる。レポートへの引用は分析に必要な最小限にとどめ、トークンやパスワード様の文字列は伏せる
- スクリプトの改修時は `UV_PROJECT_ENVIRONMENT="$HOME/.cache/uv-venvs/session-insights" uv run --project "<skill-dir>" pytest` を全件通す
