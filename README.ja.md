# incus-in-nixos

**素の NixOS ホストを Incus ホストに変え、そのうえでコンテナを運用まで面倒を見る Hermes Agent 向けスキルです。**

1 つのスキルに 2 つの経路が入っています。

- **Path A** — インストール直後の NixOS から使える Incus ホストまで: サーバ初期化、OS アップグレード、宣言的 Incus、LAN IPv4 のブリッジ接続、そしてルーティングされた IPv6 プールによるランダム・一意・回収可能なアドレス割り当て。
- **Path B** — コンテナの CRUD。作成されたコンテナは**すでに初期化済み**(root ユーザー、ランダム 8 文字パスワード、sshd)で、サーバー情報ブロックが出力されます。

スクリプトも NixOS 設定も、すべて**単一の `site.conf` からレンダリング**されます。パッケージにサイト固有の情報(実際の IP、パスワード、ホスト名)は一切含まれていません。

---

## アーキテクチャ

```
upstream gateway (LAN ルーター / ハイパーバイザのホスト)
   └── vmbr / 物理 L2
        └── IFACE (ブリッジに収容される物理 NIC。純粋な L2 で、アドレスは持たず link-local のみ)
             └── incusbr0 (Incus 管理のブリッジ)
                  アドレス: ホスト IPv4/24 + ホスト本来の IPv6 /128 + プールゲートウェイ /112
                  dnsmasq: DHCPv4(範囲を限定、ゲートウェイは上流)+ stateful DHCPv6 + RA
                  veth x N (= コンテナの eth0。ホストや上流 VM と同じ L2)
```

- コンテナの IPv4 は LAN セグメントからランダムに払い出され(プールは上流の静的割り当て範囲を避ける)、デフォルトルートは上流ゲートウェイを直接指します — **このホストでは NAT を行いません**。
- コンテナの IPv6 はこのホストにルーティングされた `/112` からランダムに払い出され、外部から到達できます。
- アドレスは 2 つのアロケータが管理します: **ランダム、一意、安定、回収可能**。`incus-reconcile` タイマーが削除済みインスタンスのアドレスを回収し、`incus-pool-autogrow` が必要に応じてストレージプールを拡張します。
- 固定されるのは 3 つだけです: ホスト自身の IPv4、ホスト本来の IPv6 `/128`、そして上流の静的範囲(プールは決してそこを覆いません)。

## 動作要件

- flakes を有効にした systemd ベースの NixOS(26.11 / unstable で検証済み)
- ホストのネットワーク: IPv4 の LAN ゲートウェイ、このホストにルーティングされた IPv6 プレフィックス(通常は `/112`)、ブリッジに収容できる物理 NIC
- ホスト上の `python3`(アロケータとコンテナの自己テストで使用。Path A の設定が `environment.systemPackages` で導入します)

## Hermes へのインストール

```bash
git clone https://github.com/mushokumunou/incus-in-nixos.git \
  ~/.hermes/skills/infrastructure/incus-in-nixos
```

- 同じ名前のスキルが既にある場合は、先に退避してください(このパッケージが置き換えます)。
- 登録作業は不要です。該当するタスクで Hermes が `SKILL.md` を自動的に読み込みます。
- 人が直接読むこともできます。入口は `SKILL.md`、手順書と落とし穴の一覧は `references/` にあります。

## クイックスタート

### Path A — 素の NixOS から完全な Incus ホストへ

