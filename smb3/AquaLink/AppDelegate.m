#import "AppDelegate.h"
#import "WebDAVServer.h"
#import "LocalWebDAVServer.h"
#include <fcntl.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <Security/Security.h>

/* NSString版sprintfの単純な置換ヘルパー(定義は本ファイル下部)。前方宣言。 */
static NSString *AQReplaceAll(NSString *source, NSString *target, NSString *replacement);
/* applicationWillTerminate: (本ファイル前方)がマウントの後始末に使うため、
   定義(後方、Finderマウント節)より前で前方宣言しておく */
static BOOL AQTeardownMountPoint(NSString *mountPoint);
/* ImageAndTextCell(本ファイル前方で定義)が使うため、定義(後方、ファイル
   一覧節)より前で前方宣言しておく。引数は拡張子文字列、フォルダならnil。 */
static NSImage *IconForExtension(NSString *ext);

/* 古いgcc(4.0系)はObjective-Cの @"..." 日本語リテラルを正しく解釈しないことがあるため、
   C文字列(生バイト列、コンパイラによる再解釈なし)からUTF-8として明示的に組み立てる */
#define UTF8(cstr) [NSString stringWithUTF8String:(cstr)]

/* --- 表示言語の自動切り替え ---
   .lprojやNSBundleのローカライズ機構は使わず、日本語原文をキーにした対訳表を
   コード内に直接持つ単純な仕組みにしている(ビルド設定・Makefileの変更が不要、
   Tiger世代のNSBundleの言語選択の細かい挙動に依存しない、というのが理由)。
   Localizable.strings相当のものは EnglishTranslations() の1箇所にまとまっている。
   訳が無いキーは日本語のまま出す(表示が崩れるより安全)。 */
static BOOL UseEnglish(void)
{
    static BOOL checked = NO;
    static BOOL useEnglish = NO;
    if (!checked) {
        NSArray *langs = [[NSUserDefaults standardUserDefaults] objectForKey:@"AppleLanguages"];
        NSString *primary = ([langs count] > 0) ? [langs objectAtIndex:0] : nil;
        useEnglish = (primary != nil && ![primary hasPrefix:@"ja"]);
        checked = YES;
    }
    return useEnglish;
}

static NSDictionary *EnglishTranslations(void)
{
    static NSDictionary *table = nil;
    if (table == nil) {
        table = [[NSDictionary alloc] initWithObjectsAndKeys:
            @"Share Settings...", UTF8("共有設定..."),
            @"Quit AquaLink", UTF8("AquaLinkを終了"),
            @"Username", UTF8("ユーザー名"),
            @"Address (no smb:// needed)", UTF8("アドレス(smb://は不要)"),
            @"Share Name", UTF8("共有名"),
            @"Password", UTF8("パスワード"),
            @"Connect", UTF8("接続"),
            @"▲ Up", UTF8("▲ 上へ"),
            @"Connect in Finder", UTF8("Finderに接続"),
            @"Share This Mac (as NAS)...", UTF8("このMacを共有(NAS化)..."),
            @"Name", UTF8("名前"),
            @"Kind", UTF8("種類"),
            @"Size", UTF8("サイズ"),
            @"Modified", UTF8("更新日時"),
            @"Not Connected", UTF8("未接続"),
            @"Connecting...", UTF8("接続中..."),
            @"Failed to initialize the SMB2 context", UTF8("smb2コンテキストの初期化に失敗しました"),
            @"Connected", UTF8("接続しました"),
            @"%lu items", UTF8("%lu 件"),
            @"Loading...", UTF8("読み込み中..."),
            @"Folder", UTF8("フォルダ"),
            @"File", UTF8("ファイル"),
            @"Failed to download %@", UTF8("%@ のダウンロードに失敗しました"),
            @"Uploading...", UTF8("アップロード中..."),
            @"Failed to upload %d item(s)", UTF8("%d件のアップロードに失敗しました"),
            @"Please connect first", UTF8("先に接続してください"),
            @"Connecting in Finder...", UTF8("Finderに接続中..."),
            @"Failed to start the WebDAV server", UTF8("WebDAVサーバーの起動に失敗しました"),
            @"Mount failed: %@", UTF8("マウント失敗: %@"),
            @"Mounted at %@", UTF8("%@ にマウントしました"),
            @"Disconnect", UTF8("取り外す"),
            @"Disconnecting...", UTF8("取り外し中..."),
            @"Disconnected", UTF8("取り外しました"),
            @"Failed to disconnect. Try ejecting from Finder, or try again.", UTF8("取り外しに失敗しました。Finderから取り出すか、再度お試しください"),
            @"Require SMB3 encryption (won't connect to shares that don't support it)", UTF8("SMB3暗号化を必須にする(対応していない共有には接続できません)"),
            @"Failed to disconnect: %@", UTF8("取り外しに失敗しました: %@"),
            @"Password entry was cancelled", UTF8("パスワード入力がキャンセルされました"),
            @"Privileged umount failed", UTF8("管理者権限でのumountに失敗しました"),
            @"Share This Mac (as NAS)", UTF8("このMacを共有(NAS化)"),
            @"⚠️ LAN use only. Passwords are sent unencrypted (plain HTTP). Do not expose this to the internet (e.g. via router port forwarding).", UTF8("⚠️ LAN内限定で使用してください。パスワードは暗号化されません(平文HTTP)。ルーターのポート開放等でインターネットに直接公開しないこと。"),
            @"Shared Folders:", UTF8("共有フォルダ一覧:"),
            @"Folder Path", UTF8("フォルダパス"),
            @"Username:", UTF8("ユーザー名:"),
            @"Password:", UTF8("パスワード:"),
            @"Required", UTF8("必須"),
            @"Port:", UTF8("ポート:"),
            @"Stop Sharing", UTF8("共有停止"),
            @"Start Sharing", UTF8("共有開始"),
            @"Windows Connection Guide", UTF8("Windows用接続ガイド"),
            @"Stopping...", UTF8("停止中..."),
            @"Please add at least one shared folder", UTF8("共有フォルダを1つ以上追加してください"),
            @"Please enter a username and password", UTF8("ユーザー名とパスワードを入力してください"),
            @"Starting sharing...", UTF8("共有を開始しています..."),
            @"Sharing is active (%d folder(s)). Connect from another device at:\nhttp://%@:%d/ (username/password required)",
              UTF8("共有中です(%d フォルダ)。他の機器から下記へ接続してください:\nhttp://%@:%d/ (ユーザー名/パスワードが必要)"),
            @"Failed to start sharing (couldn't bind the port)", UTF8("共有の開始に失敗しました(ポートを確保できません)"),
            @"Sharing stopped", UTF8("共有を停止しました"),
            @"URL parse error: %s", UTF8("URL解析エラー: %s"),
            @"Failed to list directory: %s", UTF8("一覧取得失敗: %s"),
            @"Connection failed: The username or password appears to be incorrect.\n(Details: %@)",
              UTF8("接続失敗: ユーザー名またはパスワードが正しくないようです。\n(詳細: %@)"),
            @"Connection failed: The specified share name was not found. Please check the spelling.\n(Details: %@)",
              UTF8("接続失敗: 指定した共有名が見つかりません。共有名のつづりを確認してください。\n(詳細: %@)"),
            @"Connection failed: Access was denied. Please check the username, password, and share permissions.\n(Details: %@)",
              UTF8("接続失敗: アクセスが拒否されました。ユーザー名・パスワード・共有の権限を確認してください。\n(詳細: %@)"),
            @"Connection failed: The server address could not be found. Please check the spelling.\n(Details: %@)",
              UTF8("接続失敗: サーバーのアドレスが見つかりません。アドレスのつづりを確認してください。\n(詳細: %@)"),
            @"Connection failed: Could not reach the server. Please check its power, network connection, and the address.\n(Details: %@)",
              UTF8("接続失敗: サーバーに接続できません。電源やネットワーク接続、アドレスを確認してください。\n(詳細: %@)"),
            @"Connection failed: Timed out. Please check your network connection.\n(Details: %@)",
              UTF8("接続失敗: タイムアウトしました。ネットワーク接続を確認してください。\n(詳細: %@)"),
            @"Connection failed: Disconnected by the server mid-communication. This device may not support SMB2/3 (e.g. an older router's built-in sharing feature).\n(Details: %@)",
              UTF8("接続失敗: 通信の途中でサーバー側から切断されました。この機器がSMB2/3に対応していない可能性があります(古いルーター内蔵の共有機能など)。\n(詳細: %@)"),
            @"Connection failed: %@", UTF8("接続失敗: %@"),
            @"Connection Failed", UTF8("接続に失敗しました"),
            @"OK", UTF8("OK"),
            @"Edit", UTF8("編集"),
            @"Undo", UTF8("取り消す"),
            @"Redo", UTF8("やり直す"),
            @"Cut", UTF8("カット"),
            @"Copy", UTF8("コピー"),
            @"Paste", UTF8("ペースト"),
            @"Select All", UTF8("すべてを選択"),
            @"Connecting in Finder failed", UTF8("Finderへの接続に失敗しました"),
            @"Mount setup needed", UTF8("マウントの準備が必要です"),
            @"/sbin/mount_webdav has lost its setuid (admin) bit. OS updates can strip it. To put it back the way it should be, this will run the following as administrator:\n\nchmod u+s /sbin/mount_webdav",
              UTF8("/sbin/mount_webdav に管理者権限(setuid)が付いていません。OSアップデート等で外れることがあります。本来あるべき状態に戻すため、次のコマンドを管理者権限で実行します:\n\nchmod u+s /sbin/mount_webdav"),
            @"Fix it automatically", UTF8("自動で直す"),
            @"Cancel", UTF8("キャンセル"),
            @"Automatic fix failed", UTF8("自動修復に失敗しました"),
            @"%@\n\nYou can also fix it by hand. Run this one line in Terminal:\nsudo chmod u+s /sbin/mount_webdav",
              UTF8("%@\n\n手動でも直せます。ターミナルで次を1行実行してください:\nsudo chmod u+s /sbin/mount_webdav"),
            @"Could not restore the setuid bit", UTF8("setuidビットの復元に失敗しました"),
            @"No free mount point found. There may be a stale mount left under /Volumes. Try: sudo umount -f /Volumes/<share>",
              UTF8("マウント先の空きが見つかりません。/Volumes に古いマウントが残っている可能性があります。ターミナルで sudo umount -f /Volumes/共有名 を試してください。"),
            @"Mount failed: no response (timed out). Check for a stale mount left under /Volumes.",
              UTF8("マウント失敗: 応答がありません(タイムアウト)。/Volumes に古いマウントが残っていないか確認してください。"),
            nil];
    }
    return table;
}

/* 日本語原文(cstr)を、UseEnglish()なら英訳へ、そうでなければそのまま返す */
#define L(cstr) LocalizedString(cstr)
static NSString *LocalizedString(const char *cstr)
{
    NSString *ja = UTF8(cstr);
    if (!UseEnglish()) {
        return ja;
    }
    NSString *en = [EnglishTranslations() objectForKey:ja];
    return en ? en : ja;
}

/* 一覧のソート指定。keyKind: 0=名前 1=サイズ 2=更新日時 */
typedef struct {
    int keyKind;
    BOOL ascending;
} EntrySortSpec;

/* ディレクトリは常に先頭にまとめ、その中で指定キー・方向に並べる比較関数。
   キーが同値のときは名前で決着させる(表示順を安定させるため)。
   フォルダ先頭のルールはascendingの影響を受けない(降順でもフォルダが上)。 */
static int CompareEntries(id a, id b, void *context)
{
    EntrySortSpec def = { 0, YES };
    EntrySortSpec *s = context ? (EntrySortSpec *)context : &def;

    BOOL aDir = [[a objectForKey:@"isDir"] boolValue];
    BOOL bDir = [[b objectForKey:@"isDir"] boolValue];
    if (aDir != bDir) {
        return aDir ? NSOrderedAscending : NSOrderedDescending;
    }

    int r;
    if (s->keyKind == 1) {
        unsigned long long sa = [[a objectForKey:@"size"] unsignedLongLongValue];
        unsigned long long sb = [[b objectForKey:@"size"] unsignedLongLongValue];
        r = (sa < sb) ? NSOrderedAscending : (sa > sb) ? NSOrderedDescending : NSOrderedSame;
    } else if (s->keyKind == 2) {
        unsigned long long ma = [[a objectForKey:@"mtime"] unsignedLongLongValue];
        unsigned long long mb = [[b objectForKey:@"mtime"] unsignedLongLongValue];
        r = (ma < mb) ? NSOrderedAscending : (ma > mb) ? NSOrderedDescending : NSOrderedSame;
    } else {
        r = (int)[[a objectForKey:@"name"] caseInsensitiveCompare:[b objectForKey:@"name"]];
    }
    if (r == NSOrderedSame) {
        r = (int)[[a objectForKey:@"name"] caseInsensitiveCompare:[b objectForKey:@"name"]];
    }
    return s->ascending ? r : -r;
}

static NSString *FormatSize(unsigned long long size, BOOL isDir)
{
    if (isDir) {
        return @"--";
    }
    if (size < 1024) {
        return [NSString stringWithFormat:@"%llu B", size];
    } else if (size < 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f KB", size / 1024.0];
    } else if (size < 1024ULL * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.1f MB", size / (1024.0 * 1024.0)];
    }
    return [NSString stringWithFormat:@"%.1f GB", size / (1024.0 * 1024.0 * 1024.0)];
}

/* SMB2のmtime(1970年からの秒)を「2026-09-06 14:32」形式に整形する。
   NSDateFormatterは10.4と10.5で挙動が異なるので、10.4から確実に使える
   descriptionWithCalendarFormat:を使う(deprecated扱いだがTigerでは正常動作) */
static NSString *FormatDate(unsigned long long mtime)
{
    if (mtime == 0) {
        return @"";
    }
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)mtime];
    /* 日付と時刻の境目が分かるよう " | " で区切る(依頼者の要望)。
       "2026-09-06 | 14:32" のように出る */
    return [d descriptionWithCalendarFormat:@"%Y-%m-%d | %H:%M"
                                  timeZone:[NSTimeZone localTimeZone]
                                    locale:nil];
}

/* NSNetServiceのaddresses(struct sockaddrを包んだNSDataの配列)から、
   最初のIPv4アドレスを "192.168.x.x" 形式の文字列で返す。無ければnil。
   ホスト名(service.hostName)ではなく数値IPをそのまま使うのは、環境によって
   名前解決自体が壊れているケースがあるため(実際にそういう報告があった)。
   数値IPで繋げば名前解決を一切通らない */
static NSString *AQFirstIPv4FromNetService(NSNetService *service)
{
    NSArray *addrs = [service addresses];
    unsigned i;
    for (i = 0; i < [addrs count]; i++) {
        NSData *data = [addrs objectAtIndex:i];
        const struct sockaddr *sa = (const struct sockaddr *)[data bytes];
        if (sa != NULL && sa->sa_family == AF_INET &&
                [data length] >= sizeof(struct sockaddr_in)) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
            char buf[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf)) != NULL) {
                return [NSString stringWithUTF8String:buf];
            }
        }
    }
    return nil;
}

/* 名前列用: 行頭に16pxのアイコンを描き、その右にファイル名を出すセル。
   Cyberduck/Transmit風の一覧にするための最小実装(Appleのサンプル
   ImageAndTextCellを10.4向けに削ったもの)。NSInteger等の10.5専用型は
   使わず、Tigerの実際のメソッドシグネチャに合わせてintを使う。

   [重大][PowerMac G4実機で確認・修正済み] 以前は「今描くべき画像」を
   `iatImage`という自作のivarにsetImage:で持たせていた。NSTableViewは行を
   選択した瞬間、ハイライト表示用にこのセルを内部で一時的に複製する
   (copyWithZone:)動きがあり、その複製されたセルの中で`iatImage`ivarの
   扱いが壊れ、値がゼロに近い小さなおかしい数値になってEXC_BAD_ACCESSで
   落ちることが実機調査で判明した(複製直後にsetFlipped:で共有画像を
   書き換える別の問題も併発しており、両方が絡んだ末の結果とみられる)。

   根本原因を完全には特定しきれなかったため、対症療法ではなく設計そのものを
   変えた: 自作のivarを一切持たず、NSCell標準の`representedObject`
   (「拡張子」の文字列だけを保持する。フォルダならnil)を使う。この仕組みは
   NSCell自身が持つ標準機能で、コピー時の扱いも含めてAppleの実装に
   委ねられるため、自作ivarで起きたような複製時の不具合が原理的に起こらない。
   画像そのものは毎回の描画時にIconForExtension()で(拡張子ごとにキャッシュ
   済みの)共有画像を引くだけにし、セル自身は一切保持しない。 */
@interface ImageAndTextCell : NSTextFieldCell
@end

@implementation ImageAndTextCell

/* アイコン分だけ右にずらした、文字を描くための矩形 */
- (NSRect)iatTitleRectForBounds:(NSRect)bounds
{
    NSImage *img = IconForExtension([self representedObject]);
    if (img == nil) {
        return bounds;
    }
    float w = [img size].width + 4;
    NSRect r = bounds;
    r.origin.x += w;
    r.size.width -= w;
    return r;
}

- (void)editWithFrame:(NSRect)aRect inView:(NSView *)controlView
               editor:(NSText *)textObj delegate:(id)anObject event:(NSEvent *)theEvent
{
    [super editWithFrame:[self iatTitleRectForBounds:aRect] inView:controlView
                  editor:textObj delegate:anObject event:theEvent];
}

