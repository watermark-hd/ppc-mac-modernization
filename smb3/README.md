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
git apply /path/to/libsmb2_tiger_ppc.patch   # 本ディレクトリのパッチを適用
LIBTOOLIZE=glibtoolize ./bootstrap            # 母艦(Homebrew)にautomake/libtoolが必要
```

パッチの内容: `configure.ac` に `CommonCrypto/CommonCrypto.h` の有無チェックを追加し、
`lib/aes.c` / `lib/aes_apple.c` の `#ifdef __APPLE__` 判定を
`#if defined(__APPLE__) && defined(HAVE_COMMONCRYPTO_COMMONCRYPTO_H)` に変更。
Tiger の SDK には CommonCrypto フレームワークが無いため、素の `#ifdef __APPLE__` だけでは
誤ってCommonCrypto版のAES実装を選んでしまいビルドが失敗する。

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
rsync -a AquaLink/ ibook:~/AquaLink/
ssh ibook 'cd ~/AquaLink && make'
open ~/AquaLink/AquaLink.app   # または実機でダブルクリック
```

`libsmb2.a`(静的ライブラリ)を直接リンクしているため、`make install` は不要。
`$HOME/libsmb2` にビルド済みの libsmb2 ソースツリーがある前提。

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

## iBookをNAS化する(逆方向: 現代機 → iBook) ✅ 完了

`LocalWebDAVServer.h/.m` に実装。当初のCLAUDE.mdスコープには無かったが、依頼者の実要件
(iBookに入っている古いRAW写真を現代のMac/Windowsから直接参照・編集したい)を受けて追加。

これまでの「iBookが外部のNASに繋ぎに行く」(libsmb2クライアント)とは逆方向。
`WebDAVServer`(NASへのループバック接続用)を土台に、libsmb2呼び出しをPOSIXのファイルI/O
(`open`/`read`/`write`/`opendir`等)に置き換え、`127.0.0.1`限定ではなく`INADDR_ANY`で
LAN上の他機器からも接続できるようにし、Basic認証とパストラバーサル(`../`)対策を追加した。

AquaLinkのメインウィンドウに「iBookを共有(NAS化)...」ボタンがあり、共有フォルダ・
ユーザー名・パスワード・ポートを設定して開始する。実機で以下を確認済み:

- `curl` での認証・PROPFIND一覧・GET・PUT・DELETE・パストラバーサル拒否
- macOS Finder(現代のMacBook Air)からの実際のマウント・ブラウズ・ダウンロード

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
