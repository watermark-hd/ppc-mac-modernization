#import "LocalWebDAVServer.h"

#include <fcntl.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <CommonCrypto/CommonDigest.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <ifaddrs.h>

#define UTF8(cstr) [NSString stringWithUTF8String:(cstr)]

static NSString *MD5Hex(NSString *input)
{
    const char *cstr = [input UTF8String];
    CC_MD5_CTX ctx;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5_Init(&ctx);
    CC_MD5_Update(&ctx, cstr, (CC_LONG)strlen(cstr));
    CC_MD5_Final(digest, &ctx);

    char hex[CC_MD5_DIGEST_LENGTH * 2 + 1];
    int i;
    for (i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        snprintf(hex + i * 2, 3, "%02x", digest[i]);
    }
    return [NSString stringWithUTF8String:hex];
}

/* "Digest key=\"value\", key2=value2, ..." を雑にパースする(フルRFC準拠のトークナイザではない) */
static NSDictionary *ParseDigestAuthHeader(NSString *header)
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (![header hasPrefix:@"Digest "]) {
        return dict;
    }
    NSString *rest = [header substringFromIndex:7];
    NSArray *parts = [rest componentsSeparatedByString:@","];
    NSEnumerator *e = [parts objectEnumerator];
    NSString *part;
    while ((part = [e nextObject])) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSRange eq = [trimmed rangeOfString:@"="];
        if (eq.location == NSNotFound) {
            continue;
        }
        NSString *key = [trimmed substringToIndex:eq.location];
        NSString *value = [trimmed substringFromIndex:eq.location + 1];
        if ([value length] >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
            value = [value substringWithRange:NSMakeRange(1, [value length] - 2)];
        }
        [dict setObject:value forKey:key];
    }
    return dict;
}

static const char *kWeekdays[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
static const char *kMonths[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

static void FormatHTTPDate(time_t t, char *buf, size_t buflen)
{
    struct tm tmv;
    gmtime_r(&t, &tmv);
    snprintf(buf, buflen, "%s, %02d %s %04d %02d:%02d:%02d GMT",
              kWeekdays[tmv.tm_wday], tmv.tm_mday, kMonths[tmv.tm_mon],
              tmv.tm_year + 1900, tmv.tm_hour, tmv.tm_min, tmv.tm_sec);
}

static long FindBytes(const uint8_t *haystack, long haystackLen,
                       const uint8_t *needle, long needleLen, long searchFrom)
{
    long i;
    if (needleLen == 0 || haystackLen < needleLen) {
        return -1;
    }
    for (i = searchFrom; i <= haystackLen - needleLen; i++) {
        if (memcmp(haystack + i, needle, needleLen) == 0) {
            return i;
        }
    }
    return -1;
}

static NSString *XMLEscape(NSString *s)
{
    NSMutableString *r = [NSMutableString stringWithString:s];
    [r replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [r length])];
    [r replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [r length])];
    [r replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [r length])];
    return r;
}

/* PROPPATCHリクエストのXML本文から、<D:set>/<D:remove> 内のプロパティ要素名(名前空間接頭辞込み)を
   雑に抜き出す。フルXMLパーサは使わず、開始タグを単純に走査するだけの簡易実装。 */
static NSArray *ExtractPropertyElementNames(NSString *xml)
{
    NSMutableArray *names = [NSMutableArray array];
    NSSet *skipNames = [NSSet setWithObjects:@"propertyupdate", @"set", @"remove", @"prop", nil];
    unsigned int i = 0;
    unsigned int len = [xml length];
    while (i < len) {
        if ([xml characterAtIndex:i] == '<') {
            if (i + 1 < len && ([xml characterAtIndex:i + 1] == '/' || [xml characterAtIndex:i + 1] == '?')) {
                i++;
                continue;
            }
            NSRange close = [xml rangeOfString:@">" options:0 range:NSMakeRange(i, len - i)];
            if (close.location == NSNotFound) {
                break;
            }
            NSString *tag = [xml substringWithRange:NSMakeRange(i + 1, close.location - i - 1)];
            if ([tag hasSuffix:@"/"]) {
                tag = [tag substringToIndex:[tag length] - 1];
            }
            NSRange space = [tag rangeOfString:@" "];
            if (space.location != NSNotFound) {
                tag = [tag substringToIndex:space.location];
            }
            NSRange colon = [tag rangeOfString:@":"];
            NSString *localName = (colon.location != NSNotFound) ? [tag substringFromIndex:colon.location + 1] : tag;
            if ([localName length] > 0 && ![skipNames containsObject:localName]) {
                [names addObject:tag];
            }
            i = close.location + 1;
        } else {
            i++;
        }
    }
    return names;
}

