#import "WebDAVServer.h"
#import "AppDelegate.h"

#include <fcntl.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define UTF8(cstr) [NSString stringWithUTF8String:(cstr)]

static const char *kWeekdays[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
static const char *kMonths[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

/* NSDateFormatterはシステムロケール依存になりうるため、HTTP日付は自前でASCII固定生成する */
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

@implementation WebDAVServer

- (id)initWithAppDelegate:(AppDelegate *)delegate
{
    self = [super init];
    if (self) {
        appDelegate = delegate;
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
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
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
            return NO; /* ヘッダが異常に長い */
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

- (NSString *)smbPathForWebDAVPath:(NSString *)path
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
    return decoded;
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
    struct smb2_context *ctx = [appDelegate smb2Context];
    NSLock *lock = [appDelegate smb2Lock];

    if (ctx == NULL) {
        [self sendSimpleStatus:@"503 Service Unavailable" toSocket:fd];
        return;
    }

    NSString *smbPath = [self smbPathForWebDAVPath:path];
    BOOL isRoot = ([smbPath length] == 0);
    BOOL isDir = isRoot;
    unsigned long long selfSize = 0;
    time_t selfMtime = time(NULL);

    [lock lock];

    if (!isRoot) {
        struct smb2_stat_64 st;
        int rc = smb2_stat(ctx, [smbPath UTF8String], &st);
        if (rc != 0) {
            [lock unlock];
            [self sendSimpleStatus:@"404 Not Found" toSocket:fd];
            return;
        }
        isDir = (st.smb2_type == SMB2_TYPE_DIRECTORY);
        selfSize = st.smb2_size;
        selfMtime = (time_t)st.smb2_mtime;
    }

    NSMutableArray *children = [NSMutableArray array];
    if (isDir && ![depth isEqualToString:@"0"]) {
        struct smb2dir *dir = smb2_opendir(ctx, [smbPath UTF8String]);
        if (dir != NULL) {
            struct smb2dirent *ent;
            while ((ent = smb2_readdir(ctx, dir)) != NULL) {
                NSString *name = [NSString stringWithUTF8String:ent->name];
                if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
                    continue;
                }
                NSDictionary *e = [NSDictionary dictionaryWithObjectsAndKeys:
                                    name, @"name",
                                    [NSNumber numberWithBool:(ent->st.smb2_type == SMB2_TYPE_DIRECTORY)], @"isDir",
                                    [NSNumber numberWithUnsignedLongLong:ent->st.smb2_size], @"size",
                                    [NSNumber numberWithUnsignedLongLong:ent->st.smb2_mtime], @"mtime",
                                    nil];
                [children addObject:e];
            }
            smb2_closedir(ctx, dir);
        }
    }

    [lock unlock];

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
    struct smb2_context *ctx = [appDelegate smb2Context];
    NSLock *lock = [appDelegate smb2Lock];
    NSString *smbPath = [self smbPathForWebDAVPath:path];

    [lock lock];
    struct smb2fh *fh = smb2_open(ctx, [smbPath UTF8String], O_RDONLY);
    if (fh == NULL) {
        [lock unlock];
        [self sendSimpleStatus:@"404 Not Found" toSocket:fd];
        return;
    }

    NSMutableData *data = [NSMutableData data];
    uint8_t buf[65536];
    int n;
    while ((n = smb2_read(ctx, fh, buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:n];
    }
    smb2_close(ctx, fh);
    [lock unlock];

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
    struct smb2_context *ctx = [appDelegate smb2Context];
    NSLock *lock = [appDelegate smb2Lock];
    NSString *smbPath = [self smbPathForWebDAVPath:path];

    [lock lock];
    struct smb2fh *fh = smb2_open(ctx, [smbPath UTF8String], O_WRONLY | O_CREAT | O_TRUNC);
    if (fh == NULL) {
        [lock unlock];
        [self sendSimpleStatus:@"500 Internal Server Error" toSocket:fd];
        return;
    }

    const uint8_t *bytes = [body bytes];
    unsigned long long length = [body length];
    unsigned long long offset = 0;
    BOOL ok = YES;
    while (offset < length) {
        unsigned long long remaining = length - offset;
        uint32_t chunkSize = (remaining > 65536) ? 65536 : (uint32_t)remaining;
        int n = smb2_write(ctx, fh, bytes + offset, chunkSize);
        if (n <= 0) {
            ok = NO;
            break;
        }
        offset += (unsigned long long)n;
    }
    smb2_close(ctx, fh);
    [lock unlock];

    [self sendSimpleStatus:(ok ? @"201 Created" : @"500 Internal Server Error") toSocket:fd];
}

/* ============ DELETE / MKCOL ============ */

- (void)handleDELETE:(NSString *)path toSocket:(int)fd
{
    struct smb2_context *ctx = [appDelegate smb2Context];
    NSLock *lock = [appDelegate smb2Lock];
    NSString *smbPath = [self smbPathForWebDAVPath:path];

    [lock lock];
    struct smb2_stat_64 st;
    int rc = smb2_stat(ctx, [smbPath UTF8String], &st);
    if (rc == 0) {
        if (st.smb2_type == SMB2_TYPE_DIRECTORY) {
            rc = smb2_rmdir(ctx, [smbPath UTF8String]);
        } else {
            rc = smb2_unlink(ctx, [smbPath UTF8String]);
        }
    }
    [lock unlock];

    [self sendSimpleStatus:(rc == 0 ? @"204 No Content" : @"404 Not Found") toSocket:fd];
}

- (void)handleMKCOL:(NSString *)path toSocket:(int)fd
{
    struct smb2_context *ctx = [appDelegate smb2Context];
    NSLock *lock = [appDelegate smb2Lock];
    NSString *smbPath = [self smbPathForWebDAVPath:path];

    [lock lock];
    int rc = smb2_mkdir(ctx, [smbPath UTF8String]);
    [lock unlock];

    [self sendSimpleStatus:(rc == 0 ? @"201 Created" : @"409 Conflict") toSocket:fd];
}

/* ============ LOCK / UNLOCK(擬似実装。実際のロック管理はしない) ============ */

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
    [super dealloc];
}

@end
