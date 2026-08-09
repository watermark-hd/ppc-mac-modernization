# PPC Mac 現代化プロジェクト — 引き継ぎ

## このプロジェクトについて

20年前の PowerPC Mac（iBook）を、現代のネットワーク環境で実用できるようにする。
2つの独立したタスクがある。

1. **Aquafox の日本語化** — PPC 向けブラウザに日本語ロケールを追加する
2. **SMB3 接続** — 現代の NAS に繋いで Finder にマウントする

収益目的ではない。個人プロジェクトかつ、PPC コミュニティへの貢献。

---

## 依頼者について（重要）

- **非エンジニア。コードは書けない。**
- Python の構造も把握していない
- ターミナルはコピペ操作のみ。**タイプミスが起きやすいと自認している**
- ただし**判断力は高い**。設計上の誤りを何度も正しく指摘している
- 別プロジェクト（Flask + SQLite の Web サイト）を公開まで完遂した実績あり
- **忌憚のないフィードバックを求める。楽観的すぎる見積もりは嫌う**
- 日本語で対応すること

### 作業スタイルの要求

- **ファイルを変更する前に必ず `.bak` を取る。** 20年前のハードで、壊すと復旧が難しい
- 破壊的な操作（削除、上書き、システム設定変更）の前に確認を取る
- 「◯行目」ではなく「この文字列を含む箇所」で場所を指示する
- エラーが出るのは正常。淡々と反復してよい
- 何をやっているか日本語で簡潔に説明する。コードが読めない前提で

---

## 環境

```
[母艦の Mac] ← Claude Code はここで動く
     │ SSH（接続済み・すぐ入れる）
     ▼
[iBook] Mac OS X（PPC）
```

**iBook 上では Claude Code は動かない**（PPC 向け Node.js が存在しない）。
必ず母艦から SSH 越しに操作すること。

### 最初に確認すべき未確定事項

```bash
# iBook 上で実行
sw_vers
system_profiler SPHardwareDataType | head -20
gcc --version | head -1
ls /Developer/Applications 2>/dev/null
```

判明させたいこと:

- **iBook G3 か G4 か** — G3 は Leopard が入らないので Tiger 10.4.11 が上限
- **OS が Tiger (10.4) か Leopard (10.5) か** — 使えるツールチェーンが変わる
- **Xcode のバージョン** — Tiger なら 2.5、Leopard なら 3.1.4。gcc は 4.0.1 か 4.2
- 空きディスク容量、RAM

---

## タスク1: Aquafox の日本語化

### 背景

Aquafox は TenFourFox のフォーク。現在も活発に開発されており、2026年5月に v3.2 がリリース、セキュリティベースは 140 ESR まで更新されている。
ただし **UI は Firefox 45 世代のまま**（セキュリティパッチのバックポートであり、UI の刷新ではない）。

**日本語ロケールが存在しない。** 用意されているのは de / es-ES / en-US / fi / fr / it / pl / ru / sv-SE の9言語のみ。
日本語圏の PPC ユーザーにとって、これが唯一の未解決問題になっている。

### 仕様上の注意

- ロケール切り替えは現代の「言語パック」UI ではなく、**`about:config` の `general.useragent.locale` を直接書き換える方式**（Fx45 世代）
- **現代の Firefox 用 `.xpi` 言語パックは使えない。** APIバージョンが合わず弾かれる

### 手順（想定）

**Step 1. Aquafox のアプリ ID とバージョンを取得**

```bash
cat /Applications/Aquafox.app/Contents/Resources/application.ini
```

`[App]` セクションの `ID=` と `Version=` を確認する。これが全ての起点。

**Step 2. 先に地雷チェック（重要）**

`Contents/Resources/omni.ja`（実体は zip）を展開し、以下を確認:

- `chrome.manifest` に `locale` 行が存在するか
- `chrome/` 配下にロケールリソースが登録されているか