static NSString *URLEncodePathComponent(NSString *s)
{
    return [s stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
}

static int Base64DecodeChar(char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static NSData *Base64Decode(NSString *input)
{
    const char *cstr = [input UTF8String];
    int len = cstr ? (int)strlen(cstr) : 0;
    NSMutableData *out = [NSMutableData data];
    int buffer = 0, bitsCollected = 0;
    int i;
    for (i = 0; i < len; i++) {
        char c = cstr[i];
        if (c == '=') break;
        int v = Base64DecodeChar(c);
        if (v < 0) continue;
        buffer = (buffer << 6) | v;
        bitsCollected += 6;
        if (bitsCollected >= 8) {
            bitsCollected -= 8;
            uint8_t byte = (uint8_t)((buffer >> bitsCollected) & 0xFF);
            [out appendBytes:&byte length:1];
        }
    }
    return out;
}

/* [2026-09-22追加] 証明書+秘密鍵の保存先。NSUserDefaultsではなく実ファイルに
   するのは、OpenSSLのPEM読み書きAPIがファイルベースだから。既存の設定保存が
   このディレクトリを使っていなかったので新設した。 */
static NSString *AQTLSSupportDir(void)
{
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:
                      @"Library/Application Support/AquaLink"];
    /* [実機検証: 2026-09-22] createDirectoryAtPath:withIntermediateDirectories:
       attributes:error: はLeopard(10.5)以降のAPIで、このTiger実機の
       Foundationにはやはり存在しないことをrespondsToSelector:で確認済み
       (今日のNSAlert setAccessoryView:と同種の罠)。Tiger互換の旧API
       (中間ディレクトリ非対応・NSError無し)を使う。"Library/Application
       Support"自体は実機に既に存在するので、最後の1階層だけ作れれば足りる。
       このプロジェクトの他の箇所(AppDelegate.m内のマウントポイント作成)でも
       同じ旧APIが使われている。 */
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    return dir;
}

static NSString *AQTLSCertPath(void)
{
    return [AQTLSSupportDir() stringByAppendingPathComponent:@"tls-cert.pem"];
}

static NSString *AQTLSKeyPath(void)
{
    return [AQTLSSupportDir() stringByAppendingPathComponent:@"tls-key.pem"];
}

/* 現在のLAN側IPv4アドレスを取得する(AppDelegate.mのGetLocalIPAddress()と
   同じロジック。ファイルをまたいだ共有はせず、このファイル内で完結させる
   既存の方針に合わせて独立に実装している)。証明書のSAN(Subject
   Alternative Name)に載せるためだけに使う。 */
static NSString *AQLocalIPAddress(void)
{
    struct ifaddrs *interfaces = NULL;
    NSString *address = nil;
    if (getifaddrs(&interfaces) == 0) {
        struct ifaddrs *temp = interfaces;
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
    return address;
}

/* 自己署名証明書+RSA鍵を新規生成し、PEMファイルとして保存する。呼ぶのは
   証明書がまだ無い初回だけ(2回目以降は保存済みのものを読み込んで使い回す。
   毎回作り直すと、Finder側で一度信頼した証明書がそのたびに無効になり、
   起動のたびに警告が出てしまうため)。 */
static BOOL AQGenerateAndSaveCertificate(void)
{
    BOOL ok = NO;
    RSA *rsa = RSA_generate_key(2048, RSA_F4, NULL, NULL);
    if (rsa == NULL) {
        return NO;
    }
    EVP_PKEY *pkey = EVP_PKEY_new();
    EVP_PKEY_assign_RSA(pkey, rsa); /* 以後pkeyがrsaの所有権を持つ */

    X509 *x509 = X509_new();
    /* [実機検証: 2026-09-23] X509_new()の既定バージョンはv1(値0)だが、
       拡張(SAN等)はX.509v3(値2。バージョン番号は0始まり)でないと構造上
       許されない。ここを明示しないままSAN拡張だけ追加すると、opensslの
       -textでは一見表示されてしまうものの、.NETの厳密なX509Certificate2
       パーサからは"Certificate is corrupted"として拒否される不正な証明書
       になることを実機で確認した。 */
    X509_set_version(x509, 2);
    ASN1_INTEGER_set(X509_get_serialNumber(x509), 1);
    X509_gmtime_adj(X509_get_notBefore(x509), 0);
    X509_gmtime_adj(X509_get_notAfter(x509), 60L * 60 * 24 * 3650); /* 10年 */
    X509_set_pubkey(x509, pkey);
    X509_NAME *name = X509_get_subject_name(x509);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                                (unsigned char *)"AquaLink", -1, -1, 0);
    X509_set_issuer_name(x509, name);

    /* [実機検証: 2026-09-23] SANが無くCN=AquaLinkだけの証明書だと、Windows
       (Schannel)がホスト名不一致として拒否し、`net use`が「システムエラー
       1244(認証されていない)」で失敗することを実機で確認した。macOSの
       Finderは証明書の信頼可否をOS標準の警告ダイアログでユーザーに直接
       確認させる作りのため、ホスト名の厳密な一致が無くても通っていたが、
       Windows側は`Import-Certificate`で信頼ルートに追加した後の検証で
       CN/SANとの一致を要求するため、この差が表面化した。今のLAN側IPを
       SANのIPアドレスとして載せることで対応する(接続時に指定する
       「任意のサーバー名」はホスト間で揃う保証が無いため、SANに含める
       対象は自己申告不要で必ず一意に定まるIPアドレスのみにしている)。 */
    NSString *localIP = AQLocalIPAddress();
    if ([localIP length] > 0) {
        X509V3_CTX ctx;
        X509V3_set_ctx_nodb(&ctx);
        X509V3_set_ctx(&ctx, x509, x509, NULL, NULL, 0);
        NSString *sanValue = [NSString stringWithFormat:@"IP:%@", localIP];
        X509_EXTENSION *ext = X509V3_EXT_conf_nid(NULL, &ctx, NID_subject_alt_name,
                                                    (char *)[sanValue UTF8String]);
        if (ext != NULL) {
            X509_add_ext(x509, ext, -1);
            X509_EXTENSION_free(ext);
        }
    }

    X509_sign(x509, pkey, EVP_sha256());

    FILE *keyFile = fopen([AQTLSKeyPath() UTF8String], "w");
    if (keyFile) {
        if (PEM_write_PrivateKey(keyFile, pkey, NULL, NULL, 0, NULL, NULL) == 1) {
            ok = YES;
        }
        fclose(keyFile);
        /* 秘密鍵なので所有者以外読めないようにする */
        chmod([AQTLSKeyPath() UTF8String], S_IRUSR | S_IWUSR);
    }
    FILE *certFile = fopen([AQTLSCertPath() UTF8String], "w");
    if (certFile) {
        if (PEM_write_X509(certFile, x509) != 1) {
            ok = NO;
        }
        fclose(certFile);
    } else {
        ok = NO;
    }

    X509_free(x509);
    EVP_PKEY_free(pkey); /* rsaもこれで一緒に解放される */
    return ok;
}

@implementation LocalWebDAVServer

- (id)initWithShares:(NSDictionary *)sharesDict user:(NSString *)user password:(NSString *)password useTLS:(BOOL)tls
{
    self = [super init];
    if (self) {
        shares = [sharesDict retain];
        authUser = [user retain];
        authPassword = [password retain];
        listenFd = -1;
        shouldRun = NO;
        port = 0;
        authFailureCounts = [[NSMutableDictionary alloc] init];
        authFailureLock = [[NSLock alloc] init];
        useTLS = tls;
        sslCtx = NULL;
        tlsConnections = [[NSMutableDictionary alloc] init];
        tlsConnectionsLock = [[NSLock alloc] init];
    }
    return self;
}

/* 証明書+鍵が保存済みならそれを読み込み、無ければ新規生成する。
   startOnPort:からuseTLSの時だけ呼ばれる。 */
- (BOOL)loadOrCreateCertificateAndKey
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:AQTLSCertPath()] ||
        ![[NSFileManager defaultManager] fileExistsAtPath:AQTLSKeyPath()]) {
        if (!AQGenerateAndSaveCertificate()) {
            return NO;
        }
    }

    sslCtx = SSL_CTX_new(SSLv23_server_method());
    if (sslCtx == NULL) {
        return NO;
    }
    /* 現代のクライアント(Finder等)は普通TLS1.2以上で繋いでくるが、古い
       SSLv2/SSLv3だけは既知の脆弱性があるため明示的に禁止する。
       TLS1.0/1.1は互換性のため許可のままにしておく。 */
    SSL_CTX_set_options((SSL_CTX *)sslCtx, SSL_OP_NO_SSLv2 | SSL_OP_NO_SSLv3);

    if (SSL_CTX_use_certificate_file((SSL_CTX *)sslCtx, [AQTLSCertPath() UTF8String], SSL_FILETYPE_PEM) != 1) {
        return NO;
    }
    if (SSL_CTX_use_PrivateKey_file((SSL_CTX *)sslCtx, [AQTLSKeyPath() UTF8String], SSL_FILETYPE_PEM) != 1) {
        return NO;
    }
    return YES;
}