```bash
# 0) 読み取りのみの調査(site.conf の推奨値が出力されます)
ssh root@<host> 'bash -s' < scripts/probe-host.sh

# 1) パラメータを記入してレンダリング(制御側のマシンで実行。値の欠落や未置換の @@KEY@@ はエラーになります)
cp scripts/site.conf.example /root/incus-site.conf && $EDITOR /root/incus-site.conf
scripts/render-site.sh /root/incus-site.conf /root/incus-rendered

# 2) ホストへ転送(先に素の設定をバックアップ)
H=root@<host>; P=<ssh-port>
ssh -p $P $H 'mkdir -p /root/backup-$(date +%F) /usr/local/bin; cp -n /etc/nixos/configuration.nix /root/backup-$(date +%F)/configuration.nix.orig'
scp -P $P /root/incus-rendered/configuration.nix $H:/etc/nixos/configuration.nix
scp -P $P /root/incus-rendered/bin/* $H:/usr/local/bin/
scp -P $P /root/incus-rendered/bin/{rebuild-detached.sh,fix-first-switch.sh,rollback-net.sh} $H:/root/
ssh -p $P $H 'chmod 0755 /usr/local/bin/* /root/*.sh'

# 3) OS をアップグレードして再構築(切り離し実行: 先に build し、成功したときだけ switch)
ssh -p $P $H 'systemd-run --unit=incus-stack-upgrade --collect /run/current-system/sw/bin/bash /root/rebuild-detached.sh'
ssh -p $P $H 'tail -f /root/rebuild-*.log'   # FLAKE_UPDATE_EXIT=0 -> BUILD_EXIT=0 -> REBUILD_EXIT=0 -> BRIDGE_ADDR_OK

# 4) 最初の切り替えで preseed / resolvconf の失敗が出た場合(NetworkManager 構成から移行するときによく起きます)
ssh -p $P $H 'systemd-run --unit=fix-first-switch --collect /run/current-system/sw/bin/bash /root/fix-first-switch.sh'
```

その後 `references/verification-checklist.md` のホスト用チェックリストを実行し、一度再起動して自己復旧を確認してください(ブリッジ、ホストのアドレス、ルートは自動的に再構築されます)。

### Path B — コンテナの CRUD(作成時点で初期化済み)

```bash
incus-ct-create.sh web1                        # Debian 13、4 vCPU、4GiB、10GiB、スナップショット付き
incus-ct-create.sh db1 --cpu 8 --mem 8GiB --disk 40GiB
incus-ct-create.sh probe1 --no-init --no-snapshot

incus-ct-info.sh web1 [password]               # サーバー情報ブロックを表示
incus snapshot create web1 <snap>              # スナップショット。ロールバック: incus stop web1 && incus snapshot restore web1 <snap>
incus-ct-delete.sh web1                        # 削除 + 解放 + プールの確認
incus-ct-flush-lease.sh <addr>                 # 残った DHCP リースを即座に回収(約 1 時間待たない)
```

作成の順序: create → 制限(`limits.cpu`、`limits.memory`、`limits.memory.swap=true`、`security.nesting=true`)→ ルートボリュームのクォータ → アロケータが v4/v6 を選び `incus config device override` で eth0 に固定 → start → 固定したアドレスが実際に現れるまで待機 → **コンテナ内の初期化** → スナップショット → サーバー情報を表示し `/root/incus-ct-<name>.info`(mode 0600)に保存。

**コンテナ内の初期化で行うこと**(冪等):

1. hostname をインスタンス名にし、`/etc/hosts` に `127.0.1.1` の行を追加
2. タイムゾーンを UTC に、`localedef en_US.UTF-8` を実行
3. `apt-get update && apt-get upgrade` と基本パッケージ(openssh-server、curl、ca-certificates、sudo、locales、tzdata、procps、less。dnf / apk の分岐もあり)
4. **root パスワードはランダム 8 文字**(英大文字・小文字・数字を含み、それぞれ最低 1 文字。引数で指定も可能)
5. `/etc/ssh/sshd_config.d/99-ct-init.conf` で root ログインとパスワードログインを許可し、そのうえで**ループバックへの実際のパスワードログインを自己テスト**。失敗した場合は自動的に `UsePAM no` に切り替えます(非特権コンテナで PAM ヘルパー `unix_chkpwd` がパスワードを検証できない環境への回避策)。どちらのモードで動作したかを出力します
6. NTP(`systemd-timesyncd`)と自己チェック(hostname、カーネル、アドレス、sshd の状態、`readlink -f /bin/sh`)
7. `/bin/sh` は変更しません(イメージ本来の dash を維持。スクリプトは必ず shebang を持たせます)