- (void)selectWithFrame:(NSRect)aRect inView:(NSView *)controlView
                 editor:(NSText *)textObj delegate:(id)anObject start:(int)selStart length:(int)selLength
{
    [super selectWithFrame:[self iatTitleRectForBounds:aRect] inView:controlView
                    editor:textObj delegate:anObject start:selStart length:selLength];
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    NSImage *img = IconForExtension([self representedObject]);
    if (img != nil) {
        NSSize is = [img size];
        NSPoint p = cellFrame.origin;
        p.x += 2;
        p.y += (cellFrame.size.height - is.height) / 2.0;
        [img drawAtPoint:p fromRect:NSZeroRect
                operation:NSCompositeSourceOver fraction:1.0];
    }
    [super drawWithFrame:[self iatTitleRectForBounds:cellFrame] inView:controlView];
}

@end

/* ループバック以外の最初のIPv4アドレスを返す(LAN上の他機器に案内するURL用) */
static NSString *GetLocalIPAddress(void)
{
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp;
    NSString *address = nil;

    if (getifaddrs(&interfaces) == 0) {
        temp = interfaces;
        while (temp != NULL) {
            if (temp->ifa_addr != NULL && temp->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:temp->ifa_name];
                if (![name isEqualToString:@"lo0"]) {
                    char buf[INET_ADDRSTRLEN];
                    struct sockaddr_in *addrIn = (struct sockaddr_in *)temp->ifa_addr;
                    if (inet_ntop(AF_INET, &(addrIn->sin_addr), buf, sizeof(buf)) != NULL) {
                        NSString *ip = [NSString stringWithUTF8String:buf];
                        if (![ip hasPrefix:@"169.254"]) {
                            address = ip;
                            break;
                        }
                    }
                }
            }
            temp = temp->ifa_next;
        }
        freeifaddrs(interfaces);
    }
    return address ? address : UTF8("(IP不明)");
}

/* --- キーチェーン: パスワードを平文でNSUserDefaultsに置かないための保存先 ---
   service/accountを引数化し、「このMacを共有する」機能のパスワードと、
   「NASに繋ぐ」接続フォームのパスワード(接続ごとに別アカウント名を使う)の
   両方をこの2関数で扱う */
#define KEYCHAIN_SERVICE_SHARE @"AquaLink-Share"
#define KEYCHAIN_ACCOUNT_SHARE @"shared-password"
#define KEYCHAIN_SERVICE_CONNECT @"AquaLink-Connect"

static void SaveKeychainPassword(NSString *service, NSString *account, NSString *password)
{
    const char *svc = [service UTF8String];
    const char *acct = [account UTF8String];
    const char *pass = [password UTF8String];
    UInt32 passLen = pass ? (UInt32)strlen(pass) : 0;

    SecKeychainItemRef item = NULL;
    OSStatus status = SecKeychainFindGenericPassword(NULL,
                                                       (UInt32)strlen(svc), svc,
                                                       (UInt32)strlen(acct), acct,
                                                       NULL, NULL, &item);
    if (status == noErr && item != NULL) {
        SecKeychainItemModifyContent(item, NULL, passLen, pass);
        CFRelease(item);
    } else {
        SecKeychainAddGenericPassword(NULL,
                                       (UInt32)strlen(svc), svc,
                                       (UInt32)strlen(acct), acct,
                                       passLen, pass, NULL);
    }
}

static NSString *LoadKeychainPassword(NSString *service, NSString *account)
{
    const char *svc = [service UTF8String];
    const char *acct = [account UTF8String];
    UInt32 passLen = 0;
    void *passData = NULL;
    OSStatus status = SecKeychainFindGenericPassword(NULL,
                                                       (UInt32)strlen(svc), svc,
                                                       (UInt32)strlen(acct), acct,
                                                       &passLen, &passData, NULL);
    if (status != noErr || passData == NULL) {
        return nil;
    }
    NSString *result = [[[NSString alloc] initWithBytes:passData
                                                   length:passLen
                                                 encoding:NSUTF8StringEncoding] autorelease];
    SecKeychainItemFreeContent(NULL, passData);
    return result;
}

/* 接続フォームのKeychainアカウント名。ユーザー名/アドレス/共有名の組み合わせごとに
   別のパスワードを覚えられるようにする(複数のNAS/共有を行き来しても混ざらない) */
static NSString *ConnectKeychainAccount(NSString *username, NSString *address, NSString *share)
{
    return [NSString stringWithFormat:@"%@@%@/%@",
            (username ? username : @""),
            (address ? address : @""),
            (share ? share : @"")];
}

/* smb2_get_error()が返す生のエラー文字列(libsmb2ソース確認済み: 例
   "Session setup failed with (0x...) STATUS_LOGON_FAILURE"、
   "Tree Connect failed with (0x...) STATUS_BAD_NETWORK_NAME. ..."、
   "Invalid address:... Can not resolve into IPv4/v6."、
   "Connect failed with errno : Connection refused(61)" など)を、
   よくあるパターンだけ日本語の分かりやすい文言に置き換える。
   マッチしないものはそのまま(生の文字列)を表示するので、情報が失われることはない */
static NSString *FriendlyConnectError(NSString *raw)
{
    if (raw == nil) {
        raw = @"";
    }
    NSString *lower = [raw lowercaseString];

    if ([lower rangeOfString:@"logon_failure"].location != NSNotFound) {
        return [NSString stringWithFormat:L("接続失敗: ユーザー名またはパスワードが正しくないようです。\n(詳細: %@)"), raw];
    }
    if ([lower rangeOfString:@"bad_network_name"].location != NSNotFound) {
        return [NSString stringWithFormat:L("接続失敗: 指定した共有名が見つかりません。共有名のつづりを確認してください。\n(詳細: %@)"), raw];
    }
    if ([lower rangeOfString:@"access_denied"].location != NSNotFound) {
        return [NSString stringWithFormat:L("接続失敗: アクセスが拒否されました。ユーザー名・パスワード・共有の権限を確認してください。\n(詳細: %@)"), raw];
    }
    if ([lower rangeOfString:@"can not resolve"].location != NSNotFound ||
        [lower rangeOfString:@"invalid address"].location != NSNotFound) {
        return [NSString stringWithFormat:L("接続失敗: サーバーのアドレスが見つかりません。アドレスのつづりを確認してください。\n(詳細: %@)"), raw];
    }
    if ([lower rangeOfString:@"connect failed with errno"].location != NSNotFound ||
        [lower rangeOfString:@"socket connect failed"].location != NSNotFound) {
        return [NSString stringWithFormat:L("接続失敗: サーバーに接続できません。電源やネットワーク接続、アドレスを確認してください。\n(詳細: %@)"), raw];
    }
    if ([lower rangeOfString:@"timeout expired"].location != NSNotFound) {
        return [NSString stringWithFormat:L("接続失敗: タイムアウトしました。ネットワーク接続を確認してください。\n(詳細: %@)"), raw];
    }
    if ([lower rangeOfString:@"pollhup"].location != NSNotFound) {
        return [NSString stringWithFormat:L("接続失敗: 通信の途中でサーバー側から切断されました。この機器がSMB2/3に対応していない可能性があります(古いルーター内蔵の共有機能など)。\n(詳細: %@)"), raw];
    }
    return [NSString stringWithFormat:L("接続失敗: %@"), raw];
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    entries = [[NSMutableArray alloc] init];
    sortColumnId = [@"name" retain];
    sortAscending = YES;
    currentPath = [@"" retain];
    smb2Lock = [[NSLock alloc] init];
    mounted = NO;

    shareFolders = [[NSMutableArray alloc] init];
    [self loadShareSettings];

    /* --- メニューバー(共有設定・Quit) ---
       [修正済みの不具合・その1] クリックするとタイトルは青くハイライトするのに
       中身が出ず、タイトルの右の空白にカーソルを移動すると出る、という症状が
       あった。原因は appMenuItem(見出し側)には "AquaLink" というタイトルを
       設定していた一方、そのプルダウンの中身である appMenu(NSMenuオブジェクト
       自体)にはタイトルを一切設定していなかったこと。appMenuにも同じタイトルを
       設定して解消した。
       [修正済みの不具合・その2] その1を直した後、"AquaLink" が2つ並んで表示され、
       左側はハイライトのみで反応せず、右側(こちらが本物)だけメニューが開く症状が
       出た。原因は [NSApp setAppleMenu:] を呼んでいなかったこと。nibを使わず
       手組みでメニューバーを作る場合、これを呼ばないとAppKit側が「アプリケー
       ションメニューが設定されていない」と判断し、プロセス名から中身の無い
       メニュー項目をもう一つ自動生成してしまう。下記で明示的に指定して解消した。 */
    NSMenu *menubar = [NSApp mainMenu];
    NSMenuItem *appMenuItem;
    if (menubar == nil) {
        menubar = [[NSMenu alloc] init];
        appMenuItem = [[NSMenuItem alloc] init];
        [menubar addItem:appMenuItem];
    } else if ([menubar numberOfItems] > 0) {
        appMenuItem = (NSMenuItem *)[menubar itemAtIndex:0];
    } else {
        appMenuItem = [[NSMenuItem alloc] init];
        [menubar addItem:appMenuItem];
    }
    [appMenuItem setTitle:@"AquaLink"];

    NSMenu *appMenu = [appMenuItem submenu];
    if (appMenu == nil) {
        appMenu = [[NSMenu alloc] init];
        [appMenuItem setSubmenu:appMenu];
    }
    [appMenu setTitle:[appMenuItem title]];
    [NSApp setAppleMenu:appMenu];

    NSMenuItem *shareMenuItem = [[NSMenuItem alloc] initWithTitle:L("共有設定...")
                                                             action:@selector(showShareWindow:)
                                                      keyEquivalent:@""];
    [shareMenuItem setTarget:self];
    [appMenu addItem:shareMenuItem];
    [shareMenuItem release];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:L("AquaLinkを終了")
                                                        action:@selector(terminate:)
                                                 keyEquivalent:@"q"];
    [quitItem setTarget:NSApp];
    [appMenu addItem:quitItem];
    [quitItem release];
    /* menubar / appMenuItem / appMenu はここでreleaseしない(意図的) */

    /* 標準の「編集」メニュー。手組みのメニューバーだとこれが無く、テキスト欄で
       ⌘C/⌘V/⌘X/⌘A/⌘Z が全く効かなかった(ダイアログのコマンドをコピーできない等)。
       action の target は付けず(nil)、レスポンダチェーンでフォーカスのある
       テキスト欄まで届くようにする(標準のcut:/copy:/paste:等) */
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] initWithTitle:L("編集")
                                                         action:NULL keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:L("編集")];
    [editMenuItem setSubmenu:editMenu];
    [menubar addItem:editMenuItem];
    /* appMenuと同様、editMenuItem/editMenuはここでreleaseしない(アプリの
       生存期間中ずっと使うメニュー。上のappMenuのコメント参照) */
    {
        struct { NSString *title; SEL action; NSString *key; } items[] = {
            { L("取り消す"),        @selector(undo:),      @"z" },
            { L("やり直す"),        @selector(redo:),      @"Z" },
            { nil,                  NULL,                  nil },
            { L("カット"),          @selector(cut:),       @"x" },
            { L("コピー"),          @selector(copy:),      @"c" },
            { L("ペースト"),        @selector(paste:),     @"v" },
            { L("すべてを選択"),    @selector(selectAll:), @"a" },
        };
        unsigned k;
        for (k = 0; k < sizeof(items) / sizeof(items[0]); k++) {
            if (items[k].title == nil) {
                [editMenu addItem:[NSMenuItem separatorItem]];
                continue;
            }
            NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:items[k].title
                                                       action:items[k].action
                                                keyEquivalent:items[k].key];
            [editMenu addItem:mi];
            [mi release];
        }
    }

    /* タイトル・中身が全て確定してから最後にインストールする。
       menubarが既存のものを流用したケースでも、念のため毎回呼び直して反映を確実にする */
    [NSApp setMainMenu:menubar];

    /* --- ウィンドウ --- */
    /* 接続欄の上にラベル行を追加したため、旧レイアウト(高さ450)より22px高くする。
       ラベル行・接続欄行は新しい高さ(h)基準、それより下の要素は旧来の高さ(oldH)基準のまま
       絶対位置を変えずに済ませている。 */
    float oldH = 450;
    NSRect frame = NSMakeRect(100, 100, 700, oldH + 22);
    window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:(NSTitledWindowMask | NSClosableWindowMask |
                                                      NSMiniaturizableWindowMask | NSResizableWindowMask)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [window setTitle:@"AquaLink"];

    NSView *content = [window contentView];
    float h = frame.size.height;
    float w = frame.size.width;

    [self loadBookmarks];

    NSString *savedUser = [[NSUserDefaults standardUserDefaults] stringForKey:@"AquaLinkLastUsername"];
    NSString *savedShare = [[NSUserDefaults standardUserDefaults] stringForKey:@"AquaLinkLastShare"];

    /* ラベル行(ユーザー名/アドレス/共有名/パスワードの取り違え防止のため常時表示) */
    NSFont *captionFont = [NSFont systemFontOfSize:9];

    NSTextField *userCaption = [[NSTextField alloc] initWithFrame:NSMakeRect(10, h - 16, 90, 14)];
    [userCaption setEditable:NO];
    [userCaption setBezeled:NO];
    [userCaption setDrawsBackground:NO];
    [userCaption setFont:captionFont];
    [userCaption setTextColor:[NSColor grayColor]];
    [userCaption setStringValue:L("ユーザー名")];
    [content addSubview:userCaption];
    [userCaption release];

    NSTextField *addressCaption = [[NSTextField alloc] initWithFrame:NSMakeRect(105, h - 16, 190, 14)];
    [addressCaption setEditable:NO];
    [addressCaption setBezeled:NO];
    [addressCaption setDrawsBackground:NO];
    [addressCaption setFont:captionFont];
    [addressCaption setTextColor:[NSColor grayColor]];
    [addressCaption setStringValue:L("アドレス(smb://は不要)")];
    [content addSubview:addressCaption];
    [addressCaption release];

    NSTextField *shareCaption = [[NSTextField alloc] initWithFrame:NSMakeRect(300, h - 16, 110, 14)];
    [shareCaption setEditable:NO];
    [shareCaption setBezeled:NO];
    [shareCaption setDrawsBackground:NO];
    [shareCaption setFont:captionFont];
    [shareCaption setTextColor:[NSColor grayColor]];
    [shareCaption setStringValue:L("共有名")];
    [content addSubview:shareCaption];
    [shareCaption release];

    NSTextField *passwordCaption = [[NSTextField alloc] initWithFrame:NSMakeRect(415, h - 16, 110, 14)];
    [passwordCaption setEditable:NO];
    [passwordCaption setBezeled:NO];
    [passwordCaption setDrawsBackground:NO];
    [passwordCaption setFont:captionFont];
    [passwordCaption setTextColor:[NSColor grayColor]];
    [passwordCaption setStringValue:L("パスワード")];
    [content addSubview:passwordCaption];
    [passwordCaption release];

    usernameField = [[NSTextField alloc] initWithFrame:NSMakeRect(10, h - 40, 90, 22)];
    if ([savedUser length] > 0) {
        [usernameField setStringValue:savedUser];
    }
    [usernameField setAutoresizingMask:(NSViewMinYMargin)];
    [content addSubview:usernameField];
    [usernameField release];

    urlField = [[NSComboBox alloc] initWithFrame:NSMakeRect(105, h - 40, 190, 22)];
    [urlField setStringValue:@""];
    [urlField setUsesDataSource:YES];
    [urlField setDataSource:self];
    [urlField setDelegate:self];
    [urlField setCompletes:NO];
    [urlField setAutoresizingMask:(NSViewMinYMargin)];
    [content addSubview:urlField];
    [urlField release];

    shareField = [[NSTextField alloc] initWithFrame:NSMakeRect(300, h - 40, 110, 22)];
    if ([savedShare length] > 0) {
        [shareField setStringValue:savedShare];
    }
    [shareField setAutoresizingMask:(NSViewMinXMargin | NSViewMinYMargin)];
    [content addSubview:shareField];
    [shareField release];

    passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(415, h - 40, 110, 22)];
    [passwordField setAutoresizingMask:(NSViewMinXMargin | NSViewMinYMargin)];
    [content addSubview:passwordField];
    [passwordField release];

    /* 起動時、直近の接続履歴があればアドレス・共有名・ユーザー名・パスワードを
       まとめて自動入力する(savedUser/savedShareの単純な記憶より新しく正確) */
    if ([bookmarks count] > 0) {
        [self autofillFromBookmarkAtIndex:0];
    }

    connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(530, h - 42, 100, 26)];
    [connectButton setTitle:L("接続")];
    [connectButton setBezelStyle:NSRoundedBezelStyle];
    [connectButton setTarget:self];
    [connectButton setAction:@selector(connectAction:)];
    [connectButton setAutoresizingMask:(NSViewMinXMargin | NSViewMinYMargin)];
    [content addSubview:connectButton];
    [connectButton release];

    /* libsmb2は何も指定しなければ「相手が暗号化を要求すれば暗号化する、
       要求しなければ平文のまま繋ぐ」という透過的な挙動になる。
       このチェックボックスは、それをさらに一歩進めて「相手が暗号化に対応して
       いなければ、そもそも接続自体を拒否する」という明示的なモードに切り替える。
       デフォルトはオフ(今まで通りの挙動を変えないため)。 */
    encryptCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(10, oldH - 42, 400, 18)];
    [encryptCheckbox setButtonType:NSSwitchButton];
    [encryptCheckbox setTitle:L("SMB3暗号化を必須にする(対応していない共有には接続できません)")];
    [encryptCheckbox setState:NSOffState];
    [encryptCheckbox setAutoresizingMask:(NSViewMinYMargin)];
    [content addSubview:encryptCheckbox];
    [encryptCheckbox release];

    /* 「▲ 上へ」表記に伴いupButtonの幅を広げる分、ここを20px削って場所を空ける */
    pathLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, oldH - 60, 460, 18)];
    [pathLabel setEditable:NO];
    [pathLabel setBezeled:NO];
    [pathLabel setDrawsBackground:NO];
    [pathLabel setStringValue:@""];
    [pathLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [content addSubview:pathLabel];
    [pathLabel release];

    /* 角丸ボタン(NSRoundedBezelStyle)は高さ22pxだと上辺の描画がフォントと
       被って消える不具合が実機で確認された(connectButton等、高さ26pxの
       ボタンでは発生しない)。他の正常なボタンに合わせて26pxにする。
       見た目の中心がずれないよう、上下2pxずつ広げる形でy座標も調整 */
    /* 「▲ 上へ」は「上へ」より長くなった分、幅を50→70pxに広げる。
       mountButtonの位置(x=560)に触れないよう、左のpathLabel側を20px削って
       場所を確保した(すぐ上のコメント参照) */
    upButton = [[NSButton alloc] initWithFrame:NSMakeRect(470, oldH - 64, 70, 26)];
    [upButton setTitle:L("▲ 上へ")];
    [upButton setBezelStyle:NSRoundedBezelStyle];
    [upButton setTarget:self];
    [upButton setAction:@selector(upAction:)];
    /* Finderと同じ⌘+↑で「上の階層へ」を呼べるようにする。NSButtonのkeyEquivalent
       機構をそのまま使うので、ボタンを直接クリックする操作と全く同じ経路を通る */
    [upButton setKeyEquivalent:[NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey]];
    [upButton setKeyEquivalentModifierMask:NSCommandKeyMask];
    [upButton setAutoresizingMask:(NSViewMinXMargin | NSViewMinYMargin)];
    [content addSubview:upButton];
    [upButton release];

    mountButton = [[NSButton alloc] initWithFrame:NSMakeRect(560, oldH - 64, 130, 26)];
    [mountButton setTitle:L("Finderに接続")];
    [mountButton setBezelStyle:NSRoundedBezelStyle];
    [mountButton setTarget:self];
    [mountButton setAction:@selector(mountAction:)];
    [mountButton setAutoresizingMask:(NSViewMinXMargin | NSViewMinYMargin)];
    [content addSubview:mountButton];
    [mountButton release];

    NSButton *shareSettingsButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, oldH - 94, 200, 26)];
    [shareSettingsButton setTitle:L("このMacを共有(NAS化)...")];
    [shareSettingsButton setBezelStyle:NSRoundedBezelStyle];
    [shareSettingsButton setTarget:self];
    [shareSettingsButton setAction:@selector(showShareWindow:)];
    [shareSettingsButton setAutoresizingMask:(NSViewMinYMargin)];
    [content addSubview:shareSettingsButton];
    [shareSettingsButton release];

    scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 30, w - 20, oldH - 130)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    tableView = [[NSTableView alloc] initWithFrame:[scrollView bounds]];
    [tableView setDataSource:self];
    [tableView setDelegate:self];
    [tableView setTarget:self];
    [tableView setUsesAlternatingRowBackgroundColors:YES];
    [tableView setDoubleAction:@selector(rowDoubleClicked:)];
    [tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [tableView registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
    /* アイコン(16px)と標準フォントが収まる行高。ウィンドウを広げたときは
       名前列だけが伸びる(サイズ・更新日時は固定幅のまま) */
    [tableView setRowHeight:18.0];
    [tableView setColumnAutoresizingStyle:NSTableViewFirstColumnOnlyAutoresizingStyle];

    NSFont *rowFont = [NSFont systemFontOfSize:[NSFont systemFontSize]];

    /* 名前列: 行頭にフォルダ/ファイルのアイコンを出す(Cyberduck/Transmit風)。
       アイコンの出し分けはtableView:willDisplayCell:forTableColumn:row:で行う。 */
    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[nameCol headerCell] setStringValue:L("名前")];
    [nameCol setWidth:300];
    [nameCol setMinWidth:120];
    /* 編集可能のままだとダブルクリックがフォルダを開かず名前変更モードに入ってしまうため */
    [nameCol setEditable:NO];
    [nameCol setResizingMask:NSTableColumnUserResizingMask];
    {
        ImageAndTextCell *nameCell = [[ImageAndTextCell alloc] init];
        [nameCell setFont:rowFont];
        [nameCell setEditable:NO];
        [nameCol setDataCell:nameCell];
        [nameCell release];
    }
    [tableView addTableColumn:nameCol];
    [nameCol release];

    /* サイズ列: 数字なので右寄せ。桁が揃って読みやすくなる */
    NSTableColumn *sizeCol = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    [[sizeCol headerCell] setStringValue:L("サイズ")];
    [[sizeCol headerCell] setAlignment:NSRightTextAlignment];
    [sizeCol setWidth:80];
    [sizeCol setMinWidth:60];
    [sizeCol setEditable:NO];
    [sizeCol setResizingMask:NSTableColumnUserResizingMask];
    [[sizeCol dataCell] setFont:rowFont];
    [[sizeCol dataCell] setAlignment:NSRightTextAlignment];
    [tableView addTableColumn:sizeCol];
    [sizeCol release];

    /* 更新日時列: ファイル自体の最終更新日時(接続日時ではない) */
    NSTableColumn *dateCol = [[NSTableColumn alloc] initWithIdentifier:@"date"];
    [[dateCol headerCell] setStringValue:L("更新日時")];
    [[dateCol headerCell] setAlignment:NSRightTextAlignment];
    [dateCol setWidth:135];
    [dateCol setMinWidth:115];
    [dateCol setEditable:NO];
    [dateCol setResizingMask:NSTableColumnUserResizingMask];
    [[dateCol dataCell] setFont:rowFont];
    [[dateCol dataCell] setAlignment:NSRightTextAlignment];
    [tableView addTableColumn:dateCol];
    [dateCol release];

    /* 起動時は名前・昇順。ヘッダに▲を出しておく */
    [self updateSortIndicators];

    [scrollView setDocumentView:tableView];
    [tableView release];
    [content addSubview:scrollView];
    [scrollView release];

    statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 6, w - 20, 18)];
    [statusLabel setEditable:NO];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setStringValue:L("未接続")];
    [statusLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [content addSubview:statusLabel];
    [statusLabel release];

    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    /* --- Bonjour: LAN上のSMB共有(_smb._tcp)を探し、アドレス欄のプルダウンに
       候補として出す。Finderの「ネットワーク」を開くとNASが出てくる、あの体験の
       代わり。IPアドレスを知らない人でも繋げるようにするのが狙い。
       見つけたサーバーは解決して数値IPにしてから候補に載せる(名前解決を通さない) */
    discoveredServices = [[NSMutableArray alloc] init];
    pendingResolves = [[NSMutableArray alloc] init];
    serviceBrowser = [[NSNetServiceBrowser alloc] init];
    [serviceBrowser setDelegate:self];
    [serviceBrowser searchForServicesOfType:@"_smb._tcp." inDomain:@"local."];

    [self autoStartSharingIfConfigured];

    /* アプリがアクティブになるたび(Dockクリック・⌘Tab復帰等)に、実際の
       マウント状態を確認して「取り外す」ボタンのずれを直す。Finderから
       直接取り出された場合などにボタンだけが残る不具合の保険。 */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                              selector:@selector(resyncMountedStateFromGroundTruth)
                                                  name:NSApplicationDidBecomeActiveNotification
                                                object:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    /* マウント中に何も考えずWebDAVサーバーを止めると、OS側はマウントされたままだと
       思い込んだ「壊れたマウント」が残ってしまう(実際に発生した不具合)。
       終了処理でも必ず先にマウントの後始末(mount_webdav kill + umount -f)をしてから
       サーバーを止める。ここが不完全だと、アプリ終了だけでマシンが固まる。 */
    if (mountPointPath != nil) {
        AQTeardownMountPoint(mountPointPath);
    }
    if (webdavServer != nil) {
        [webdavServer stop];
        [webdavServer release];
        webdavServer = nil;
    }
    if (localWebDAVServer != nil) {
        [localWebDAVServer stop];
        [localWebDAVServer release];
        localWebDAVServer = nil;
    }
    if (smb2 != NULL) {
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        smb2 = NULL;
    }
    if (serviceBrowser != nil) {
        [serviceBrowser stop];
        [serviceBrowser setDelegate:nil];
        [serviceBrowser release];
        serviceBrowser = nil;
    }
}

