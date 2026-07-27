---
name: nix-store-lookup
description: "/nix/store 配下の store path・ファイルを特定するときに必ず参照する。`find /nix/store` で名前を総当たりする前に読む。「あのパッケージの store path が知りたい」「nix-unit のバイナリはどこ」「flake input の実体パスを知りたい」「derivation の出力パスを取りたい」「store の中のこのファイルを探したい」「store path が実在するか確かめたい」といった場面が対象。/nix/store は数万エントリあり深さ無制限の find は完了しない（実測: 20秒でも終わらず出力ゼロ）一方、入力として何を持っているか（PATH 上のコマンド名 / derivation / flake input / パッケージ名のみ）に応じて 0.02〜0.9 秒で一意に解ける公式コマンドがある。nix-locate が返す path はローカルに存在しないことがあるという反直感的な挙動も扱う。"
---

# nix-store-lookup — /nix/store の探索を一意なクエリに置き換える

## なぜ find を使ってはいけないか

`/nix/store` はこの種の環境で数万エントリ（実測 35,220）ある。深さで所要時間が破滅的に変わる:

| コマンド | 実測 |
|---|---|
| `find /nix/store -maxdepth 1 -name '*nix-unit*'` | 0.22s |
| `find /nix/store -maxdepth 2 ...` | 5.5s |
| `find /nix/store -name '*nix-unit*'`（深さ無制限） | **20秒経っても完了せず出力ゼロ** |
| store DB への SQLite クエリ | **0.022s** |

ただし速度以上に問題なのは **結果が一意に決まらない**こと。`find /nix/store -maxdepth 1 -name '*nput*'` は 0.14s で終わるが、`.drv`・`-vendor.drv`・manifest を含む 20 件が返り、そこからどれが目的のものか判断できない。**探索ではなく、入力から一意に引く**のが正しい。

## まず「何を持っているか」を確定する

分岐はこの 1 点で決まる。上から順に該当するものを使う（上ほど速く、一意性が高い）。

| 持っているもの | コマンド | 実測 |
|---|---|---|
| **PATH に通ったコマンド名** | `readlink -f "$(command -v <cmd>)"` | 0.005s |
| **derivation パス（`.drv`）** | `nix-store --query --outputs <drv>` | 0.072s |
| **store path（出力側）から drv を知りたい** | `nix-store --query --deriver <path>` | 0.075s |
| **flake のディレクトリ** | `nix flake archive --json --dry-run` | 0.086s |
| **パッケージ名のみ（ローカルにある前提）** | store DB クエリ（下記） | 0.022s |
| **store path が分かっていて中のファイルを探す** | `nix store ls -R <path>` | 0.087s |
| **nixpkgs のどのパッケージがこのファイルを持つか** | `nix-locate -w <path>` | 0.75s ⚠️ 後述 |
| **実行できればよい（path 不要）** | `nix shell --offline nixpkgs#<pkg> -c <cmd>` | 0.9s |

## 各手段の詳細

### PATH 上のコマンド → 実体（最優先）

nix 管理のコマンドは profile 経由の symlink なので、追えば store path が一意に出る。

```bash
readlink -f "$(command -v nix-locate)"
# /nix/store/7nyap0ih1lr0wmcz96dv9ywbn4zlv27r-nix-index-with-full-db-0.1.11/bin/nix-locate
```

「`nput` の store path を知りたい」のような依頼はこれ一発で終わる。`find` で名前を総当たりして 20 件から選ぶ必要はない。

### ローカル store を名前で検索（ハッシュ不明のとき）

store DB を読み取り専用で引く。`immutable=1` を付けること（ロックを取らず、書き込みも起こさない）。

```bash
sqlite3 "file:/nix/var/nix/db/db.sqlite?immutable=1" \
  "select path from ValidPaths where path like '%nix-unit%' and path not like '%.drv';"
# /nix/store/95pgigkpc5lya7kjw97l8al4yxgvhagw-nix-unit-2.35.0
# /nix/store/rnxy3jqqipm77l5rgr2by1jrfxbv95al-nix-unit-2.35.1
```

`.drv` を除外しないとビルド定義まで混ざる。公式コマンドで代替するなら `nix path-info --all`（2.85s、DB スキーマ変更に強いが 100 倍以上遅い）。

