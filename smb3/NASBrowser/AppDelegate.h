#import <Cocoa/Cocoa.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>

@interface AppDelegate : NSObject
{
    NSWindow *window;

    NSTextField *urlField;
    NSSecureTextField *passwordField;
    NSButton *connectButton;
    NSButton *upButton;
    NSTextField *pathLabel;
    NSTextField *statusLabel;
    NSScrollView *scrollView;
    NSTableView *tableView;

    struct smb2_context *smb2;
    NSString *currentServer;
    NSString *currentShare;
    NSString *currentPath;   /* "" がルート。区切りは "/" */

    NSMutableArray *entries; /* 各要素は NSDictionary { name, isDir, size } */
}

- (void)connectAction:(id)sender;
- (void)upAction:(id)sender;

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

@end