サーバー情報の出力例:

```
============================================================
 container : web1  (RUNNING)
 hostname  : web1
 IPv4 (LAN): 10.10.10.50/24
 IPv6 (WAN): 2001:db8:1234:5678:9abc:0:50:2a/128
 pinned    : v4=10.10.10.50  v6=2001:db8:1234:5678:9abc:0:50:2a
 login     : root@10.10.10.50   password: Xy7Qm2Kd
   ssh -4 root@10.10.10.50
   ssh -6 root@2001:db8:1234:5678:9abc:0:50:2a
 resources : cpu=4 mem=4GiB swap=true nesting=true disk=10GiB
 snapshots : initial-20261005
 allocator : v4=10.10.10.50 v6=2001:db8:1234:5678:9abc:0:50:2a
============================================================
```

## アドレスプールと回収に関する 3 つの原則

1. **IPv4 は削除と同時に回収されます。** インスタンスを削除するとリースはすぐに解放され、同じアドレスを新しいインスタンスに固定できます。
2. **解放された IPv6 `/128` には約 1 時間のリースの名残があります。** 削除したインスタンスの DHCPv6 リースはリース時間のあいだ dnsmasq に残り、その間に同じ `/128` を新しいインスタンスに固定しようとすると**別のアドレスに黙って置き換えられます**。そのためアロケータには**リースガード**があり、`alloc` はリース表に残っているアドレスを避け、`status` は `held by dnsmasq leases (not handed out): N` を出力し、リースの期限が切れるとアドレスはプールに戻ります。
3. **即座に回収したい場合:** `incus-ct-flush-lease.sh <addr>` を使います。まず `dnsmasq.leases` から該当行を削除し、**そのあとで** incusd を再起動してください。順序が重要で、dnsmasq はメモリ上の内容でファイルを上書きするため、先に再起動しても何も消えません。動作中のコンテナはこの再起動の影響を受けません。

削除のたびに確認すること: `incus list` からインスタンスが消えている、両方の `*-alloc status` が元の数に戻り state ファイルもきれい、`dnsmasq.leases` にそのアドレスがない(またはリースとして保持されていることを把握している)、そして**使い捨てのインスタンスにそのアドレスを固定して本当に使えることを証明する**。

## セキュリティ上の注意

- コンテナは**グローバルな IPv6 アドレス**を持ち、ブリッジ転送のためにホストのファイアウォールは無効です。したがって、コンテナが待ち受けるポートは IPv6 経由でインターネットから到達可能です。
- ホスト自身の IPv6 `/128` も外部から到達できます。`PermitRootLogin yes` は引き渡し時の便宜的な設定です。本番では鍵ログインに切り替えてください。
- コンテナの MAC アドレスが物理回線に出ることはありません(ブリッジはホスト内部にあります)。ポートあたりの MAC 数を制限するプラットフォーム(Hetzner など)でも問題ありません。

## トラブルシューティング

`references/pitfalls.md` に、構築中に実際に遭遇した問題を現象・根本原因・対処の形でまとめています。主なもの:

- NixOS には **`/bin/bash` がなく**、systemd サービスの PATH は最小限です。そのためスクリプトには絶対パスの shebang と `PATH` の明示的な export が必要です
- 切り離して実行する再構築やコンテナ作成は `systemd-run` で起動してください(`setsid nohup` は無言で失敗します)
- 最初の切り替え時に、素の NetworkManager のアドレスがインターフェースに残っていると `incus-preseed` が `Only unconfigured network interfaces can be bridged` で失敗します
- `/etc/resolv.conf` を手で編集した後に出る `resolvconf: signature mismatch`
- 素の設定では flakes が無効なので、最初の再構築は `NIX_CONFIG` で橋渡しします
- ホストの IPv6 アドレスは `incusbr0` 上に置く必要があります(ブリッジポート側だと近隣エントリが解決されません)
- プロファイル由来の NIC は `device set` では変更できず、`device override` が必要です
- preseed にストレージの `size` を書いてはいけません(btrfs は縮小できません)
- 非特権コンテナでは `swapon` ができず、多くのカーネル sysctl も変更できません
- インスタンス削除後の IPv6 `/128` の約 1 時間のリースの名残(リースガードと flush)
- NixOS では `/etc/systemd/system/` に書き込めません