- (int)port
{
    return port;
}

- (BOOL)startOnPort:(int)p
{
    if (useTLS) {
        SSL_library_init();
        SSL_load_error_strings();
        if (![self loadOrCreateCertificateAndKey]) {
            return NO;
        }
    }

    listenFd = socket(AF_INET, SOCK_STREAM, 0);
    if (listenFd < 0) {
        return NO;
    }

    int yes = 1;
    setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY); /* LAN上の他機器からも接続できるようにする */
    addr.sin_port = htons((unsigned short)p);

    if (bind(listenFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(listenFd);
        listenFd = -1;
        return NO;
    }
    if (listen(listenFd, 16) != 0) {
        close(listenFd);
        listenFd = -1;
        return NO;
    }

    port = p;
    shouldRun = YES;
    [NSThread detachNewThreadSelector:@selector(acceptLoop) toTarget:self withObject:nil];
    return YES;
}

- (void)stop
{
    shouldRun = NO;
    if (listenFd >= 0) {
        close(listenFd);
        listenFd = -1;
    }
    if (sslCtx != NULL) {
        SSL_CTX_free((SSL_CTX *)sslCtx);
        sslCtx = NULL;
    }
}

- (void)acceptLoop
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    while (shouldRun) {
        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        int clientFd = accept(listenFd, (struct sockaddr *)&clientAddr, &clientLen);
        if (clientFd < 0) {
            if (!shouldRun) {
                break;
            }
            continue;
        }
        NSString *clientIP = [NSString stringWithUTF8String:inet_ntoa(clientAddr.sin_addr)];
        NSDictionary *connInfo = [NSDictionary dictionaryWithObjectsAndKeys:
                                   [NSNumber numberWithInt:clientFd], @"fd",
                                   clientIP, @"ip", nil];
        [NSThread detachNewThreadSelector:@selector(handleConnection:)
                                  toTarget:self
                                withObject:connInfo];
    }
    [pool release];
}

/* ============ 認証 ============ */

/* [2026-09-18追加] 認証失敗を繰り返すクライアントを弾くための簡易なレート制限。
   きっかけ: Digest認証を試した際、macOS純正のFinderクライアントが認証情報を
   一切付けずに同じリクエストを無限に送り続け、数秒でログが14MB超まで
   膨れ上がる事態が実機で発生した(詳細はsmb3/README.md参照)。原因がどちら
   側にあっても、「短時間に大量の認証失敗を繰り返す相手には、しばらく
   相手をしない」という安全装置を入れておけば、同種の暴走(バグでも、
   総当たり攻撃でも)による資源の浪費を防げる。
   閾値はほどほどに緩く設定してある(普通の利用でパスワードを数回打ち間違えた
   程度では引っかからない)。 */
#define AQ_RATE_LIMIT_WINDOW_SECONDS 5.0
#define AQ_RATE_LIMIT_MAX_FAILURES 20
#define AQ_RATE_LIMIT_COOLDOWN_SECONDS 30.0

- (BOOL)isRateLimitedForIP:(NSString *)ip
{
    if (ip == nil) {
        return NO;
    }
    BOOL limited = NO;
    [authFailureLock lock];
    NSDictionary *entry = [authFailureCounts objectForKey:ip];
    if (entry != nil) {
        NSDate *windowStart = [entry objectForKey:@"windowStart"];
        int count = [[entry objectForKey:@"count"] intValue];
        double elapsed = -[windowStart timeIntervalSinceNow];
        if (count >= AQ_RATE_LIMIT_MAX_FAILURES && elapsed < AQ_RATE_LIMIT_COOLDOWN_SECONDS) {
            limited = YES;
        }
    }
    [authFailureLock unlock];
    return limited;
}

- (void)recordAuthFailureForIP:(NSString *)ip
{
    if (ip == nil) {
        return;
    }
    [authFailureLock lock];
    NSDictionary *entry = [authFailureCounts objectForKey:ip];
    NSDate *windowStart = (entry != nil) ? [entry objectForKey:@"windowStart"] : nil;
    int count = (entry != nil) ? [[entry objectForKey:@"count"] intValue] : 0;
    double elapsed = (windowStart != nil) ? -[windowStart timeIntervalSinceNow] : 0.0;
    if (windowStart == nil || elapsed > AQ_RATE_LIMIT_WINDOW_SECONDS) {
        /* 直近の失敗から時間が経っていれば、集計をリセットして数え直す */
        windowStart = [NSDate date];
        count = 1;
    } else {
        count++;
    }
    NSDictionary *newEntry = [NSDictionary dictionaryWithObjectsAndKeys:
                               windowStart, @"windowStart",
                               [NSNumber numberWithInt:count], @"count", nil];
    [authFailureCounts setObject:newEntry forKey:ip];
    [authFailureLock unlock];
}