**この系譜のフォーク（InterWebPPC）は「不要と判断したもの」を削って 15MB 軽量化した経緯がある。
削られたものが l10n インフラだった場合、langpack をどう作っても登録されない。**
ここが空振りなら、ビルドからやり直す必要があるので、最初に判定すること。

**Step 3. 土台を用意**

Firefox 45.9.0esr の公式 `ja` langpack を入手し、`install.rdf` の
`<em:targetApplication>` の ID と minVersion / maxVersion を Step 1 の値に書き換える。

**この時点で一度インストールを試す。** 単純なバージョン不一致が原因なら、ここで通る可能性がある。

**Step 4. 差分の翻訳（ここが本番）**

TenFourFox 系は独自の UI 文字列を追加している。Fx45 の ja をそのまま入れると、
不足エンティティのところで XUL が壊れる。

1. Aquafox の `omni.ja` から `en-US` ロケールを抽出
2. Firefox 45 の `en-US` と diff を取る
3. **差分のエントリだけを翻訳対象として抽出する**

想定は数十エントリ程度。

**翻訳の文言は依頼者が決める。**
Claude Code 側は候補を提示してよいが、自然さの最終判断は依頼者に委ねること。
ここは依頼者が最も貢献できる領域なので、勝手に確定させない。

**Step 5. 再パッケージして検証**

`general.useragent.locale` を `ja` に設定し、実機で表示崩れを確認。

### 出口

Aquafox のメンテナ（blackbirdlc）は MacRumors のスレッドで活動しており、フィードバックを募集している。
個人配布より **upstream に投げて公式ビルドに同梱してもらう**ほうが望ましい。
配布先の定番は Macintosh Garden と当該 MacRumors スレッド。

---

## タスク2: SMB3 マウント

### ゴール

現代の NAS（SMB3）の共有を、**iBook の Finder にアイコンとしてマウントし、
ドラッグ&ドロップとコピー&ペーストで操作できる**状態にする。

完璧は求めていない。多少の機能制限は許容される。

### 制約の整理

- Tiger / Leopard の Samba は 3.0.x で **SMB1 (CIFS) のみ**。SMB2/3 は原理的に喋れない
- 現代の NAS / Windows 11 / macOS は SMB1 を既定で無効化または削除済み
- 認証も NTLMv1 で現代サーバに蹴られる
- **Apple の `smbfs.kext` はクローズドソースで SMB1 固定。** ここは変更できない

### やってはいけないこと

**Samba 4 を PPC でビルドしようとしないこと。**

- ビルドシステム（waf）が Python 3.6+ を要求し、PPC への Python 3 移植が独立した大プロジェクトになる
- 仮に成功しても得られるのは `smbclient`（CLI のみ）で、**Finder にはマウントされない**
- 労力と成果が完全に見合わない

### 採用する方針: libsmb2

https://github.com/sahlberg/libsmb2

Samba チームの Ronnie Sahlberg が独立開発している SMB2/3 クライアントライブラリ。

- **依存関係なし**（POSIX libc のみ。Kerberos を使う場合だけ MIT krb5）
- コンパイル後 **約120KB**
- **SMB 3.1.1 対応。** 署名、SMB3 暗号化（sealing）、プリ認証整合性、NTLMSSP
- **暗号実装を内蔵**（OpenSSL 不要 — これが決定的。Leopard の OpenSSL 0.9.7 では足りない）
- CMake / autotools。**Python 不要**
- **PS3 の PPU（PowerPC・ビッグエンディアン）が公式サポート対象。** PS2、Vita、3DS、ESP32 も
- `portable-endian.h` でエンディアン差を明示的に吸収する設計
- LGPLv2.1+

作者本人が「Amiga Kickstart 1.3 でネイティブコンパイルできる」水準の移植性を目標としている。
**gcc 4.0.1 / 4.2 で通る見込みが高い。**

### 段階的に進める

#### A案: ブリッジサーバ（保険 / 即効性あり）

別筐体（Linux / BSD / ラズパイ）に:

