#import <Cocoa/Cocoa.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>

@class WebDAVServer;

@interface AppDelegate : NSObject
{
    NSWindow *window;

    NSComboBox *urlField;
    NSSecureTextField *passwordField;
    NSButton *connectButton;
    NSButton *upButton;
    NSButton *mountButton;
    NSTextField *pathLabel;
    NSTextField *statusLabel;
    NSScrollView *scrollView;
    NSTableView *tableView;

    struct smb2_context *smb2;
    NSLock *smb2Lock;         /* smb2への全アクセスはこのロックを取ってから行う */
    NSString *currentServer;
    NSString *currentShare;
    NSString *currentPath;    /* "" がルート。区切りは "/" */

    NSMutableArray *entries;  /* 各要素は NSDictionary { name, isDir, size } */

    WebDAVServer *webdavServer;
    BOOL mounted;
    NSString *mountPointPath;

    NSMutableArray *bookmarks; /* 接続に成功したsmb://URLの履歴。新しい順、最大10件 */
}

- (void)connectAction:(id)sender;
- (void)upAction:(id)sender;
- (void)mountAction:(id)sender;
- (void)loadBookmarks;
- (void)addBookmark:(NSString *)urlString;

/* NSComboBox データソース(履歴の一覧表示に使用) */
- (int)numberOfItemsInComboBox:(NSComboBox *)aComboBox;
- (id)comboBox:(NSComboBox *)aComboBox objectValueForItemAtIndex:(int)index;

- (void)doConnect:(NSDictionary *)args;
- (void)connectSucceeded;
- (void)connectFailed:(NSString *)message;
- (void)listDirectory:(NSString *)path;
- (void)navigateThread:(NSString *)path;
- (void)listFailed:(NSString *)message;
- (void)applyEntries:(NSDictionary *)payload;
- (void)rowDoubleClicked:(id)sender;
- (BOOL)downloadRemotePath:(NSString *)remotePath toLocalPath:(NSString *)localPath;
- (BOOL)uploadLocalPath:(NSString *)localPath toRemotePath:(NSString *)remotePath;
- (void)uploadFiles:(NSArray *)localPaths;
- (void)uploadFinished:(NSDictionary *)result;

/* WebDAVServerから使うアクセサ */
- (struct smb2_context *)smb2Context;
- (NSLock *)smb2Lock;
- (NSString *)currentShareName;
- (BOOL)isConnected;

- (void)doMount;
- (void)mountFinishedWithMessage:(NSString *)message;
- (void)unmountAction:(id)sender;
- (void)doUnmount;
- (BOOL)runUnmountCommand:(NSString *)mountPoint force:(BOOL)force;

@end
