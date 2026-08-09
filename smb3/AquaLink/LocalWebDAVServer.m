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

#define UTF8(cstr) [NSString stringWithUTF8String:(cstr)]

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

@implementation LocalWebDAVServer

- (id)initWithRootPath:(NSString *)path user:(NSString *)user password:(NSString *)password
{
    self = [super init];
    if (self) {
        rootPath = [path retain];
        authUser = [user retain];
        authPassword = [password retain];
        listenFd = -1;
        shouldRun = NO;
        port = 0;
    }
    return self;
}

- (int)port
{
    return port;
}

- (BOOL)startOnPort:(int)p
{
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
        [NSThread detachNewThreadSelector:@selector(handleConnection:)
                                  toTarget:self
                                withObject:[NSNumber numberWithInt:clientFd]];
    }
    [pool release];
}

/* ============ 認証 ============ */

- (BOOL)checkAuth:(NSDictionary *)headers
{
    NSString *authHeader = [headers objectForKey:@"authorization"];
    if (authHeader == nil || ![authHeader hasPrefix:@"Basic "]) {
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
    NSString *head = @"HTTP/1.1 401 Unauthorized\r\n"
                      "WWW-Authenticate: Basic realm=\"AquaLink\"\r\n"
                      "Content-Length: 0\r\nConnection: close\r\n\r\n";
    [self sendBytes:[head dataUsingEncoding:NSUTF8StringEncoding] toSocket:fd];
}

/* ============ 1接続分の処理 ============ */

- (void)handleConnection:(NSNumber *)fdNumber
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int fd = [fdNumber intValue];

    NSString *method = nil;
    NSString *path = nil;
    NSDictionary *headers = nil;
    NSData *body = nil;

    if ([self readRequestFromSocket:fd method:&method path:&path headers:&headers body:&body]) {
        /* OPTIONSはクライアントが機能確認のため認証前に送ってくることが多いので許可する */
        if (![method isEqualToString:@"OPTIONS"] && ![self checkAuth:headers]) {
            [self sendUnauthorized:fd];
        } else {
            NSString *depth = [headers objectForKey:@"depth"];
            if ([method isEqualToString:@"OPTIONS"]) {
                [self handleOPTIONS:fd];
            } else if ([method isEqualToString:@"PROPFIND"]) {
                [self handlePROPFIND:path depth:(depth ? depth : @"1") toSocket:fd];
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
        int n = recv(fd, chunk, sizeof(chunk), 0);
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
        int n = recv(fd, chunk, sizeof(chunk), 0);
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

/* ============ レスポンス送信 ============ */

- (void)sendBytes:(NSData *)data toSocket:(int)fd
{
    const uint8_t *bytes = [data bytes];
    long length = (long)[data length];
    long sent = 0;
    while (sent < length) {
        int n = send(fd, bytes + sent, length - sent, 0);
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

/* WebDAVパスをローカルの絶対パスに変換する。パストラバーサル(..)は拒否してnilを返す */
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

    NSArray *comps = [decoded componentsSeparatedByString:@"/"];
    NSEnumerator *e = [comps objectEnumerator];
    NSString *c;
    while ((c = [e nextObject])) {
        if ([c isEqualToString:@".."]) {
            return nil;
        }
    }

    if ([decoded length] == 0) {
        return rootPath;
    }
    return [rootPath stringByAppendingPathComponent:decoded];
}

/* ============ OPTIONS ============ */

- (void)handleOPTIONS:(int)fd
{
    NSMutableString *head = [NSMutableString string];
    [head appendString:@"HTTP/1.1 200 OK\r\n"];
    [head appendString:@"DAV: 1, 2\r\n"];
    [head appendString:@"MS-Author-Via: DAV\r\n"];
    [head appendString:@"Allow: OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, MKCOL, LOCK, UNLOCK\r\n"];
    [head appendString:@"Content-Length: 0\r\n"];
    [head appendString:@"Connection: close\r\n\r\n"];
    [self sendBytes:[head dataUsingEncoding:NSUTF8StringEncoding] toSocket:fd];
}

/* ============ PROPFIND ============ */

- (NSString *)responseEntryForHref:(NSString *)href isDir:(BOOL)isDir
                               size:(unsigned long long)size mtime:(time_t)mtime
{
    char dateBuf[64];
    FormatHTTPDate(mtime, dateBuf, sizeof(dateBuf));

    NSMutableString *entry = [NSMutableString string];
    [entry appendString:@"<D:response>\n"];
    [entry appendFormat:@"<D:href>%@</D:href>\n", XMLEscape(href)];
    [entry appendString:@"<D:propstat>\n<D:prop>\n"];
    if (isDir) {
        [entry appendString:@"<D:resourcetype><D:collection/></D:resourcetype>\n"];
    } else {
        [entry appendString:@"<D:resourcetype/>\n"];
        [entry appendFormat:@"<D:getcontentlength>%llu</D:getcontentlength>\n", size];
    }
    [entry appendFormat:@"<D:getlastmodified>%s</D:getlastmodified>\n", dateBuf];
    [entry appendString:@"</D:prop>\n<D:status>HTTP/1.1 200 OK</D:status>\n</D:propstat>\n"];
    [entry appendString:@"</D:response>\n"];
    return entry;
}

- (void)handlePROPFIND:(NSString *)path depth:(NSString *)depth toSocket:(int)fd
{
    NSString *localPath = [self localPathForWebDAVPath:path];
    if (localPath == nil) {
        [self sendSimpleStatus:@"403 Forbidden" toSocket:fd];
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
    [xml appendString:[self responseEntryForHref:path isDir:isDir size:selfSize mtime:selfMtime]];

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

        [xml appendString:[self responseEntryForHref:childHref isDir:childIsDir size:size mtime:mtime]];
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
    [rootPath release];
    [authUser release];
    [authPassword release];
    [super dealloc];
}

@end