- (BOOL)checkAuth:(NSDictionary *)headers method:(NSString *)method path:(NSString *)path
{
    NSString *authHeader = [headers objectForKey:@"authorization"];
    if (authHeader == nil) {
        return NO;
    }

    if ([authHeader hasPrefix:@"Digest "]) {
        NSDictionary *params = ParseDigestAuthHeader(authHeader);
        NSString *username = [params objectForKey:@"username"];
        NSString *realm = [params objectForKey:@"realm"];
        NSString *nonce = [params objectForKey:@"nonce"];
        NSString *uri = [params objectForKey:@"uri"];
        NSString *qop = [params objectForKey:@"qop"];
        NSString *nc = [params objectForKey:@"nc"];
        NSString *cnonce = [params objectForKey:@"cnonce"];
        NSString *response = [params objectForKey:@"response"];
        if (username == nil || realm == nil || nonce == nil || uri == nil || response == nil) {
            return NO;
        }
        if (![username isEqualToString:authUser]) {
            return NO;
        }
        NSString *ha1 = MD5Hex([NSString stringWithFormat:@"%@:%@:%@", username, realm, authPassword]);
        NSString *ha2 = MD5Hex([NSString stringWithFormat:@"%@:%@", method, uri]);
        NSString *expected;
        if ([qop length] > 0 && [nc length] > 0 && [cnonce length] > 0) {
            expected = MD5Hex([NSString stringWithFormat:@"%@:%@:%@:%@:%@:%@", ha1, nonce, nc, cnonce, qop, ha2]);
        } else {
            expected = MD5Hex([NSString stringWithFormat:@"%@:%@:%@", ha1, nonce, ha2]);
        }
        return [[expected lowercaseString] isEqualToString:[response lowercaseString]];
    }

    if (![authHeader hasPrefix:@"Basic "]) {
        return NO;
    }
    NSString *b64 = [authHeader substringFromIndex:6];
    NSData *decoded = Base64Decode(b64);
    NSString *userpass = [[[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding] autorelease];
    if (userpass == nil) {
        return NO;
    }
    NSRange colon = [userpass rangeOfString:@":"];
    if (colon.location == NSNotFound) {
        return NO;
    }
    NSString *u = [userpass substringToIndex:colon.location];
    NSString *p = [userpass substringFromIndex:colon.location + 1];
    return ([u isEqualToString:authUser] && [p isEqualToString:authPassword]);
}

- (void)sendUnauthorized:(int)fd
{
    /* [2026-09-18、Digest限定への切り替えを試した結果、断念] パスワードを
       盗聴から守るためDigestのみを要求するよう変更してみたが、実機検証で
       macOS純正のFinder経由マウント(WebDAVFSクライアント)が全く相性が
       悪いことが判明した: 認証情報を一切付けずに同じPROPFINDを無限に
       送り続け、Finderの「接続中」から永久に戻ってこない(実際にログが
       数秒で14MB超まで膨れ上がった)。curlでは問題なくDigestが通ったので、
       サーバー側の実装自体の不備というよりmacOS純正クライアント側の
       Digest対応の弱さと見られる。
       Basic+Digestを両方チャレンジするとWindows標準WebDAVクライアントが
       諦める(下記の元々の理由)、DigestのみだとmacOS純正クライアントが
       ハングする、という板挟みで、今回はBasicへ戻す判断とした。
       元々の理由: 同じ401応答にDigestとBasic両方のWWW-Authenticateを
       含めると、Windows標準WebDAVクライアント(Microsoft-WebDAV-MiniRedir)
       がどちらの認証情報も送らずに諦めることが実機検証で判明したため、
       Basicのみを要求している。checkAuth: はDigest/Basicの両方を検証
       できる作りのまま残してあるので、将来別の切り分け方(例:
       User-Agentで判定してクライアントごとにチャレンジを変える等)を
       試す余地はある。 */
    NSMutableString *head = [NSMutableString string];
    [head appendString:@"HTTP/1.1 401 Unauthorized\r\n"];
    [head appendString:@"WWW-Authenticate: Basic realm=\"AquaLink\"\r\n"];
    [head appendString:@"Content-Length: 0\r\nConnection: close\r\n\r\n"];
    [self sendBytes:[head dataUsingEncoding:NSUTF8StringEncoding] toSocket:fd];
}

/* ============ 1接続分の処理 ============ */

- (void)handleConnection:(NSDictionary *)connInfo
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int fd = [[connInfo objectForKey:@"fd"] intValue];
    NSString *clientIP = [connInfo objectForKey:@"ip"];

    /* 短時間に大量の認証失敗を繰り返している相手には、リクエストの中身すら
       読まずに即座に切る。無限リトライの暴走(実機で確認済み)による
       スレッド・ログの浪費を防ぐための安全装置。 */
    if ([self isRateLimitedForIP:clientIP]) {
        close(fd);
        [pool release];
        return;
    }

    /* [2026-09-22追加] HTTPS有効時は、リクエストを読む前にまずTLSハンド
       シェイクを完了させる。成立したSSL*はfd番号をキーにした対応表に
       登録し、以後の低レベル送受信(aq_readSocket:/aq_writeSocket:)から
       参照する。この接続処理は元々専用スレッドで動くので、ここで
       ハンドシェイクにかかる時間(RSA計算を含む)を使っても他の接続を
       ブロックしない。 */
    if (useTLS) {
        SSL *ssl = SSL_new((SSL_CTX *)sslCtx);
        SSL_set_fd(ssl, fd);
        if (SSL_accept(ssl) != 1) {
            SSL_free(ssl);
            close(fd);
            [pool release];
            return;
        }
        [tlsConnectionsLock lock];
        [tlsConnections setObject:[NSValue valueWithPointer:ssl] forKey:[NSNumber numberWithInt:fd]];
        [tlsConnectionsLock unlock];
    }

    NSString *method = nil;
    NSString *path = nil;
    NSDictionary *headers = nil;
    NSData *body = nil;

    if ([self readRequestFromSocket:fd method:&method path:&path headers:&headers body:&body]) {
        /* OPTIONSはクライアントが機能確認のため認証前に送ってくることが多いので許可する */
        if (![method isEqualToString:@"OPTIONS"] && ![self checkAuth:headers method:method path:path]) {
            [self recordAuthFailureForIP:clientIP];
            [self sendUnauthorized:fd];
        } else {
            NSString *depth = [headers objectForKey:@"depth"];
            NSString *host = [headers objectForKey:@"host"];
            if ([method isEqualToString:@"OPTIONS"]) {
                [self handleOPTIONS:fd];
            } else if ([method isEqualToString:@"PROPFIND"]) {
                [self handlePROPFIND:path depth:(depth ? depth : @"1") host:host toSocket:fd];
            } else if ([method isEqualToString:@"PROPPATCH"]) {
                [self handlePROPPATCH:path body:(body ? body : [NSData data]) host:host toSocket:fd];
            } else if ([method isEqualToString:@"GET"]) {
                [self handleGET:path toSocket:fd includeBody:YES];
            } else if ([method isEqualToString:@"HEAD"]) {
                [self handleGET:path toSocket:fd includeBody:NO];
            } else if ([method isEqualToString:@"PUT"]) {
                [self handlePUT:path body:(body ? body : [NSData data]) toSocket:fd];
            } else if ([method isEqualToString:@"DELETE"]) {
                [self handleDELETE:path toSocket:fd];
            } else if ([method isEqualToString:@"MKCOL"]) {
                [self handleMKCOL:path toSocket:fd];
            } else if ([method isEqualToString:@"LOCK"]) {
                [self handleLOCK:path toSocket:fd];
            } else if ([method isEqualToString:@"UNLOCK"]) {
                [self sendSimpleStatus:@"204 No Content" toSocket:fd];
            } else {
                [self sendSimpleStatus:@"501 Not Implemented" toSocket:fd];
            }
        }
    }

    if (useTLS) {
        [tlsConnectionsLock lock];
        NSNumber *key = [NSNumber numberWithInt:fd];
        NSValue *boxed = [tlsConnections objectForKey:key];
        if (boxed != nil) {
            SSL *ssl = (SSL *)[boxed pointerValue];
            SSL_shutdown(ssl);
            SSL_free(ssl);
            [tlsConnections removeObjectForKey:key];
        }
        [tlsConnectionsLock unlock];
    }

    close(fd);
    [pool release];
}

