# libsmb2 on iBook G4 (Tiger 10.4.11) — ビルド記録

## 結果

**成功。** iBook G4 (PowerPC, Mac OS X 10.4.11) から、母艦 Mac(現代の macOS, SMB3対応)
の共有フォルダに `smb2-ls` で接続し、日本語ファイル名を含むディレクトリ一覧を取得できた。
`?vers=3` を明示指定しても成功しており、SMB3 での接続を確認済み。

これは CLAUDE.md に記載の通り、世界的にもまだ実証例が少ない「PPC Mac 向け SMB3 クライアント」
の動作実績にあたる。

## 再現手順

### 1. 母艦でソース取得・configure生成

```bash
git clone --depth 1 https://github.com/sahlberg/libsmb2.git
cd libsmb2
git apply /path/to/libsmb2_tiger_ppc.patch                  # 本ディレクトリのパッチを適用
git apply /path/to/libsmb2-ppc-sessionid-endian-fix.patch    # 同上、SMB3暗号化を使うなら必須
LIBTOOLIZE=glibtoolize ./bootstrap            # 母艦(Homebrew)にautomake/libtoolが必要
```

`libsmb2_tiger_ppc.patch`の内容: `configure.ac` に `CommonCrypto/CommonCrypto.h` の有無チェックを追加し、
`lib/aes.c` / `lib/aes_apple.c` の `#ifdef __APPLE__` 判定を
`#if defined(__APPLE__) && defined(HAVE_COMMONCRYPTO_COMMONCRYPTO_H)` に変更。
Tiger の SDK には CommonCrypto フレームワークが無いため、素の `#ifdef __APPLE__` だけでは
誤ってCommonCrypto版のAES実装を選んでしまいビルドが失敗する。