## 検証済みの環境

- NixOS 26.11(unstable)、カーネル 6.18.x、Incus 7.5.1(メインライン、LTS ではない)
- Path A: 素の設定をレンダリング済み設定に置き換え、`nix flake update` + build + switch、その後の**再起動**: failed unit は 0、ホスト IPv4・本来の IPv6 `/128`・プールゲートウェイがすべて `incusbr0` 上、物理 NIC は link-local のみ、IPv4 / IPv6 の外向き通信はどちらも HTTP 200、アロケータの数はインスタンスと一致
- Path B: 作成、ランダムな v4/v6 の固定、コンテナ内初期化(自己テストが `password login self-test: OK` を報告)、スナップショット。**別のマシン**から IPv4 / IPv6 の両方でパスワード SSH ログインに成功し、コンテナ自身も IPv6 で外部に到達。削除後は IPv4 が即座に回収され、IPv6 はリースガードで保護されつつ flush ヘルパーで回収可能
- ストレージプールのオンライン拡張(`incus storage set <pool> size=<N>GiB`)でコンテナのダウンタイムなし(loop ファイルはスパース)

## リポジトリ構成

```
incus-in-nixos/
├── SKILL.md                          # Hermes スキルの入口: 2 つの経路
├── README.md                         # このファイルの英語版(デフォルト)
├── README.ja.md                      # このファイル(日本語)
├── references/
│   ├── parameters.md                 # site.conf の各キーと調べ方
│   ├── path-a-fresh-nixos.md         # Path A の手順書
│   ├── path-b-containers.md          # Path B の手順書
│   ├── pitfalls.md                   # 落とし穴: 現象 / 根本原因 / 対処
│   └── verification-checklist.md     # ホスト / コンテナ / 回収のチェックリスト
├── scripts/
│   ├── probe-host.sh                 # 読み取りのみの環境調査
│   ├── render-site.sh                # site.conf + templates -> 配備用ファイル一式
│   ├── site.conf.example             # パラメータの雛形(プレースホルダのみ)
│   ├── incus-ct-create.sh            # 作成 + 固定 + 初期化 + スナップショット + レポート
│   ├── incus-ct-init.sh              # 初期化ドライバ(パスワード生成/受け取り)
│   ├── incus-ct-init-inner.sh        # コンテナ内の初期化本体(パスワード自己テスト付き)
│   ├── incus-ct-info.sh              # サーバー情報
│   ├── incus-ct-delete.sh            # 削除 + 回収 + 確認
│   └── incus-ct-flush-lease.sh       # 残ったリースを即座に回収
└── templates/
    ├── configuration.nix.tpl         # 宣言的: ネットワーク / プール / プロファイル / systemd
    ├── incus-ipv4-alloc.tpl          # ランダム・一意・回収可能な IPv4 アロケータ(リースガード付き)
    ├── incus-ipv6-alloc.tpl          # ランダム・一意・回収可能な IPv6 アロケータ(リースガード付き)
    ├── incus-pool-autogrow.tpl       # ストレージプールの自動拡張(使用率 80% 超で発動)
    ├── rebuild-detached.sh.tpl       # flake update + build + switch + ネットワークのフォールバック
    ├── fix-first-switch.sh.tpl       # 初回切り替え後の冪等なネットワーク修復
    └── rollback-net.sh.tpl           # コンソール用フォールバック: フラット構成へ戻す
```

## ライセンス

MIT — `LICENSE` を参照してください。