- `cifs-utils` で NAS の SMB3 共有をマウント
- **同じディレクトリを Netatalk（AFP）の共有ポイントとして再エクスポート**
- iBook からは AFP で接続 → **Finder に普通にアイコンが出る**

コードはゼロ、設定のみ。Netatalk 4.x は現役開発中（4.5系）。
リソースフォーク対応で、Tiger / Leopard では最速。

**注意: Netatalk は CVE が多い。必ず LAN 内限定にし、インターネットに直接晒さないこと。**

代替として WebDAV（`mount_webdav` は 10.4 標準搭載）も可。平文 HTTP なので TLS 問題が発生しない。

> AFP は macOS 27 でサポート削除予定だが、これは「現代 Mac が AFP クライアントとして繋がらなくなる」話。
> Netatalk が PPC に配る分には無関係。**現代側 SMB3 / 旧側 AFP** の分離設計なら影響を受けない。

#### B案: libsmb2 の実証（次のステップ）

iBook 上で libsmb2 をビルドし、付属のサンプルツールで NAS への SMB3 接続を確認する。

```bash
git clone https://github.com/sahlberg/libsmb2.git
cd libsmb2
./bootstrap        # または cmake
./configure
make
```

**gcc 4 系で古いヘッダ由来の軽微な修正が必要になる可能性がある。**
エラーが出たら潰していく。Samba 4 と違い、ビルドは数分で終わるはずなので反復コストが低い。

**PPC Mac 向けの SMB3 クライアントは現時点で世界に存在しない。**
CLI で接続できただけでも実証として意味があり、報告する価値がある。

#### C案: マウントアプリ（B が動いてから）

libsmb2 を組み込んだ Cocoa アプリ。2段構え。

**第1段: ファイルブラウザ型**
- 自前ウィンドウにファイル一覧（Cyberduck / Transmit 形式）
- `NSPasteboard` のファイルプロミスで Finder と双方向ドラッグ&ドロップ
- kext 不要

**第2段: ローカルループバック（Finder アイコンが出る）**

```
NAS (SMB3) ──libsmb2──> [アプリ内蔵の極小 WebDAV サーバ] ──> 127.0.0.1
                                                              ↓
                                                       mount_webdav
                                                              ↓
                                                    Finder にアイコン
```

`mount_webdav` は Tiger 標準搭載のため、**kext を一切書かずに Finder にボリュームが生える。**
別筐体も不要になる。

想定される難所:
- Apple の WebDAV クライアントは Class 2 ロック（LOCK）を要求する
- `._` リソースフォークファイルを大量生成する
- キャッシュ挙動が読みにくい

ただしサーバ側も自作なので、Apple のクライアントに合わせて実装を寄せられる。

暗号について: SMB3.1.1 の AES-CCM/GCM は G4 にハードウェア支援がなく全てソフト処理だが、
100Mbit イーサの帯域は超えるためボトルネックにならない。気になるなら `seal` を無効にして署名のみでも可。

### 実装環境

- Tiger → Xcode 2.5、Leopard → Xcode 3.1.4
- `NSJSONSerialization` は 10.7 以降。**10.4/10.5 には存在しない**
- 一般原則として、**重い処理はサーバ側でやり、PPC 側には整形済みのデータだけ渡す**

---

## 進行順の推奨

1. 環境情報の取得（上記コマンド）
2. Aquafox の `application.ini` と `omni.ja` の地雷チェック → 日本語化
3. libsmb2 のビルドが通るかだけ確認
4. 結果を見て C案の設計へ

**A案（ブリッジサーバ）と B案（libsmb2）は競合しない。**
A で実用を確保しつつ、B を実験として進めるのが合理的。

---

## 補足

- PPC コミュニティの中心は MacRumors の PowerPC Macs 板
- 2026年は PowerFox（新規ブラウザ）、PowerVLC など新規プロジェクトが出ており、むしろ再活性化フェーズにある
- PowerFox は Leopard + G4/G5 以上が要件のため、**iBook G3 / Tiger の場合は Aquafox が唯一の選択肢**になる
