#import <Foundation/Foundation.h>
#include <time.h>

/* このMacのローカルフォルダ(複数可)を、LAN上の他機器(Mac/Windows)にWebDAVで公開する。
   ルート("/")には各共有フォルダが名前付きの仮想サブフォルダとして並ぶ。
   Basic認証必須(全フォルダ共通の1組)。パストラバーサル(../)は拒否する。 */
@interface LocalWebDAVServer : NSObject
{
    NSDictionary *shares;   /* { 共有名(NSString) : ローカル絶対パス(NSString) } */
    NSString *authUser;
    NSString *authPassword;
    int listenFd;
    int port;
    BOOL shouldRun;
}

- (id)initWithShares:(NSDictionary *)sharesDict user:(NSString *)user password:(NSString *)password;
- (BOOL)startOnPort:(int)p;
- (void)stop;
- (int)port;

- (void)acceptLoop;
- (void)handleConnection:(NSNumber *)fdNumber;
- (BOOL)checkAuth:(NSDictionary *)headers method:(NSString *)method path:(NSString *)path;
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
                               size:(unsigned long long)size mtime:(time_t)mtime
                               host:(NSString *)host;
- (void)handlePROPFINDRoot:(NSString *)path depth:(NSString *)depth host:(NSString *)host toSocket:(int)fd;
- (void)handlePROPFIND:(NSString *)path depth:(NSString *)depth host:(NSString *)host toSocket:(int)fd;
- (void)handlePROPPATCH:(NSString *)path body:(NSData *)body host:(NSString *)host toSocket:(int)fd;
- (void)handleGET:(NSString *)path toSocket:(int)fd includeBody:(BOOL)includeBody;
- (void)handlePUT:(NSString *)path body:(NSData *)body toSocket:(int)fd;
- (void)handleDELETE:(NSString *)path toSocket:(int)fd;
- (void)handleMKCOL:(NSString *)path toSocket:(int)fd;
- (void)handleLOCK:(NSString *)path toSocket:(int)fd;

@end
