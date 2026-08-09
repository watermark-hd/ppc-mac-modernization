# Aquafox 日本語化 — 不足項目の翻訳候補

公式 Firefox 45.9.0esr 用の ja langpack をそのまま入れたところ、Aquafox が独自に追加・変更している項目が
langpack 側に無いため XUL エラーが発生しました。
以下は「langpack に無く、Aquafox 側にしかない」項目の全リストと翻訳候補です。

**進め方:** 各項目の「候補」を確認し、直してほしいものだけ書き換えてください。
「これでOK」の場合は何もしなくて大丈夫です。全部確認できたら教えてください。

---

## 1. TenFourFox.dtd / TenFourFox.properties（環境設定パネル）

Aquafox 独自の環境設定項目（ユーザーエージェント切替・広告ブロック・PDF表示・MediaSource・
サイト別UA・サイト別リーダービュー）です。dtd と properties でほぼ同じ内容が重複しています。

| 項目名 | 原文(英語) | 候補(日本語) |
|---|---|---|
| TFFuserAgent.title | User Agent | ユーザーエージェント |
| TFFuserAgent.prompt | Set user agent to current version of Firefox | ユーザーエージェントを現在のバージョンの Firefox に設定する |
| TFFuserAgent.prompt2 | Select user agent string to use: | 使用するユーザーエージェント文字列を選択: |
| TFFuserAgent.default | Aquafox (default) | Aquafox (デフォルト) |
| TFFadBlock.title | Adblock | 広告ブロック |
| TFFadBlock.prompt | Enable basic adblock | 簡易広告ブロックを有効にする |
| TFFpdfViewMode.title | PDF Viewing | PDF表示 |
| TFFpdfViewMode.prompt | Use built-in PDF viewer (slower but safer) | 内蔵PDFビューアーを使用する(低速だが安全) |
| TFFmseMode.title | MediaSource | MediaSource |
| TFFmseMode.prompt | Enable MSE/media quality options (slower, if available) | MSE/メディア品質オプションを有効にする(利用可能な場合、低速) |
| TFFsiteSpecificUAs.label | Site Specific... | サイト別設定... |
| TFFsiteSpecificUAs.title | Site Specific User Agents | サイト別ユーザーエージェント |
| TFFsiteSpecificUAs.add | Add | 追加 |
| TFFsiteSpecificUAs.domain | Domain | ドメイン |
| TFFsiteSpecificUAs.domain.l | Domain: | ドメイン: |
| TFFsiteSpecificUAs.ua | User agent | ユーザーエージェント |
| TFFsiteSpecificUAs.ua.l | User agent string: | ユーザーエージェント文字列: |
| TFFsiteSpecificUAs.preua | Common user agents: | よく使うユーザーエージェント: |
| TFFautoReaderView.label | Auto Reader View... | 自動リーダービュー... |
| TFFautoReaderView.title | Site Specific Auto Reader View | サイト別自動リーダービュー |
| TFFautoReaderView.mode | Mode | モード |
| TFFautoReaderView.mode.l | Mode: | モード: |
| TFFautoReaderView.mode.all | All pages | すべてのページ |
| TFFautoReaderView.mode.sub | Only subpages | サブページのみ |

properties版で文言が異なるもののみ:

| 項目名 | 原文(英語) | 候補(日本語) |
|---|---|---|
| TFFuserAgent.default.p | TenFourFox 45 (default) | TenFourFox 45 (デフォルト) |
| TFFsiteSpecificUAs.prompt | This is for advanced users to use a custom user agent for particular domains automatically. Enter a domain and a user agent string, or select a predefined one. | これは上級者向けの機能で、特定のドメインに対して自動的にカスタムユーザーエージェントを使用します。ドメインとユーザーエージェント文字列を入力するか、あらかじめ用意されたものを選択してください。 |
| TFFautoReaderView.prompt | Enter domain names that will automatically switch to the simpler Reader View for all pages, or for subpages only. | すべてのページ、またはサブページのみを対象に、自動的にシンプルなリーダービューへ切り替えるドメイン名を入力してください。 |

---

## 2. browser.dtd（メディア再生速度・リーダービュー・JS切替）

| 項目名 | 原文(英語) | 候補(日本語) |
|---|---|---|
| toggleReaderMode.label | Toggle Reader Mode | リーダーモードの切り替え |
| toggleReaderMode.key | R | R (アクセスキーは英字のまま慣例) |
| JavascriptToggleCmd.label | Enable JavaScript | JavaScript を有効にする |
| mediaPlaybackRate050x2.label | Slow (0.5×) | 低速 (0.5倍) |
| mediaPlaybackRate050x2.accesskey | S | S |
| mediaPlaybackRate100x2.label | Normal | 標準 |
| mediaPlaybackRate100x2.accesskey | N | N |
| mediaPlaybackRate125x2.label | Fast (1.25×) | 高速 (1.25倍) |
| mediaPlaybackRate125x2.accesskey | F | F |
| mediaPlaybackRate150x2.label | Faster (1.5×) | さらに高速 (1.5倍) |
| mediaPlaybackRate150x2.accesskey | a | a |
| mediaPlaybackRate200x2.label | Ludicrous (2×) | 超高速 (2倍) |
| mediaPlaybackRate200x2.accesskey | L | L |

※ accesskey（アクセスキー）はメニューを開いたときにキーボードで選択するための1文字です。
日本語訳をつけても機能上は意味がないので、英字のままにするのが一般的です。

