#import "AppDelegate.h"
#import "WebDAVServer.h"
#include <fcntl.h>

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

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    entries = [[NSMutableArray alloc] init];
    currentPath = [@"" retain];
    smb2Lock = [[NSLock alloc] init];
    mounted = NO;

    /* --- 最低限のメニューバー(Quitだけ) --- */
    NSMenu *menubar = [[NSMenu alloc] init];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    [menubar addItem:appMenuItem];
    [NSApp setMainMenu:menubar];
    NSMenu *appMenu = [[NSMenu alloc] init];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit NASBrowser"
                                                        action:@selector(terminate:)
                                                 keyEquivalent:@"q"];
    [appMenu addItem:quitItem];
    [appMenuItem setSubmenu:appMenu];
    [quitItem release];
    [appMenu release];
    [appMenuItem release];
    [menubar release];

    /* --- ウィンドウ --- */
    NSRect frame = NSMakeRect(100, 100, 700, 420);
    window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:(NSTitledWindowMask | NSClosableWindowMask |
                                                      NSMiniaturizableWindowMask | NSResizableWindowMask)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [window setTitle:@"NASBrowser"];

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

    scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(10, 30, w - 20, h - 100)];
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
    return (int)[entries count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(int)rowIndex
{
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
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:@"NASBrowserBookmarks"];
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
    [[NSUserDefaults standardUserDefaults] setObject:bookmarks forKey:@"NASBrowserBookmarks"];
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
    [super dealloc];
}

@end