### derivation ↔ 出力パス

```bash
nix-store --query --outputs /nix/store/xxx-foo.drv   # drv -> 出力パス
nix-store --query --deriver /nix/store/yyy-foo       # 出力パス -> drv
nix-store --query --referrers /nix/store/yyy-foo     # これに依存しているもの
```

`nix eval --raw .#checks.<system>.<name>.drvPath` で drv を得たあとは、`find` ではなく `--outputs` で出力パスに変換する。

### flake input の実体パス

```bash
nix flake archive --json --dry-run
```

`--dry-run` なのでダウンロードは起きない。`{"inputs": {"<name>": {"path": "/nix/store/..."}}, "path": "..."}` の形で自分自身（`path`）と全 input を再帰的に返す。

### store path の「中身」を探す

store path が確定しているなら、その配下だけを見る。`/nix/store` 全体を舐める理由にはならない。

```bash
nix store ls -R /nix/store/xxx-ripgrep-15.2.0
```

`find /nix/store/xxx-ripgrep-15.2.0/ -name '*.so'` のように**単一 store path 配下に限定**するなら `find` でも構わない。禁じられているのは `/nix/store` そのものを起点にすることだけ。

## 落とし穴（すべて実測で確認済み）

### nix-locate が返す path はローカルに存在しないことがある

**最も誤解しやすい点。** `nix-locate` / `nix-index` は **upstream nixpkgs の index** であって、ローカル store の索引ではない。

```bash
nix-locate -w bin/rg
# vscode-extensions.joshmu.periscope.out  ... /nix/store/188j0vw7...-vscode-extension-.../bin/rg  ← 実在しない
# vscode-extensions.continue.continue.out ... /nix/store/i5z9pd3i...-vscode-extension-.../bin/rg  ← 実在しない
# ripgrep.out                             ... /nix/store/sh64cdxk...-ripgrep-15.2.0/bin/rg        ← たまたま実在
```

実測ではこの 3 件中 2 件がディスクに存在しなかった。`nix-locate` は「nixpkgs のどのパッケージがこのファイルを持つか」を調べる道具であり、**ローカルにあるものを探す用途に使うと、存在しない path を掴んで次の操作が失敗する**。ローカルを探すなら store DB クエリを使う。

同じ理由で `nix eval --raw nixpkgs#<pkg>` が返す outPath も実在するとは限らない（pin が違えばハッシュが変わる）。実在を確かめるなら `nix path-info <path>`（未ビルドなら exit 1 / 0.071s）。

### lookup 目的で nix build を使わない

`nix build --print-out-paths --no-link` は path を表示するが、**実際にビルド・fetch する**。実測で 25.1s かかり 2.1MiB の転送が始まった。`--dry-run` でも 4.0s + 依存解決が走る。path を知りたいだけなら `nix eval` か `nix-store --query`。

### nix eval には --offline を付ける

`--offline` 無しだと substituter に問い合わせに行く。実測で 14.9s（`copying path ... from https://cache.numtide.com` が発生）vs `--offline` で 0.56s。ただし `--offline` はローカルに無いものを解決できないので、upstream を引きたいときは外す。

### nix-store --query --roots は読み取り専用ではない

stale な gcroot symlink を削除する副作用がある。「安全な参照系」として無自覚に実行しない。

### DB と filesystem は完全一致しない

実測で filesystem 35,220 / DB 35,141 と 79 件ずれる。差分はビルド中の一時ファイル・`.lock`・GC 待ちの残骸。**これらを探すときだけは DB クエリでは出ない**ので、`find /nix/store -maxdepth 1` が必要になる。

## find /nix/store が残る例外

次の場合に限り `find /nix/store` を使ってよい。いずれも **`-maxdepth 1` を必ず付ける**（深さ 2 で 5.5s、無制限で完了しない）。

- DB に載らない一時ファイル（`.lock`、ビルド中の中間物）を探すとき
- store DB が読めない環境

それ以外で `/nix/store` を起点にした探索が必要になったら、まず「何を持っているか」の表に戻る。

## 関連スキル

- nix-cache-check: バイナリキャッシュ未ヒットの原因調査（store path の特定ではなく、substituter / Hydra 側の問題を扱う）