`libsmb2-ppc-sessionid-endian-fix.patch`の内容: **ビッグエンディアン環境でSMB3暗号化
(`smb2_set_seal`)を使うと接続が必ず失敗する、libsmb2側のバグの修正。** 詳細・経緯は
本READMEの「SMB3暗号化の必須化オプション」の節、および
[upstream Issue #477](https://github.com/sahlberg/libsmb2/issues/477)を参照。
SMB3暗号化機能を使わない(接続画面のチェックボックスを入れない)なら無くても動くが、
将来公式の修正版がリリースされるまでは当てておくことを推奨。

### 2. iBookに転送してビルド

```bash
rsync -a --exclude='.git' ./ ibook:~/libsmb2/
ssh ibook 'cd ~/libsmb2 && find . -exec touch {} \;'   # rsyncの日時ズレ対策
ssh ibook 'cd ~/libsmb2 && ./configure --disable-werror --without-libkrb5 && make'
```

- `--disable-werror`: 古い gcc 4.0.0 が `-Wshadow` を今の gcc より広範囲に警告するため、
  `-Werror` のままだと大量の shadowed declaration warning がエラー扱いになりビルドが止まる。
  実害のあるバグではないので無効化。
- `--without-libkrb5`: Tiger には Apple の `GSS.framework`(`GSS/GSS.h`)や `krb5/krb5.h` が
  無く、Kerberos対応を有効にするとヘッダ不足でビルドが止まる。内蔵の NTLMSSP 認証を使う
  設定にすることで回避。個人のNAS接続用途ならNTLMSSPで十分。

### 3. 動作確認(認証情報の渡し方)

`smb2-ls`/`smb2-cp` はURLにパスワードを含められない。`NTLM_USER_FILE` 環境変数で
`ドメイン:ユーザー名:パスワード` 形式のファイルを指定する(ドメイン欄は空でワイルドカード)。

```bash
export DYLD_LIBRARY_PATH=~/libsmb2/lib/.libs   # make installしていない場合
export NTLM_USER_FILE=~/.smb2_ntlm
~/libsmb2/utils/.libs/smb2-ls "smb://ユーザー名@サーバーIP/共有名?vers=3"
```

パスワードファイルはテスト後に必ず削除すること。

## C案 第1段: AquaLink.app ✅ 完了

`AquaLink/` にソース一式。libsmb2 を静的リンクした自己完結の Cocoa アプリ(nib不要、
プログラムでUI構築)。iBook 実機で以下すべて動作確認済み:

- smb3:// URL + パスワードでの接続(NTLMSSP認証)
- ディレクトリ一覧表示(日本語ファイル名を含め文字化けなし)
- ダブルクリックでの移動、「上へ」での親ディレクトリ移動
- **ドラッグ&ドロップでのダウンロード**(AquaLink → Finder。ファイルプロミス方式)
- **ドラッグ&ドロップでのアップロード**(Finder → AquaLink)

### ビルド方法

```bash
rsync -a AquaLink/ ibook:~/developer/AquaLink/
ssh ibook 'cd ~/developer/AquaLink && make'
open ~/developer/AquaLink/AquaLink.app   # または実機でダブルクリック
```

`libsmb2.a`(静的ライブラリ)を直接リンクしているため、`make install` は不要。
`$HOME/developer/libsmb2` にビルド済みの libsmb2 ソースツリーがある前提
(iBook側の開発系フォルダは `~/developer/` 配下にまとめてある。旧パス`~/libsmb2`/`~/AquaLink`
参照は移行済み)。

**PPCPorts経由でlibsmb2を入れている場合(この前提が無い場合)**: `git clone`して
そのまま`make`すると、`AppDelegate.h:3: error: smb2/smb2.h: No such file`のように
ヘッダーが見つからず失敗する(実際にMacRumorsで報告された不具合)。`LIBSMB2_DIR`に
PPCPortsのインストール先を渡せばよい。

```bash
sudo port install libsmb2
make LIBSMB2_DIR=/opt/local   # PPCPortsのインストール先(通常このパス)
```

`LIBSMB2_DIR`を1つ指定するだけで、静的ライブラリ(`.a`)・動的ライブラリ(`.dylib`)の
どちらがインストールされていても自動で見つける(Makefile側で対応済み)。

### ハマった点

- **日本語文字化け**: 古い gcc(4.0.0)の Objective-C コンパイラが `@"日本語"` 形式の
  文字列リテラルを正しく解釈しないことがある。`[NSString stringWithUTF8String:"日本語"]`
  （Cの生バイト列からUTF-8として明示デコード）に置き換えて解決。`AppDelegate.m` 冒頭の
  `UTF8(cstr)` マクロ参照。
- **ドラッグ&ドロップのダウンロードが無反応**: `NSPasteboard` 汎用の
  `-namesOfPromisedFilesDroppedAtDestination:` ではなく、`NSTableView` 専用の
  `-tableView:namesOfPromisedFilesDroppedAtDestination:forDraggedRowsWithIndexes:`
  を実装する必要があった(`NSTableView.h` に明記されている、Tiger時代からのAPI)。
- **`errno:9`ソケットエラー**: パスワード未入力(空パスワード=ゲスト接続扱い)で発生。
  macOSのファイル共有はデフォルトでゲスト接続を許可しないため、正しいパスワードが必須。

### 使い勝手の改善(依頼者フィードバックにより追加)

- **接続履歴**: `NSComboBox` にURL欄を変更。入力もでき、ドロップダウンから過去の接続先
  (最大10件、`NSUserDefaults` に保存。パスワードは保存しない)も選べる。
  当初 `NSPopUpButton`(プルダウンメニュー)で実装したが、小さいボタン幅のせいか
  項目の文字が読み取れない不具合が発生したため、Safariのアドレスバーに近い
  `NSComboBox` に置き換えて解決。データソースAPIは `numberOfItemsInComboBox:` /
  `comboBox:objectValueForItemAtIndex:`(いずれも `int` 版。Tigerは`NSInteger`以前)。
- **パスワード欄のプレースホルダー**: 何を入力する欄か分かりにくいとの指摘を受け、
  `[[passwordField cell] setPlaceholderString:...]` で薄く「パスワード」と表示するようにした。
  `NSTextFieldCell` の `setPlaceholderString:` は Tiger の時点で既に存在する。

## C案 第2段: WebDAVループバックでFinderマウント ✅ 完了

`WebDAVServer.h/.m` に実装。AquaLink 内蔵の極小 HTTP/WebDAV サーバー(生の BSD ソケット、
OPTIONS/PROPFIND/GET/HEAD/PUT/DELETE/MKCOL/LOCK/UNLOCK に対応)を 127.0.0.1 の適当なポートで
立ち上げ、`mount_webdav` でそこに接続することで Finder に通常のボリュームとして表示させる。

iBook 実機で確認済み:
- 「Finderに接続」ボタンで `/Volumes/<共有名>` にマウントされ、**デスクトップにアイコンが出る**
- Finder 上で直接ドラッグ&ドロップでコピーできる(AquaLink を介さない、普通のボリュームとして機能)
- 「取り外す」で正常にアンマウントできる

これで CLAUDE.md タスク2の当初ゴール(「NASをiBookのFinderにアイコンとしてマウントし、
ドラッグ&ドロップとコピー&ペーストで操作できる」)を完全に達成。自己完結(別筐体不要)。

### ハマった点(第2段)

- **`-fobjc-exceptions` が必要**: `@try`/`@catch` を使うと、このバージョンの gcc では
  明示的に `-fobjc-exceptions` を CFLAGS に追加しないと警告が出て正しくコンパイルされない。
- **`NSData -rangeOfData:options:range:` が使えない**: Snow Leopard(10.6)以降のAPIなので
  Tiger では自前のバイト列検索関数(`FindBytes`)が必要だった。HTTPリクエストのヘッダ終端
  (`\r\n\r\n`)検出に使用。
- **[重大] 取り外し失敗時にサーバーを止めてOSと状態不整合を起こした**:
  「取り外す」ボタンで `diskutil unmount` の成否を確認せずに WebDAV サーバーを停止していたら、
  取り外しが実際には失敗(またはハング)していたケースで「OSはマウント中と思っているのに
  応答するサーバーが無い」壊れたマウントが発生。結果、iBook の `/Volumes` へのアクセス全体が
  ハングする実害が出た。**復旧には `umount -f` も効かず、該当ポートに何かHTTP応答を返す
  プロセスを一時的に立てて初めて詰まりが解消した**(kernel側が保留中の応答を待ち続けていたと
  推測)。教訓: OSレベルの状態を変更するコマンドは、成否を確認してから次の後始末をすること。
  修正後は `diskutil unmount` ではなく `umount`(失敗時は `-f` で再試行)を使い、
  成功を確認できた場合のみサーバーを停止するようにした。
- **デスクトップにアイコンが出ない**: マウント自体は成功していても、Finder環境設定の
  「一般」→「デスクトップに表示する項目」→「接続中のサーバ」がオフだと見た目に現れない。
  `/Volumes` を直接開けば確認できる。今回はこの設定が過去にコマンドでオフにされていたのが原因だった。
- **[MacRumorsで報告された不具合・未解決/既知の制限として決着] 一部環境で `umount` が
  権限不足で失敗する**:
  非公式パッチ当ての10.6.8(Snow Leopard) PPCイメージ利用者から、「取り外す」が常に
  失敗するという報告(2026-08-22)。実機で `umount` (sudo無し)を手動実行してもらったところ
  `Operation not permitted` で失敗し、`sudo umount` なら成功することを確認。原因は
  `mount_webdav` がsetuid rootで動作するため、マウント自体がroot所有として扱われ、
  一般ユーザー権限では取り外せなくなっていたこと(この環境は別途 `mount_webdav` 自身の
  setuidビットが失われる不具合も抱えていた個体だった。両者は別の症状)。

  対策として、通常の`umount`→`umount -f`が両方失敗した場合の最終手段を2種類試した。
  1つ目は`NSAppleScript`の`do shell script ... with administrator privileges`(`runPrivilegedUnmount:`)。
  これでもまだ`Operation not permitted`が再現。2つ目として、AppleScriptを経由しない
  より低レベルな`AuthorizationExecuteWithPrivileges`(Security.framework)に切り替えたが、
  **これでも症状は変わらず**。

  `umount(2)`は本物のroot権限であれば無条件で成功するはずのシステムコールであり、
  2種類の異なるAPI(どちらも最終的にはSecurityAgent/認証データベースを経由する)が
  両方とも同じ失敗をすることから、**このパッチ当てイメージのGUI認証まわりの仕組み自体が
  壊れていて、アプリ側の実装をどう変えても直せない可能性が高い**と判断した。
  一方でターミナルの`sudo`(GUI認証を経由しない別系統の仕組み)は一貫して成功している。

  代替案として、FUSE(ユーザー権限のままマウント・取り外しができ、この種の問題が
  原理的に起きない)も検討したが、**後継プロジェクト(OSXFUSE→現macFUSE、2010年以降)は
  Tigerを切り捨てている**ため見送った(PowerPC対応自体も2011年頃には打ち切られている)。

  [訂正・2026-08-26] 上記は不正確だった。**Google製の初代MacFUSE(2008年頃、
  バージョン1.7.0)には実はTiger(10.4)専用ビルドが存在する**(`exFAT for Tiger
  (PowerPC)`プロジェクトで実際に動作実績あり: https://github.com/watermark-hd/exfat-tiger-ppc )。
  ただし公式配布は2012年に停止しており、Wayback Machine経由でしか入手できない
  野良ビルドである点は変わらず、この判断(AquaLinkでは見送り)自体は維持する。

  **最終結論: この特定の(非公式パッチ当て)環境については既知の制限として受け入れる。**
  GUI経由の「取り外す」が失敗した場合は、ターミナルで`sudo umount -f /Volumes/共有名`を
  手動実行するのが確実な回避策。Tiger/Leopard/未改造のSnow Leopardなど、通常の環境では
  この問題は起きていない(これまでの実機検証・報告いずれも通常環境では成功している)。

## iBookをNAS化する(逆方向: 現代機 → iBook) ✅ 完了

`LocalWebDAVServer.h/.m` に実装。当初のCLAUDE.mdスコープには無かったが、依頼者の実要件
(iBookに入っている古いRAW写真を現代のMac/Windowsから直接参照・編集したい)を受けて追加。

これまでの「iBookが外部のNASに繋ぎに行く」(libsmb2クライアント)とは逆方向。
`WebDAVServer`(NASへのループバック接続用)を土台に、libsmb2呼び出しをPOSIXのファイルI/O
(`open`/`read`/`write`/`opendir`等)に置き換え、`127.0.0.1`限定ではなく`INADDR_ANY`で
LAN上の他機器からも接続できるようにし、Basic認証とパストラバーサル(`../`)対策を追加した。

**⚠️ セキュリティ上の注意(LAN限定で使うこと):** この機能はTLSを使わず、**平文HTTP上で
Basic認証**を行っている(Tiger標準の古いOpenSSLではTLS1.2以降がまともに使えず、それを
避けるための意図的な設計判断)。つまりパスワードは暗号化されずにネットワーク上を流れる。
**信頼できる自宅LANの中だけで使うことを強く前提としており、ルーターのポート開放等で
インターネットから直接アクセスできる状態にしてはいけない。** Hackadayの記事([Native
SMB3 Client Brings Modern NAS Access To 20-Year-Old PowerPC Macs](https://hackaday.com/2026/08/25/native-smb3-client-brings-modern-nas-access-to-20-year-old-powerpc-macs/))
のコメント欄で指摘を受け、2026-08-25にこの注意書きを追加した。

AquaLinkのメインウィンドウに「このMacを共有(NAS化)...」ボタンがあり、共有フォルダ・
ユーザー名・パスワード・ポートを設定して開始する。実機で以下を確認済み:

- `curl` での認証・PROPFIND一覧・GET・PUT・DELETE・パストラバーサル拒否
- macOS Finder(現代のMacBook Air)からの実際のマウント・ブラウズ・ダウンロード

### 機能追加: 複数フォルダ共有 + 自動再開(依頼者フィードバックにより追加)

- **複数フォルダ共有**: `LocalWebDAVServer` を単一`rootPath`から`shares`辞書
  ( `{共有名: ローカルパス}` )に変更。ルート(`/`)へのPROPFINDは各共有名を仮想サブフォルダ
  として一覧表示し(`handlePROPFINDRoot:`)、`/共有名/以下のパス`を実際のローカルパスに
  解決する(`localPathForWebDAVPath:`が先頭1階層を共有名として扱う)。市販NASの
  「複数共有フォルダ」に近い挙動になった。
- **フォルダ一覧UI**: `NSTableView`で共有フォルダ(名前・パス)を一覧表示し、「+」でフォルダ
  選択(複数選択可、フォルダ名の重複は自動で連番を付けて回避)、「-」で削除。
- **再起動しても自動的に共有を再開**: フォルダ一覧・ユーザー名・ポートは`NSUserDefaults`に、
  パスワードは平文で残さないよう**キーチェーン**(`SecKeychainAddGenericPassword`/
  `SecKeychainFindGenericPassword`/`SecKeychainItemModifyContent`、Tiger時点で既存のAPI)
  に保存し、`applicationDidFinishLaunching:`の最後で`autoStartSharingIfConfigured`を呼んで
  自動的に共有を開始する。ウィンドウを開かなくても機能するよう、UIフィールドとは別に
  `shareUser`/`sharePassword`/`sharePortValue`のivarを設定の実体として持たせ、ウィンドウは
  それらを表示するだけの薄いビューにした。

### ハマった点

- **[未解決] 手作りメニューバーのプルダウンが開かない**: メニューをクリックしても
  ハイライトしたまま何も表示されない/隣の項目の内容がずれて浮遊表示される、という不具合が
  最後まで解決しなかった。試した仮説と結果:
  - サブメニュー未接続のまま`setMainMenu:`していた説 → 順序を直しても再現
  - `NSApplication`が`mainMenu`をretainしない説 → 強参照を保持しても再現
  - Quitの`nil`ターゲットでのレスポンダーチェイン探索がハングする説 → 明示ターゲットにしても再現
  - メニュー項目が重複している説 → 実際にダンプして確認したところ**構造は完全に正しく重複なし**
  - タイトル確定前に`setMainMenu:`していた説 → 順序を直しても再現
  - 2個目のメニューを追加すると別のメニューとして正しく振る舞うか → スクリーンショットで確認したところ、
    2個目は通常のメニューバー項目としてではなく、**独立した小さな浮遊ボックスとして異常な位置に表示**された

  メニューのデータ構造そのものは正しいことが確認できているため、この古いTiger環境固有の
  WindowServer描画バグである可能性が高いと判断し、原因究明を断念した。
  **教訓: 確実性を優先するなら、メニューに頼らずウィンドウ内にボタンを置く方が古い環境では無難。**
  最終的にはメインウィンドウ内の「iBookを共有(NAS化)...」ボタンから同じ画面を開ける形で回避した。
- **「これ以上のユーザーはアクセスできません」等、Finderの分かりにくい認証エラー**:
  実際の原因は認証情報の入力ミス(IMEオンのまま入力し、変換途中の文字列が送信された)
  だったが、macOSのWebDAV接続エラーはこの手の失敗を「サーバへの接続で問題が発生しました」
  「これ以上のユーザーはアクセスできません」など、実態と無関係に見える汎用メッセージで
  表示することがある。`curl`や`mount_webdav -i`で直接テストすると、サーバー側の応答自体は
  正常であることが早期に切り分けられる。原因究明には、サーバー側に受信リクエストの
  デバッグログ(メソッド・パス・Authorizationヘッダの有無)を一時的に仕込むのが最も確実だった。

## 正式名称「AquaLink」への改名とアイコン作成

作業用の仮称「NASBrowser」から、Aquafoxとの統一感を持たせた「AquaLink」に改名した
(ディレクトリ名・アプリ名・`Info.plist`・ウィンドウタイトル・`NSUserDefaults`キー等を全て変更)。

あわせてアイコンも作成したが、**Tiger互換の`.icns`作成が今回で一番の難所**だった。

### ハマった点(アイコン作成)

- **`iconutil`で作った`.icns`はTigerで開けない**: 現代の`iconutil`は既定でPNGベースの
  新しいアイコン表現(`ic07`〜`ic14`等)しか書き出さない。Tiger(10.4)はこれらを一切理解できず、
  Finderで「ファイルが開けませんでした」となる。Tiger時代の`.icns`は生ビットマップ形式の
  レガシーチャンク(`is32`/`il32`/`it32` = 24bit RGB、`s8mk`/`l8mk`/`t8mk` = 8bitマスク、
  それぞれ16x16/32x32/128x128)が必要で、これらは自分で組み立てるしかなかった
  (`png2icns`等の定番ツールも見当たらず、ImageMagickの`.icns`書き出しも試したが
  期待通りには動かなかった)。
- **[重大] PackBits(RLE24)の制御バイトの意味を思い込みで間違えていた**: `is32`/`il32`/`it32`は
  各チャンネル(R/G/B、interleaved ではなく **planar**: 全R→全G→全B の順)を個別にPackBits圧縮した
  ものだが、当初「制御バイト`n`が128超なら繰り返し長`257-n`」という誤った式で実装していた。
  自分で書いたエンコーダ/デコーダのペアで往復検証(round-trip)しても一致してしまうため、
  **この種のバグは自己検証だけでは絶対に見つからない**。実機(Tiger)で「白い角丸にノイズ」という
  形で症状が出たため、`libicns`(実績のあるOSSライブラリ)のソースを直接調べたところ、
  正しい式は「制御バイト`n`が128以上(高位ビットが立っている)なら繰り返し長は`n-125`
  (3〜130の範囲)」だった。加えて、Aquafox自身のアイコン(`firefox.icns`、実機で表示実績あり)を
  実際にこの正しい式でデコードして絵が復元できることまで確認してから、自分のエンコーダを
  同じ式に直した。**教訓: 独自フォーマットの自己検証(round-trip)は「自分の思い込みと矛盾しない」
  ことしか証明しない。実在する「正解」のファイルを外部の実装/資料で解読できて初めて検証になる。**
- **`it32`だけ先頭に4バイトのゼロパディングが入る**: 128x128サイズ特有の歴史的な仕様
  (`libicns`のコメントいわく「理由は不明だがよくある」)。他のサイズには無い。
- **Finderのアイコンキャッシュ**: 正しい`.icns`に差し替えた後も、Dockには反映されても
  Finder上の表示だけ古いまま(または汎用の書類アイコン)ということがあった。`killall Finder`で解消。

## SMB3暗号化の必須化オプション ✅ 解決(libsmb2側のビッグエンディアン不具合と判明)

Hackadayでの記事掲載(2026-08-25)のコメント欄で「暗号化されたSMB3シェアに対応していない」と
指摘されたのを受けて追加。接続画面に「SMB3暗号化を必須にする」チェックボックスを追加し、
`smb2_set_seal(ctx, 1)`を呼ぶようにした(デフォルトはオフ、今まで通りの挙動)。

### 調査の経緯

チェックを入れて接続すると、macOS標準のSMB共有(自宅LAN内、現代のMac)に対して
`POLLHUP, socket error`で毎回失敗した。チェックを外せば同じ共有に問題なく繋がる。

- libsmb2の`smb2_set_seal()`には既知の設計不整合(GitHub issue #465/#466、2026-07-17に
  修正)があったため、修正後のコミットからlibsmb2をビルドし直して検証したが、**症状は
  変わらなかった**(この不具合が原因ではないと判明)
- 実機で`tcpdump`によるパケットキャプチャを取得(依頼者が実機で`sudo`を対話実行)し、
  Wireshark等が無い環境のため`tcpdump -X`の生バイト列を手動で解読した
- **macOSだけでなくWindows 11の標準SMB共有に対しても、全く同じ場所(認証成功直後、
  暗号化パケット送信直後)で失敗する**ことを確認。Windowsは`RST`、macOSは`FIN`と
  切断のされ方は違うが、発生箇所は同一
- Apple・Microsoftという別々の実装が同じ箇所で拒否している = **サーバー側ではなく
  クライアント(libsmb2)が送る暗号化パケット自体が壊れている**と判断

### 根本原因

`lib/smb3-seal.c`の`smb3_encrypt_pdu()`内、SMB3暗号化ヘッダーの`SessionId`フィールドの
書き込み処理が、他のフィールド(`OriginalMessageSize`や`EncryptionAlgorithm`)は
`htole32`/`htole16`で明示的にlittle-endianへ変換しているのに、**`session_id`だけ
変換せず生の`memcpy`をしていた**。

```c
memcpy(&pdu->crypt[44], &smb2->session_id, 8);  // 修正前: エンディアン変換なし
```

`smb2->session_id`はライブラリの他の箇所(`smb2_set_uint64`/`smb2_get_uint64`)の作法通り
ホストのバイト順で保持されている値なので、通信線に流す際はlittle-endianへの変換が必須。
**x86/ARMはネイティブでlittle-endianのため、この変換漏れがあっても偶然正しく動いてしまい、
表面化しない。** PowerPC(ビッグエンディアン)でSMB3暗号化を使って初めて、SessionIdが
バイト逆順の意味不明な値になり、サーバー側が「不正なセッションからのパケット」として
即座に接続を切っていた。v6.0.0(タグ)・master(2026-08時点)の両方に存在することを確認済み。

### 修正

```c
*(uint64_t *)(void *)&pdu->crypt[44] = htole64(smb2->session_id);
```

(当初は`{ uint64_t sid_le = ...; memcpy(...); }`という形で書いていたが、
[Issue #477](https://github.com/sahlberg/libsmb2/issues/477)でsahlberg氏本人から
「スコープのためだけの波括弧は好みではない」とスタイルの指摘を受け、上記の形に修正した。)

パッチは`smb3/libsmb2-ppc-sessionid-endian-fix.patch`に保存済み。実機のiBookで
libsmb2(v6.0.0ベース)にこのパッチを適用してビルドし直し、**macOS・Windows 11の
両方の標準SMB共有に対して、暗号化必須モードでの接続が成功することを実機で確認済み**。

**進捗:**
- ✅ libsmb2の作者(sahlberg氏)へGitHub Issueとして報告
  ([#477](https://github.com/sahlberg/libsmb2/issues/477))。作者本人からバグ自体は
  認められ、PRとして送るよう依頼された
- ✅ 修正PRを送付済み・**マージ済み**:
  [sahlberg/libsmb2#478](https://github.com/sahlberg/libsmb2/pull/478)
- ✅ AquaLink本体のPPCPortsポート化: [macos-powerpc/powerpc-ports#232](https://github.com/macos-powerpc/powerpc-ports/pull/232)、**マージ済み**
- PPCPortsの`devel/libsmb2` Portfileにこのパッチを追加するPR
  ([#236](https://github.com/macos-powerpc/powerpc-ports/pull/236))も送付したが、
  barracuda156氏が気づかないうちに同内容を直接コミット
  (`8b844c5`)していたため、#236はクローズ。結果として同じ修正がPPCPorts側にも反映済み

### `aqualink` Portfileのバージョン追従

PPCPortsの`aqua/aqualink` Portfileは、AquaLink本体のバージョンアップに追従して
都度バージョンを上げる必要がある(自動化されていない)。抜けると、ポート経由で
ビルドしたユーザーが古いバージョンのまま新機能を使えない、という形で表面化する。

- v0.3のままv0.4(SMB3暗号化オプション)がリリースされたことにbarracuda156氏が気づき、
  「0.4に上げよう」と提案
- ✅ [macos-powerpc/powerpc-ports#237](https://github.com/macos-powerpc/powerpc-ports/pull/237)
  でv0.4へ追従済み
- ✅ v0.5へ追従: [macos-powerpc/powerpc-ports#238](https://github.com/macos-powerpc/powerpc-ports/pull/238)、マージ済み
- v0.5のMakefile回帰(下記)を受けてv0.5.1へ追従するPRを送付
  ([macos-powerpc/powerpc-ports#241](https://github.com/macos-powerpc/powerpc-ports/pull/241))、
  マージ前にv0.5.1側のSMB2_SEC_NTLMSSP不具合(下記)も見つかったため、
  同PRをv0.5.2へ更新。✅ マージ済み
- ✅ v0.5.3(エラーメッセージのUI表示不具合、下記)へ追従:
  [macos-powerpc/powerpc-ports#255](https://github.com/macos-powerpc/powerpc-ports/pull/255)、マージ済み
- ✅ v0.5.4(フェーズA UI修正、下記)へ追従:
  [macos-powerpc/powerpc-ports#267](https://github.com/macos-powerpc/powerpc-ports/pull/267)、マージ済み(barracuda156氏が承認・マージ)

## 接続失敗「gss_acquire_cred: 不正な名前」✅ 解決(v0.5)

saxfun氏が、PPCPorts経由でビルドしたv0.4のAquaLinkから自宅NASへ接続しようとした際に
報告。ビルド自体は成功するが、接続時に以下のエラーで毎回失敗する:

```
Connection failed: gss_acquire_cred: (Ein ungültiger Name wurde übergeben.,
SPNEGO kann keine Mechanismen zum Aushandeln finden.)
```

(ドイツ語ロケール。意訳: 「不正な名前が渡されました」「SPNEGOが交渉可能な
メカニズムを見つけられません」)

### 根本原因

libsmb2の認証方式は`smb2_set_authentication()`を呼ばない限りデフォルトで
`SMB2_SEC_UNDEFINED`(「Kerberosが使えるならKerberos、ダメならNTLM」)になっている。

PPCPortsの`devel/libsmb2` Portfileは`default_variants +gssapi`、つまり
**Kerberos/GSSAPIサポート付きでビルドされる**。GSS.framework自体はLeopard以降の
標準フレームワークなので、saxfun氏の環境ではこれが「使える」と判定され、
`smb2_connect_share()`がまずKerberos経由の認証を試みる。

ところが自宅NAS相手にはKerberosの領域(realm)もKDCも存在しない。この状態で
`gss_acquire_cred()`を呼ぶと、渡されたユーザー名がKerberosプリンシパルとして
不正だとしてエラーになり、**SPNEGOがNTLMへフォールバックせず、接続全体が
失敗する**。x86/ARM向けにKerberosサポート無しでビルドされることが多い他の
libsmb2利用環境では表面化しにくく、PPCPorts経由でKerberosサポート込みでビルドする
という組み合わせで初めて顕在化した。

### 修正

AquaLinkが接続する先はほぼ全て家庭用NAS・Windowsのワークグループ共有であり、
Active Directoryドメイン環境を意図的に使うケースは想定していない。そのため
接続時に明示的にNTLM認証を指定し、そもそもKerberos経路に入らないようにした:

```objc
smb2_set_authentication(ctx, SMB2_SEC_NTLMSSP);
```

実機のiBookで再ビルドし、コンパイルが通ることを確認済み(接続確認はsaxfun氏の
環境での再テスト待ち)。

### v0.5→v0.5.1: 上のMakefile変更がLeopard/Snow Leopardのビルドを壊していた

v0.5のこのfixと同時に、Makefileに`-isysroot /Developer/SDKs/MacOSX10.4u.sdk`への
フォールバックを入れた。手元のiBookでOSアップデート後か何かのタイミングで
システム側(`/System/Library/Frameworks`)のCocoaヘッダーが消えており、
`Cocoa/Cocoa.h: No such file or directory`でビルドが通らなくなっていたための
対処だったが、条件を「10.4u SDKが`/Developer/SDKs`に**存在すれば**使う」に
してしまっていた。

これが、Leopard/Snow Leopard上でシステム側のヘッダーが正常に揃っている環境でも
無条件にSDKを掴んでしまう回帰バグになっていた。saxfun氏の環境(おそらくSnow
Leopard)で`stdarg.h`/`float.h`が見つからないというビルドエラーとして表面化した。

修正: 判定条件を「システム側の`Cocoa.h`が実際に見つからない場合に限って」
SDKへフォールバックするよう変更(`ifeq ($(wildcard .../Cocoa.h),)`)。
saxfun氏が最初にビルドできていた(`-isysroot`無しの素の`cc`)状態に戻しつつ、
iBookでヘッダーが消えていた問題への対処も両立できる。

### v0.5.1→v0.5.2: `SMB2_SEC_NTLMSSP`がタグ付きリリースの公開ヘッダに無かった

v0.5.1の修正でビルドは通るようになったが、saxfun氏の環境(PPCPortsの
`libsmb2-6.2`)では今度は`AppDelegate.m:687: error: 'SMB2_SEC_NTLMSSP'
undeclared`でコンパイル自体が失敗した。

**原因はlibsmb2本体側の未リリースの穴だった。** `smb2_set_authentication()`
関数自体はタグ付きリリース(`libsmb2-6.2`含む)の公開ヘッダ`libsmb2.h`に
宣言されているが、その引数に渡す`enum smb2_sec`(`SMB2_SEC_NTLMSSP`等)の
定義は非公開ヘッダ`libsmb2-private.h`にしかない。この`enum`が公開ヘッダへ
移動したのはmaster上のコミット`fbe9674`(2024-12)だが、**2026-08時点で
どのタグ付きリリースにもまだ含まれていない**。私自身の実機検証はmasterから
直接ビルドしたlibsmb2で行っていたため、この穴に気づけなかった
(タグ付きリリースを使う環境全てで同じエラーになるはず)。

値自体は2019年の導入(`a148a80`)以来一度も変わっていない安定したABI
(`SMB2_SEC_UNDEFINED=0, SMB2_SEC_NTLMSSP=1, SMB2_SEC_KRB5=2`)なので、
`AppDelegate.h`側で`#ifndef SMB2_SEC_NTLMSSP`ガード付きの互換定義を追加した。
masterベースでビルドした場合(本家の定義が既にある)は何もせず本家を優先し、
タグ付きリリースの場合のみこちらの定義が使われる。

### v0.5.3: エラーメッセージの詳細行がUIで表示されていなかった

v0.5.2でビルドが通り、実際に接続を試みたsaxfun氏から「Connection failed:
The username or password appears to be incorrect.」という認証失敗の報告が
届いた。かつ「このシェアは今週の変更前は繋がっていた」という、本物の
regressionを示唆する情報も。原因調査のため、詳細な内部エラー文言
(`FriendlyConnectError()`が組み立てる「\n(Details: %@)」の2行目)を
見せてもらうよう依頼したところ、**「2行目が存在しない」との回答**。

**原因はUI側のバグだった。** 接続失敗時のメッセージを表示する`statusLabel`は
高さ18pxの1行専用`NSTextField`で、`\n`を含む複数行のメッセージを設定しても、
2行目は単純に画面上へ現れない(切り詰められるのではなく、丸ごと見えなくなる)。
コード側は詳細情報を正しく組み立てて渡していたが、UIがそれを表示できて
いなかった。診断に必要な情報がそもそもユーザー側に届かない状態だったため、
saxfun氏の報告だけでは根本原因を特定できずにいた。

修正: `connectFailed:`で`NSAlert`のモーダルダイアログも表示し、複数行の
詳細メッセージを確実に見せるようにした。実機のiBookでわざと接続を失敗させ、
ダイアログに2行とも表示されることを確認済み。

### v0.5.3→v0.5.4: ファイルブラウザ画面のUI修正(フェーズA)

依頼者がiBookで日常的にAquaLinkを使う中で溜まっていたUIの引っかかりのうち、
「小さく安全に直せるもの」をまとめて対処した。全て実機(iBook G4 / Tiger
10.4.11)で確認済み。

- **「上へ」ボタン** — 表記を`▲ Up` / `▲ 上へ`に変更。ブラウザの戻る/進むと
  混同されやすかったため、「階層を上がる」動作であることを矢印で明示する。
  あわせてFinderと同じ`⌘↑`(enclosing folder)のキーボードショートカットを
  `setKeyEquivalent:`で追加。
- **ラベルが伸びた分の幅調整** — `▲ 上へ`は`上へ`より長く、旧来の50px幅では
  文字が横に切れた。`upButton`を50→70pxに拡げ、x座標を500→470へ、左隣の
  `pathLabel`を480→460pxに詰めて場所を確保(`mountButton`の位置は不変)。
- **角丸ボタンの上辺が消える不具合** — `NSRoundedBezelStyle`のボタンを高さ22pxで
  作ると、上辺の線がフォント描画と被って見えなくなる(丸い側面と下線だけが
  残る)。既に26pxで作っていて問題の出ていなかった`connectButton`に合わせ、
  `upButton` / `mountButton` / `shareSettingsButton`を26pxへ統一。
- **隠しファイルが一覧に出る** — 従来は`.DS_Store`だけを名指しで除外していたため
  `.lesshst`等の他のドットファイルが素通りしていた。`listDirectory:`で
  `hasPrefix:@"."`によるドットファイル全般の除外に変更。実データには触れない
  表示上のフィルタ。

**プロセス上の教訓:** この修正、一度目は「直っていない」と報告された。原因は
コードではなく配置漏れ。iBookにソースをrsyncして`ssh ibook make`まではやって
いたが、ビルドされた`~/developer/AquaLink/AquaLink.app`を`/Applications/`へ
コピーしていなかった。iBookのDockは`/Applications/AquaLink.app`(8/28ビルドの
v0.4のまま)を起動する設定で、そちらが更新されない限りユーザーには何も
変わって見えない。**iBookでのビルド後は`cp -R ~/developer/AquaLink/AquaLink.app
/Applications/`と、`Info.plist`のバージョン確認までを1セットにする。**
