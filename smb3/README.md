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

## C案 第1段: NASBrowser.app ✅ 完了

`NASBrowser/` にソース一式。libsmb2 を静的リンクした自己完結の Cocoa アプリ(nib不要、
プログラムでUI構築)。iBook 実機で以下すべて動作確認済み:

- smb3:// URL + パスワードでの接続(NTLMSSP認証)
- ディレクトリ一覧表示(日本語ファイル名を含め文字化けなし)
- ダブルクリックでの移動、「上へ」での親ディレクトリ移動
- **ドラッグ&ドロップでのダウンロード**(NASBrowser → Finder。ファイルプロミス方式)
- **ドラッグ&ドロップでのアップロード**(Finder → NASBrowser)

### ビルド方法

```bash
rsync -a NASBrowser/ ibook:~/NASBrowser/
ssh ibook 'cd ~/NASBrowser && make'
open ~/NASBrowser/NASBrowser.app   # または実機でダブルクリック
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

`WebDAVServer.h/.m` に実装。NASBrowser 内蔵の極小 HTTP/WebDAV サーバー(生の BSD ソケット、
OPTIONS/PROPFIND/GET/HEAD/PUT/DELETE/MKCOL/LOCK/UNLOCK に対応)を 127.0.0.1 の適当なポートで
立ち上げ、`mount_webdav` でそこに接続することで Finder に通常のボリュームとして表示させる。

iBook 実機で確認済み:
- 「Finderに接続」ボタンで `/Volumes/<共有名>` にマウントされ、**デスクトップにアイコンが出る**
- Finder 上で直接ドラッグ&ドロップでコピーできる(NASBrowser を介さない、普通のボリュームとして機能)
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
