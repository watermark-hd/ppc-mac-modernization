#import <Cocoa/Cocoa.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>

/* smb2_set_authentication()自体はタグ付きリリース(libsmb2-6.2含む)の
   libsmb2.hに公開されているが、その引数に渡すSMB2_SEC_*の値は
   libsmb2-private.h(非公開ヘッダ)にしか定義されていない。この値が公開
   ヘッダへ移動したのは2024-12のコミット(fbe9674)で、2026-08時点でどの
   タグ付きリリースにもまだ含まれていない(masterのみ)。値自体は2019年の
   導入(a148a80)以来変わっていない安定したABIなので、無ければここで
   自前定義する。将来のリリースで公開ヘッダに入れば、この#ifndefにより
   自動的に本家の定義を優先する。 */
#ifndef SMB2_SEC_NTLMSSP
enum smb2_sec_compat {
    SMB2_SEC_UNDEFINED_COMPAT = 0,
    SMB2_SEC_NTLMSSP_COMPAT = 1,
    SMB2_SEC_KRB5_COMPAT = 2,
};
#define SMB2_SEC_NTLMSSP SMB2_SEC_NTLMSSP_COMPAT
#endif

@class WebDAVServer;
@class LocalWebDAVServer;

@interface AppDelegate : NSObject
{
    NSWindow *window;

    NSTextField *usernameField;
    NSComboBox *urlField;
    NSTextField *shareField;
    NSSecureTextField *passwordField;
    NSButton *encryptCheckbox; /* SMB3暗号化(seal)を必須にするかどうか */
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

    NSMutableArray *entries;  /* 各要素は NSDictionary { name, isDir, size, mtime } */
    NSString *sortColumnId;   /* 一覧のソート列 "name"/"size"/"date" */
    BOOL sortAscending;       /* 昇順か */

    WebDAVServer *webdavServer;
    BOOL mounted;
    NSString *mountPointPath;

    NSMutableArray *bookmarks; /* 接続に成功したsmb://URLの履歴。新しい順、最大10件 */

    /* --- Bonjour(接続先の自動発見) --- */
    NSNetServiceBrowser *serviceBrowser;
    NSMutableArray *discoveredServices; /* 各要素 NSDictionary { name, address } 解決済みのSMBサーバー */
    NSMutableArray *pendingResolves;    /* resolve中のNSNetService。解決/失敗まで参照を保持する */

    /* --- このMacを共有する(NAS化)機能 --- */
    NSWindow *shareWindow;
    NSTableView *shareFolderTable;
    NSMutableArray *shareFolders;  /* 各要素は NSMutableDictionary { name, path } */
    NSButton *addFolderButton;
    NSButton *removeFolderButton;
    NSTextField *shareUserField;
    NSSecureTextField *sharePasswordField;
    NSTextField *sharePortField;
    NSButton *shareStartButton;
    NSButton *windowsGuideButton;
    NSTextField *shareStatusLabel;
    LocalWebDAVServer *localWebDAVServer;
    BOOL sharing;

    /* Windows用接続ガイド */
    NSWindow *windowsGuideWindow;
    NSTextView *windowsGuideTextView;

    /* ウィンドウが無くても(起動時の自動再開などで)使える設定保持用 */
    NSString *shareUser;
    NSString *sharePassword;
    int sharePortValue;
}

- (void)connectAction:(id)sender;
- (void)upAction:(id)sender;
- (void)mountAction:(id)sender;
- (void)loadBookmarks;
- (void)addBookmarkWithAddress:(NSString *)address share:(NSString *)share username:(NSString *)username;
- (void)autofillFromBookmarkAtIndex:(unsigned int)index;

/* NSComboBox データソース(履歴 + Bonjourで見つけたサーバーの一覧表示に使用) */
- (int)numberOfItemsInComboBox:(NSComboBox *)aComboBox;
- (id)comboBox:(NSComboBox *)aComboBox objectValueForItemAtIndex:(int)index;

/* Bonjour(接続先の自動発見)デリゲート */
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing;
- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didRemoveService:(NSNetService *)service moreComing:(BOOL)moreComing;
- (void)netServiceDidResolveAddress:(NSNetService *)service;
- (void)netService:(NSNetService *)service didNotResolve:(NSDictionary *)errorDict;

/* --- このMacを共有する(NAS化)機能 --- */
- (void)showShareWindow:(id)sender;
- (void)addFolderAction:(id)sender;
- (void)removeFolderAction:(id)sender;
- (void)toggleSharingAction:(id)sender;
- (void)showWindowsGuideAction:(id)sender;
- (void)doStartSharing:(NSDictionary *)args;
- (void)sharingStartedWithMessage:(NSString *)message;
- (void)doStopSharing;
- (void)sharingStoppedWithMessage:(NSString *)message;
- (void)loadShareSettings;
- (void)saveShareSettings;
- (void)autoStartSharingIfConfigured;

- (void)doConnect:(NSDictionary *)args;
- (void)connectSucceeded;
- (void)connectFailed:(NSString *)message;
- (void)listDirectory:(NSString *)path;
- (void)navigateThread:(NSString *)path;
- (void)listFailed:(NSString *)message;
- (void)applyEntries:(NSDictionary *)payload;
- (int)sortKeyKind;
- (void)resortEntries;
- (void)updateSortIndicators;
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
- (BOOL)runPrivilegedUnmount:(NSString *)mountPoint errorMessage:(NSString **)outErrorMessage;

@end
