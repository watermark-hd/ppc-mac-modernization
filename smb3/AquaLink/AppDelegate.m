#import "AppDelegate.h"
#import "WebDAVServer.h"
#import "LocalWebDAVServer.h"
#include <fcntl.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <string.h>
#include <Security/Security.h>

/* 古いgcc(4.0系)はObjective-Cの @"..." 日本語リテラルを正しく解釈しないことがあるため、
   C文字列(生バイト列、コンパイラによる再解釈なし)からUTF-8として明示的に組み立てる */
#define UTF8(cstr) [NSString stringWithUTF8String:(cstr)]

/* ディレクトリを先に、続いてファイル名の昇順でソートする比較関数 */
static int CompareEntries(id a, id b, void *context)
{
    BOOL aDir = [[a objectForKey:@"isDir"] boolValue];
    BOOL bDir = [[b objectForKey:@"isDir"] boolValue];
    if (aDir != bDir) {
        return aDir ? NSOrderedAscending : NSOrderedDescending;
    }
    return [[a objectForKey:@"name"] caseInsensitiveCompare:[b objectForKey:@"name"]];
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
    return address ? address : @"(IP不明)";
}

/* --- キーチェーン: 共有機能のパスワードを平文でNSUserDefaultsに置かないための保存先 --- */
#define KEYCHAIN_SERVICE "AquaLink-Share"
#define KEYCHAIN_ACCOUNT "shared-password"

static void SaveKeychainPassword(NSString *password)
{
    const char *pass = [password UTF8String];
    UInt32 passLen = pass ? (UInt32)strlen(pass) : 0;

    SecKeychainItemRef item = NULL;
    OSStatus status = SecKeychainFindGenericPassword(NULL,
                                                       (UInt32)strlen(KEYCHAIN_SERVICE), KEYCHAIN_SERVICE,
                                                       (UInt32)strlen(KEYCHAIN_ACCOUNT), KEYCHAIN_ACCOUNT,
                                                       NULL, NULL, &item);
    if (status == noErr && item != NULL) {
        SecKeychainItemModifyContent(item, NULL, passLen, pass);
        CFRelease(item);
    } else {
        SecKeychainAddGenericPassword(NULL,
                                       (UInt32)strlen(KEYCHAIN_SERVICE), KEYCHAIN_SERVICE,
                                       (UInt32)strlen(KEYCHAIN_ACCOUNT), KEYCHAIN_ACCOUNT,
                                       passLen, pass, NULL);
    }
}