/* ============ 接続 ============ */

- (void)connectAction:(id)sender
{
    NSString *username = [usernameField stringValue];
    NSString *address = [urlField stringValue];
    NSString *share = [shareField stringValue];
    NSString *password = [passwordField stringValue];

    /* ユーザー名はURL文字列に埋め込まず、別経路(doConnect:のargs)でsmb2_set_user()に
       直接渡す。以前は "smb://user@address/share" の形にユーザー名を埋め込んでいたが、
       libsmb2のsmb2_parse_url()は"@"で単純にuser/serverを区切るだけでURLエスケープの
       デコードを一切行わないため、Windows 11のMicrosoftアカウント(例:
       tomo820@hotmail.co.jp)のように**ユーザー名自体に"@"が含まれる場合**、
       URL中に"@"が2つできてしまい「アドレスが見つからない」エラーになっていた
       (実際に発生した不具合)。%エスケープで回避しようとしても、smb2_parse_url側が
       デコードしないため今度は認証情報自体が壊れてしまう。ユーザー名を最初から
       URLに含めないのが正しい回避策。 */
    NSString *urlString = [NSString stringWithFormat:@"smb://%@/%@", address, share];

    [[NSUserDefaults standardUserDefaults] setObject:username forKey:@"AquaLinkLastUsername"];
    [[NSUserDefaults standardUserDefaults] setObject:share forKey:@"AquaLinkLastShare"];

    [connectButton setEnabled:NO];
    [statusLabel setStringValue:L("接続中...")];

    NSNumber *requireEncryption = [NSNumber numberWithBool:([encryptCheckbox state] == NSOnState)];
    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                           urlString, @"url",
                           (username ? username : @""), @"username",
                           (password ? password : @""), @"password",
                           requireEncryption, @"requireEncryption", nil];
    [NSThread detachNewThreadSelector:@selector(doConnect:) toTarget:self withObject:args];
}

- (void)doConnect:(NSDictionary *)args
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *urlString = [args objectForKey:@"url"];
    NSString *username = [args objectForKey:@"username"];
    NSString *password = [args objectForKey:@"password"];
    BOOL requireEncryption = [[args objectForKey:@"requireEncryption"] boolValue];

    [smb2Lock lock];
    if (smb2 != NULL) {
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        smb2 = NULL;
    }
    [smb2Lock unlock];

    struct smb2_context *ctx = smb2_init_context();
    if (ctx == NULL) {
        [self performSelectorOnMainThread:@selector(connectFailed:)
                                withObject:L("smb2コンテキストの初期化に失敗しました")
                             waitUntilDone:NO];
        [pool release];
        return;
    }

    struct smb2_url *url = smb2_parse_url(ctx, [urlString UTF8String]);
    if (url == NULL) {
        NSString *err = [NSString stringWithFormat:L("URL解析エラー: %s"), smb2_get_error(ctx)];
        smb2_destroy_context(ctx);
        [self performSelectorOnMainThread:@selector(connectFailed:) withObject:err waitUntilDone:NO];
        [pool release];
        return;
    }

    smb2_set_security_mode(ctx, SMB2_NEGOTIATE_SIGNING_ENABLED);
    /* 認証方式をNTLMSSPに固定する。デフォルト(SMB2_SEC_UNDEFINED)だと
       「Kerberosが使えるならKerberos、ダメならNTLM」という挙動になるが、
       libsmb2をKerberosサポート付きでビルドした環境(PPCPortsのdevel/libsmb2は
       デフォルトでこの変種)だと、ドメインコントローラの無い自宅NAS相手でも
       まずKerberos(GSSAPI)側を試しに行ってしまう。krb5.confも領域(realm)も
       無い環境ではgss_acquire_credがそこで失敗し、SPNEGOがNTLMへフォール
       バックせずに接続全体が落ちる(「Connection failed: gss_acquire_cred:
       Ein ungültiger Name wurde übergeben., SPNEGO kann keine Mechanismen
       zum Aushandeln finden.」のような文言で報告された不具合)。
       AquaLinkが繋ぐ先は家庭用NAS/Windows共有が主眼で、Active Directory
       環境を意図的に使うケースはまず無いので、最初からNTLMSSPに固定して
       このKerberos経路自体を回避する。 */
    smb2_set_authentication(ctx, SMB2_SEC_NTLMSSP);
    /* 何も指定しなければ、相手が暗号化を要求する場合は透過的に暗号化されるが、
       ここでチェックが入っていれば、相手が暗号化に対応していない場合は
       接続自体を失敗させる(smb2_set_sealのコメント参照)。 */
    smb2_set_seal(ctx, requireEncryption ? 1 : 0);
    /* ユーザー名はURLに埋め込まれていない(url->userは常にNULL)ので、
       別途渡された生のユーザー名をそのまま使う。%エスケープ等の変換は挟まない。 */
    if ([username length] > 0) {
        smb2_set_user(ctx, [username UTF8String]);
    }
    if ([password length] > 0) {
        smb2_set_password(ctx, [password UTF8String]);
    }

    int rc = smb2_connect_share(ctx, url->server, url->share, url->user);
    if (rc != 0) {
        NSString *err = FriendlyConnectError(UTF8(smb2_get_error(ctx)));
        smb2_destroy_url(url);
        smb2_destroy_context(ctx);
        [self performSelectorOnMainThread:@selector(connectFailed:) withObject:err waitUntilDone:NO];
        [pool release];
        return;
    }

    NSString *share = [NSString stringWithUTF8String:url->share];
    NSString *initialPath = url->path ? [NSString stringWithUTF8String:url->path] : @"";

    smb2_destroy_url(url);

    [smb2Lock lock];
    smb2 = ctx;
    [smb2Lock unlock];
    [currentShare release];
    currentShare = [share retain];

    [self performSelectorOnMainThread:@selector(connectSucceeded) withObject:nil waitUntilDone:NO];
    [self listDirectory:initialPath];

    [pool release];
}

- (void)connectSucceeded
{
    [statusLabel setStringValue:L("接続しました")];
    [connectButton setEnabled:YES];

    NSString *address = [urlField stringValue];
    NSString *share = [shareField stringValue];
    NSString *username = [usernameField stringValue];
    NSString *password = [passwordField stringValue];

    /* 依頼者フィードバック(2026-09-11): 接続先を示すpathLabel(「/共有名/パス」)が
       小さくて見落とされる。ウィンドウのタイトルバーに接続先を出せば、どこに
       繋がっているか一目で分かる。区切りの「—」はUTF8()経由で組む(@"..."直書き
       だと古いgccで文字化けするため) */
    [window setTitle:[NSString stringWithFormat:UTF8("AquaLink  —  %@/%@"), address, share]];

    [self addBookmarkWithAddress:address share:share username:username];

    /* 接続に成功したパスワードだけをKeychainに保存する(誤入力を覚えないため) */
    if ([password length] > 0) {
        NSString *account = ConnectKeychainAccount(username, address, share);
        SaveKeychainPassword(KEYCHAIN_SERVICE_CONNECT, account, password);
    }
}

- (void)connectFailed:(NSString *)message
{
    /* statusLabelは高さ18pxの1行専用フィールドなので、FriendlyConnectError()が
       返す「\n(詳細: ...)」付きの2行メッセージを渡しても、2行目は画面上に
       全く表示されない(切れるのではなく、単純に見えなくなる)。詳細情報が
       診断に必要な場面(saxfun氏からの報告で判明)なので、NSAlertでも
       全文を出すようにする。 */
    [statusLabel setStringValue:message];
    [connectButton setEnabled:YES];
    /* doConnect:は新しい接続を試す前に必ず既存の接続を切っているので、失敗時点で
       前の接続はもう無い。タイトルバーを素のアプリ名に戻す。 */
    [window setTitle:@"AquaLink"];

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:L("接続に失敗しました")];
    [alert setInformativeText:message];
    [alert addButtonWithTitle:L("OK")];
    [alert runModal];
    [alert release];
}

/* ============ ディレクトリ一覧 ============ */

/* バックグラウンドスレッドから呼ばれる。呼び出し元がNSAutoreleasePoolを用意していること */
- (void)listDirectory:(NSString *)path
{
    NSMutableArray *result = [NSMutableArray array];

    [smb2Lock lock];
    struct smb2dir *dir = smb2_opendir(smb2, [path UTF8String]);
    if (dir == NULL) {
        NSString *err = [NSString stringWithFormat:L("一覧取得失敗: %s"), smb2_get_error(smb2)];
        [smb2Lock unlock];
        [self performSelectorOnMainThread:@selector(listFailed:) withObject:err waitUntilDone:NO];
        return;
    }

    struct smb2dirent *ent;
    while ((ent = smb2_readdir(smb2, dir)) != NULL) {
        NSString *name = [NSString stringWithUTF8String:ent->name];
        if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
            continue;
        }
        /* "."で始まるファイル(.DS_Store、.lesshst等のドットファイル全般)は
           Finderの標準動作に合わせて一覧から隠す。.DS_Storeだけを個別に
           除外していたら.lesshst等の他の隠しファイルが素通りしていたため、
           プレフィックス判定に変更した。実データが消えるわけではなく、
           あくまで表示上のフィルタ */
        if ([name hasPrefix:@"."]) {
            continue;
        }
        BOOL isDir = (ent->st.smb2_type == SMB2_TYPE_DIRECTORY);
        NSDictionary *e = [NSDictionary dictionaryWithObjectsAndKeys:
                            name, @"name",
                            [NSNumber numberWithBool:isDir], @"isDir",
                            [NSNumber numberWithUnsignedLongLong:ent->st.smb2_size], @"size",
                            [NSNumber numberWithUnsignedLongLong:ent->st.smb2_mtime], @"mtime",
                            nil];
        [result addObject:e];
    }
    smb2_closedir(smb2, dir);
    [smb2Lock unlock];

    [currentPath release];
    currentPath = [path retain];

    NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
                              result, @"entries",
                              path, @"path", nil];
    [self performSelectorOnMainThread:@selector(applyEntries:) withObject:payload waitUntilDone:NO];
}

