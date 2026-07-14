---
name: gh-push
description: "非対話セッション（claude-code の remote-control / CI など TTY が無く SSH 鍵パスフレーズを入力できない状況）で git push を通すスキル。remote が SSH URL で `ssh -o BatchMode=yes` による非対話 SSH 認証が実際に通る（agent の鍵・パスフレーズ無しのディスク鍵・macOS キーチェーン鍵のいずれでも可）なら素の SSH push を実行し、非対話 SSH 認証が通らず `git push` が `Permission denied (publickey)` で失敗する場合は、push を HTTPS + gh トークン（credential.helper='!gh auth git-credential'）経由へ自動フォールバックして標準入力なしで実行する。「push して」「リモートに反映して」と頼まれたが SSH 認証が使えない、push が publickey で弾かれた、remote-control から push したい、といった場面で使う。`/gh-push` で明示起動も可。GitHub(gh) 前提。"
argument-hint: "[push 先ブランチ名（任意、省略時は現在のブランチ）]"
---

# gh-push — 非対話 push（SSH 優先・gh フォールバック）

## このスキルの目的

非対話セッション（TTY 無し）で `git push` を通す。経路は **決定論的に** 選ぶ:

1. **SSH 優先** — remote が SSH URL で、かつ `ssh -o BatchMode=yes` による非対話 SSH 認証が実際に通るなら、素の `git push` を SSH で実行する。判定は agent の鍵有無ではなく **BatchMode=yes での `ls-remote` が成功するかで直接テスト**する（agent の鍵・パスフレーズ無しのディスク鍵・macOS キーチェーン鍵を区別せず「非対話で通るか」を確かめられる）。`GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new'` を強制し、パスフレーズ入力プロンプトや接続ハングに落ちず即失敗させる。
2. **gh(HTTPS) フォールバック** — SSH push が失敗した場合、または SSH が使えない（remote が HTTPS / 非対話 SSH 認証テストが失敗）場合は、push 認証を gh の credential helper に肩代わりさせて HTTPS で送る:

   ```
   git -c credential.helper= -c credential.helper='!gh auth git-credential' push <https-url> <branch>
   ```

   `credential.helper=`（空）で既存ヘルパー一覧をリセットし gh ヘルパーだけを使う（`cache`/`oauth` 等の介入を避ける）。remote が SSH URL でも URL を HTTPS に変換して push 先に使うので **origin の設定は変更しない**。

**なぜ SSH を先に試すか**: 「SSH で push できるか」は `ssh -o BatchMode=yes` の `ls-remote` を1回打って直接テストすれば決定論的に判定できる。非対話 SSH が通る環境（Linux で ssh-agent 常駐、macOS のキーチェーン連携、パスフレーズ無しのディスク鍵など）では素の push がそのまま通るため、余計なトークン経由を挟まない。判定の `ls-remote` は push 範囲算出に使うリモート tip 取得と兼ねるので、往復コストは増えない。`ssh-add -l`（agent の鍵一覧）では、agent が空でもディスク鍵やキーチェーン鍵で非対話認証できるケースを取りこぼすため使わない。

## 前提

- **SSH 経路の条件**: remote が SSH URL（`ssh://git@…` または `git@host:owner/repo`）で、`ssh -o BatchMode=yes` の非対話 SSH 認証が実際に通ること（agent 鍵・パスフレーズ無しのディスク鍵・キーチェーン鍵のいずれでも可）。この2条件が揃わなければ自動的に gh 経路になる。
- **gh 経路（フォールバック）の条件**: `gh auth status` でログイン済みで、トークンに **`repo`（write）scope** があること。無ければ push は権限エラーで落ちる（`gh auth refresh -s repo` で付与）。
- SSH と gh のどちらも使えない（非対話 SSH 認証が通らず かつ gh 未認証/未導入）ときは preflight/push が `ERROR:` で停止する。SSH 鍵を非対話で使える状態にするか `gh auth login` を促す。
- GitHub（github.com / GitHub Enterprise）が対象。GitLab 等 gh が扱わないホストは gh 経路が使えない — SSH が通らなければこのスキルの対象外（SSH 鍵や glab を案内する）。

## ワークフロー

判定・URL 変換・push 範囲算出・push 実行はすべて決定論的なので、git コマンドを手で並べ直さず `scripts/gh-push.sh` を使う。

### 1. preflight（push 対象を収集して提示）

```bash
bash <skill-dir>/scripts/gh-push.sh preflight [branch]
```

`=== SECTION ===` 区切りの出力を読み、**push 経路（SSH / gh）・push 先 URL・ブランチ・送るコミット**をユーザーに提示する。`TARGET` の `route` 行で、SSH 経路か gh 経路かとその理由が分かる。`AUTH` セクションで非対話 SSH 認証テストの成否と gh 認証を確認する。`STATE` の意味:

- `up-to-date` … 差分なし。push 不要。
- `new` … リモートに無い新規ブランチ。直近コミットを提示。
- `fast-forward` … 通常 push 可。送るコミット一覧が出る。
- `diverged` … **履歴分岐**。通常 push は弾かれる。WARNING を読み、**ここで停止してユーザーに確認**（fetch して rebase/merge で整合させるのが既定。意図的な上書きのときだけ force）。
- `unknown` … リモート tip がローカルに無く厳密判定不能。非 FF ならサーバが安全に拒否するのでそのまま push 試行してよい。

preflight が `ERROR:` を出したら、その内容（非対話 SSH 認証不可 かつ gh 未認証・未対応 URL・detached HEAD 等）を解決してから進む。

### 2. push 実行

起動＝push 意図とみなし、preflight 提示後そのまま実行する（毎回の yes/no は取らない）。ただし上記 `diverged`（force が要る状況）だけは**必ず停止して確認**する。

```bash
bash <skill-dir>/scripts/gh-push.sh push [branch]
```

意図的な上書きをユーザーが承認した場合のみ force を付ける:

```bash
bash <skill-dir>/scripts/gh-push.sh push [branch] --force [--expect=<sha>]
```

force は両経路とも `--force-with-lease=<branch>:<現リモート tip>` の**明示 lease** で実行される（gh 経路の URL 直 push では引数なし `--force-with-lease` の比較対象となる remote-tracking ref が参照されず常に stale info で拒否されるため、明示 lease に統一している）。呼び出し元が「安全と確認済みのリモート tip」を持っている場合 — rebase-flow スキルからの委譲等 — は `--expect=<sha>` で渡す。確認時点以降に他者の push が挟まると実 tip と不一致になり、push 前に確実に停止する。

gh 経路で push した場合、スクリプトは `refs/remotes/<remote>/<branch>` を手で進めて `git status` の ahead 表示を整合させる（URL 直 push では remote-tracking ref が自動更新されないため）。SSH 経路では git が更新するのでこの補正は行われない。実行結果の `OK: [ssh]` / `OK: [gh]` でどちらの経路を使ったか分かる。

## 制約

- **force はユーザーの明示承認が無い限り付けない**。`diverged` 検出時は停止が既定。
- **保護ブランチへの force は script が拒否する**（静的リスト main/master/develop/trunk/release 等 + origin/HEAD + GitHub 既定ブランチ）。force が許されるのは作業ブランチのみ。
- このスキルは push そのものが目的なので、起動された時点では実行してよい（pr-create の「自動 push 禁止」とは役割が別）。ただし push 先が `main`/`master` など保護ブランチのときは、送るコミットを提示した上で一言断ってから実行する。
- remote URL や push 先ブランチが曖昧・複数候補ありうるときは、憶測で push せずユーザーに確認する。