- (BOOL)readRequestFromSocket:(int)fd
                        method:(NSString **)methodOut
                          path:(NSString **)pathOut
                       headers:(NSDictionary **)headersOut
                          body:(NSData **)bodyOut
{
    NSMutableData *buf = [NSMutableData data];
    uint8_t chunk[4096];
    long headerEnd = -1;

    while (headerEnd < 0) {
        int n = [self aq_readSocket:fd buffer:chunk length:sizeof(chunk)];
        if (n <= 0) {
            return NO;
        }
        [buf appendBytes:chunk length:n];
        headerEnd = FindBytes((const uint8_t *)[buf bytes], (long)[buf length],
                               (const uint8_t *)"\r\n\r\n", 4, 0);
        if (headerEnd < 0 && [buf length] > 1024 * 1024) {
            return NO;
        }
    }

    NSData *headerData = [NSData dataWithBytes:[buf bytes] length:headerEnd];
    NSString *headerStr = [[[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding] autorelease];
    if (headerStr == nil) {
        headerStr = [[[NSString alloc] initWithData:headerData encoding:NSASCIIStringEncoding] autorelease];
    }
    if (headerStr == nil) {
        return NO;
    }

    NSArray *lines = [headerStr componentsSeparatedByString:@"\r\n"];
    if ([lines count] == 0) {
        return NO;
    }

    NSArray *parts = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];
    if ([parts count] < 2) {
        return NO;
    }
    NSString *method = [parts objectAtIndex:0];
    NSString *path = [parts objectAtIndex:1];
    NSRange q = [path rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        path = [path substringToIndex:q.location];
    }

    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    unsigned int i;
    for (i = 1; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        if ([line length] == 0) {
            continue;
        }
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }
        NSString *key = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [line substringFromIndex:colon.location + 1];
        value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [headers setObject:value forKey:key];
    }

    long bodyStart = headerEnd + 4;
    long alreadyRead = (long)[buf length] - bodyStart;
    int contentLength = 0;
    NSString *clStr = [headers objectForKey:@"content-length"];
    if (clStr != nil) {
        contentLength = [clStr intValue];
    }

    NSMutableData *bodyData = [NSMutableData data];
    if (alreadyRead > 0) {
        [bodyData appendBytes:(((const uint8_t *)[buf bytes]) + bodyStart) length:alreadyRead];
    }
    while ((long)[bodyData length] < contentLength) {
        int n = [self aq_readSocket:fd buffer:chunk length:sizeof(chunk)];
        if (n <= 0) {
            break;
        }
        [bodyData appendBytes:chunk length:n];
    }

    if (methodOut) *methodOut = method;
    if (pathOut) *pathOut = path;
    if (headersOut) *headersOut = headers;
    if (bodyOut) *bodyOut = bodyData;
    return YES;
}

/* [2026-09-22追加] 低レベル送受信の共通口。fdがTLS接続として登録されて
   いればSSL_read/SSL_write、そうでなければ従来通りのrecv/sendにフォール
   バックする。この2つのメソッドだけがソケットの生I/Oを直接触るように
   なっているので、呼び出し側(readRequestFromSocket:/sendBytes:toSocket:
   /handleGET:等)は"toSocket:fd"という既存のシグネチャのまま一切変更せずに
   済んでいる。 */
- (int)aq_readSocket:(int)fd buffer:(void *)buf length:(int)len
{
    if (useTLS) {
        SSL *ssl = NULL;
        [tlsConnectionsLock lock];
        NSValue *boxed = [tlsConnections objectForKey:[NSNumber numberWithInt:fd]];
        if (boxed != nil) {
            ssl = (SSL *)[boxed pointerValue];
        }
        [tlsConnectionsLock unlock];
        if (ssl != NULL) {
            return SSL_read(ssl, buf, len);
        }
    }
    return (int)recv(fd, buf, len, 0);
}

- (int)aq_writeSocket:(int)fd buffer:(const void *)buf length:(int)len
{
    if (useTLS) {
        SSL *ssl = NULL;
        [tlsConnectionsLock lock];
        NSValue *boxed = [tlsConnections objectForKey:[NSNumber numberWithInt:fd]];
        if (boxed != nil) {
            ssl = (SSL *)[boxed pointerValue];
        }
        [tlsConnectionsLock unlock];
        if (ssl != NULL) {
            return SSL_write(ssl, buf, len);
        }
    }
    return (int)send(fd, buf, len, 0);
}

/* ============ レスポンス送信 ============ */

- (void)sendBytes:(NSData *)data toSocket:(int)fd
{
    const uint8_t *bytes = [data bytes];
    long length = (long)[data length];
    long sent = 0;
    while (sent < length) {
        int n = [self aq_writeSocket:fd buffer:(bytes + sent) length:(int)(length - sent)];
        if (n <= 0) {
            break;
        }
        sent += n;
    }
}

- (void)sendSimpleStatus:(NSString *)status toSocket:(int)fd
{
    NSString *head = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status];
    [self sendBytes:[head dataUsingEncoding:NSUTF8StringEncoding] toSocket:fd];
}

