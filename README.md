# PPC Mac Modernization Project

Bringing 20-year-old PowerPC Macs (iBook G4, PowerMac G4 — Mac OS X Tiger 10.4) into
usable shape on a modern network. A personal, non-commercial project for the PowerPC
Mac community.

Two independent sub-projects live in this repository:

## ⚠️ Before you use this

- **Personal hobby project, provided as-is, no warranty.** Tested only on the
  author's own hardware/network; your mileage may vary.
- **AquaLink's WebDAV NAS server sends passwords as HTTP Basic Auth over plain,
  unencrypted HTTP** (there was no practical alternative on this OS/hardware — see
  [`smb3/README.md`](smb3/README.md) for why). Only use this on a trusted home LAN.
  **Do not expose it to the public internet.**
- `windows-setup/connect-aqualink.bat` modifies Windows registry settings
  (`WebClient` service Basic-auth policy) system-wide to make the above work without
  the user having to touch `regedit` by hand. Review the script before running it.
- These machines run long-unsupported, unpatched operating systems (Tiger/Leopard).
  Treat them as inherently insecure and keep them off untrusted networks regardless
  of what this software does.
- Back up anything important before installing/building on real hardware — some of
  this touches system-level settings (firewall rules, LaunchDaemons) as well as app
  files.

## AquaLink — SMB3 client & WebDAV NAS server for PPC Mac

**[`smb3/AquaLink/`](smb3/AquaLink/)**

A native Cocoa app for Tiger/Leopard PowerPC Macs, built around
[libsmb2](https://github.com/sahlberg/libsmb2) (the only SMB2/3 client library that
still compiles on this hardware — see [`smb3/README.md`](smb3/README.md) for the full
build story).

AquaLink does two things:

- **SMB3 client**: browse and drag-and-drop files to/from a modern SMB3 NAS,
  Windows share, or modern Mac — something no PPC Mac has ever been able to do
  natively, since Apple's own `smbfs.kext` is stuck on SMB1.
- **WebDAV NAS server**: the reverse direction. AquaLink can also expose local
  folders on the PPC Mac as a WebDAV share, so a modern Mac or Windows PC can mount
  them as an ordinary network drive — turning the old Mac itself into a small NAS.
  `smb3/AquaLink/windows-setup/` has a one-click Windows connection script
  (`connect-aqualink.bat`) that takes care of the Windows-side registry tweaks
  required for this to work over plain HTTP.

As far as we know, this is the first working SMB2/3 client for PowerPC Mac OS X.

## Aquafox Japanese localization