static NSString *LoadKeychainPassword(void)
{
    UInt32 passLen = 0;
    void *passData = NULL;
    OSStatus status = SecKeychainFindGenericPassword(NULL,
                                                       (UInt32)strlen(KEYCHAIN_SERVICE), KEYCHAIN_SERVICE,
                                                       (UInt32)strlen(KEYCHAIN_ACCOUNT), KEYCHAIN_ACCOUNT,
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

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    entries = [[NSMutableArray alloc] init];
    currentPath = [@"" retain];
    smb2Lock = [[NSLock alloc] init];
    mounted = NO;

    shareFolders = [[NSMutableArray alloc] init];
    [self loadShareSettings];

    /* --- メニューバー(共有設定・Quit) ---
       [既知の不具合・原因不明] このTiger環境ではプルダウンメニューを開いても
       中身が表示されない/意図しない場所に浮遊表示される問題がある。メニュー構造
       そのものは正しいことをダンプで確認済み(重複なし)。target設定・release
       タイミング・setMainMenu:の順序など複数の仮説を試したが解消しなかったため、
       WindowServer側の描画バグの可能性が高いと判断し、メニュー自体の修正は断念した。
       実用上は下記のメインウィンドウ内の「このMacを共有(NAS化)...」ボタンから
       同じ画面を開けるので、共有設定はそちらを使うこと。 */
    NSMenu *menubar = [NSApp mainMenu];
    NSMenuItem *appMenuItem;
    BOOL needsInstall = NO;
    if (menubar == nil) {
        menubar = [[NSMenu alloc] init];
        appMenuItem = [[NSMenuItem alloc] init];
        [menubar addItem:appMenuItem];
        needsInstall = YES;
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

    NSMenuItem *shareMenuItem = [[NSMenuItem alloc] initWithTitle:UTF8("共有設定...")
                                                             action:@selector(showShareWindow:)
                                                      keyEquivalent:@""];
    [shareMenuItem setTarget:self];
    [appMenu addItem:shareMenuItem];
    [shareMenuItem release];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit AquaLink"
                                                        action:@selector(terminate:)
                                                 keyEquivalent:@"q"];
    [quitItem setTarget:NSApp];
    [appMenu addItem:quitItem];
    [quitItem release];
    /* menubar / appMenuItem / appMenu はここでreleaseしない(意図的) */

    /* タイトル・中身が全て確定してから最後にインストールする */
    if (needsInstall) {
        [NSApp setMainMenu:menubar];
    }

    /* --- ウィンドウ --- */
    NSRect frame = NSMakeRect(100, 100, 700, 450);
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

    urlField = [[NSComboBox alloc] initWithFrame:NSMakeRect(10, h - 32, 380, 22)];
    [urlField setStringValue:@"smb://user@server/share"];
    [urlField setUsesDataSource:YES];
    [urlField setDataSource:self];
    [urlField setCompletes:NO];
    [urlField setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [content addSubview:urlField];
    [urlField release];

    passwordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(400, h - 32, 150, 22)];
    [[passwordField cell] setPlaceholderString:UTF8("パスワード")];
    [passwordField setAutoresizingMask:(NSViewMinXMargin | NSViewMinYMargin)];
    [content addSubview:passwordField];
    [passwordField release];

    connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(560, h - 34, 130, 26)];
    [connectButton setTitle:UTF8("接続")];
    [connectButton setBezelStyle:NSRoundedBezelStyle];
    [connectButton setTarget:self];
    [connectButton setAction:@selector(connectAction:)];
    [connectButton setAutoresizingMask:(NSViewMinXMargin | NSViewMinYMargin)];
    [content addSubview:connectButton];
    [connectButton release];

    pathLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, h - 60, 480, 18)];
    [pathLabel setEditable:NO];
    [pathLabel setBezeled:NO];
    [pathLabel setDrawsBackground:NO];
    [pathLabel setStringValue:@""];
    [pathLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [content addSubview:pathLabel];
    [pathLabel release];

    upButton = [[NSButton alloc] initWithFrame:NSMakeRect(500, h - 62, 50, 22)];
    [upButton setTitle:UTF8("上へ")];
    [upButton setBezelStyle:NSRoundedBezelStyle];
    [upButton setTarget:self];
    [upButton setAction:@selector(upAction:)];
    [upButton setAutoresizingMask:(NSViewMinXMargin | NSViewMinYMargin)];
    [content addSubview:upButton];
    [upButton release];

    mountButton = [[NSButton alloc] initWithFrame:NSMakeRect(560, h - 62, 130, 22)];
    [mountButton setTitle:UTF8("Finderに接続")];
    [mountButton setBezelStyle:NSRoundedBezelStyle];
    [mountButton setTarget:self];
    [mountButton setAction:@selector(mountAction:)];
    [mountButton setAutoresizingMask:(NSViewMinXMargin | NSViewMinYMargin)];
    [content addSubview:mountButton];
    [mountButton release];

    NSButton *shareSettingsButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, h - 92, 200, 22)];
    [shareSettingsButton setTitle:UTF8("このMacを共有(NAS化)...")];
    [shareSettingsButton setBezelStyle:NSRoundedBezelStyle];
    [shareSettingsButton setTarget:self];
    [shareSettingsButton setAction:@selector(showShareWindow:)];
    [shareSettingsButton setAutoresizingMask:(NSViewMinYMargin)];
    [content addSubview:shareSettingsButton];
    [shareSettingsButton release];

    scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 30, w - 20, h - 130)];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

    tableView = [[NSTableView alloc] initWithFrame:[scrollView bounds]];
    [tableView setDataSource:self];
    [tableView setDelegate:self];
    [tableView setTarget:self];
    [tableView setDoubleAction:@selector(rowDoubleClicked:)];
    [tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [tableView registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];

    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    [[nameCol headerCell] setStringValue:UTF8("名前")];
    [nameCol setWidth:340];
    [tableView addTableColumn:nameCol];
    [nameCol release];

    NSTableColumn *typeCol = [[NSTableColumn alloc] initWithIdentifier:@"type"];
    [[typeCol headerCell] setStringValue:UTF8("種類")];
    [typeCol setWidth:100];
    [tableView addTableColumn:typeCol];
    [typeCol release];

    NSTableColumn *sizeCol = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    [[sizeCol headerCell] setStringValue:UTF8("サイズ")];
    [sizeCol setWidth:100];
    [tableView addTableColumn:sizeCol];
    [sizeCol release];

    [scrollView setDocumentView:tableView];
    [tableView release];
    [content addSubview:scrollView];
    [scrollView release];

    statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 6, w - 20, 18)];
    [statusLabel setEditable:NO];
    [statusLabel setBezeled:NO];
    [statusLabel setDrawsBackground:NO];
    [statusLabel setStringValue:UTF8("未接続")];
    [statusLabel setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
    [content addSubview:statusLabel];
    [statusLabel release];

    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    [self autoStartSharingIfConfigured];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    /* マウント中に何も考えずWebDAVサーバーを止めると、OS側はマウントされたままだと
       思い込んだ「壊れたマウント」が残ってしまう(実際に発生した不具合)。
       終了処理でも必ず先にOSレベルの取り外しを試みてからサーバーを止める。 */
    if (mounted && mountPointPath != nil) {
        BOOL ok = [self runUnmountCommand:mountPointPath force:NO];
        if (!ok) {
            [self runUnmountCommand:mountPointPath force:YES];
        }
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
}

/* ============ 接続 ============ */

- (void)connectAction:(id)sender
{
    NSString *urlString = [urlField stringValue];
    NSString *password = [passwordField stringValue];
    [connectButton setEnabled:NO];
    [statusLabel setStringValue:UTF8("接続中...")];

    NSDictionary *args = [NSDictionary dictionaryWithObjectsAndKeys:
                           urlString, @"url",
                           (password ? password : @""), @"password", nil];
    [NSThread detachNewThreadSelector:@selector(doConnect:) toTarget:self withObject:args];
}

- (void)doConnect:(NSDictionary *)args
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *urlString = [args objectForKey:@"url"];
    NSString *password = [args objectForKey:@"password"];

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
                                withObject:UTF8("smb2コンテキストの初期化に失敗しました")
                             waitUntilDone:NO];
        [pool release];
        return;
    }

    struct smb2_url *url = smb2_parse_url(ctx, [urlString UTF8String]);
    if (url == NULL) {
        NSString *err = [NSString stringWithFormat:UTF8("URL解析エラー: %s"), smb2_get_error(ctx)];
        smb2_destroy_context(ctx);
        [self performSelectorOnMainThread:@selector(connectFailed:) withObject:err waitUntilDone:NO];
        [pool release];
        return;
    }

    smb2_set_security_mode(ctx, SMB2_NEGOTIATE_SIGNING_ENABLED);
    if (url->user) {
        smb2_set_user(ctx, url->user);
    }
    if ([password length] > 0) {
        smb2_set_password(ctx, [password UTF8String]);
    }

    int rc = smb2_connect_share(ctx, url->server, url->share, url->user);
    if (rc != 0) {
        NSString *err = [NSString stringWithFormat:UTF8("接続失敗: %s"), smb2_get_error(ctx)];
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
    [statusLabel setStringValue:UTF8("接続しました")];
    [connectButton setEnabled:YES];
    [self addBookmark:[urlField stringValue]];
}