/* WebDAVパスをローカルの絶対パスに変換する。
   先頭の1階層は共有名(shares辞書のキー)として扱う。
   ルート("/")自体・共有名が見つからない・パストラバーサル(..)の場合はnilを返す。 */
- (NSString *)localPathForWebDAVPath:(NSString *)path
{
    NSString *decoded = [path stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    if (decoded == nil) {
        decoded = path;
    }
    if ([decoded hasPrefix:@"/"]) {
        decoded = [decoded substringFromIndex:1];
    }
    if ([decoded length] > 0 && [decoded hasSuffix:@"/"]) {
        decoded = [decoded substringToIndex:[decoded length] - 1];
    }

    if ([decoded length] == 0) {
        return nil; /* ルート自体は仮想フォルダなのでローカルパスに対応しない */
    }

    NSRange slash = [decoded rangeOfString:@"/"];
    NSString *shareName = (slash.location == NSNotFound) ? decoded : [decoded substringToIndex:slash.location];
    NSString *rest = (slash.location == NSNotFound) ? @"" : [decoded substringFromIndex:slash.location + 1];

    NSString *shareRoot = [shares objectForKey:shareName];
    if (shareRoot == nil) {
        /* Windows等のクライアントはUnicode正規化形式C(結合済み、例:「ダ」)でパスを送ってくるが、
           HFS+上のフォルダ名はFinder等で作成された時点で正規化形式D(分解、「タ」+濁点)のまま
           保持されていることが多く、単純な文字列一致では共有名が見つからないことがある。
           そのため正規化した上で再照合する。 */
        NSString *normalizedRequested = [shareName precomposedStringWithCanonicalMapping];
        NSEnumerator *keyEnum = [shares keyEnumerator];
        NSString *key;
        while ((key = [keyEnum nextObject])) {
            if ([[key precomposedStringWithCanonicalMapping] isEqualToString:normalizedRequested]) {
                shareRoot = [shares objectForKey:key];
                break;
            }
        }
    }
    if (shareRoot == nil) {
        return nil;
    }
    if ([rest length] == 0) {
        return shareRoot;
    }

    NSArray *comps = [rest componentsSeparatedByString:@"/"];
    NSEnumerator *e = [comps objectEnumerator];
    NSString *c;
    while ((c = [e nextObject])) {
        if ([c isEqualToString:@".."]) {
            return nil;
        }
    }

    return [shareRoot stringByAppendingPathComponent:rest];
}

/* ============ OPTIONS ============ */

- (void)handleOPTIONS:(int)fd
{
    NSMutableString *head = [NSMutableString string];
    [head appendString:@"HTTP/1.1 200 OK\r\n"];
    [head appendString:@"DAV: 1, 2\r\n"];
    [head appendString:@"MS-Author-Via: DAV\r\n"];
    [head appendString:@"Allow: OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, LOCK, UNLOCK\r\n"];
    [head appendString:@"Content-Length: 0\r\n"];
    [head appendString:@"Connection: close\r\n\r\n"];
    [self sendBytes:[head dataUsingEncoding:NSUTF8StringEncoding] toSocket:fd];
}

/* ============ PROPFIND ============ */

- (NSString *)responseEntryForHref:(NSString *)href isDir:(BOOL)isDir
                               size:(unsigned long long)size mtime:(time_t)mtime
                               host:(NSString *)host
{
    char dateBuf[64];
    FormatHTTPDate(mtime, dateBuf, sizeof(dateBuf));

    /* WindowsのミニリダイレクタはD:hrefが絶対URLでないと応答を無効と判断することがあるため、
       Hostヘッダーが分かる場合は絶対URLにする */
    NSString *fullHref = (host != nil) ? [NSString stringWithFormat:@"http://%@%@", host, href] : href;

    /* コレクション(フォルダ)のhrefは末尾に "/" が無いとWindows側で不正な応答とみなされることがある */
    if (isDir && ![fullHref hasSuffix:@"/"]) {
        fullHref = [fullHref stringByAppendingString:@"/"];
    }

    /* 表示名はhrefの末尾のパス要素から作る(ルートは"/"のまま) */
    NSString *trimmedHref = [fullHref hasSuffix:@"/"]
        ? [fullHref substringToIndex:[fullHref length] - 1]
        : fullHref;
    NSString *lastComponent = [trimmedHref lastPathComponent];
    NSString *displayName = ([lastComponent length] > 0) ? lastComponent : @"/";

    char isoDateBuf[64];
    struct tm tmv;
    gmtime_r(&mtime, &tmv);
    snprintf(isoDateBuf, sizeof(isoDateBuf), "%04d-%02d-%02dT%02d:%02d:%02dZ",
             tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec);

    NSMutableString *entry = [NSMutableString string];
    [entry appendString:@"<D:response>\n"];
    [entry appendFormat:@"<D:href>%@</D:href>\n", XMLEscape(fullHref)];
    [entry appendString:@"<D:propstat>\n<D:prop>\n"];
    if (isDir) {
        [entry appendString:@"<D:resourcetype><D:collection/></D:resourcetype>\n"];
        [entry appendString:@"<D:getcontentlength>0</D:getcontentlength>\n"];
    } else {
        [entry appendString:@"<D:resourcetype/>\n"];
        [entry appendFormat:@"<D:getcontentlength>%llu</D:getcontentlength>\n", size];
        [entry appendString:@"<D:getcontenttype>application/octet-stream</D:getcontenttype>\n"];
        [entry appendFormat:@"<D:getetag>\"%llx-%llx\"</D:getetag>\n", (unsigned long long)mtime, size];
    }
    [entry appendFormat:@"<D:displayname>%@</D:displayname>\n", XMLEscape(displayName)];
    [entry appendFormat:@"<D:creationdate>%s</D:creationdate>\n", isoDateBuf];
    [entry appendFormat:@"<D:getlastmodified>%s</D:getlastmodified>\n", dateBuf];
    [entry appendString:@"<D:supportedlock>\n<D:lockentry>\n<D:lockscope><D:exclusive/></D:lockscope>\n<D:locktype><D:write/></D:locktype>\n</D:lockentry>\n</D:supportedlock>\n"];
    [entry appendString:@"</D:prop>\n<D:status>HTTP/1.1 200 OK</D:status>\n</D:propstat>\n"];
    [entry appendString:@"</D:response>\n"];
    return entry;
}

/* ルート("/")向け: 各共有フォルダを仮想サブフォルダとして一覧表示する */
- (void)handlePROPFINDRoot:(NSString *)path depth:(NSString *)depth host:(NSString *)host toSocket:(int)fd
{
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"];
    [xml appendString:@"<D:multistatus xmlns:D=\"DAV:\">\n"];
    [xml appendString:[self responseEntryForHref:@"/" isDir:YES size:0 mtime:time(NULL) host:host]];

    if (![depth isEqualToString:@"0"]) {
        NSEnumerator *e = [[shares allKeys] objectEnumerator];
        NSString *name;
        while ((name = [e nextObject])) {
            NSString *localPath = [shares objectForKey:name];
            time_t mtime = time(NULL);
            struct stat st;
            if (stat([localPath UTF8String], &st) == 0) {
                mtime = st.st_mtime;
            }
            NSString *href = [NSString stringWithFormat:@"/%@/", URLEncodePathComponent(name)];
            [xml appendString:[self responseEntryForHref:href isDir:YES size:0 mtime:mtime host:host]];
        }
    }
    [xml appendString:@"</D:multistatus>\n"];

    NSData *bodyData = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableString *head = [NSMutableString string];
    [head appendString:@"HTTP/1.1 207 Multi-Status\r\n"];
    [head appendString:@"Content-Type: text/xml; charset=\"utf-8\"\r\n"];
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[bodyData length]];
    [head appendString:@"Connection: close\r\n\r\n"];

    [self sendBytes:[head dataUsingEncoding:NSUTF8StringEncoding] toSocket:fd];
    [self sendBytes:bodyData toSocket:fd];
}