**→ [aquafox-japanese-langpack](https://github.com/watermark-hd/aquafox-japanese-langpack)**
(separate repository)

A Japanese (`ja`) locale for [Aquafox](https://tenfourfox.jp/) (the actively
maintained TenFourFox fork for PowerPC Macs), built from Mozilla's official
Firefox 45.9.0esr `ja` langpack plus translations for the ~80 Aquafox/TenFourFox-specific
UI strings not present in stock Firefox. Aquafox ships with de/es-ES/en-US/fi/fr/it/pl/ru/sv-SE
but no Japanese locale — this fills that gap for Japanese-speaking PPC users, for whom
Aquafox is often the only realistic browser left on G3-class hardware. The finished
langpack, install instructions, and full string list live in the dedicated repo linked
above.

## Related resources

- [oldmac.policy-log.jp](https://oldmac.policy-log.jp/) — another software archive/download
  site for classic Mac hardware, worth checking out alongside this repository.
- [Macintosh Garden](https://www.macintoshgarden.org/) and the
  [MacRumors PowerPC Macs forum](https://forums.macrumors.com/) — the usual gathering
  places for this community.
- [AquaFinder](https://github.com/watermark-hd/AquaFinder) — a separate project by the
  same author: a Tiger/Snow Leopard-style Finder skin for *modern* macOS. Unrelated to
  PPC hardware, but built by the same "old Mac look" enthusiasm.

---

# PPC Mac 現代化プロジェクト

20年前の PowerPC Mac(iBook G4、PowerMac G4 — Mac OS X Tiger 10.4)を、現代のネットワーク
環境で実用できるようにする個人プロジェクトです。収益目的ではなく、PPC コミュニティへの
貢献を目的としています。

このリポジトリには独立した2つのサブプロジェクトが入っています。

## ⚠️ 利用前の注意事項

- **個人の趣味プロジェクトであり、無保証で提供しています。** 作者自身のハードウェア・
  ネットワーク環境でのみ動作確認しており、環境によって挙動が異なる可能性があります。
- **AquaLinkのWebDAV NASサーバー機能は、パスワードを暗号化していない平文HTTP上で
  Basic認証として送信します**(このOS・ハードウェアの制約上、現実的な代替手段が
  ありませんでした。詳細は[`smb3/README.md`](smb3/README.md)参照)。**信頼できる
  自宅LAN内でのみ使用してください。インターネットに直接公開しないでください。**
- `windows-setup/connect-aqualink.bat`は、上記を利用者が`regedit`を手作業で触らずに
  済むよう、Windowsのレジストリ設定(`WebClient`サービスのBasic認証ポリシー)を
  システム全体に対して変更します。実行前にスクリプトの中身をご確認ください。
- これらの実機は、長期間サポートが切れた未更新のOS(Tiger/Leopard)で動作しています。
  本ソフトウェアの内容に関わらず、本質的にセキュリティ上のリスクがあるものとして扱い、
  信頼できないネットワークには接続しないでください。
- 実機へのインストール・ビルドの前に、大事なデータのバックアップを取ってください。
  アプリ本体だけでなく、ファイアウォールのルールやLaunchDaemonなど、システムレベルの
  設定にも変更が及ぶ箇所があります。

## AquaLink — PPC Mac 向け SMB3クライアント & WebDAV NASサーバー

**[`smb3/AquaLink/`](smb3/AquaLink/)**

Tiger/Leopard 世代の PowerPC Mac 向けに書かれたネイティブ Cocoa アプリです。
[libsmb2](https://github.com/sahlberg/libsmb2)(この世代のハードでもビルドできる、
唯一と言っていい SMB2/3 クライアントライブラリ。ビルドの詳細は
[`smb3/README.md`](smb3/README.md) 参照)を土台にしています。

AquaLink は2つの機能を持っています。

- **SMB3クライアント**: 現代の SMB3 NAS・Windows共有・現代の Mac の共有フォルダに接続し、
  ドラッグ&ドロップでファイルをやり取りできます。Apple 純正の `smbfs.kext` が SMB1 止まり
  のため、これまで PPC Mac には存在しなかった機能です。
- **WebDAV NASサーバー**: 逆方向の機能です。PPC Mac 側のローカルフォルダを WebDAV 共有として
  公開し、現代の Mac や Windows PC から通常のネットワークドライブとしてマウントできます。
  つまり、古い Mac 自体を小さな NAS にできます。`smb3/AquaLink/windows-setup/` には、
  Windows 側で必要なレジストリ設定を自動化するワンクリック接続スクリプト
  (`connect-aqualink.bat`)を同梱しています。

把握している限り、PowerPC Mac OS X 向けに実際に動作する SMB2/3 クライアントは、これが
世界初の実例です。

## Aquafox 日本語化

**→ [aquafox-japanese-langpack](https://github.com/watermark-hd/aquafox-japanese-langpack)**
(別リポジトリ)

PowerPC Mac 向けに現役開発が続いている TenFourFox のフォーク、[Aquafox](https://tenfourfox.jp/)
用の日本語(`ja`)ロケールです。Firefox 45.9.0esr の公式 `ja` 言語パックをベースに、
Aquafox/TenFourFox 独自に追加された約80件のUI文字列(標準の Firefox 45.9.0esr には無いもの)
を翻訳して統合しています。Aquafox は de/es-ES/en-US/fi/fr/it/pl/ru/sv-SE の9言語のみ用意されて
おり日本語ロケールが存在しなかったため、この空白を埋めるものです。G3世代のハードでは
Aquafox が唯一現実的なブラウザという場面も多く、日本語圏の PPC ユーザーにとっての課題を
解決します。完成版の言語パック・インストール手順・全翻訳文字列は、上記の専用リポジトリに
まとまっています。

## 関連リンク

- [oldmac.policy-log.jp](https://oldmac.policy-log.jp/) — 同じくクラシックMac向けのソフトウェア
  アーカイブ/配布サイトです。あわせてご覧ください。
- [Macintosh Garden](https://www.macintoshgarden.org/) と
  [MacRumors PowerPC Macs 板](https://forums.macrumors.com/) — このコミュニティの定番の
  集まり場所です。
- [AquaFinder](https://github.com/watermark-hd/AquaFinder) — 同じ作者による別プロジェクト。
  *現代の* macOS を Tiger/Snow Leopard 風の見た目にする Finder スキンです。PPC実機とは
  無関係ですが、「懐かしいMacの見た目が好き」という同じ動機から生まれたものです。
