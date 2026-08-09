#import <Foundation/Foundation.h>
#include <time.h>

@class AppDelegate;

/* iBook自身(127.0.0.1)向けに極小のWebDAVサーバーを立て、mount_webdavからのリクエストを
   libsmb2経由でNAS(SMB3)に転送する。CLAUDE.md 第2段の実装。 */
@interface WebDAVServer : NSObject
{
    AppDelegate *appDelegate; /* weak参照。所有はAppDelegate側 */
    int listenFd;
    int port;
    BOOL shouldRun;
}

- (id)initWithAppDelegate:(AppDelegate *)delegate;
- (BOOL)startOnPort:(int)p;
- (void)stop;
- (int)port;

- (void)acceptLoop;
- (void)handleConnection:(NSNumber *)fdNumber;
- (BOOL)readRequestFromSocket:(int)fd
                        method:(NSString **)methodOut
                          path:(NSString **)pathOut
                       headers:(NSDictionary **)headersOut
                          body:(NSData **)bodyOut;
- (void)sendBytes:(NSData *)data toSocket:(int)fd;
- (void)sendSimpleStatus:(NSString *)status toSocket:(int)fd;
- (NSString *)smbPathForWebDAVPath:(NSString *)path;
- (void)handleOPTIONS:(int)fd;
- (NSString *)responseEntryForHref:(NSString *)href isDir:(BOOL)isDir
                               size:(unsigned long long)size mtime:(time_t)mtime;
- (void)handlePROPFIND:(NSString *)path depth:(NSString *)depth toSocket:(int)fd;
- (void)handleGET:(NSString *)path toSocket:(int)fd includeBody:(BOOL)includeBody;
- (void)handlePUT:(NSString *)path body:(NSData *)body toSocket:(int)fd;
- (void)handleDELETE:(NSString *)path toSocket:(int)fd;
- (void)handleMKCOL:(NSString *)path toSocket:(int)fd;
- (void)handleLOCK:(NSString *)path toSocket:(int)fd;

@end
