---
name: nix-store-lookup
description: "/nix/store 配下の store path・ファイルを特定するときに必ず参照する。`find /nix/store` で名前を総当たりする前に読む。「あのパッケージの store path が知りたい」「nix-unit のバイナリはどこ」「flake input の実体パスを知りたい」「derivation の出力パスを取りたい」「store の中のこのファイルを探したい」「store path が実在するか確かめたい」といった場面が対象。/nix/store は数万エントリあり深さ無制限の find は完了しない（実測: 20秒でも終わらず出力ゼロ）。同梱の collect_store_lookup.sh が入力の種別判定・一意な解決・候補収集・実在確認までを決定論的に行うので、まずそれを実行してから分析する。nix-locate が返す path はローカルに存在しないことがあるという反直感的な挙動も、データとして検出される。"
---

# nix-store-lookup — /nix/store の探索を決定論的な解決に置き換える

## なぜ find を使ってはいけないか

`/nix/store` はこの種の環境で数万エントリある（実測 35,220）。深さで所要時間が破滅的に変わる:

| コマンド | 実測 |
| --- | --- |
| `find /nix/store -maxdepth 1 -name '*nix-unit*'` | 0.22s |
| `find /nix/store -maxdepth 2 ...` | 5.5s |
| `find /nix/store -name '*nix-unit*'`（深さ無制限） | **20秒経っても完了せず出力ゼロ** |
| 同梱スクリプト（分類・解決・実在確認まで込み） | **0.3s** |

速度以上に問題なのは **結果が一意に決まらない**こと。`find /nix/store -maxdepth 1 -name '*nput*'` は 0.14s で終わるが、`.drv`・`-vendor.drv`・manifest を含む 20 件が返り、どれが目的か判断できない。**探索ではなく、入力から一意に引く**のが正しい。

## 手順

### 1. 収集（必ず最初に実行する）

手段を選ぶ前に、決定論で取れるものを一括で取る。入力の種別を事前に判定する必要はない（スクリプトが分類する）。

```bash
bash <skill-dir>/scripts/collect_store_lookup.sh <query>
```

`<query>` はコマンド名・store path・derivation パス・パッケージ名のいずれでもよい。

オプション:

- `--all` — ローカルで一意に解決できた場合でも upstream index（`nix-locate`）を照会する。既定は skip（理由は後述）
- `--flake <dir>` — 指定 flake の input も収集する（既定: カレントが flake なら自動）

### 2. 出力の読み方

```json
{
  "classified_as": "command_on_path",
  "resolved": { "store_path": "...", "via": "...", "exists": true },
  "candidates": {
    "local_db": { "matches": [...], "count": 4, "total_matched": 4, "truncated": false },
    "upstream_index": { "skipped": "...", "matches": null }
  },
  "context": { "store_entries": 35220, "db_valid_paths": 35141, "flake": {...} },
  "warnings": [...]
}
```

判断はこの順で行う:

1. **`resolved` が null でなければそれが答え**。分岐は不要で、追加のコマンドも要らない
2. `resolved` が null なら `candidates.local_db.matches` を見る。`is_drv` でビルド定義を除外し、`exists` で実在を確認して選ぶ
3. `truncated: true` なら候補を絞れていない。**より長い検索語で再実行する**（`warnings` が具体的に指示する）
4. `warnings` は必ず読む。誤誘導を招く事象がここに出る

`classified_as` の値と、それぞれで `resolved` に入るもの:

| classified_as | 入力の例 | resolved の内容 | 実測 |
| --- | --- | --- | --- |
| `command_on_path` | `nput`, `rg` | symlink を辿った store path | 0.005s |
| `derivation` | `/nix/store/xxx-foo.drv` | `--query --outputs` の出力パス | 0.072s |
| `store_path` | `/nix/store/xxx-foo` | 正規化した store path と deriver | 0.075s |
| `name_query` | `nix-unit` | null（候補から選ぶ） | 0.022s |

### 3. 追加で必要になる操作

収集結果で足りるのが大半だが、次は個別に実行する。

**store path の中身を探す** — store path が確定しているなら、その配下だけを見る:

```bash
nix store ls -R /nix/store/xxx-ripgrep-15.2.0     # 0.087s
```

`find /nix/store/xxx-ripgrep-15.2.0/ -name '*.so'` のように**単一 store path 配下に限定**するなら `find` でも構わない。禁じられているのは `/nix/store` そのものを起点にすることだけ。

**依存関係を辿る**:

```bash
nix-store --query --referrers /nix/store/yyy-foo   # これに依存しているもの
```

**実行できればよい（path 不要）**:

```bash
nix shell --offline nixpkgs#<pkg> -c <cmd>          # 0.9s
```

## 落とし穴（すべて実測で確認済み）

### nix-locate が返す path はローカルに存在しないことがある

**最も誤解しやすい点。** `nix-locate` / `nix-index` は **upstream nixpkgs の index** であって、ローカル store の索引ではない。実測では `nix-locate -w bin/rg` が返した 3 件中 2 件がディスクに存在しなかった。

スクリプトは全 upstream 候補に `exists_locally` を付け、未存在があれば `warnings` に出す。**この判定を記憶や推測で代替しない**（出力を見ればよい）。

既定で upstream を照会しないのもこのため。ローカルで一意に解決済みなのに、実在しない候補を並べると誤誘導になる。nixpkgs 側を調べたいときだけ `--all` を付ける。

同じ理由で `nix eval --raw nixpkgs#<pkg>` が返す outPath も実在するとは限らない（pin が違えばハッシュが変わる）。実在確認は `nix path-info <path>`（未ビルドなら exit 1 / 0.071s）。

### lookup 目的で nix build を使わない

`nix build --print-out-paths --no-link` は path を表示するが **実際にビルド・fetch する**。実測で 25.1s かかり 2.1MiB の転送が始まった。`--dry-run` でも 4.0s + 依存解決が走る。path を知りたいだけなら `nix eval` か `nix-store --query`。

### nix eval には --offline を付ける

`--offline` 無しだと substituter に問い合わせに行く。実測 14.9s（`copying path ... from https://cache.numtide.com` が発生）vs `--offline` で 0.56s。ただしローカルに無いものは解決できないので、upstream を引きたいときは外す。

### nix-store --query --roots は読み取り専用ではない

stale な gcroot symlink を削除する副作用がある。「安全な参照系」として無自覚に実行しない（スクリプトも使っていない）。

### DB と filesystem は完全一致しない

実測で filesystem 35,220 / DB 35,141 と 79 件ずれる。差分はビルド中の一時ファイル・`.lock`・GC 待ちの残骸で、**DB クエリでは出ない**。スクリプトはこのずれを検出して `warnings` に出す。

## find /nix/store が残る例外

次の場合に限り使ってよい。いずれも **`-maxdepth 1` を必ず付ける**（深さ 2 で 5.5s、無制限で完了しない）:

- DB に載らない一時ファイル（`.lock`、ビルド中の中間物）を探すとき
- store DB が読めない環境

それ以外で `/nix/store` を起点にした探索が必要になったら、収集スクリプトに戻る。

## 関連スキル

- nix-cache-check: バイナリキャッシュ未ヒットの原因調査（store path の特定ではなく、substituter / Hydra 側の問題を扱う）
