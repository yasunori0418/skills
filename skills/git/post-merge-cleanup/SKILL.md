---
name: post-merge-cleanup
description: "PR マージ後のローカル後片付け（worktree / ブランチ / tmux セッションの削除と main の最新化）を、収集 → 計画提示 → 承認 → 実行 → 検証のゲートで定型化する。`/post-merge-cleanup [PR番号|ブランチ名]...` の明示実行専用。"
user-invocable: true
disable-model-invocation: true
argument-hint: "[PR番号|ブランチ名]...（省略時は merged PR 直近 30 件から自動検出）"
allowed-tools: Bash, Read, AskUserQuestion
---

# post-merge-cleanup — PR マージ後の後片付け

worktree / ブランチ / tmux セッションの削除は不可逆で、消えた作業ディレクトリの
gitignored なファイル（`.env` / `.direnv` / ビルド成果物）は復旧できない。本スキルは
**収集 → 計画提示 → 承認 → 実行 → 検証** をゲートとして固定し、後片付けの範囲が
毎回揺れるのを防ぐ。

破壊操作を含むため `disable-model-invocation: true`。「PR をマージした」といった
平叙文で勝手に発火せず、`/post-merge-cleanup` の明示実行時のみ動く。

## 依存

`gh` / `jq` / `git` が必須。`collect-merge-state.sh` が起動時に存在を確認し、欠けていれば
名指しで中断する。無い依存を回避する実装は持たない — 何を入れれば動くかを伝えて
落ちる方が短く、挙動も読みやすい。`wt`（worktrunk）と `tmux` は任意で、無ければ
worktree 情報を `git worktree list` から取り、tmux セッションの対応付けは行わない。

## 設計の前提（判断の根拠）

着手前にこの 3 点を頭に入れる。手順の理由がここにある。

1. **マージ済みかの真実源は GitHub の PR state（MERGED）。** main が rebase-merge の
   線形履歴だと、マージ後もローカルブランチの sha は変わらないため
   `git branch --merged` には出てこない。ローカルだけで patch-id を比較する自前判定は
   持たない — 実際の削除可否は `wt remove` が tree 一致（`tree matches main, ⊂`）で
   機械判定しており、実測でも rebase-merge 済みブランチを正しく削除できている。

2. **`wt remove` は「ブランチ」は守るが「worktree」は守らない。** 未マージブランチは
   `-D` 無しでは消えない一方、その worktree は確認なく削除される。dirty なら削除を
   拒否する（exit 1）が、**clean かつ未 push コミットがあるだけの worktree は消える**。
   その作業は次の PR になる予定のものかもしれないので、`collect` 側で `ahead > 0` を
   検出して候補から外す。この保護は `wt` 単体では効かない。

3. **削除の実行は AI が生コマンドを組まない。** 承認した計画と実行対象がズレる余地を
   無くすため、`collect` が出した JSON を絞って `apply` に stdin で渡す。ブランチ名を
   文字列で組み直すと、承認していない対象が紛れ込みうる。

## 制約（厳守）

1. **承認なし実行禁止** — §3 の計画を提示し、ユーザーの明示承認を得るまで
   `apply-cleanup.sh` を実行しない。
2. **force 系フラグ禁止** — `wt remove -D` / `wt remove --force` / `git branch -D` /
   `git worktree remove --force` / `rm -rf` は使わない。`apply-cleanup.sh` にこれらの
   経路は存在せず、拒否されたら報告して次の対象へ進む。拒否は判定漏れのシグナルなので、
   強行せず原因を報告する。
3. **計画に無い対象を実行中に追加しない** — 承認後に候補が増えたら、計画提示からやり直す。
4. **`deletable=false` は消さない** — dirty / マージ後の追加コミット / main / 実行中
   セッションの作業ディレクトリは保護対象。`apply` は 1 件でも混ざれば実行前に停止する。
5. **tmux は完全一致のセッションのみ** — 部分一致で無関係なセッションを巻き込まない。
   `tmux_busy: true`（pane で claude 稼働中）は既定を「残す」に倒し、kill するなら
   計画で明示して承認を取る。

## ワークフロー

### 0. main の最新化（後片付けの前）

後片付けより先に main を進める。`wt remove` のマージ判定はローカル main の tree と
比較するため、main が古いと消せるはずのブランチが残る。

```bash
git fetch --prune origin && git merge --ff-only origin/main   # main worktree に居る場合
git fetch --prune origin                                       # 別 worktree に居る場合
```