- (void)connectFailed:(NSString *)message
{
    [statusLabel setStringValue:message];
    [connectButton setEnabled:YES];
}

/* ============ ディレクトリ一覧 ============ */

/* バックグラウンドスレッドから呼ばれる。呼び出し元がNSAutoreleasePoolを用意していること */
- (void)listDirectory:(NSString *)path
{
    NSMutableArray *result = [NSMutableArray array];

    [smb2Lock lock];
    struct smb2dir *dir = smb2_opendir(smb2, [path UTF8String]);
    if (dir == NULL) {
        NSString *err = [NSString stringWithFormat:UTF8("一覧取得失敗: %s"), smb2_get_error(smb2)];
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
        BOOL isDir = (ent->st.smb2_type == SMB2_TYPE_DIRECTORY);
        NSDictionary *e = [NSDictionary dictionaryWithObjectsAndKeys:
                            name, @"name",
                            [NSNumber numberWithBool:isDir], @"isDir",
                            [NSNumber numberWithUnsignedLongLong:ent->st.smb2_size], @"size",
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

    NSArray *sorted = [result sortedArrayUsingFunction:CompareEntries context:NULL];
    [entries release];
    entries = [sorted mutableCopy];

    [tableView reloadData];
    [pathLabel setStringValue:[NSString stringWithFormat:@"/%@/%@",
                                (currentShare ? currentShare : @""), path]];
    [statusLabel setStringValue:[NSString stringWithFormat:UTF8("%lu 件"), (unsigned long)[entries count]]];
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

    [statusLabel setStringValue:UTF8("読み込み中...")];
    [NSThread detachNewThreadSelector:@selector(navigateThread:) toTarget:self withObject:newPath];
}

- (void)upAction:(id)sender
{
    if (smb2 == NULL || [currentPath length] == 0) {
        return;
    }
    NSRange r = [currentPath rangeOfString:@"/" options:NSBackwardsSearch];
    NSString *parent = (r.location == NSNotFound) ? @"" : [currentPath substringToIndex:r.location];

    [statusLabel setStringValue:UTF8("読み込み中...")];
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
    } else if ([identifier isEqualToString:@"type"]) {
        return isDir ? UTF8("フォルダ") : UTF8("ファイル");
    } else if ([identifier isEqualToString:@"size"]) {
        return FormatSize([[e objectForKey:@"size"] unsignedLongLongValue], isDir);
    }
    return @"";
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
            [statusLabel setStringValue:[NSString stringWithFormat:UTF8("%@ のダウンロードに失敗しました"), name]];
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

    [statusLabel setStringValue:UTF8("アップロード中...")];
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
        [statusLabel setStringValue:[NSString stringWithFormat:UTF8("%d件のアップロードに失敗しました"), fail]];
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

- (void)mountAction:(id)sender
{
    if (mounted) {
        [self unmountAction:sender];
        return;
    }
    if (![self isConnected]) {
        [statusLabel setStringValue:UTF8("先に接続してください")];
        return;
    }
    [mountButton setEnabled:NO];
    [statusLabel setStringValue:UTF8("Finderに接続中...")];
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
        [self performSelectorOnMainThread:@selector(mountFinishedWithMessage:)
                                withObject:UTF8("WebDAVサーバーの起動に失敗しました")
                             waitUntilDone:NO];
        [pool release];
        return;
    }

    NSString *mountName = ([currentShare length] > 0) ? currentShare : @"NAS";
    NSString *mountPoint = [NSString stringWithFormat:@"/Volumes/%@", mountName];
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
    @try {
        [task launch];
        [task waitUntilExit];
        success = ([task terminationStatus] == 0);
    }
    @catch (NSException *ex) {
        resultMessage = [NSString stringWithFormat:UTF8("マウント失敗: %@"), [ex reason]];
        success = NO;
    }

    if (success) {
        mountPointPath = [mountPoint retain];
        mounted = YES;
        resultMessage = [NSString stringWithFormat:UTF8("%@ にマウントしました"), mountPoint];
    } else if (resultMessage == nil) {
        NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errStr = [[[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] autorelease];
        resultMessage = [NSString stringWithFormat:UTF8("マウント失敗: %@"), (errStr ? errStr : @"")];
    }
    [task release];

    if (!success) {
        [webdavServer stop];
        [webdavServer release];
        webdavServer = nil;
    }

    [self performSelectorOnMainThread:@selector(mountFinishedWithMessage:)
                            withObject:resultMessage
                         waitUntilDone:NO];
    [pool release];
}

- (void)mountFinishedWithMessage:(NSString *)message
{
    [statusLabel setStringValue:message];
    [mountButton setEnabled:YES];
    [mountButton setTitle:(mounted ? UTF8("取り外す") : UTF8("Finderに接続"))];
}

- (void)unmountAction:(id)sender
{
    [mountButton setEnabled:NO];
    [statusLabel setStringValue:UTF8("取り外し中...")];
    [NSThread detachNewThreadSelector:@selector(doUnmount) toTarget:self withObject:nil];
}

- (void)doUnmount
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    BOOL unmountOK = NO;

    if (mountPointPath != nil) {
        /* まず通常のumountを試し、失敗したら-fで強制する。
           OSレベルの取り外しが本当に成功したかどうかをterminationStatusで確認してから
           WebDAVサーバーを止める。ここを確認せずにサーバーだけ止めると、OS側は
           マウントされたままなのに応答するサーバーが無い「壊れたマウント」になり、
           以後 /Volumes へのアクセス全体がハングする(実際に発生した不具合)。 */
        unmountOK = [self runUnmountCommand:mountPointPath force:NO];
        if (!unmountOK) {
            unmountOK = [self runUnmountCommand:mountPointPath force:YES];
        }
    } else {
        unmountOK = YES;
    }

    NSString *resultMessage;
    if (unmountOK) {
        if (webdavServer != nil) {
            [webdavServer stop];
            [webdavServer release];
            webdavServer = nil;
        }
        [mountPointPath release];
        mountPointPath = nil;
        mounted = NO;
        resultMessage = UTF8("取り外しました");
    } else {
        /* 取り外しに失敗した場合はサーバーを止めない(壊れたマウントを作らないため) */
        resultMessage = UTF8("取り外しに失敗しました。Finderから取り出すか、再度お試しください");
    }

    [self performSelectorOnMainThread:@selector(mountFinishedWithMessage:)
                            withObject:resultMessage
                         waitUntilDone:NO];
    [pool release];
}

/* バックグラウンドスレッドから呼ばれる。umount(必要なら-f付き)を実行し、成功したかを返す */
- (BOOL)runUnmountCommand:(NSString *)mountPoint force:(BOOL)force
{
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/sbin/umount"];
    if (force) {
        [task setArguments:[NSArray arrayWithObjects:@"-f", mountPoint, nil]];
    } else {
        [task setArguments:[NSArray arrayWithObjects:mountPoint, nil]];
    }
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];

    BOOL ok = NO;
    @try {
        [task launch];
        [task waitUntilExit];
        ok = ([task terminationStatus] == 0);
    }
    @catch (NSException *ex) {
        ok = NO;
    }
    [task release];
    return ok;
}