- (void)navigateThread:(NSString *)path
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [self listDirectory:path];
    [pool release];
}

- (void)listFailed:(NSString *)message
{
    [statusLabel setStringValue:message];
}

- (void)applyEntries:(NSDictionary *)payload
{
    NSArray *result = [payload objectForKey:@"entries"];
    NSString *path = [payload objectForKey:@"path"];

    [entries release];
    entries = [result mutableCopy];
    [self resortEntries];

    [tableView reloadData];
    [pathLabel setStringValue:[NSString stringWithFormat:@"/%@/%@",
                                (currentShare ? currentShare : @""), path]];
    [statusLabel setStringValue:[NSString stringWithFormat:L("%lu 件"), (unsigned long)[entries count]]];
}

/* ============ 一覧のソート(ヘッダクリック) ============ */

- (int)sortKeyKind
{
    if ([sortColumnId isEqualToString:@"size"]) {
        return 1;
    }
    if ([sortColumnId isEqualToString:@"date"]) {
        return 2;
    }
    return 0;
}

- (void)resortEntries
{
    EntrySortSpec spec;
    spec.keyKind = [self sortKeyKind];
    spec.ascending = sortAscending;
    [entries sortUsingFunction:CompareEntries context:&spec];
}

/* ソート中の列をハイライトし、▲▼のインジケータを付ける */
- (void)updateSortIndicators
{
    NSArray *cols = [tableView tableColumns];
    unsigned int i;
    for (i = 0; i < [cols count]; i++) {
        NSTableColumn *c = [cols objectAtIndex:i];
        if ([[c identifier] isEqualToString:sortColumnId]) {
            [tableView setHighlightedTableColumn:c];
            [tableView setIndicatorImage:
                [NSImage imageNamed:(sortAscending ? @"NSAscendingSortIndicator"
                                                   : @"NSDescendingSortIndicator")]
                           inTableColumn:c];
        } else {
            [tableView setIndicatorImage:nil inTableColumn:c];
        }
    }
}

- (void)tableView:(NSTableView *)aTableView didClickTableColumn:(NSTableColumn *)aTableColumn
{
    if (aTableView != tableView) {
        return;
    }
    NSString *clicked = [aTableColumn identifier];
    if ([clicked isEqualToString:sortColumnId]) {
        /* 同じ列を再クリック → 昇順/降順を反転 */
        sortAscending = !sortAscending;
    } else {
        [sortColumnId release];
        sortColumnId = [clicked retain];
        sortAscending = YES;
    }
    [self updateSortIndicators];
    [self resortEntries];
    [tableView reloadData];
}

- (void)rowDoubleClicked:(id)sender
{
    int row = [tableView clickedRow];
    if (row < 0 || row >= (int)[entries count]) {
        return;
    }
    NSDictionary *e = [entries objectAtIndex:row];
    if (![[e objectForKey:@"isDir"] boolValue]) {
        return;
    }
    NSString *name = [e objectForKey:@"name"];
    NSString *newPath = ([currentPath length] > 0)
        ? [NSString stringWithFormat:@"%@/%@", currentPath, name]
        : name;

    [statusLabel setStringValue:L("読み込み中...")];
    [NSThread detachNewThreadSelector:@selector(navigateThread:) toTarget:self withObject:newPath];
}

- (void)upAction:(id)sender
{
    if (smb2 == NULL || [currentPath length] == 0) {
        return;
    }
    NSRange r = [currentPath rangeOfString:@"/" options:NSBackwardsSearch];
    NSString *parent = (r.location == NSNotFound) ? @"" : [currentPath substringToIndex:r.location];

    [statusLabel setStringValue:L("読み込み中...")];
    [NSThread detachNewThreadSelector:@selector(navigateThread:) toTarget:self withObject:parent];
}

/* ============ NSTableView データソース ============ */

- (int)numberOfRowsInTableView:(NSTableView *)aTableView
{
    if (aTableView == shareFolderTable) {
        return (int)[shareFolders count];
    }
    return (int)[entries count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex
{
    if (aTableView == shareFolderTable) {
        if (rowIndex < 0 || rowIndex >= (int)[shareFolders count]) {
            return @"";
        }
        NSDictionary *f = [shareFolders objectAtIndex:rowIndex];
        NSString *identifier = [aTableColumn identifier];
        if ([identifier isEqualToString:@"name"]) {
            return [f objectForKey:@"name"];
        } else if ([identifier isEqualToString:@"path"]) {
            return [f objectForKey:@"path"];
        }
        return @"";
    }

    if (rowIndex < 0 || rowIndex >= (int)[entries count]) {
        return @"";
    }
    NSDictionary *e = [entries objectAtIndex:rowIndex];
    NSString *identifier = [aTableColumn identifier];
    BOOL isDir = [[e objectForKey:@"isDir"] boolValue];

    if ([identifier isEqualToString:@"name"]) {
        return [e objectForKey:@"name"];
    } else if ([identifier isEqualToString:@"size"]) {
        return FormatSize([[e objectForKey:@"size"] unsignedLongLongValue], isDir);
    } else if ([identifier isEqualToString:@"date"]) {
        return FormatDate([[e objectForKey:@"mtime"] unsignedLongLongValue]);
    }
    return @"";
}

/* 拡張子(フォルダの場合はnil)に対応する16pxアイコンを返す。
   NSWorkspaceの戻り値は使い回されるので、リサイズする前にcopyして
   拡張子ごとにキャッシュする(同じ一覧で何度も引かれるため)。

   [重大][修正済み・PowerMac G4実機で確認] このキャッシュされたNSImageは
   複数行・複数セルから共有される。以前は呼び出し側(ImageAndTextCellの
   drawWithFrame:inView:)で描画のたびに[icon setFlipped:...]を呼んでいたが、
   これは「行ごとに専用の画像」ではなく「共有された1つの画像オブジェクト」を
   毎回ミュータブルに書き換えていたことになる。NSTableViewの行選択時、
   AppKitは内部でハイライト用にセルを一時的にcopyWithZone:することがあり
   (実機で確認済み: 通常はcCell=0x547dd0が固定だが、選択の瞬間だけ別アドレスの
   コピーが一度だけ現れる)、そのコピーのiatImageも同じ共有画像インスタンスを
   指す(copyWithZone:はiatImageを retain するだけで複製はしない)。つまり
   「本来の行のセル」と「選択ハイライト用の一時コピー」が同時に同じ画像へ
   setFlipped:するタイミングが生まれ得る。スクロールバーの帯をクリックして
   一気に大量の行を再描画する操作(内部で行選択とほぼ同時に多数のwillDisplayCell
   呼び出しが走る)と組み合わさった時に、PowerMac G4実機で
   EXC_BAD_ACCESS(壊れたメモリへのアクセス)が再現した。他のアプリ(Aquafoxを
   含む)はこの独自セルを使っていないため無関係で、AquaLink固有の不具合だった。
   対策: setFlipped:を「描画のたび」ではなく「アイコンをキャッシュに入れる、
   ただ一度だけ」ここで呼ぶように変更した。NSTableViewの中身は常にflippedな
   座標系なので、行ごとに問い合わせ直す必要はそもそも無い。 */
static NSImage *IconForExtension(NSString *ext)
{
    static NSMutableDictionary *cache = nil;
    if (cache == nil) {
        cache = [[NSMutableDictionary alloc] init];
    }
    NSString *key = (ext != nil) ? ext : @"__folder__";
    NSImage *icon = [cache objectForKey:key];
    if (icon != nil) {
        return icon;
    }
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    NSImage *src = (ext != nil)
        ? [ws iconForFileType:ext]
        : [ws iconForFile:@"/Library"];   /* 常に存在する素のフォルダ */
    icon = [[src copy] autorelease];
    [icon setSize:NSMakeSize(16.0, 16.0)];
    [icon setFlipped:YES]; /* NSTableViewの行は常にflipped。ここで一度だけ設定する */
    if (icon != nil) {
        [cache setObject:icon forKey:key];
    }
    return icon;
}

- (void)tableView:(NSTableView *)aTableView willDisplayCell:(id)aCell
   forTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex
{
    if (aTableView != tableView) {
        return;
    }
    if (![[aTableColumn identifier] isEqualToString:@"name"]) {
        return;
    }
    if (rowIndex < 0 || rowIndex >= (int)[entries count]) {
        return;
    }
    NSDictionary *e = [entries objectAtIndex:rowIndex];
    BOOL isDir = [[e objectForKey:@"isDir"] boolValue];
    NSString *ext = isDir ? nil : [[e objectForKey:@"name"] pathExtension];
    /* 画像そのものは持たせず、拡張子(文字列、フォルダならnil)だけをNSCell標準の
       representedObjectに積む。実際の画像はセル自身がdrawWithFrame:inView:の
       中でIconForExtension()から都度引く(詳細はImageAndTextCellのコメント参照)。 */
    [aCell setRepresentedObject:ext];
}

/* ============ ドラッグ&ドロップ(書き出しのみ。第1段) ============ */

- (BOOL)tableView:(NSTableView *)aTableView writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard
{
    NSMutableIndexSet *fileRows = [NSMutableIndexSet indexSet];
    unsigned int idx = [rowIndexes firstIndex];
    while (idx != NSNotFound) {
        NSDictionary *e = [entries objectAtIndex:idx];
        if (![[e objectForKey:@"isDir"] boolValue]) {
            [fileRows addIndex:idx];
        }
        idx = [rowIndexes indexGreaterThanIndex:idx];
    }
    if ([fileRows count] == 0) {
        /* フォルダのドラッグ書き出しは第1段では未対応 */
        return NO;
    }

    NSMutableArray *extensions = [NSMutableArray array];
    idx = [fileRows firstIndex];
    while (idx != NSNotFound) {
        NSDictionary *e = [entries objectAtIndex:idx];
        NSString *ext = [[e objectForKey:@"name"] pathExtension];
        [extensions addObject:(ext ? ext : @"")];
        idx = [fileRows indexGreaterThanIndex:idx];
    }

    [pboard declareTypes:[NSArray arrayWithObject:NSFilesPromisePboardType] owner:self];
    [pboard setPropertyList:extensions forType:NSFilesPromisePboardType];
    return YES;
}

- (NSArray *)tableView:(NSTableView *)tv
    namesOfPromisedFilesDroppedAtDestination:(NSURL *)dropDestination
    forDraggedRowsWithIndexes:(NSIndexSet *)indexSet
{
    NSMutableArray *writtenNames = [NSMutableArray array];
    NSString *destPath = [dropDestination path];

    unsigned int idx = [indexSet firstIndex];
    while (idx != NSNotFound) {
        NSDictionary *e = [entries objectAtIndex:idx];
        NSString *name = [e objectForKey:@"name"];
        NSString *remotePath = ([currentPath length] > 0)
            ? [NSString stringWithFormat:@"%@/%@", currentPath, name]
            : name;
        NSString *localPath = [destPath stringByAppendingPathComponent:name];

        if ([self downloadRemotePath:remotePath toLocalPath:localPath]) {
            [writtenNames addObject:name];
        } else {
            [statusLabel setStringValue:[NSString stringWithFormat:L("%@ のダウンロードに失敗しました"), name]];
        }
        idx = [indexSet indexGreaterThanIndex:idx];
    }
    return writtenNames;
}

/* Finderからのドロップ完了コールバック中(メインスレッド)で同期的に実行する */
- (BOOL)downloadRemotePath:(NSString *)remotePath toLocalPath:(NSString *)localPath
{
    [smb2Lock lock];
    struct smb2fh *fh = smb2_open(smb2, [remotePath UTF8String], O_RDONLY);
    if (fh == NULL) {
        [smb2Lock unlock];
        return NO;
    }

    NSMutableData *data = [NSMutableData data];
    uint8_t buf[65536];
    int n;
    while ((n = smb2_read(smb2, fh, buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:n];
    }
    smb2_close(smb2, fh);
    [smb2Lock unlock];

    if (n < 0) {
        return NO;
    }
    return [data writeToFile:localPath atomically:YES];
}

/* ============ ドラッグ&ドロップ(受け入れ。Finder → NAS) ============ */

- (NSDragOperation)tableView:(NSTableView *)tv
                 validateDrop:(id <NSDraggingInfo>)info
                  proposedRow:(int)row
        proposedDropOperation:(NSTableViewDropOperation)op
{
    if (smb2 == NULL) {
        return NSDragOperationNone;
    }
    NSPasteboard *pboard = [info draggingPasteboard];
    if (![[pboard types] containsObject:NSFilenamesPboardType]) {
        return NSDragOperationNone;
    }
    /* 特定の行ではなく「このフォルダ全体」への配置として扱う */
    [tv setDropRow:-1 dropOperation:NSTableViewDropOn];
    return NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView *)tv
        acceptDrop:(id <NSDraggingInfo>)info
               row:(int)row
     dropOperation:(NSTableViewDropOperation)op
{
    NSPasteboard *pboard = [info draggingPasteboard];
    NSArray *localPaths = [pboard propertyListForType:NSFilenamesPboardType];
    if ([localPaths count] == 0) {
        return NO;
    }

    /* ディレクトリのアップロードは第1段では未対応。ファイルのみ対象にする */
    NSMutableArray *filePaths = [NSMutableArray array];
    NSEnumerator *e = [localPaths objectEnumerator];
    NSString *p;
    while ((p = [e nextObject])) {
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && !isDir) {
            [filePaths addObject:p];
        }
    }
    if ([filePaths count] == 0) {
        return NO;
    }

    [statusLabel setStringValue:L("アップロード中...")];
    [NSThread detachNewThreadSelector:@selector(uploadFiles:) toTarget:self withObject:filePaths];
    return YES;
}

/* バックグラウンドスレッドで実行 */
- (void)uploadFiles:(NSArray *)localPaths
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    int successCount = 0;
    int failCount = 0;
    NSEnumerator *e = [localPaths objectEnumerator];
    NSString *localPath;
    while ((localPath = [e nextObject])) {
        NSString *filename = [localPath lastPathComponent];
        NSString *remotePath = ([currentPath length] > 0)
            ? [NSString stringWithFormat:@"%@/%@", currentPath, filename]
            : filename;
        if ([self uploadLocalPath:localPath toRemotePath:remotePath]) {
            successCount++;
        } else {
            failCount++;
        }
    }

    NSDictionary *result = [NSDictionary dictionaryWithObjectsAndKeys:
                             [NSNumber numberWithInt:successCount], @"success",
                             [NSNumber numberWithInt:failCount], @"fail", nil];
    [self performSelectorOnMainThread:@selector(uploadFinished:) withObject:result waitUntilDone:NO];

    [pool release];
}

- (void)uploadFinished:(NSDictionary *)result
{
    int fail = [[result objectForKey:@"fail"] intValue];
    if (fail > 0) {
        [statusLabel setStringValue:[NSString stringWithFormat:L("%d件のアップロードに失敗しました"), fail]];
    }
    [NSThread detachNewThreadSelector:@selector(navigateThread:) toTarget:self withObject:currentPath];
}

/* バックグラウンドスレッドから呼ばれる */
- (BOOL)uploadLocalPath:(NSString *)localPath toRemotePath:(NSString *)remotePath
{
    NSData *data = [NSData dataWithContentsOfFile:localPath];
    if (data == nil) {
        return NO;
    }

    [smb2Lock lock];
    struct smb2fh *fh = smb2_open(smb2, [remotePath UTF8String], O_WRONLY | O_CREAT | O_TRUNC);
    if (fh == NULL) {
        [smb2Lock unlock];
        return NO;
    }

    const uint8_t *bytes = [data bytes];
    unsigned long long length = [data length];
    unsigned long long offset = 0;
    BOOL ok = YES;
    while (offset < length) {
        unsigned long long remaining = length - offset;
        uint32_t chunk = (remaining > 65536) ? 65536 : (uint32_t)remaining;
        int n = smb2_write(smb2, fh, bytes + offset, chunk);
        if (n <= 0) {
            ok = NO;
            break;
        }
        offset += (unsigned long long)n;
    }
    smb2_close(smb2, fh);
    [smb2Lock unlock];
    return ok;
}

/* ============ WebDAVServerから使うアクセサ ============ */

- (struct smb2_context *)smb2Context
{
    return smb2;
}

- (NSLock *)smb2Lock
{
    return smb2Lock;
}

- (NSString *)currentShareName
{
    return currentShare;
}

- (BOOL)isConnected
{
    return smb2 != NULL;
}

/* ============ Finderへのマウント(第2段) ============ */

/* pathが今まさにマウントポイントの直上(そこがボリュームのルート)かどうか。
   statfsのf_mntonnameがpath自身と一致すればマウントポイント。 */
static BOOL AQIsMountPoint(NSString *path)
{
    struct statfs sfs;
    if (statfs([path fileSystemRepresentation], &sfs) != 0) {
        return NO;
    }
    return (strcmp(sfs.f_mntonname, [path fileSystemRepresentation]) == 0);
}

/* /Volumes/<base> が既にマウント済みなら /Volumes/<base>-2, -3 ... と空いている名前を探す。
   Finder自身も共有名が衝突すると同じことをする。見つからなければnil。 */
static NSString *AQAvailableMountPoint(NSString *base)
{
    NSString *p = [@"/Volumes" stringByAppendingPathComponent:base];
    if (!AQIsMountPoint(p)) {
        return p;
    }
    int i;
    for (i = 2; i <= 20; i++) {
        NSString *cand = [@"/Volumes" stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"%@-%d", base, i]];
        if (!AQIsMountPoint(cand)) {
            return cand;
        }
    }
    return nil;
}