---

## 3. browser.properties（更新チェック・リーダービュー）

| 項目名 | 原文(英語) | 候補(日本語) |
|---|---|---|
| reader-mode-button.tooltip | Toggle Reader View (%S) | リーダービューの切り替え (%S) |
| updatesItem_default | Check for Updates… | 更新を確認… |
| updatesItem_defaultFallback | Check for Updates… | 更新を確認… |
| updatesItem_default.accesskey | C | C |
| updatesItem_downloading | Downloading %S… | %S をダウンロード中… |
| updatesItem_downloadingFallback | Downloading Update… | 更新をダウンロード中… |
| updatesItem_downloading.accesskey | D | D |
| updatesItem_resume | Resume Downloading %S… | %S のダウンロードを再開… |
| updatesItem_resumeFallback | Resume Downloading Update… | 更新のダウンロードを再開… |
| updatesItem_resume.accesskey | D | D |
| updatesItem_pending | Apply Downloaded Update Now… | ダウンロード済みの更新を今すぐ適用… |
| updatesItem_pendingFallback | Apply Downloaded Update Now… | ダウンロード済みの更新を今すぐ適用… |
| updatesItem_pending.accesskey | D | D |

---

## 4. baseMenuOverlay.dtd

| 項目名 | 原文(英語) | 候補(日本語) |
|---|---|---|
| updateCmd.label | Check for Updates… | 更新を確認… |

---

## 5. aboutDialog.dtd（バージョン情報ダイアログ）

人名・著作権表示が含まれるため、翻訳するかどうかも含めてご判断ください。

| 項目名 | 原文(英語) | 候補(日本語) |
|---|---|---|
| contribute.start | Thanks to Cameron Kaiser, wicknix, Chris Jones, zgxSystems, Zac, Tobias Netzel, Ben Stuhl, Claudio Leite, Chris Trusch, David Kilbridge, David Fang, Riccardo Mottola, Raphaël Guay, Ken Cunningham, Olga T Park, Chad Weider, Narcotix, PoLiYa, Edwin Smith and the TenFourFox localizers. Powered by Mozilla Firefox: | Cameron Kaiser 氏、wicknix 氏、Chris Jones 氏、zgxSystems 氏、Zac 氏、Tobias Netzel 氏、Ben Stuhl 氏、Claudio Leite 氏、Chris Trusch 氏、David Kilbridge 氏、David Fang 氏、Riccardo Mottola 氏、Raphaël Guay 氏、Ken Cunningham 氏、Olga T Park 氏、Chad Weider 氏、Narcotix 氏、PoLiYa 氏、Edwin Smith 氏、および TenFourFox のローカライザーの皆様に感謝します。Powered by Mozilla Firefox: |
| contribute.end | (空文字列) | (空文字列のまま) |
| copyright.blurb | Copyright © 2010-2025 Contributors to TenFourFox. Copyright © 2024-2026 Maintainers of Aquafox. All rights reserved. | (著作権表示は英語のまま残すのが一般的な慣例です。翻訳しない案) |

---

## 6. devtools/client/storage.properties（開発者ツール）

| 項目名 | 原文(英語) | 候補(日本語) |
|---|---|---|
| table.headers.cookies.sameSite | sameSite | SameSite (Cookie属性の技術用語なので原文のまま推奨) |

---

## 7. mozapps/update/updates.dtd（手動更新ダイアログ）

| 項目名 | 原文(英語) | 候補(日本語) |
|---|---|---|
| manualUpdate2.title | Update Available | 更新が利用可能です |
| manualUpdate2.desc | A recommended security and stability update is available for your browser. You should download and install it to make sure your browser is up to date. | ブラウザーに推奨されるセキュリティおよび安定性の更新が利用可能です。ブラウザーを最新の状態に保つため、ダウンロードしてインストールしてください。 |
| manualUpdate2.space.desc | A recommended security and stability update is available, but you do not have enough space to install it. | 推奨されるセキュリティおよび安定性の更新が利用可能ですが、インストールするための空き容量が不足しています。 |
| manualUpdate2GetMsg.label | Visit the main download page to get this browser update: | このブラウザーの更新を入手するには、ダウンロードページにアクセスしてください: |
| manualUpdate3.title | Download Update Now | 今すぐ更新をダウンロード |
| manualUpdate3.desc | You are now ready to update your browser. | ブラウザーを更新する準備ができました。 |
| manualUpdate3.space.desc | A recommended security and stability update is available, but you do not have enough space to install it. | 推奨されるセキュリティおよび安定性の更新が利用可能ですが、インストールするための空き容量が不足しています。 |
| manualUpdate3GetMsg.label | Visit the main download page to get the browser update: | ブラウザーの更新を入手するには、ダウンロードページにアクセスしてください: |

---

## 8. necko/necko.properties（通信状況メッセージ）

| 項目名 | 原文(英語) | 候補(日本語) |
|---|---|---|
| 12 | Performing a TLS handshake to %1$S… | %1$S に対して TLS ハンドシェイクを実行中… |
| 13 | The TLS handshake finished for %1$S… | %1$S の TLS ハンドシェイクが完了しました… |

---

## 合計

- 完全新規ファイル: 2件（TenFourFox.dtd, TenFourFox.properties）
- 既存ファイル内の不足項目: 41件（7ファイル）
- 総項目数: 約80件