- (void)handlePROPFIND:(NSString *)path depth:(NSString *)depth host:(NSString *)host toSocket:(int)fd
{
    NSString *trimmed = path;
    if ([trimmed hasPrefix:@"/"]) {
        trimmed = [trimmed substringFromIndex:1];
    }
    if ([trimmed hasSuffix:@"/"]) {
        trimmed = [trimmed substringToIndex:[trimmed length] - 1];
    }
    if ([trimmed length] == 0) {
        [self handlePROPFINDRoot:path depth:depth host:host toSocket:fd];
        return;
    }

    NSString *localPath = [self localPathForWebDAVPath:path];
    if (localPath == nil) {
        [self sendSimpleStatus:@"404 Not Found" toSocket:fd];
        return;
    }

    struct stat st;
    if (stat([localPath UTF8String], &st) != 0) {
        [self sendSimpleStatus:@"404 Not Found" toSocket:fd];
        return;
    }
    BOOL isDir = S_ISDIR(st.st_mode);
    unsigned long long selfSize = (unsigned long long)st.st_size;
    time_t selfMtime = st.st_mtime;

    NSMutableArray *children = [NSMutableArray array];
    if (isDir && ![depth isEqualToString:@"0"]) {
        DIR *dir = opendir([localPath UTF8String]);
        if (dir != NULL) {
            struct dirent *ent;
            while ((ent = readdir(dir)) != NULL) {
                NSString *name = [NSString stringWithUTF8String:ent->d_name];
                if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
                    continue;
                }
                NSString *childLocal = [localPath stringByAppendingPathComponent:name];
                struct stat cst;
                if (stat([childLocal UTF8String], &cst) != 0) {
                    continue;
                }
                NSDictionary *e = [NSDictionary dictionaryWithObjectsAndKeys:
                                    name, @"name",
                                    [NSNumber numberWithBool:S_ISDIR(cst.st_mode)], @"isDir",
                                    [NSNumber numberWithUnsignedLongLong:(unsigned long long)cst.st_size], @"size",
                                    [NSNumber numberWithUnsignedLongLong:(unsigned long long)cst.st_mtime], @"mtime",
                                    nil];
                [children addObject:e];
            }
            closedir(dir);
        }
    }

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"];
    [xml appendString:@"<D:multistatus xmlns:D=\"DAV:\">\n"];
    [xml appendString:[self responseEntryForHref:path isDir:isDir size:selfSize mtime:selfMtime host:host]];

    NSEnumerator *e = [children objectEnumerator];
    NSDictionary *child;
    BOOL pathHasSlash = [path hasSuffix:@"/"];
    while ((child = [e nextObject])) {
        NSString *name = [child objectForKey:@"name"];
        BOOL childIsDir = [[child objectForKey:@"isDir"] boolValue];
        unsigned long long size = [[child objectForKey:@"size"] unsignedLongLongValue];
        time_t mtime = (time_t)[[child objectForKey:@"mtime"] unsignedLongLongValue];

        NSString *encodedName = URLEncodePathComponent(name);
        NSString *childHref = pathHasSlash
            ? [path stringByAppendingString:encodedName]
            : [NSString stringWithFormat:@"%@/%@", path, encodedName];

        [xml appendString:[self responseEntryForHref:childHref isDir:childIsDir size:size mtime:mtime host:host]];
    }
    [xml appendString:@"</D:multistatus>\n"];

    NSData *bodyData = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableString *head = [NSMutableString string];
    [head appendString:@"HTTP/1.1 207 Multi-Status\r\n"];
    [head appendString:@"Content-Type: text/xml; charset=\"utf-8\"\r\n"];
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[bodyData length]];
    [head appendString:@"Connection: close\r\n\r\n"];

    [self sendBytes:[head dataUsingEncoding:NSUTF8StringEncoding] toSocket:fd];
    [self sendBytes:bodyData toSocket:fd];
}

/* ============ PROPPATCH ============ */

/* Windows ExplorerはPUT後に必ずWin32CreationTime等のプロパティ設定(PROPPATCH)を送ってくる。
   POSIXファイルシステムには置き場がないため実際には保存しないが、
   501を返すとExplorer側がコピー操作全体を失敗として扱ってしまうため、
   要求されたプロパティをすべて成功として返す(擬似実装)。 */