/* 指定のマウントポイントを引数に持つ mount_webdav プロセスを SIGKILL する。
   mount_webdav は setuid root だが「実UID」は起動ユーザーのままなので、同じ実UIDの
   このプロセスから kill(2) が通る(サーバーが応答しなくなって固まった mount_webdav を
   確実に始末するための手段)。umount より先にこれをやると、以後の umount -f が
   ほぼ確実に成功する。 */
static void AQKillMountWebdavAt(NSString *mountPoint)
{
    NSTask *ps = [[NSTask alloc] init];
    [ps setLaunchPath:@"/bin/ps"];
    [ps setArguments:[NSArray arrayWithObjects:@"-axww", @"-o", @"pid=,command=", nil]];
    NSPipe *pipe = [NSPipe pipe];
    [ps setStandardOutput:pipe];
    [ps setStandardError:[NSPipe pipe]];
    NSData *out = nil;
    @try {
        [ps launch];
        out = [[pipe fileHandleForReading] readDataToEndOfFile];
        [ps waitUntilExit];
    }
    @catch (NSException *ex) { }
    [ps release];
    if (out == nil) {
        return;
    }
    NSString *s = [[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] autorelease];
    NSEnumerator *lines = [[s componentsSeparatedByString:@"\n"] objectEnumerator];
    NSString *line;
    while ((line = [lines nextObject])) {
        if ([line rangeOfString:@"mount_webdav"].location == NSNotFound) {
            continue;
        }
        if ([line rangeOfString:mountPoint].location == NSNotFound) {
            continue;
        }
        int pid = [line intValue]; /* 行頭のpid */
        if (pid > 1) {
            kill(pid, SIGKILL);
        }
    }
}

/* umount(必要なら -f)を、指定秒でタイムアウトしながら実行する。
   固まった WebDAV マウントに対して素の umount がハングすることがあるため、
   waitUntilExit ではなくポーリングし、時間切れなら SIGKILL する。
   戻り値: 実行後に mountPoint がマウントポイントでなくなっていれば YES。 */
static BOOL AQRunUmount(NSString *mountPoint, BOOL force, double timeoutSec)
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/sbin/umount"];
    [task setArguments:(force
        ? [NSArray arrayWithObjects:@"-f", mountPoint, nil]
        : [NSArray arrayWithObjects:mountPoint, nil])];
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    @try {
        [task launch];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSec];
        while ([task isRunning] && [deadline timeIntervalSinceNow] > 0) {
            [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        }
        if ([task isRunning]) {
            kill([task processIdentifier], SIGKILL);
            [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        }
    }
    @catch (NSException *ex) { }
    [task release];
    /* 成否は terminationStatus ではなく「実際に外れたか」で判断する */
    return !AQIsMountPoint(mountPoint);
}

/* 開いているFinderウィンドウの数を、osascriptを子プロセスとして起動して尋ねる
   (NSAppleScriptではなくNSTask経由にしているのは、この関数がバックグラウンド
   スレッドから呼ばれることもあるため。スレッドを問わず安全に使えるNSTaskで
   統一する)。判定できなければ-1を返す(安全側に倒すため「開いている扱い」
   として使う)。 */
static int AQFinderOpenWindowCount(void)
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/osascript"];
    [task setArguments:[NSArray arrayWithObjects:@"-e",
                            @"tell application \"Finder\" to count windows", nil]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];
    NSData *out = nil;
    @try {
        [task launch];
        out = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
    }
    @catch (NSException *ex) {
        [task release];
        return -1;
    }
    [task release];
    if (out == nil || [out length] == 0) {
        return -1;
    }
    NSString *s = [[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] autorelease];
    return [s intValue];
}

static void AQKillallFinder(void)
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/killall"];
    [task setArguments:[NSArray arrayWithObject:@"Finder"]];
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    @try {
        [task launch];
    }
    @catch (NSException *ex) { }
    [task release];
}

/* 生のumount(2)(setuidヘルパー・ターミナルのsudo umount共通)はDiskArbitration
   経由の通知を出さないため、デスクトップ/サイドバーのボリュームアイコンが
   実体消滅後も残ってしまう(実機で確認済み)。NSWorkspaceの
   noteFileSystemChanged:も試したが効果が無かった(実機で確認済み)。
   Finder自身を再起動する(killall Finder)以外に実機で効く手段が無かった。
   ★ただし、複数のFinderウィンドウを開いて中身を見比べている最中に
   問答無用で再起動すると、その作業を丸ごと中断させてしまう(実際に指摘を
   受けた懸念)。開いているウィンドウが無ければ黙って直す。ウィンドウが
   ある(または判定できない)時は、無断で閉じずに本人に確認する
   (AppDelegateの-refreshFinderVolumeIconsAskingIfNeededへ)。 */
static void AQRefreshFinderVolumeIcons(void)
{
    if (AQFinderOpenWindowCount() == 0) {
        AQKillallFinder();
        return;
    }
    [(id)[NSApp delegate] performSelectorOnMainThread:@selector(refreshFinderVolumeIconsAskingIfNeeded)
                                            withObject:nil
                                         waitUntilDone:NO];
}

/* mountPointに残った空ディレクトリを片付ける(中身があれば触らない=
   /Volumes直下の実フォルダを誤って消さない) */
static void AQCleanupEmptyMountDir(NSString *mountPoint)
{
    if (mountPoint == nil || AQIsMountPoint(mountPoint)) {
        return;
    }
    NSArray *contents = [[NSFileManager defaultManager] directoryContentsAtPath:mountPoint];
    if (contents != nil && [contents count] == 0) {
        rmdir([mountPoint fileSystemRepresentation]);
        AQRefreshFinderVolumeIcons();
    }
}

/* マウントポイントを「普通に」外す。umount → umount -f の順でタイムアウト付きで
   試す。★ここでは絶対に mount_webdav を先にkillしない。実機で確認済み:
   生きているデーモンとの協調が無いと、その後どれだけ強くumountを試しても
   (root権限でも)綺麗に外れなくなる。中途半端に「早く外そう」とkillを混ぜるのは
   逆効果で、この方式(何もkillしない)が一番確実だった。
   戻り値: 実行後に mountPoint がマウントポイントでなくなっていれば YES。 */
static BOOL AQTeardownMountPoint(NSString *mountPoint)
{
    if (mountPoint == nil) {
        return YES;
    }
    if (AQIsMountPoint(mountPoint)) {
        AQRunUmount(mountPoint, NO, 10.0);
    }
    if (AQIsMountPoint(mountPoint)) {
        AQRunUmount(mountPoint, YES, 10.0);
    }
    BOOL clear = !AQIsMountPoint(mountPoint);
    if (clear) {
        AQCleanupEmptyMountDir(mountPoint);
    }
    return clear;
}

/* まだ一度も成立していない(失敗/タイムアウトした)マウント「試行」を諦めて
   片付ける専用。doMountの失敗経路だけから呼ぶこと。守るべき成功済みマウントが
   まだ無いので、ここでは mount_webdav をSIGKILLしても実害が無い
   (AQTeardownMountPointと違い、これは既存の生きたマウントには絶対に使わない)。 */
static BOOL AQAbandonFailedMountAttempt(NSString *mountPoint)
{
    if (mountPoint == nil) {
        return YES;
    }
    AQKillMountWebdavAt(mountPoint);
    [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    BOOL clear = AQTeardownMountPoint(mountPoint);
    if (!clear) {
        AQCleanupEmptyMountDir(mountPoint);
    }
    return clear;
}

/* アプリに同梱したsetuid rootヘルパー(aqualink-umount-helper。詳細は
   その.cファイルとsmb3/README.md参照)へのパス。アプリバンドルの外に出ても
   困らないよう、実行中のバンドル自身から探す。 */
static NSString *AQUmountHelperPath(void)
{
    return [[NSBundle mainBundle] pathForResource:@"aqualink-umount-helper" ofType:nil];
}

/* ヘルパーが「root所有 かつ setuidビット付き」になっているか。両方揃って
   初めて実行時にroot権限で動く(所有者がwatermarkのままだとsetuidを立てても
   watermark権限にしかならない)。 */
static BOOL AQUmountHelperHasSetuid(void)
{
    NSString *path = AQUmountHelperPath();
    if (path == nil) {
        return NO; /* 同梱されていない(古いビルド等) */
    }
    NSDictionary *a = [[NSFileManager defaultManager] fileAttributesAtPath:path traverseLink:YES];
    if (a == nil) {
        return NO;
    }
    BOOL isRoot = ([[a objectForKey:NSFileOwnerAccountID] unsignedLongValue] == 0);
    BOOL setuid = (([[a objectForKey:NSFilePosixPermissions] unsignedLongValue] & 04000) != 0);
    return isRoot && setuid;
}

/* setuid rootヘルパーを使って、パスワードダイアログを一切出さずにumountする
   (helperPathは実行時にroot所有・setuid付きになっている前提。呼ぶ前に
   AQUmountHelperHasSetuid()で確認しておくこと)。ハング対策はAQRunUmountと
   同じ、ポーリング+タイムアウト+SIGKILL。
   戻り値: 実行後にmountPointがマウントポイントでなくなっていればYES。 */
static BOOL AQRunPrivilegedHelperUmount(NSString *mountPoint, double timeoutSec)
{
    NSString *helperPath = AQUmountHelperPath();
    if (helperPath == nil) {
        return !AQIsMountPoint(mountPoint);
    }
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:helperPath];
    [task setArguments:[NSArray arrayWithObject:mountPoint]];
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    @try {
        [task launch];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSec];
        while ([task isRunning] && [deadline timeIntervalSinceNow] > 0) {
            [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        }
        if ([task isRunning]) {
            kill([task processIdentifier], SIGKILL);
            [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        }
    }
    @catch (NSException *ex) { }
    [task release];
    return !AQIsMountPoint(mountPoint);
}

/* /sbin/mount_webdav にsetuidビットが付いているか。付いていないと一般ユーザーでは
   マウントできない(OSアップデート等で剥がれることがある) */
static BOOL AQMountWebdavHasSetuid(void)
{
    NSDictionary *a = [[NSFileManager defaultManager]
                          fileAttributesAtPath:@"/sbin/mount_webdav" traverseLink:YES];
    if (a == nil) {
        return YES; /* 取得できないなら判定しない(そのまま実行を試す) */
    }
    return ([[a objectForKey:NSFilePosixPermissions] unsignedLongValue] & 04000) != 0;
}

/* 実際のマウント状態を後から確認し、内部状態(mounted)とボタン表示を現実に
   合わせ直す。Finderのサイドバーから直接「取り出す」を選んだ場合や、今回の
   ようにSSH等アプリの外からumountされた場合、AquaLink自身の取り外し処理
   (doUnmount)を一度も通らないため、mountedフラグが古いままになり、実際には
   何も残っていないのに「取り外す」ボタンだけが表示され続けてしまう
   (実機で確認された不具合)。ボタンを押す直前と、アプリがアクティブに
   なった直後に呼んで、ずれていれば直す。 */
- (void)resyncMountedStateFromGroundTruth
{
    if (!mounted || mountPointPath == nil) {
        return;
    }
    if (AQIsMountPoint(mountPointPath)) {
        return; /* 実際にまだマウントされている。合っているので何もしない */
    }
    if (webdavServer != nil) {
        [webdavServer stop];
        [webdavServer release];
        webdavServer = nil;
    }
    AQCleanupEmptyMountDir(mountPointPath);
    [mountPointPath release];
    mountPointPath = nil;
    mounted = NO;
    [mountButton setEnabled:YES];
    [mountButton setTitle:L("Finderに接続")];
    [statusLabel setStringValue:L("取り外し済みでした(Finder等で先に取り外された可能性があります)")];
}

- (void)mountAction:(id)sender
{
    [self resyncMountedStateFromGroundTruth];
    if (mounted) {
        [self unmountAction:sender];
        return;
    }
    if (![self isConnected]) {
        [statusLabel setStringValue:L("先に接続してください")];
        return;
    }

    /* /sbin/mount_webdav のsetuidビットが剥がれていると、この後のマウントは必ず
       失敗する。原因が分かりにくいので、実行前にここで確認し、剥がれていたら
       「自動で直す」ボタン付きのダイアログを出す。押せば管理者権限で
       `chmod u+s /sbin/mount_webdav`(本来あるべき状態に戻すだけ)を代行する。 */
    if (!AQMountWebdavHasSetuid()) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:L("マウントの準備が必要です")];
        [alert setInformativeText:L("/sbin/mount_webdav に管理者権限(setuid)が付いていません。OSアップデート等で外れることがあります。本来あるべき状態に戻すため、次のコマンドを管理者権限で実行します:\n\nchmod u+s /sbin/mount_webdav")];
        [alert addButtonWithTitle:L("自動で直す")];
        [alert addButtonWithTitle:L("キャンセル")];
        int resp = [alert runModal];
        [alert release];
        if (resp != NSAlertFirstButtonReturn) {
            return;
        }
        NSString *err = nil;
        if (![self restorePrivilegedMountWebdavSetuid:&err]) {
            NSAlert *a2 = [[NSAlert alloc] init];
            [a2 setMessageText:L("自動修復に失敗しました")];
            [a2 setInformativeText:[NSString stringWithFormat:
                L("%@\n\n手動でも直せます。ターミナルで次を1行実行してください:\nsudo chmod u+s /sbin/mount_webdav"),
                (err ? err : @"")]];
            [a2 addButtonWithTitle:L("OK")];
            [a2 runModal];
            [a2 release];
            return;
        }
    }

    [mountButton setEnabled:NO];
    [statusLabel setStringValue:L("Finderに接続中...")];
    [NSThread detachNewThreadSelector:@selector(doMount) toTarget:self withObject:nil];
}

- (void)doMount
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    webdavServer = [[WebDAVServer alloc] initWithAppDelegate:self];
    int p = 8090;
    BOOL started = NO;
    int attempt;
    for (attempt = 0; attempt < 10; attempt++) {
        if ([webdavServer startOnPort:p]) {
            started = YES;
            break;
        }
        p++;
    }

    if (!started) {
        [webdavServer release];
        webdavServer = nil;
        [self performSelectorOnMainThread:@selector(mountFailed:)
                                withObject:L("WebDAVサーバーの起動に失敗しました")
                             waitUntilDone:NO];
        [pool release];
        return;
    }

    NSString *mountName = ([currentShare length] > 0) ? currentShare : @"NAS";
    /* 同名のマウントが既に残っていると、その場所へ再度mount_webdavしようとして
       ハングする(前セッションのマウントが外れずに残っていた実例あり)。
       Finder同様、空いている `/Volumes/<名前>-2` 等を探して使う。 */
    NSString *mountPoint = AQAvailableMountPoint(mountName);
    if (mountPoint == nil) {
        [webdavServer stop];
        [webdavServer release];
        webdavServer = nil;
        [self performSelectorOnMainThread:@selector(mountFailed:)
            withObject:L("マウント先の空きが見つかりません。/Volumes に古いマウントが残っている可能性があります。ターミナルで sudo umount -f /Volumes/共有名 を試してください。")
            waitUntilDone:NO];
        [pool release];
        return;
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:mountPoint attributes:nil];

    NSString *urlString = [NSString stringWithFormat:@"http://127.0.0.1:%d/", [webdavServer port]];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/sbin/mount_webdav"];
    [task setArguments:[NSArray arrayWithObjects:urlString, mountPoint, nil]];
    [task setStandardOutput:[NSPipe pipe]];
    NSPipe *errPipe = [NSPipe pipe];
    [task setStandardError:errPipe];

    NSString *resultMessage = nil;
    BOOL success = NO;
    BOOL timedOut = NO;
    @try {
        [task launch];
        /* mount_webdav が万一固まっても永久に待たないよう、25秒で打ち切る。
           waitUntilExit の代わりにポーリングする。 */
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:25.0];
        while ([task isRunning] && [deadline timeIntervalSinceNow] > 0) {
            [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        }
        if ([task isRunning]) {
            /* terminate(SIGTERM)ではmount_webdavが死なないことがあるので直接SIGKILL。
               実UIDが同じなので届く。 */
            kill([task processIdentifier], SIGKILL);
            [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            timedOut = YES;
            resultMessage = L("マウント失敗: 応答がありません(タイムアウト)");
            success = NO;
        } else {
            success = ([task terminationStatus] == 0);
        }
    }
    @catch (NSException *ex) {
        resultMessage = [NSString stringWithFormat:L("マウント失敗: %@"), [ex reason]];
        success = NO;
    }

    /* 「成功」と言っていても本当にマウントできているか最終確認する。
       mount_webdav が終了コード0で戻りつつ実際にはマウントできていない、
       という半端な状態を弾く。 */
    if (success && !AQIsMountPoint(mountPoint)) {
        success = NO;
        if (resultMessage == nil) {
            resultMessage = L("マウント失敗: マウントが完了しませんでした");
        }
    }

    if (success) {
        mountPointPath = [mountPoint retain];
        mounted = YES;
        resultMessage = [NSString stringWithFormat:L("%@ にマウントしました"), mountPoint];
    } else if (resultMessage == nil) {
        NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errStr = [[[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] autorelease];
        resultMessage = [NSString stringWithFormat:L("マウント失敗: %@"), (errStr ? errStr : @"")];
    }
    (void)timedOut;
    [task release];

    if (!success) {
        /* 失敗した時は、サーバーを止める *前に* 必ずマウント試行の後始末をする。
           半端に張られたマウント + mount_webdav を残したままサーバーを止めると、
           カーネルが応答の来ないHTTPを永久に待ち、/Volumes 全体(Finder/Dock含む)が
           固まる。順序が命。まだ成立していない試行を諦めるだけなので、
           mount_webdavをkillしても実害は無い(成功済みマウントには絶対に使わない
           AQAbandonFailedMountAttemptを使う。AQTeardownMountPointとの違いは
           コメント参照)。 */
        AQAbandonFailedMountAttempt(mountPoint);
        [webdavServer stop];
        [webdavServer release];
        webdavServer = nil;
    }

    [self performSelectorOnMainThread:(success ? @selector(mountSucceededWithMessage:)
                                              : @selector(mountFailed:))
                            withObject:resultMessage
                         waitUntilDone:NO];
    [pool release];
}

/* マウント失敗時。接続失敗(connectFailed:)と同じく、下部のステータス欄だけだと
   見落とされる(実際に「押しても何も起きない」と受け取られた)ので、NSAlertでも
   全文を出す。ボタンはクリックできる「OK」。 */
- (void)mountFailed:(NSString *)message
{
    [statusLabel setStringValue:message];
    [mountButton setEnabled:YES];
    [mountButton setTitle:L("Finderに接続")];

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:L("Finderへの接続に失敗しました")];
    [alert setInformativeText:message];
    [alert addButtonWithTitle:L("OK")];
    [alert runModal];
    [alert release];
}

