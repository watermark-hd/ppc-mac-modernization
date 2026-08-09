#import <Foundation/Foundation.h>
#include <time.h>

/* iBookのローカルフォルダを、LAN上の他機器(Mac/Windows)にWebDAVで公開する。
   Basic認証必須。パストラバーサル(../)は拒否する。 */
@interface LocalWebDAVServer : NSObject
{
    NSString *rootPath;   /* 共有するローカルフォルダの絶対パス */
    NSString *authUser;
    NSString *authPassword;
    int listenFd;
    int port;
    BOOL shouldRun;
}

- (id)initWithRootPath:(NSString *)path user:(NSString *)user password:(NSString *)password;
- (BOOL)startOnPort:(int)p;
- (void)stop;
- (int)port;

- (void)acceptLoop;
- (void)handleConnection:(NSNumber *)fdNumber;
- (BOOL)checkAuth:(NSDictionary *)headers;
- (void)sendUnauthorized:(int)fd;
- (BOOL)readRequestFromSocket:(int)fd
                        method:(NSString **)methodOut
                          path:(NSString **)pathOut
                       headers:(NSDictionary **)headersOut
                          body:(NSData **)bodyOut;
- (void)sendBytes:(NSData *)data toSocket:(int)fd;
- (void)sendSimpleStatus:(NSString *)status toSocket:(int)fd;
- (NSString *)localPathForWebDAVPath:(NSString *)path;
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