`Permission denied (publickey)` で失敗したときだけ **gh-fetch スキルの SKILL.md を読み**、
その手順（HTTPS + gh トークンへのフォールバック）に従う。通っているなら読む必要はない。

main worktree が dirty で ff できない場合は、最新化を見送った旨を報告して後片付けは続行する
（後片付け自体は main の前進に依存しない。ただし候補が減る可能性を計画に書く）。

### 1. 状況収集

```bash
bash <skill-dir>/scripts/collect-merge-state.sh [PR番号|ブランチ名]...
```

read-only。引数を省略すると merged PR 直近 30 件とローカルの worktree / ブランチの
積集合を候補にする。出力（JSON）の見どころ:

| キー | 意味 |
|---|---|
| `candidates[].deletable` | `true` のみが削除対象。`false` の理由は `blocked_reasons` |
| `candidates[].tmux_busy` | pane で claude 稼働中。`true` なら既定は「残す」 |
| `not_merged` | 引数指定されたが MERGED でない PR。対象外として報告する |
| `followups.stacked_children` | マージ済みブランチを base に持つ open PR |
| `followups.tracking_issues` | GitHub が自動クローズしない `#N` 参照 |

`candidates` が空なら片付けるものが無い。その旨を報告して終える。

### 2. 計画提示（承認ゲート）

```markdown
## 後片付け計画: <対象を一言>

### main の最新化
- <実施済み / 見送り（理由）>

### 削除する
| ブランチ | worktree | tmux | PR |
|---|---|---|---|
| `feat-x` | `../repo.feat-x` | `feat-x` | #199 |

### 残す（保護対象）
| ブランチ | 理由 |
|---|---|
| `feat-y` | マージ後の追加コミット 2 件（未 push） |

### 後続タスク（このスキルでは実行しない）
- stacked 子ブランチ: <一覧。あれば rebase-flow での main 追従を提案>
- tracking issue: <一覧。あれば external-writes ゲートでの更新を提案>
```

AskUserQuestion で承認を取る。保護対象を消したいと言われた場合は、本スキルでは扱わず
（force 系は制約 2 で禁止）、dirty なら内容の確認を、未 push なら push を先に促す。

### 3. 実行

承認された対象だけに JSON を絞って `apply` へ渡す。**ブランチ名を手で組み直さない**。

```bash
bash <skill-dir>/scripts/collect-merge-state.sh <引数> > /tmp/state.json
# 承認された対象だけ残す（例: 全 deletable を承認した場合）
jq '{candidates: [.candidates[] | select(.deletable == true)]}' \
  /tmp/state.json > /tmp/approved.json
bash <skill-dir>/scripts/apply-cleanup.sh < /tmp/approved.json
```

絞り込みは一度ファイルへ落としてから `<` で渡す。`jq ... | bash` の形はセキュリティ
hook が「インタプリタへのパイプ」として差し戻すことがあり、無駄打ちになる。

一部だけ承認された場合は `select(.branch as $b | ["feat-x"] | index($b))` のように
承認済みブランチで絞る。`apply` は tmux kill → worktree/ブランチ削除の順に実行し、
個別の失敗では止まらず記録して次へ進む（1 件の失敗で残りが中途半端に残るのを避けるため）。

### 4. 検証と報告

```bash
bash <skill-dir>/scripts/verify-cleanup.sh < /tmp/approved.json
```

`RESIDUAL` が出たら計画と不一致。**force 系での強行はせず**、原因（未マージだった /
dirty だった / セッションが掴んでいた）を特定して報告する。

response-format 準拠で報告する: 削除した対象 / 残した対象と理由 / main の最新化結果 /
後続タスクの提案（stacked 子ブランチ・tracking issue）。

## 参照

- `scripts/collect-merge-state.sh` — 候補列挙と削除可否判定（read-only）
- `scripts/apply-cleanup.sh` — 承認済み JSON を stdin で受けて実行。`--print-only` で
  コマンド生成のみ（テスト用）
- `scripts/verify-cleanup.sh` — 実行後の残存確認。単独で再実行できる
- 関連スキル: gh-fetch（非対話 SSH が通らないときの fetch 委譲）/ rebase-flow（stacked
  子ブランチの main 追従）/ external-writes（tracking issue の更新ゲート）/
  job-graph（全レーンのマージ完了後の終端処理として本スキルを案内する）