/* マウント成功時。ステータス・ボタンを更新し、そのボリュームをFinderで開いて見せる。
   「接続しました」と出ても何が起きたか分からない、Finder環境設定次第では
   デスクトップ/サイドバーにアイコンも出ない、という声を受けての対応。
   ★アンマウント経路からは呼ばない(失敗した取り外しでフォルダが再オープンされる
   のを防ぐため、マウント成功専用にした)。 */
- (void)mountSucceededWithMessage:(NSString *)message
{
    [statusLabel setStringValue:message];
    [mountButton setEnabled:YES];
    [mountButton setTitle:L("取り外す")];
    if (mountPointPath != nil) {
        [[NSWorkspace sharedWorkspace] openFile:mountPointPath];
    }
}

/* 取り外し(成否問わず)の結果表示。ここではFinderを開かない。 */
- (void)mountFinishedWithMessage:(NSString *)message
{
    [statusLabel setStringValue:message];
    [mountButton setEnabled:YES];
    [mountButton setTitle:(mounted ? L("取り外す") : L("Finderに接続"))];
}

- (void)unmountAction:(id)sender
{
    [mountButton setEnabled:NO];
    [statusLabel setStringValue:L("取り外し中...")];
    [NSThread detachNewThreadSelector:@selector(doUnmount) toTarget:self withObject:nil];
}

- (void)doUnmount
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *mp = [[mountPointPath retain] autorelease];
    NSString *privilegedError = nil;

    /* まず標準の後始末(mount_webdavをkill → umount → umount -f、いずれもタイムアウト付き。
       最後に「本当に外れたか」をstatfsで確認)。ここを terminationStatus ではなく
       実際の状態で判定するのが肝。半端に外れたと誤認してサーバーを止めると、
       応答の来ないマウントが残って /Volumes 全体(Finder/Dock含む)が固まる。 */
    BOOL unmountOK = AQTeardownMountPoint(mp);

    if (!unmountOK && mp != nil) {
        /* 一部の環境では、マウントがroot所有として扱われ、一般ユーザー権限の
           umountが "Operation not permitted" で拒否される(実機で確認済み)。
           次の一手は、GUIのパスワードダイアログ(runPrivilegedUnmount:)ではなく、
           同梱のsetuid rootヘルパー(aqualink-umount-helper)を直接叩く方法。
           GUIダイアログ経由のroot権限は、マウントしたのと別セッション扱いに
           なるらしく同じ"Operation not permitted"で失敗することが実機で判明した
           一方、mount_webdav自身と同じ「setuidで直接fork/exec」した権限なら
           成功することも確認済み(smb3/README.md参照)。ヘルパーの初回準備だけは
           管理者パスワードが要るので、メインスレッドに同期で確認してもらう。 */
        NSMutableArray *helperReadyHolder = [NSMutableArray array];
        [self performSelectorOnMainThread:@selector(ensureUmountHelperSetuidWithPromptInto:)
                                withObject:helperReadyHolder
                             waitUntilDone:YES];
        BOOL helperReady = ([helperReadyHolder count] > 0) && [[helperReadyHolder objectAtIndex:0] boolValue];

        if (helperReady) {
            unmountOK = AQRunPrivilegedHelperUmount(mp, 10.0);
        }

        if (!unmountOK) {
            /* ヘルパーが使えない(準備を断られた等)、またはそれでも外れない場合の
               最終手段として、従来のGUIパスワードダイアログも一応試す。
               上記の理由で成功する見込みは薄いが、環境によっては通ることもあり
               得るため保険として残す。 */
            [self runPrivilegedUnmount:mp errorMessage:&privilegedError];
            unmountOK = !AQIsMountPoint(mp);
        }
    }

    NSString *resultMessage;
    if (unmountOK) {
        /* AQTeardownMountPoint以外の経路(ヘルパー直叩き・GUIダイアログ経由)で
           外れた場合、空ディレクトリの片付けとFinderへの通知(どちらも
           AQCleanupEmptyMountDir内)がまだ済んでいない。ここで確実に呼ぶ
           (既に片付いていれば何もしない、呼んでも無害)。 */
        AQCleanupEmptyMountDir(mp);
        /* 外れたことを確認できた後で初めてサーバーを止める */
        if (webdavServer != nil) {
            [webdavServer stop];
            [webdavServer release];
            webdavServer = nil;
        }
        [mountPointPath release];
        mountPointPath = nil;
        mounted = NO;
        resultMessage = L("取り外しました");
    } else if (privilegedError != nil) {
        resultMessage = [NSString stringWithFormat:L("取り外しに失敗しました: %@"), privilegedError];
    } else {
        /* まだ外れていない。サーバーは絶対に止めない(壊れたマウントにしないため)。
           一般利用者にターミナルやコマンドを触らせるのは避け、時間を置いての
           再試行のみを案内する(過去にコピペ案内を出していたが、専門知識の無い
           利用者には不向きと判断し撤回した)。 */
        resultMessage = L("取り外しに失敗しました。しばらく待ってから、もう一度「取り外す」をお試しください");
    }

    [self performSelectorOnMainThread:@selector(mountFinishedWithMessage:)
                            withObject:resultMessage
                         waitUntilDone:NO];

    [pool release];
}

/* 旧API名の互換用。中身は新しい安全な後始末に委譲する(applicationWillTerminate等から
   呼ばれる)。戻り値: 実行後に mountPoint がマウントポイントでなくなっていれば YES。 */
- (BOOL)runUnmountCommand:(NSString *)mountPoint force:(BOOL)force
{
    (void)force;
    return AQTeardownMountPoint(mountPoint);
}

/* NSString の -stringByReplacingOccurrencesOfString:withString: はLeopard(10.5)以降のAPIで
   Tigerには存在しないため、代わりにTiger以前から存在する
   NSMutableString -replaceOccurrencesOfString:withString:options:range: を使う */
static NSString *AQReplaceAll(NSString *source, NSString *target, NSString *replacement)
{
    NSMutableString *result = [NSMutableString stringWithString:source];
    [result replaceOccurrencesOfString:target
                             withString:replacement
                                options:0
                                  range:NSMakeRange(0, [result length])];
    return result;
}

/* バックグラウンドスレッドから呼ばれる。管理者パスワードのダイアログを出してumountする。
   通常のumount(force含む)が権限不足で失敗した場合の最終手段。
   失敗時、outErrorMessage(NULL可)に実際のエラー内容(または「キャンセルされました」)を返す。
   環境ごとに失敗理由が変わりうるため、汎用メッセージだけでは実機ごとの原因切り分けが
   できなかった(実際に発生した不具合: バグ修正後も原因不明の失敗が続いた)。

   当初はNSAppleScriptの "do shell script ... with administrator privileges" を使っていたが、
   ある実機(パッチ当てOSイメージ)でパスワード入力後も "Operation not permitted" が
   出続けることが判明した。umount(2)は本物のroot権限なら無条件で成功するはずなので、
   これはAppleScript経由の昇格がその環境では実際にはrootになれていないことを示す。
   より低レベルなAuthorization Services APIを直接使う方式に切り替える。 */
- (BOOL)runPrivilegedUnmount:(NSString *)mountPoint errorMessage:(NSString **)outErrorMessage
{
    /* シェルのシングルクォート内でmountPoint自体にシングルクォートが含まれていても
       安全になるようエスケープする: ' -> '\'' */
    NSString *shellQuoted = AQReplaceAll(mountPoint, @"'", @"'\\''");
    /* stderrも2>&1でまとめて拾う。AuthorizationExecuteWithPrivilegesが起動する
       子プロセスは、呼び出し元から見て直接のchildではないことがあり wait() で
       終了コードを確実に取得できないため、「出力が空 = 成功」(umountは成功時に
       何も出力しない)という判定方法を使う。 */
    NSString *shellCommand = [NSString stringWithFormat:
        @"/sbin/umount '%@' 2>&1 || /sbin/umount -f '%@' 2>&1", shellQuoted, shellQuoted];

    AuthorizationRef authRef = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                           kAuthorizationFlagDefaults, &authRef);
    if (status != errAuthorizationSuccess) {
        if (outErrorMessage != NULL) {
            *outErrorMessage = [NSString stringWithFormat:@"AuthorizationCreate error %d", (int)status];
        }
        return NO;
    }

    AuthorizationItem right = { kAuthorizationRightExecute, 0, NULL, 0 };
    AuthorizationRights rightSet = { 1, &right };
    AuthorizationFlags authFlags = kAuthorizationFlagDefaults
                                  | kAuthorizationFlagInteractionAllowed
                                  | kAuthorizationFlagPreAuthorize
                                  | kAuthorizationFlagExtendRights;

    status = AuthorizationCopyRights(authRef, &rightSet, kAuthorizationEmptyEnvironment, authFlags, NULL);
    if (status != errAuthorizationSuccess) {
        if (outErrorMessage != NULL) {
            /* errAuthorizationCanceled はユーザーがパスワードダイアログをキャンセルした場合 */
            *outErrorMessage = (status == errAuthorizationCanceled)
                ? L("パスワード入力がキャンセルされました")
                : [NSString stringWithFormat:@"Authorization error %d", (int)status];
        }
        AuthorizationFree(authRef, kAuthorizationFlagDefaults);
        return NO;
    }

    char *args[] = { (char *)"-c", (char *)[shellCommand UTF8String], NULL };
    FILE *outputPipe = NULL;
    status = AuthorizationExecuteWithPrivileges(authRef, "/bin/sh", kAuthorizationFlagDefaults,
                                                 args, &outputPipe);

    NSMutableData *outputData = [NSMutableData data];
    if (status == errAuthorizationSuccess && outputPipe != NULL) {
        int fd = fileno(outputPipe);
        char buf[512];
        ssize_t n;
        while ((n = read(fd, buf, sizeof(buf))) > 0) {
            [outputData appendBytes:buf length:(unsigned)n];
        }
        fclose(outputPipe);
        int wstatus = 0;
        while (wait(&wstatus) == -1 && errno == EINTR) { }
    }

    AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);

    if (status != errAuthorizationSuccess) {
        if (outErrorMessage != NULL) {
            *outErrorMessage = [NSString stringWithFormat:@"AuthorizationExecuteWithPrivileges error %d", (int)status];
        }
        return NO;
    }

    BOOL ok = ([outputData length] == 0);
    if (!ok && outErrorMessage != NULL) {
        NSString *outputStr = [[[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] autorelease];
        *outErrorMessage = ([outputStr length] > 0) ? outputStr : L("管理者権限でのumountに失敗しました");
    }
    return ok;
}

/* /sbin/mount_webdav のsetuidビットを管理者権限で復元する
   (`chmod u+s /sbin/mount_webdav`)。OSアップデート等で剥がれたのを直すだけで、
   本来あるべき状態に戻す操作。OS標準のパスワードダイアログが出る。
   runPrivilegedUnmount:と同じ「出力が空 = 成功」判定を使う。 */
- (BOOL)restorePrivilegedMountWebdavSetuid:(NSString **)outErrorMessage
{
    AuthorizationRef authRef = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                           kAuthorizationFlagDefaults, &authRef);
    if (status != errAuthorizationSuccess) {
        if (outErrorMessage != NULL) {
            *outErrorMessage = [NSString stringWithFormat:@"AuthorizationCreate error %d", (int)status];
        }
        return NO;
    }

    AuthorizationItem right = { kAuthorizationRightExecute, 0, NULL, 0 };
    AuthorizationRights rightSet = { 1, &right };
    AuthorizationFlags authFlags = kAuthorizationFlagDefaults
                                  | kAuthorizationFlagInteractionAllowed
                                  | kAuthorizationFlagPreAuthorize
                                  | kAuthorizationFlagExtendRights;
    status = AuthorizationCopyRights(authRef, &rightSet, kAuthorizationEmptyEnvironment, authFlags, NULL);
    if (status != errAuthorizationSuccess) {
        if (outErrorMessage != NULL) {
            *outErrorMessage = (status == errAuthorizationCanceled)
                ? L("パスワード入力がキャンセルされました")
                : [NSString stringWithFormat:@"Authorization error %d", (int)status];
        }
        AuthorizationFree(authRef, kAuthorizationFlagDefaults);
        return NO;
    }

    char *args[] = { (char *)"u+s", (char *)"/sbin/mount_webdav", NULL };
    FILE *outputPipe = NULL;
    status = AuthorizationExecuteWithPrivileges(authRef, "/bin/chmod", kAuthorizationFlagDefaults,
                                                 args, &outputPipe);

    NSMutableData *outputData = [NSMutableData data];
    if (status == errAuthorizationSuccess && outputPipe != NULL) {
        int fd = fileno(outputPipe);
        char buf[512];
        ssize_t n;
        while ((n = read(fd, buf, sizeof(buf))) > 0) {
            [outputData appendBytes:buf length:(unsigned)n];
        }
        fclose(outputPipe);
        int wstatus = 0;
        while (wait(&wstatus) == -1 && errno == EINTR) { }
    }
    AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);

    if (status != errAuthorizationSuccess) {
        if (outErrorMessage != NULL) {
            *outErrorMessage = [NSString stringWithFormat:@"AuthorizationExecuteWithPrivileges error %d", (int)status];
        }
        return NO;
    }

    /* chmodは成功時に何も出力しない。加えて、実際にビットが立ったかを確認する */
    NSDictionary *a = [[NSFileManager defaultManager]
                          fileAttributesAtPath:@"/sbin/mount_webdav" traverseLink:YES];
    BOOL bitSet = (a != nil &&
                   ([[a objectForKey:NSFilePosixPermissions] unsignedLongValue] & 04000) != 0);
    if (!bitSet && outErrorMessage != NULL) {
        NSString *outputStr = [[[NSString alloc] initWithData:outputData
                                                    encoding:NSUTF8StringEncoding] autorelease];
        *outErrorMessage = ([outputStr length] > 0) ? outputStr
                             : L("setuidビットの復元に失敗しました");
    }
    return bitSet;
}

/* 同梱のsetuid rootヘルパー(aqualink-umount-helper)を、初回だけ管理者権限で
   root所有+setuidに仕上げる。新しく組んだ.appはコピーしただけなので所有者は
   一般ユーザーのままであり、chmodだけでなくchownも必要(所有者がwatermarkの
   ままsetuidを立てても、実行時の権限はwatermarkにしかならないため)。
   このchown/chmod自体はumount特有のセッション制限を受けない(実機で確認済み。
   setuid復元の"自動で直す"と同じ経路で確実に成功する)ので、GUIの
   パスワードダイアログで問題ない。 */