- (void)handlePROPPATCH:(NSString *)path body:(NSData *)body host:(NSString *)host toSocket:(int)fd
{
    NSString *localPath = [self localPathForWebDAVPath:path];
    if (localPath == nil) {
        [self sendSimpleStatus:@"403 Forbidden" toSocket:fd];
        return;
    }

    NSString *bodyStr = [[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] autorelease];
    NSArray *propNames = (bodyStr != nil) ? ExtractPropertyElementNames(bodyStr) : [NSArray array];

    NSString *fullHref = (host != nil) ? [NSString stringWithFormat:@"http://%@%@", host, path] : path;

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"];
    [xml appendString:@"<D:multistatus xmlns:D=\"DAV:\">\n"];
    [xml appendString:@"<D:response>\n"];
    [xml appendFormat:@"<D:href>%@</D:href>\n", XMLEscape(fullHref)];
    [xml appendString:@"<D:propstat>\n<D:prop>\n"];
    NSEnumerator *e = [propNames objectEnumerator];
    NSString *tag;
    while ((tag = [e nextObject])) {
        [xml appendFormat:@"<%@/>\n", tag];
    }
    [xml appendString:@"</D:prop>\n<D:status>HTTP/1.1 200 OK</D:status>\n</D:propstat>\n"];
    [xml appendString:@"</D:response>\n"];
    [xml appendString:@"</D:multistatus>\n"];

    NSData *bodyData = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableString *head = [NSMutableString string];
    [head appendString:@"HTTP/1.1 207 Multi-Status\r\n"];
    [head appendString:@"Content-Type: text/xml; charset=\"utf-8\"\r\n"];
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[bodyData length]];
    [head appendString:@"Connection: close\r\n\r\n"];

    [self sendBytes:[head dataUsingEncoding:NSUTF8StringEncoding] toSocket:fd];
    [self sendBytes:bodyData toSocket:fd];
}

/* ============ GET / HEAD ============ */

- (void)handleGET:(NSString *)path toSocket:(int)fd includeBody:(BOOL)includeBody
{
    NSString *localPath = [self localPathForWebDAVPath:path];
    if (localPath == nil) {
        [self sendSimpleStatus:@"403 Forbidden" toSocket:fd];
        return;
    }

    int f = open([localPath UTF8String], O_RDONLY);
    if (f < 0) {
        [self sendSimpleStatus:@"404 Not Found" toSocket:fd];
        return;
    }

    NSMutableData *data = [NSMutableData data];
    uint8_t buf[65536];
    ssize_t n;
    while ((n = read(f, buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:n];
    }
    close(f);

    NSMutableString *head = [NSMutableString string];
    [head appendString:@"HTTP/1.1 200 OK\r\n"];
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[data length]];
    [head appendString:@"Content-Type: application/octet-stream\r\n"];
    [head appendString:@"Connection: close\r\n\r\n"];

    [self sendBytes:[head dataUsingEncoding:NSUTF8StringEncoding] toSocket:fd];
    if (includeBody) {
        [self sendBytes:data toSocket:fd];
    }
}

/* ============ PUT ============ */

- (void)handlePUT:(NSString *)path body:(NSData *)body toSocket:(int)fd
{
    NSString *localPath = [self localPathForWebDAVPath:path];
    if (localPath == nil) {
        [self sendSimpleStatus:@"403 Forbidden" toSocket:fd];
        return;
    }

    int f = open([localPath UTF8String], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (f < 0) {
        [self sendSimpleStatus:@"500 Internal Server Error" toSocket:fd];
        return;
    }

    const uint8_t *bytes = [body bytes];
    unsigned long long length = [body length];
    unsigned long long offset = 0;
    BOOL ok = YES;
    while (offset < length) {
        ssize_t n = write(f, bytes + offset, (size_t)(length - offset));
        if (n <= 0) {
            ok = NO;
            break;
        }
        offset += (unsigned long long)n;
    }
    close(f);

    [self sendSimpleStatus:(ok ? @"201 Created" : @"500 Internal Server Error") toSocket:fd];
}

/* ============ DELETE / MKCOL ============ */

- (void)handleDELETE:(NSString *)path toSocket:(int)fd
{
    NSString *localPath = [self localPathForWebDAVPath:path];
    if (localPath == nil) {
        [self sendSimpleStatus:@"403 Forbidden" toSocket:fd];
        return;
    }

    struct stat st;
    int rc = -1;
    if (stat([localPath UTF8String], &st) == 0) {
        if (S_ISDIR(st.st_mode)) {
            rc = rmdir([localPath UTF8String]);
        } else {
            rc = unlink([localPath UTF8String]);
        }
    }
    [self sendSimpleStatus:(rc == 0 ? @"204 No Content" : @"404 Not Found") toSocket:fd];
}

- (void)handleMKCOL:(NSString *)path toSocket:(int)fd
{
    NSString *localPath = [self localPathForWebDAVPath:path];
    if (localPath == nil) {
        [self sendSimpleStatus:@"403 Forbidden" toSocket:fd];
        return;
    }
    int rc = mkdir([localPath UTF8String], 0755);
    [self sendSimpleStatus:(rc == 0 ? @"201 Created" : @"409 Conflict") toSocket:fd];
}

/* ============ LOCK / UNLOCK(擬似実装) ============ */

- (void)handleLOCK:(NSString *)path toSocket:(int)fd
{
    NSString *token = [NSString stringWithFormat:@"urn:uuid:nasbrowser-fake-lock-%u",
                        (unsigned int)arc4random()];

    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"];
    [xml appendString:@"<D:prop xmlns:D=\"DAV:\">\n<D:lockdiscovery><D:activelock>\n"];
    [xml appendString:@"<D:locktype><D:write/></D:locktype>\n"];
    [xml appendString:@"<D:lockscope><D:exclusive/></D:lockscope>\n"];
    [xml appendString:@"<D:depth>infinity</D:depth>\n"];
    [xml appendString:@"<D:timeout>Second-600</D:timeout>\n"];
    [xml appendFormat:@"<D:locktoken><D:href>%@</D:href></D:locktoken>\n", token];
    [xml appendString:@"</D:activelock></D:lockdiscovery>\n</D:prop>\n"];

    NSData *bodyData = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableString *head = [NSMutableString string];
    [head appendString:@"HTTP/1.1 200 OK\r\n"];
    [head appendString:@"Content-Type: text/xml; charset=\"utf-8\"\r\n"];
    [head appendFormat:@"Lock-Token: <%@>\r\n", token];
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)[bodyData length]];
    [head appendString:@"Connection: close\r\n\r\n"];

    [self sendBytes:[head dataUsingEncoding:NSUTF8StringEncoding] toSocket:fd];
    [self sendBytes:bodyData toSocket:fd];
}

- (void)dealloc
{
    [self stop];
    [shares release];
    [authUser release];
    [authPassword release];
    [authFailureCounts release];
    [authFailureLock release];
    [tlsConnections release];
    [tlsConnectionsLock release];
    [super dealloc];
}

@end