/* ============ ブックマーク(接続履歴) ============ */

- (void)loadBookmarks
{
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"AquaLinkBookmarks"];
    [bookmarks release];
    bookmarks = saved ? [saved mutableCopy] : [[NSMutableArray alloc] init];
}

- (void)addBookmark:(NSString *)urlString
{
    if ([urlString length] == 0) {
        return;
    }
    [bookmarks removeObject:urlString];
    [bookmarks insertObject:urlString atIndex:0];
    while ([bookmarks count] > 10) {
        [bookmarks removeLastObject];
    }
    [[NSUserDefaults standardUserDefaults] setObject:bookmarks forKey:@"AquaLinkBookmarks"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [urlField reloadData];
}

/* ============ NSComboBox データソース ============ */

- (int)numberOfItemsInComboBox:(NSComboBox *)aComboBox
{
    return (int)[bookmarks count];
}

- (id)comboBox:(NSComboBox *)aComboBox objectValueForItemAtIndex:(int)index
{
    if (index < 0 || index >= (int)[bookmarks count]) {
        return @"";
    }
    return [bookmarks objectAtIndex:index];
}

/* ============ このMacを共有する(NAS化)機能 ============ */

- (void)showShareWindow:(id)sender
{
    if (shareWindow == nil) {
        NSRect frame = NSMakeRect(150, 120, 520, 420);
        shareWindow = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:(NSTitledWindowMask | NSClosableWindowMask)
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        [shareWindow setTitle:UTF8("このMacを共有(NAS化)")];
        [shareWindow setReleasedWhenClosed:NO];

        NSView *content = [shareWindow contentView];
        float h = frame.size.height;
        float w = frame.size.width;

        NSTextField *folderLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, h - 24, 200, 18)];
        [folderLabel setEditable:NO];
        [folderLabel setBezeled:NO];
        [folderLabel setDrawsBackground:NO];
        [folderLabel setStringValue:UTF8("共有フォルダ一覧:")];
        [content addSubview:folderLabel];
        [folderLabel release];

        NSScrollView *tableScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, h - 160, w - 20, 130)];
        [tableScroll setHasVerticalScroller:YES];
        [tableScroll setBorderType:NSBezelBorder];

        shareFolderTable = [[NSTableView alloc] initWithFrame:[tableScroll bounds]];
        [shareFolderTable setDataSource:self];
        [shareFolderTable setDelegate:self];

        NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
        [[nameCol headerCell] setStringValue:UTF8("共有名")];
        [nameCol setWidth:140];
        [shareFolderTable addTableColumn:nameCol];
        [nameCol release];

        NSTableColumn *pathCol = [[NSTableColumn alloc] initWithIdentifier:@"path"];
        [[pathCol headerCell] setStringValue:UTF8("フォルダパス")];
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
        [userLabel setStringValue:UTF8("ユーザー名:")];
        [content addSubview:userLabel];
        [userLabel release];

        shareUserField = [[NSTextField alloc] initWithFrame:NSMakeRect(115, h - 224, 200, 22)];
        [shareUserField setStringValue:(shareUser ? shareUser : UTF8("watermark"))];
        [content addSubview:shareUserField];
        [shareUserField release];

        NSTextField *passLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, h - 254, 100, 18)];
        [passLabel setEditable:NO];
        [passLabel setBezeled:NO];
        [passLabel setDrawsBackground:NO];
        [passLabel setStringValue:UTF8("パスワード:")];
        [content addSubview:passLabel];
        [passLabel release];

        sharePasswordField = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(115, h - 256, 200, 22)];
        [[sharePasswordField cell] setPlaceholderString:UTF8("必須")];
        if (sharePassword) {
            [sharePasswordField setStringValue:sharePassword];
        }
        [content addSubview:sharePasswordField];
        [sharePasswordField release];

        NSTextField *portLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(10, h - 286, 100, 18)];
        [portLabel setEditable:NO];
        [portLabel setBezeled:NO];
        [portLabel setDrawsBackground:NO];
        [portLabel setStringValue:UTF8("ポート:")];
        [content addSubview:portLabel];
        [portLabel release];

        sharePortField = [[NSTextField alloc] initWithFrame:NSMakeRect(115, h - 288, 80, 22)];
        [sharePortField setStringValue:(sharePortValue > 0 ? [NSString stringWithFormat:@"%d", sharePortValue] : @"8091")];
        [content addSubview:sharePortField];
        [sharePortField release];

        shareStartButton = [[NSButton alloc] initWithFrame:NSMakeRect(10, h - 328, 140, 26)];
        [shareStartButton setTitle:(sharing ? UTF8("共有停止") : UTF8("共有開始"))];
        [shareStartButton setBezelStyle:NSRoundedBezelStyle];
        [shareStartButton setTarget:self];
        [shareStartButton setAction:@selector(toggleSharingAction:)];
        [content addSubview:shareStartButton];
        [shareStartButton release];

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
        [shareStatusLabel setStringValue:UTF8("停止中...")];
        [NSThread detachNewThreadSelector:@selector(doStopSharing) toTarget:self withObject:nil];
        return;
    }

    NSString *user = [shareUserField stringValue];
    NSString *pass = [sharePasswordField stringValue];
    NSString *portStr = [sharePortField stringValue];

    if ([shareFolders count] == 0) {
        [shareStatusLabel setStringValue:UTF8("共有フォルダを1つ以上追加してください")];
        return;
    }
    if ([user length] == 0 || [pass length] == 0) {
        [shareStatusLabel setStringValue:UTF8("ユーザー名とパスワードを入力してください")];
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
    [shareStatusLabel setStringValue:UTF8("共有を開始しています...")];

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
                   UTF8("共有中です(%d フォルダ)。他の機器から下記へ接続してください:\nhttp://%@:%d/ (ユーザー名/パスワードが必要)"),
                   (int)[sharesDict count], ip, p];
    } else {
        [server release];
        message = UTF8("共有の開始に失敗しました(ポートを確保できません)");
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
    [shareStartButton setTitle:(sharing ? UTF8("共有停止") : UTF8("共有開始"))];
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
                            withObject:UTF8("共有を停止しました")
                         waitUntilDone:NO];
    [pool release];
}

- (void)sharingStoppedWithMessage:(NSString *)message
{
    sharing = NO;
    [shareStatusLabel setStringValue:message];
    [shareStartButton setEnabled:YES];
    [shareStartButton setTitle:UTF8("共有開始")];
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
        SaveKeychainPassword(sharePassword);
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
    shareUser = [(savedUser ? savedUser : UTF8("watermark")) retain];

    int savedPort = [defaults integerForKey:@"AquaLinkSharePort"];
    sharePortValue = (savedPort > 0) ? savedPort : 8091;

    [sharePassword release];
    sharePassword = [LoadKeychainPassword() retain];
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