- (BOOL)restorePrivilegedUmountHelperSetuid:(NSString **)outErrorMessage
{
    NSString *helperPath = AQUmountHelperPath();
    if (helperPath == nil) {
        if (outErrorMessage != NULL) {
            *outErrorMessage = L("専用プログラムが見つかりません(古いビルドの可能性があります)");
        }
        return NO;
    }

    NSString *shellQuoted = AQReplaceAll(helperPath, @"'", @"'\\''");
    NSString *shellCommand = [NSString stringWithFormat:
        @"chown root:wheel '%@' && chmod 4755 '%@'", shellQuoted, shellQuoted];

    AuthorizationRef authRef = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                           kAuthorizationFlagDefaults, &authRef);
    if (status != errAuthorizationSuccess) {
        if (outErrorMessage != NULL) {
            *outErrorMessage = [NSString stringWithFormat:@"AuthorizationCreate error %d", (int)status];
        }
        return NO;
    }

    AuthorizationItem right = { kAuthorizationRightExecute, 0, NULL, 0 };
    AuthorizationRights rightSet = { 1, &right };
    AuthorizationFlags authFlags = kAuthorizationFlagDefaults
                                  | kAuthorizationFlagInteractionAllowed
                                  | kAuthorizationFlagPreAuthorize
                                  | kAuthorizationFlagExtendRights;
    status = AuthorizationCopyRights(authRef, &rightSet, kAuthorizationEmptyEnvironment, authFlags, NULL);
    if (status != errAuthorizationSuccess) {
        if (outErrorMessage != NULL) {
            *outErrorMessage = (status == errAuthorizationCanceled)
                ? L("パスワード入力がキャンセルされました")
                : [NSString stringWithFormat:@"Authorization error %d", (int)status];
        }
        AuthorizationFree(authRef, kAuthorizationFlagDefaults);
        return NO;
    }

    char *args[] = { (char *)"-c", (char *)[shellCommand UTF8String], NULL };
    FILE *outputPipe = NULL;
    status = AuthorizationExecuteWithPrivileges(authRef, "/bin/sh", kAuthorizationFlagDefaults,
                                                 args, &outputPipe);

    NSMutableData *outputData = [NSMutableData data];
    if (status == errAuthorizationSuccess && outputPipe != NULL) {
        int fd = fileno(outputPipe);
        char buf[512];
        ssize_t n;
        while ((n = read(fd, buf, sizeof(buf))) > 0) {
            [outputData appendBytes:buf length:(unsigned)n];
        }
        fclose(outputPipe);
        int wstatus = 0;
        while (wait(&wstatus) == -1 && errno == EINTR) { }
    }
    AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);

    if (status != errAuthorizationSuccess) {
        if (outErrorMessage != NULL) {
            *outErrorMessage = [NSString stringWithFormat:@"AuthorizationExecuteWithPrivileges error %d", (int)status];
        }
        return NO;
    }

    BOOL ok = AQUmountHelperHasSetuid();
    if (!ok && outErrorMessage != NULL) {
        NSString *outputStr = [[[NSString alloc] initWithData:outputData
                                                    encoding:NSUTF8StringEncoding] autorelease];
        *outErrorMessage = ([outputStr length] > 0) ? outputStr
                             : L("専用プログラムの準備に失敗しました");
    }
    return ok;
}

/* 「取り外す」の最終手段としてヘルパーを使う前の、初回だけの下準備。
   既に準備済みなら何も聞かずYESを返す。未準備なら「自動で直す」ダイアログを
   出し、承諾されればその場でchown/chmodして仕上げる。必ずメインスレッドで
   呼ぶこと(NSAlertを使うため)。 */
- (BOOL)ensureUmountHelperSetuidWithPrompt
{
    if (AQUmountHelperHasSetuid()) {
        return YES;
    }

    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:L("初回の準備が必要です")];
    [alert setInformativeText:L("「取り外す」を、パスワードのダイアログを毎回出さずに確実に行えるようにするため、初回だけ管理者権限で小さな専用プログラムを準備します。次回以降はこの確認は出ません。")];
    [alert addButtonWithTitle:L("自動で準備する")];
    [alert addButtonWithTitle:L("キャンセル")];
    int resp = [alert runModal];
    [alert release];
    if (resp != NSAlertFirstButtonReturn) {
        return NO;
    }

    NSString *err = nil;
    BOOL ok = [self restorePrivilegedUmountHelperSetuid:&err];
    if (!ok) {
        NSAlert *failAlert = [[NSAlert alloc] init];
        [failAlert setMessageText:L("準備に失敗しました")];
        [failAlert setInformativeText:(err != nil) ? err : L("不明なエラーです")];
        [failAlert addButtonWithTitle:L("OK")];
        [failAlert runModal];
        [failAlert release];
    }
    return ok;
}

/* doUnmount(バックグラウンドスレッド)からメインスレッドの
   ensureUmountHelperSetuidWithPromptを同期呼び出しするための橋渡し。
   NSAlertはメインスレッド必須、かつ結果を待ってから次に進みたいため
   waitUntilDone:YESで呼び、結果はresultHolderに詰めて受け取る。 */
- (void)ensureUmountHelperSetuidWithPromptInto:(NSMutableArray *)resultHolder
{
    BOOL ok = [self ensureUmountHelperSetuidWithPrompt];
    [resultHolder addObject:[NSNumber numberWithBool:ok]];
}

/* AQRefreshFinderVolumeIconsから、Finderにウィンドウが開いている(または
   判定できない)時に呼ばれる。デスクトップに残った空のアイコンを消すには
   Finderの再起動が要るが、無断でウィンドウを閉じるのは避け、本人に選んで
   もらう。取り外し自体は既に完了しているので、キャンセルしても実害は無い
   (アイコンが見た目上残るだけ)。 */
- (void)refreshFinderVolumeIconsAskingIfNeeded
{
    NSAlert *alert = [[NSAlert alloc] init];
    [alert setMessageText:L("Finderを再起動しますか?")];
    [alert setInformativeText:L("取り外しは完了していますが、デスクトップのアイコンは見た目上残ったままです。消すにはFinderの再起動が必要です。AquaLinkや他のアプリには影響ありませんが、今開いているFinderのウィンドウは一旦閉じます。")];
    [alert addButtonWithTitle:L("再起動する")];
    [alert addButtonWithTitle:L("あとで")];
    int resp = [alert runModal];
    [alert release];
    if (resp == NSAlertFirstButtonReturn) {
        AQKillallFinder();
    }
}

/* ============ ブックマーク(接続履歴) ============ */

- (void)loadBookmarks
{
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"AquaLinkBookmarks"];
    [bookmarks release];
    bookmarks = [[NSMutableArray alloc] init];
    NSEnumerator *e = [saved objectEnumerator];
    id item;
    while ((item = [e nextObject])) {
        if ([item isKindOfClass:[NSDictionary class]]) {
            /* 現行形式: {address, share, username} */
            [bookmarks addObject:[[item mutableCopy] autorelease]];
        } else if ([item isKindOfClass:[NSString class]]) {
            /* 旧形式(アドレスの文字列のみ)からの移行: アドレスだけ引き継ぐ */
            NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                          item, @"address", @"", @"share", @"", @"username", nil];
            [bookmarks addObject:dict];
        }
    }
}

- (void)addBookmarkWithAddress:(NSString *)address share:(NSString *)share username:(NSString *)username
{
    if ([address length] == 0) {
        return;
    }
    NSEnumerator *e = [bookmarks objectEnumerator];
    NSMutableDictionary *existing;
    NSMutableArray *toRemove = [NSMutableArray array];
    while ((existing = [e nextObject])) {
        if ([[existing objectForKey:@"address"] isEqualToString:address]) {
            [toRemove addObject:existing];
        }
    }
    [bookmarks removeObjectsInArray:toRemove];

    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                   address, @"address",
                                   (share ? share : @""), @"share",
                                   (username ? username : @""), @"username", nil];
    [bookmarks insertObject:entry atIndex:0];
    while ([bookmarks count] > 10) {
        [bookmarks removeLastObject];
    }
    [[NSUserDefaults standardUserDefaults] setObject:bookmarks forKey:@"AquaLinkBookmarks"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [urlField reloadData];
}

/* 履歴の1件を選んだ(または起動直後に最新の1件を)フォームへ反映する。
   パスワードはKeychainから読み出す(NSUserDefaultsには平文で置かない) */
- (void)autofillFromBookmarkAtIndex:(unsigned int)index
{
    if (index >= [bookmarks count]) {
        return;
    }
    NSDictionary *entry = [bookmarks objectAtIndex:index];
    NSString *address = [entry objectForKey:@"address"];
    NSString *share = [entry objectForKey:@"share"];
    NSString *username = [entry objectForKey:@"username"];

    if ([address length] > 0) {
        [urlField setStringValue:address];
    }
    if ([share length] > 0) {
        [shareField setStringValue:share];
    }
    if ([username length] > 0) {
        [usernameField setStringValue:username];
    }

    NSString *account = ConnectKeychainAccount(username, address, share);
    NSString *password = LoadKeychainPassword(KEYCHAIN_SERVICE_CONNECT, account);
    [passwordField setStringValue:(password ? password : @"")];
}

/* ============ NSComboBox データソース/デリゲート ============ */

/* プルダウンの中身は「Bonjourで見つけたサーバー(上)」+「接続履歴(下)」の並び。
   discoveredServicesの件数を境目にして、index未満なら発見サーバー、以上なら履歴。 */

- (int)numberOfItemsInComboBox:(NSComboBox *)aComboBox
{
    return (int)([discoveredServices count] + [bookmarks count]);
}

- (id)comboBox:(NSComboBox *)aComboBox objectValueForItemAtIndex:(int)index
{
    int nDiscovered = (int)[discoveredServices count];
    if (index >= 0 && index < nDiscovered) {
        /* 依頼者フィードバック(2026-09-11): 「名前 — IPアドレス」表示は長すぎて
           プルダウン内で読めない。選ぶ時に必要なのは名前だけで、IPは選択後に
           comboBoxSelectionDidChange:で自動的に埋まる(下記)ので、見せる必要が
           無い。名前だけ表示する。 */
        NSDictionary *svc = [discoveredServices objectAtIndex:index];
        return [svc objectForKey:@"name"];
    }
    int bIndex = index - nDiscovered;
    if (bIndex >= 0 && bIndex < (int)[bookmarks count]) {
        return [[bookmarks objectAtIndex:bIndex] objectForKey:@"address"];
    }
    return @"";
}

/* プルダウンから選んだ時の挙動。
   - Bonjourで見つけたサーバー: アドレス欄にIPだけ入れる(共有名・ユーザー名は
     分からないので触らない。利用者が続けて入力する)
   - 接続履歴: アドレス・共有名・ユーザー名・パスワードまでまとめて埋める */
- (void)comboBoxSelectionDidChange:(NSNotification *)notification
{
    int index = [urlField indexOfSelectedItem];
    if (index < 0) {
        return;
    }
    int nDiscovered = (int)[discoveredServices count];
    if (index < nDiscovered) {
        NSString *ip = [[discoveredServices objectAtIndex:index] objectForKey:@"address"];
        /* この通知の直後に、NSComboBox自身がテキスト欄を「表示文字列
           (= 名前 — IP)」で上書きする。ここで即setStringValueしても打ち消される
           ので、1ステップ遅らせてIPだけを入れ直す */
        [self performSelector:@selector(setAddressFieldValue:)
                   withObject:(ip ? ip : @"")
                   afterDelay:0.0];
        return;
    }
    [self autofillFromBookmarkAtIndex:(unsigned int)(index - nDiscovered)];
}

- (void)setAddressFieldValue:(NSString *)value
{
    [urlField setStringValue:value];
}

/* ============ Bonjour(接続先の自動発見) ============ */

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service
               moreComing:(BOOL)moreComing
{
    /* 見つけた時点では名前しか分からない。数値IPを得るためresolveする。
       完了までNSNetServiceが解放されないよう配列で保持しておく */
    [service setDelegate:self];
    [pendingResolves addObject:service];
    [service resolveWithTimeout:5.0];
}

- (void)netServiceDidResolveAddress:(NSNetService *)service
{
    NSString *ip = AQFirstIPv4FromNetService(service);
    if (ip != nil) {
        BOOL exists = NO;
        unsigned i;
        for (i = 0; i < [discoveredServices count]; i++) {
            if ([[[discoveredServices objectAtIndex:i] objectForKey:@"name"]
                    isEqualToString:[service name]]) {
                exists = YES;
                break;
            }
        }
        if (!exists) {
            NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
                                     [service name], @"name",
                                     ip, @"address", nil];
            [discoveredServices addObject:entry];
            [urlField reloadData];
        }
    }
    [pendingResolves removeObject:service];
}

- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)errorDict
{
    [pendingResolves removeObject:service];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
         didRemoveService:(NSNetService *)service
               moreComing:(BOOL)moreComing
{
    unsigned i;
    for (i = 0; i < [discoveredServices count]; i++) {
        if ([[[discoveredServices objectAtIndex:i] objectForKey:@"name"]
                isEqualToString:[service name]]) {
            [discoveredServices removeObjectAtIndex:i];
            [urlField reloadData];
            break;
        }
    }
}

/* ============ このMacを共有する(NAS化)機能 ============ */

- (void)showShareWindow:(id)sender
{
    if (shareWindow == nil) {
        NSRect frame = NSMakeRect(150, 120, 520, 460);
        shareWindow = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        [shareWindow setTitle:L("このMacを共有(NAS化)")];
        [shareWindow setReleasedWhenClosed:NO];

        NSView *content = [shareWindow contentView];
        float h = frame.size.height;
        float w = frame.size.width;

        NSTextField *folderLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, h - 24, 200, 18)];
        [folderLabel setEditable:NO];
        [folderLabel setBezeled:NO];
        [folderLabel setDrawsBackground:NO];
        [folderLabel setStringValue:L("共有フォルダ一覧:")];
        [content addSubview:folderLabel];
        [folderLabel release];

        NSScrollView *tableScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, h - 160, w - 20, 130)];
        [tableScroll setHasVerticalScroller:YES];
        [tableScroll setBorderType:NSBezelBorder];

        shareFolderTable = [[NSTableView alloc] initWithFrame:[tableScroll bounds]];
        [shareFolderTable setDataSource:self];
        [shareFolderTable setDelegate:self];

        NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
        [[nameCol headerCell] setStringValue:L("共有名")];
        [nameCol setWidth:140];
        [shareFolderTable addTableColumn:nameCol];
        [nameCol release];

        NSTableColumn *pathCol = [[NSTableColumn alloc] initWithIdentifier:@"path"];
        [[pathCol headerCell] setStringValue:L("フォルダパス")];
        [pathCol setWidth:320];
        [shareFolderTable addTableColumn:pathCol];
        [pathCol release];

        [tableScroll setDocumentView:shareFolderTable];
        [shareFolderTable release];
        [content addSubview:tableScroll];
        [tableScroll release];

        addFolderButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, h - 190, 24, 24)];
        [addFolderButton setTitle:@"+"];
        [addFolderButton setFont:[NSFont boldSystemFontOfSize:14]];
        [addFolderButton setBezelStyle:NSSmallSquareBezelStyle];
        [addFolderButton setTarget:self];
        [addFolderButton setAction:@selector(addFolderAction:)];
        [content addSubview:addFolderButton];
        [addFolderButton release];

        removeFolderButton = [[NSButton alloc] initWithFrame:NSMakeRect(38, h - 190, 24, 24)];
        [removeFolderButton setTitle:@"-"];
        [removeFolderButton setFont:[NSFont boldSystemFontOfSize:14]];
        [removeFolderButton setBezelStyle:NSSmallSquareBezelStyle];
        [removeFolderButton setTarget:self];
        [removeFolderButton setAction:@selector(removeFolderAction:)];
        [content addSubview:removeFolderButton];
        [removeFolderButton release];

        NSTextField *userLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, h - 222, 100, 18)];
        [userLabel setEditable:NO];
        [userLabel setBezeled:NO];
        [userLabel setDrawsBackground:NO];
        [userLabel setStringValue:L("ユーザー名:")];
        [content addSubview:userLabel];
        [userLabel release];

        shareUserField = [[NSTextField alloc] initWithFrame:NSMakeRect(115, h - 224, 200, 22)];
        [shareUserField setStringValue:(shareUser ? shareUser : L("yamada"))];
        [content addSubview:shareUserField];
        [shareUserField release];

        NSTextField *passLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, h - 254, 100, 18)];
        [passLabel setEditable:NO];
        [passLabel setBezeled:NO];
        [passLabel setDrawsBackground:NO];
        [passLabel setStringValue:L("パスワード:")];
        [content addSubview:passLabel];
        [passLabel release];

        sharePasswordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(115, h - 256, 200, 22)];
        [[sharePasswordField cell] setPlaceholderString:L("必須")];
        if (sharePassword) {
            [sharePasswordField setStringValue:sharePassword];
        }
        [content addSubview:sharePasswordField];
        [sharePasswordField release];

        NSTextField *portLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, h - 286, 100, 18)];
        [portLabel setEditable:NO];
        [portLabel setBezeled:NO];
        [portLabel setDrawsBackground:NO];
        [portLabel setStringValue:L("ポート:")];
        [content addSubview:portLabel];
        [portLabel release];

        sharePortField = [[NSTextField alloc] initWithFrame:NSMakeRect(115, h - 288, 80, 22)];
        [sharePortField setStringValue:(sharePortValue > 0 ? [NSString stringWithFormat:@"%d", sharePortValue] : @"8091")];
        [content addSubview:sharePortField];
        [sharePortField release];

        shareStartButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, h - 328, 140, 26)];
        [shareStartButton setTitle:(sharing ? L("共有停止") : L("共有開始"))];
        [shareStartButton setBezelStyle:NSRoundedBezelStyle];
        [shareStartButton setTarget:self];
        [shareStartButton setAction:@selector(toggleSharingAction:)];
        [content addSubview:shareStartButton];
        [shareStartButton release];

        windowsGuideButton = [[NSButton alloc] initWithFrame:NSMakeRect(160, h - 328, 170, 26)];
        [windowsGuideButton setTitle:L("Windows用接続ガイド")];
        [windowsGuideButton setBezelStyle:NSRoundedBezelStyle];
        [windowsGuideButton setTarget:self];
        [windowsGuideButton setAction:@selector(showWindowsGuideAction:)];
        [content addSubview:windowsGuideButton];
        [windowsGuideButton release];

        NSTextField *shareWarningLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 88, w - 20, 34)];
        [shareWarningLabel setEditable:NO];
        [shareWarningLabel setBezeled:NO];
        [shareWarningLabel setDrawsBackground:NO];
        [[shareWarningLabel cell] setWraps:YES];
        [shareWarningLabel setFont:[NSFont systemFontOfSize:10]];
        [shareWarningLabel setTextColor:[NSColor darkGrayColor]];
        [shareWarningLabel setStringValue:L("⚠️ LAN内限定で使用してください。パスワードは暗号化されません(平文HTTP)。ルーターのポート開放等でインターネットに直接公開しないこと。")];
        [content addSubview:shareWarningLabel];
        [shareWarningLabel release];

        shareStatusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 10, w - 20, 70)];
        [shareStatusLabel setEditable:NO];
        [shareStatusLabel setBezeled:NO];
        [shareStatusLabel setDrawsBackground:NO];
        [[shareStatusLabel cell] setWraps:YES];
        [shareStatusLabel setStringValue:@""];
        [content addSubview:shareStatusLabel];
        [shareStatusLabel release];
    }

    [shareFolderTable reloadData];
    [shareWindow makeKeyAndOrderFront:nil];
}

