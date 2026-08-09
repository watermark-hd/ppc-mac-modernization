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

## 次のステップ(未着手)

CLAUDE.md の C案(マウントアプリ)へ進む場合の想定:

1. `make install` して `/usr/local/lib` にライブラリを配置(現状は `DYLD_LIBRARY_PATH` 指定でのみ動作)
2. 第1段: ファイルブラウザ型 Cocoa アプリ(libsmb2を組み込み、NSPasteboardのファイルプロミスでFinderとドラッグ&ドロップ)
3. 第2段: アプリ内蔵の極小WebDAVサーバー + `mount_webdav` でFinderにアイコンを出す