- (void)addFolderAction:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseDirectories:YES];
    [panel setCanChooseFiles:NO];
    [panel setAllowsMultipleSelection:YES];
    int result = [panel runModalForDirectory:NSHomeDirectory() file:nil types:nil];
    if (result != NSOKButton) {
        return;
    }
    NSArray *filenames = [panel filenames];
    NSEnumerator *e = [filenames objectEnumerator];
    NSString *path;
    while ((path = [e nextObject])) {
        NSString *baseName = [path lastPathComponent];
        NSString *name = baseName;
        int suffix = 2;
        BOOL collision;
        do {
            collision = NO;
            NSEnumerator *fe = [shareFolders objectEnumerator];
            NSDictionary *f;
            while ((f = [fe nextObject])) {
                if ([[f objectForKey:@"name"] isEqualToString:name]) {
                    collision = YES;
                    break;
                }
            }
            if (collision) {
                name = [NSString stringWithFormat:@"%@%d", baseName, suffix];
                suffix++;
            }
        } while (collision);

        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                       name, @"name", path, @"path", nil];
        [shareFolders addObject:entry];
    }
    [shareFolderTable reloadData];
    [self saveShareSettings];
}

- (void)removeFolderAction:(id)sender
{
    int row = [shareFolderTable selectedRow];
    if (row < 0 || row >= (int)[shareFolders count]) {
        return;
    }
    [shareFolders removeObjectAtIndex:row];
    [shareFolderTable reloadData];
    [self saveShareSettings];
}

- (void)toggleSharingAction:(id)sender
{
    if (sharing) {
        [shareStartButton setEnabled:NO];
        [shareStatusLabel setStringValue:L("停止中...")];
        [NSThread detachNewThreadSelector:@selector(doStopSharing) toTarget:self withObject:nil];
        return;
    }

    NSString *user = [shareUserField stringValue];
    NSString *pass = [sharePasswordField stringValue];
    NSString *portStr = [sharePortField stringValue];

    if ([shareFolders count] == 0) {
        [shareStatusLabel setStringValue:L("共有フォルダを1つ以上追加してください")];
        return;
    }
    if ([user length] == 0 || [pass length] == 0) {
        [shareStatusLabel setStringValue:L("ユーザー名とパスワードを入力してください")];
        return;
    }

    [shareUser release];
    shareUser = [user retain];
    [sharePassword release];
    sharePassword = [pass retain];
    sharePortValue = [portStr intValue];
    if (sharePortValue <= 0) {
        sharePortValue = 8091;
    }
    [self saveShareSettings];

    [shareStartButton setEnabled:NO];
    [shareStatusLabel setStringValue:L("共有を開始しています...")];

    NSMutableDictionary *sharesDict = [NSMutableDictionary dictionary];
    NSEnumerator *e = [shareFolders objectEnumerator];
    NSDictionary *f;
    while ((f = [e nextObject])) {
        [sharesDict setObject:[f objectForKey:@"path"] forKey:[f objectForKey:@"name"]];
    }

    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                           sharesDict, @"shares", user, @"user", pass, @"pass",
                           [NSNumber numberWithInt:sharePortValue], @"port", nil];
    [NSThread detachNewThreadSelector:@selector(doStartSharing:) toTarget:self withObject:args];
}

/* ============ Windows用接続ガイド ============ */

- (void)showWindowsGuideAction:(id)sender
{
    NSString *ip = GetLocalIPAddress();

    /* このガイド文書は分量が多く、文単位の対訳表(EnglishTranslations)に載せると
       改行やスペースの一致ズレで訳が引けなくなる危険があるため、日本語版・英語版を
       まるごと2系統に分けて書く方式にしている */
    NSMutableString *text = [NSMutableString string];
    BOOL en = UseEnglish();

    if (!en) {
        [text appendString:UTF8(
            "Windows11のパソコンから、この共有(NAS化)フォルダに接続する手順です。\n"
            "上から順番に、Windows側で操作してください。\n\n"
            "※注意※\n"
            "エクスプローラーに自動でドライブが出てくることはありません。\n"
            "また、エクスプローラー左側の「ネットワーク」を開くとこのMacの名前が\n"
            "見えることがありますが、それをダブルクリックしてもエラーになります\n"
            "(そちらはこの手順とは別の古い方式で見えているだけです)。\n"
            "必ず下記の【1】〜【3】の手順で接続してください。\n\n"
            "【1】このプロジェクトの配布ページから接続用ファイルをダウンロードし、\n"
            "展開(解凍)してください。\n\n"
            "【2】展開してできたフォルダの中の connect-aqualink.bat を\n"
            "ダブルクリックして起動してください。\n\n"
            "【3】以下の項目を、聞かれた順番にそのまま入力してください:\n\n")];

        [text appendFormat:UTF8("　①サーバーのIPアドレス:\n　　%@\n"), (ip ? ip : UTF8("(取得できません。共有を開始してから再度お試しください)"))];
        [text appendString:UTF8("　　(この数字はMacのネットワーク環境によって変わります。表示が違う場合は\n"
                                 "　　Macの「システム環境設定 > ネットワーク」で現在のIPアドレスをご確認ください)\n\n")];

        [text appendString:UTF8(
            "　②このサーバーの名前(自由に決めて構いませんが、\n"
            "　　ご自身の名前やWindows PCの名前と同じにしないでください。\n"
            "　　名前が衝突していると繋がらないことがあります):\n"
            "　　例) aqualink-mac\n\n")];

        if ([shareFolders count] == 0) {
            [text appendString:UTF8("　③共有名:\n　　(まだ共有フォルダが追加されていません。上の「+」で追加してください)\n\n")];
        } else {
            [text appendString:UTF8("　③共有名(共有フォルダが複数ある場合、繋ぎたいものを1つ選んで入力してください):\n")];
            NSEnumerator *e = [shareFolders objectEnumerator];
            NSDictionary *f;
            while ((f = [e nextObject])) {
                NSString *displayName = [[f objectForKey:@"name"] precomposedStringWithCanonicalMapping];
                [text appendFormat:UTF8("　　・%@\n"), displayName];
            }
            [text appendString:@"\n"];
        }

        [text appendString:UTF8("　④ユーザー名:\n　　この画面の「共有設定」で決めたユーザー名を入力してください(例: yamada)。\n\n")];
        [text appendString:UTF8(
            "　⑤パスワード:\n"
            "　　共有設定で決めたパスワードを入力してください(画面には表示されません)。\n"
            "　　パソコンのログインパスワードをそのまま使っている方も多いです。\n\n")];

        [text appendString:UTF8(
            "【4】「Connected!」と表示されれば成功です。エクスプローラーの「PC」に\n"
            "ドライブとして表示されます。\n\n"
            "うまくいかない場合は、まず①のIPアドレスが変わっていないか確認してください\n"
            "(iBook/Macを再起動するとIPアドレスが変わることがあります)。")];
    } else {
        [text appendString:UTF8(
            "Steps to connect to this shared (NAS) folder from a Windows 11 PC.\n"
            "Follow them in order on the Windows side.\n\n"
            "NOTE:\n"
            "A drive will NOT appear automatically in File Explorer.\n"
            "You may also see this Mac's name under \"Network\" in File Explorer's\n"
            "sidebar, but double-clicking it will fail\n"
            "(that's a different, older method unrelated to these steps).\n"
            "Please connect using steps [1]-[3] below.\n\n"
            "[1] Download the connection files from this project's release page\n"
            "and extract (unzip) them.\n\n"
            "[2] Double-click connect-aqualink.bat inside the extracted folder\n"
            "to run it.\n\n"
            "[3] Enter the following items exactly as asked, in order:\n\n")];

        [text appendFormat:UTF8("  1) Server IP address:\n   %@\n"), (ip ? ip : UTF8("(Could not detect it. Start sharing first, then try again.)"))];
        [text appendString:UTF8("   (This number can change depending on the Mac's network. If it looks\n"
                                 "   different, check the current IP address under \"System Preferences >\n"
                                 "   Network\" on the Mac.)\n\n")];

        [text appendString:UTF8(
            "  2) A name for this server (you can choose anything, but don't\n"
            "   make it the same as your own name or your Windows PC's name --\n"
            "   a name collision can prevent connecting):\n"
            "   e.g. aqualink-mac\n\n")];

        if ([shareFolders count] == 0) {
            [text appendString:UTF8("  3) Share name:\n   (No shared folders have been added yet. Add one with the \"+\" above.)\n\n")];
        } else {
            [text appendString:UTF8("  3) Share name (if there are multiple shared folders, enter the one you want to connect to):\n")];
            NSEnumerator *e = [shareFolders objectEnumerator];
            NSDictionary *f;
            while ((f = [e nextObject])) {
                NSString *displayName = [[f objectForKey:@"name"] precomposedStringWithCanonicalMapping];
                [text appendFormat:UTF8("   - %@\n"), displayName];
            }
            [text appendString:@"\n"];
        }

        [text appendString:UTF8("  4) Username:\n   Enter the username you set on the \"Share Settings\" screen (e.g. yamada).\n\n")];
        [text appendString:UTF8(
            "  5) Password:\n"
            "   Enter the password you set on the Share Settings screen (it won't\n"
            "   be shown on screen). Many people just use their PC login password.\n\n")];

        [text appendString:UTF8(
            "[4] If you see \"Connected!\", it worked. The drive will appear under\n"
            "\"This PC\" in File Explorer.\n\n"
            "If it doesn't work, first check whether the IP address in step 1 has\n"
            "changed (restarting the iBook/Mac can change its IP address).")];
    }

    if (windowsGuideWindow == nil) {
        NSRect frame = NSMakeRect(180, 100, 480, 480);
        windowsGuideWindow = [[NSWindow alloc] initWithContentRect:frame
                                                           styleMask:(NSTitledWindowMask | NSClosableWindowMask |
                                                                      NSResizableWindowMask)
                                                             backing:NSBackingStoreBuffered
                                                               defer:NO];
        [windowsGuideWindow setTitle:L("Windows用接続ガイド")];
        [windowsGuideWindow setReleasedWhenClosed:NO];

        NSScrollView *guideScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 480, 480)];
        [guideScroll setHasVerticalScroller:YES];
        [guideScroll setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
        [guideScroll setBorderType:NSNoBorder];

        windowsGuideTextView = [[NSTextView alloc] initWithFrame:[guideScroll bounds]];
        [windowsGuideTextView setEditable:NO];
        [windowsGuideTextView setSelectable:YES];
        [windowsGuideTextView setFont:[NSFont systemFontOfSize:13]];
        [windowsGuideTextView setAutoresizingMask:NSViewWidthSizable];
        [windowsGuideTextView setVerticallyResizable:YES];
        [windowsGuideTextView setHorizontallyResizable:NO];
        [windowsGuideTextView setTextContainerInset:NSMakeSize(10, 10)];

        [guideScroll setDocumentView:windowsGuideTextView];
        [windowsGuideTextView release];
        [[windowsGuideWindow contentView] addSubview:guideScroll];
        [guideScroll release];
    }

    [windowsGuideTextView setString:text];
    [windowsGuideWindow makeKeyAndOrderFront:nil];
}

- (void)doStartSharing:(NSDictionary *)args
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSDictionary *sharesDict = [args objectForKey:@"shares"];
    NSString *user = [args objectForKey:@"user"];
    NSString *pass = [args objectForKey:@"pass"];
    int port = [[args objectForKey:@"port"] intValue];
    if (port <= 0) {
        port = 8091;
    }

    LocalWebDAVServer *server = [[LocalWebDAVServer alloc] initWithShares:sharesDict user:user password:pass];
    BOOL started = NO;
    int attempt;
    int p = port;
    for (attempt = 0; attempt < 10; attempt++) {
        if ([server startOnPort:p]) {
            started = YES;
            break;
        }
        p++;
    }

    NSString *message;
    if (started) {
        localWebDAVServer = server;
        NSString *ip = GetLocalIPAddress();
        message = [NSString stringWithFormat:
                   L("共有中です(%d フォルダ)。他の機器から下記へ接続してください:\nhttp://%@:%d/ (ユーザー名/パスワードが必要)"),
                   (int)[sharesDict count], ip, p];
    } else {
        [server release];
        message = L("共有の開始に失敗しました(ポートを確保できません)");
    }

    [self performSelectorOnMainThread:@selector(sharingStartedWithMessage:)
                            withObject:message
                         waitUntilDone:NO
     ];
    [pool release];
}

- (void)sharingStartedWithMessage:(NSString *)message
{
    sharing = (localWebDAVServer != nil);
    [shareStatusLabel setStringValue:message];
    [shareStartButton setEnabled:YES];
    [shareStartButton setTitle:(sharing ? L("共有停止") : L("共有開始"))];
}

- (void)doStopSharing
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if (localWebDAVServer != nil) {
        [localWebDAVServer stop];
        [localWebDAVServer release];
        localWebDAVServer = nil;
    }
    [self performSelectorOnMainThread:@selector(sharingStoppedWithMessage:)
                            withObject:L("共有を停止しました")
                         waitUntilDone:NO];
    [pool release];
}

- (void)sharingStoppedWithMessage:(NSString *)message
{
    sharing = NO;
    [shareStatusLabel setStringValue:message];
    [shareStartButton setEnabled:YES];
    [shareStartButton setTitle:L("共有開始")];
}

/* ============ 共有設定の永続化 ============ */

- (void)saveShareSettings
{
    NSMutableArray *plist = [NSMutableArray array];
    NSEnumerator *e = [shareFolders objectEnumerator];
    NSDictionary *f;
    while ((f = [e nextObject])) {
        [plist addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                           [f objectForKey:@"name"], @"name",
                           [f objectForKey:@"path"], @"path", nil]];
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:plist forKey:@"AquaLinkShareFolders"];
    if (shareUser) {
        [defaults setObject:shareUser forKey:@"AquaLinkShareUser"];
    }
    [defaults setInteger:sharePortValue forKey:@"AquaLinkSharePort"];
    [defaults synchronize];

    if ([sharePassword length] > 0) {
        SaveKeychainPassword(KEYCHAIN_SERVICE_SHARE, KEYCHAIN_ACCOUNT_SHARE, sharePassword);
    }
}

- (void)loadShareSettings
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSArray *plist = [defaults arrayForKey:@"AquaLinkShareFolders"];
    [shareFolders removeAllObjects];
    if (plist != nil) {
        NSEnumerator *e = [plist objectEnumerator];
        NSDictionary *f;
        while ((f = [e nextObject])) {
            [shareFolders addObject:[NSMutableDictionary dictionaryWithDictionary:f]];
        }
    }

    NSString *savedUser = [defaults stringForKey:@"AquaLinkShareUser"];
    [shareUser release];
    shareUser = [(savedUser ? savedUser : L("yamada")) retain];

    int savedPort = [defaults integerForKey:@"AquaLinkSharePort"];
    sharePortValue = (savedPort > 0) ? savedPort : 8091;

    [sharePassword release];
    sharePassword = [LoadKeychainPassword(KEYCHAIN_SERVICE_SHARE, KEYCHAIN_ACCOUNT_SHARE) retain];
}

/* アプリ起動時、前回の共有設定が保存されていれば自動的に共有を再開する */
- (void)autoStartSharingIfConfigured
{
    if ([shareFolders count] == 0 || [sharePassword length] == 0 || [shareUser length] == 0) {
        return;
    }

    NSMutableDictionary *sharesDict = [NSMutableDictionary dictionary];
    NSEnumerator *e = [shareFolders objectEnumerator];
    NSDictionary *f;
    BOOL anyValid = NO;
    while ((f = [e nextObject])) {
        NSString *path = [f objectForKey:@"path"];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir) {
            [sharesDict setObject:path forKey:[f objectForKey:@"name"]];
            anyValid = YES;
        }
    }
    if (!anyValid) {
        return;
    }

    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                           sharesDict, @"shares", shareUser, @"user", sharePassword, @"pass",
                           [NSNumber numberWithInt:sharePortValue], @"port", nil];
    [NSThread detachNewThreadSelector:@selector(doStartSharing:) toTarget:self withObject:args];
}

- (void)dealloc
{
    [entries release];
    [sortColumnId release];
    [currentServer release];
    [currentShare release];
    [currentPath release];
    [smb2Lock release];
    [webdavServer release];
    [mountPointPath release];
    [bookmarks release];
    [localWebDAVServer release];
    [shareFolders release];
    [shareUser release];
    [sharePassword release];
    [super dealloc];
}

@end
