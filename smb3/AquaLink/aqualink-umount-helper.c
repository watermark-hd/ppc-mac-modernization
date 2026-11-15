/* aqualink-umount-helper.c
 *
 * AquaLinkが張ったWebDAVループバックマウントを、パスワードダイアログ無しで
 * 確実に取り外すための、最小限のsetuid rootヘルパー。
 *
 * 背景(詳細はsmb3/README.md参照): このマウントは /sbin/mount_webdav
 * (setuid root)が作ったものだが、GUIの管理者権限ダイアログ
 * (AuthorizationExecuteWithPrivileges や、AppleScriptの
 * "do shell script ... with administrator privileges")経由でumountを試みると、
 * 本物のroot権限であっても "Operation not permitted" で失敗する環境がある
 * (実機で確認済み)。一方、マウントしたプロセスと同じログインセッションの中で
 * setuidにより素朴にroot権限を得たプロセス(mount_webdav自身がまさにそう)
 * からのumountは成功する。
 *
 * このヘルパーは mount_webdav と全く同じ仕組み(setuid root。AquaLinkから
 * パスワード無しで直接fork/exec)で動くことで、GUIダイアログを一切経由せずに
 * umountを成功させる。setuidビットの付与自体は初回だけ管理者権限が必要だが
 * (AquaLink側の「自動で直す」ダイアログでchmod/chownするだけなので、これは
 * WebDAVのumount特有の制限を受けない=確認済み)、それ以降は無言で動く。
 *
 * 外し方: まずCarbonのFSUnmountVolumeSync(ディスク管理の仕組み=DiskArbitration
 * 経由)で外す。これだとFinderに通知が届き、デスクトップ/サイドバーの表示が
 * Finderの再起動なしで消える。AquaLinkがFSMountServerVolumeSyncでマウントした
 * ボリュームが対象(mount_webdavを直接実行した古いマウントはDiskArbitrationに
 * 登録されていないので失敗する)。失敗した場合は従来どおりunmount(2)で外す。
 * 終了コード: 0 = FSUnmountVolumeSyncで外れた(Finderへの通知済み)
 *             3 = unmount(2)で外れた(Finderの表示は古いまま残る)
 *             1 = 外せなかった / 2 = 引数が不正
 *
 * 見張り役モード(--watch <ポート>):
 *   AquaLinkがマウント成功直後に起動する。AquaLinkが強制終了・クラッシュで
 *   マウントを残したまま消えると、応答するサーバーがいなくなり、アイコンを
 *   クリックしただけでFinderが固まる(実機で確認。Finderの再起動でも戻らず、
 *   電源ボタンでの再起動が必要になった)。見張り役は親(AquaLink)の終了を
 *   kqueueで待ち、マウントが残っていれば、同じポートで「空のフォルダ」として
 *   応答する最小限のサーバーを立ててから(AquaLinkの起動時の後始末と同じ方式)、
 *   上と同じ方法で取り外す。AquaLinkが普通に取り外した場合は、マウントが
 *   消えたことに気づいて黙って終了する。
 *   ネットワークからの要求を読む部分は別プロセスに分け、root権限を捨ててから動かす。
 *
 * 安全のため:
 *   - 通常モードの引数はちょうど1つ(取り外すパス)だけを受け付ける
 *   - 見張り役モードでは、ポートはAquaLinkが使う範囲(8090〜8099)に限り、
 *     OSのマウント一覧で http://127.0.0.1:<ポート>/ からの/Volumes/配下の
 *     webdavマウントと確認できたものしか外さない
 *   - シェルを一切経由しない(パスをそのままFSUnmountVolumeSync/unmount(2)に渡すだけ)
 *   - realpath()で実体を解決した上で、必ず"/Volumes/"配下であることを
 *     確認してから実行する(それ以外は拒否する)
 * それ以外のことは一切しない。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <errno.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <signal.h>
#include <time.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/event.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <CoreServices/CoreServices.h>

/* /Volumes/配下の実在するパスに解決する。不正なら0を返す */
static int resolveVolumePath(const char *path, char *resolved)
{
    if (realpath(path, resolved) == NULL) {
        fprintf(stderr, "aqualink-umount-helper: realpath failed: %s\n", strerror(errno));
        return 0;
    }
    static const char prefix[] = "/Volumes/";
    size_t prefixLen = strlen(prefix);
    if (strncmp(resolved, prefix, prefixLen) != 0 || strlen(resolved) <= prefixLen) {
        fprintf(stderr, "aqualink-umount-helper: refusing path outside /Volumes/: %s\n", resolved);
        return 0;
    }
    return 1;
}

/* resolvedを外す。戻り値は終了コードと同じ(0 / 3 / 1) */
static int unmountResolved(const char *resolved)
{
    /* 実UIDもrootにそろえる(実UIDが一般ユーザーのままだと、
       ディスク管理側が管理者パスワードを求める可能性があるため) */
    if (setuid(0) != 0) {
        fprintf(stderr, "aqualink-umount-helper: setuid(0) failed: %s\n", strerror(errno));
    }

    FSRef ref;
    FSCatalogInfo info;
    if (FSPathMakeRef((const UInt8 *)resolved, &ref, NULL) == noErr &&
        FSGetCatalogInfo(&ref, kFSCatInfoVolume, &info, NULL, NULL, NULL) == noErr) {
        pid_t dissenter = 0;
        OSStatus err = FSUnmountVolumeSync(info.volume, 0, &dissenter);
        if (err == noErr) {
            return 0;
        }
        fprintf(stderr, "aqualink-umount-helper: FSUnmountVolumeSync failed: %d (pid %d)\n",
                (int)err, (int)dissenter);
    }

    if (unmount(resolved, 0) == 0) {
        return 3;
    }
    if (unmount(resolved, MNT_FORCE) == 0) {
        return 3;
    }
    fprintf(stderr, "aqualink-umount-helper: unmount failed: %s\n", strerror(errno));
    return 1;
}

/* ===================== 見張り役モード ===================== */

/* http://127.0.0.1:<port>/ からのwebdavマウントを探し、マウント先を
   mountOn(PATH_MAX)へ写して1を返す。無ければ0。マウント先はOSの記録を
   そのまま使う(パス文字列で照合すると、日本語の濁点の表し方(NFC/NFD)の
   違いで一致しないことがあるため。AquaLink本体で実際に起きた不具合)。
   MNT_NOWAITなので、応答先のないマウントがあっても固まらない */
static int findOurMount(int port, char *mountOn)
{
    char from[64];
    snprintf(from, sizeof(from), "http://127.0.0.1:%d/", port);
    struct statfs *mnts = NULL;
    int count = getmntinfo(&mnts, MNT_NOWAIT);
    int i;
    for (i = 0; i < count; i++) {
        if (strcmp(mnts[i].f_fstypename, "webdav") == 0 &&
            strncmp(mnts[i].f_mntfromname, from, strlen(from)) == 0 &&
            strncmp(mnts[i].f_mntonname, "/Volumes/", 9) == 0 &&
            strlen(mnts[i].f_mntonname) > 9) {
            if (mountOn != NULL) {
                strlcpy(mountOn, mnts[i].f_mntonname, PATH_MAX);
            }
            return 1;
        }
    }
    return 0;
}

static void sendAll(int fd, const char *buf, size_t len)
{
    while (len > 0) {
        ssize_t n = send(fd, buf, len, 0);
        if (n <= 0) {
            return;
        }
        buf += n;
        len -= (size_t)n;
    }
}

/* XMLに埋め込むため & < > " を置き換える(パスはURLエンコード済みで来るので通常は不要) */
static void xmlEscape(const char *in, char *out, size_t outSize)
{
    size_t o = 0;
    for (; *in && o + 7 < outSize; in++) {
        const char *rep = NULL;
        switch (*in) {
        case '&': rep = "&amp;"; break;
        case '<': rep = "&lt;"; break;
        case '>': rep = "&gt;"; break;
        case '"': rep = "&quot;"; break;
        }
        if (rep) {
            size_t l = strlen(rep);
            memcpy(out + o, rep, l);
            o += l;
        } else {
            out[o++] = *in;
        }
    }
    out[o] = '\0';
}

/* 1接続分。AquaLinkの「後始末用サーバー」(WebDAVServerのdrainOnly)と同じ応答:
   OPTIONS → DAV対応を返す、PROPFIND → 「空のフォルダ」、それ以外 → 503 */
static void drainOneConnection(int fd)
{
    struct timeval tv = { 2, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char req[16384];
    size_t len = 0;
    char *headerEnd = NULL;
    while (len < sizeof(req) - 1) {
        ssize_t n = recv(fd, req + len, sizeof(req) - 1 - len, 0);
        if (n <= 0) {
            return;
        }
        len += (size_t)n;
        req[len] = '\0';
        if ((headerEnd = strstr(req, "\r\n\r\n")) != NULL) {
            break;
        }
    }
    if (headerEnd == NULL) {
        return;
    }

    /* 本文は読み捨てる(上限付き) */
    long contentLength = 0;
    char *cl = strcasestr(req, "\r\ncontent-length:");
    if (cl != NULL && cl < headerEnd) {
        contentLength = strtol(cl + 17, NULL, 10);
    }
    long already = (long)(len - (size_t)(headerEnd + 4 - req));
    long remaining = contentLength - already;
    while (remaining > 0 && remaining < 64L * 1024 * 1024) {
        char junk[4096];
        ssize_t n = recv(fd, junk, sizeof(junk), 0);
        if (n <= 0) {
            break;
        }
        remaining -= n;
    }

    char method[16] = "";
    char path[4096] = "";
    if (sscanf(req, "%15s %4095s", method, path) != 2) {
        return;
    }
    char *q = strchr(path, '?');
    if (q) {
        *q = '\0';
    }

    if (strcmp(method, "OPTIONS") == 0) {
        static const char resp[] =
            "HTTP/1.1 200 OK\r\n"
            "DAV: 1, 2\r\n"
            "MS-Author-Via: DAV\r\n"
            "Allow: OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, MKCOL, LOCK, UNLOCK\r\n"
            "Content-Length: 0\r\n"
            "Connection: close\r\n\r\n";
        sendAll(fd, resp, sizeof(resp) - 1);
    } else if (strcmp(method, "PROPFIND") == 0) {
        char escaped[4096 * 6 + 8];
        xmlEscape(path, escaped, sizeof(escaped));
        char date[64];
        time_t now = time(NULL);
        strftime(date, sizeof(date), "%a, %d %b %Y %H:%M:%S GMT", gmtime(&now));
        char body[sizeof(escaped) + 512];
        int bodyLen = snprintf(body, sizeof(body),
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            "<D:multistatus xmlns:D=\"DAV:\">\n"
            "<D:response>\n<D:href>%s</D:href>\n"
            "<D:propstat>\n<D:prop>\n"
            "<D:resourcetype><D:collection/></D:resourcetype>\n"
            "<D:getlastmodified>%s</D:getlastmodified>\n"
            "</D:prop>\n<D:status>HTTP/1.1 200 OK</D:status>\n</D:propstat>\n"
            "</D:response>\n</D:multistatus>\n", escaped, date);
        if (bodyLen < 0 || bodyLen >= (int)sizeof(body)) {
            return;
        }
        char head[256];
        int headLen = snprintf(head, sizeof(head),
            "HTTP/1.1 207 Multi-Status\r\n"
            "Content-Type: text/xml; charset=\"utf-8\"\r\n"
            "Content-Length: %d\r\n"
            "Connection: close\r\n\r\n", bodyLen);
        sendAll(fd, head, (size_t)headLen);
        sendAll(fd, body, (size_t)bodyLen);
    } else {
        static const char resp[] =
            "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        sendAll(fd, resp, sizeof(resp) - 1);
    }
}

/* 127.0.0.1:portで待ち受ける。AquaLinkが消えた直後はポートが解放されるまで
   わずかに掛かることがあるので、少しの間だけ再試行する */
static int listenOnPort(int port)
{
    int attempt;
    for (attempt = 0; attempt < 30; attempt++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            return -1;
        }
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons((unsigned short)port);
        if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0 && listen(fd, 16) == 0) {
            return fd;
        }
        close(fd);
        usleep(100000);
    }
    return -1;
}

static int watchMain(const char *portArg)
{
    char *end = NULL;
    long port = strtol(portArg, &end, 10);
    if (end == portArg || *end != '\0' || port < 8090 || port > 8099) {
        fprintf(stderr, "aqualink-umount-helper: invalid port: %s\n", portArg);
        return 2;
    }
    char mountOn[PATH_MAX];
    if (!findOurMount((int)port, mountOn)) {
        fprintf(stderr, "aqualink-umount-helper: no mount from port %ld\n", port);
        return 2;
    }
    pid_t parent = getppid();
    if (parent <= 1) {
        return 2;
    }

    /* AquaLink側のパイプ等に縛られないよう、標準入出力を切り離す。
       親が消えた後に書き込んでSIGPIPEで落ちることも防ぐ */
    signal(SIGPIPE, SIG_IGN);
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, 0);
        dup2(devnull, 1);
        dup2(devnull, 2);
        if (devnull > 2) {
            close(devnull);
        }
    }

    /* 親(AquaLink)の終了を待つ。2秒ごとにマウントの有無も確かめ、AquaLinkが
       普通に取り外した後なら何もせず終わる */
    int kq = kqueue();
    struct kevent ev;
    EV_SET(&ev, parent, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    int registered = (kq >= 0 && kevent(kq, &ev, 1, NULL, 0, NULL) == 0);
    for (;;) {
        if (!findOurMount((int)port, NULL)) {
            return 0;
        }
        if (!registered) {
            /* 登録できない = 親が既にいない */
            if (getppid() != parent) {
                break;
            }
            sleep(2);
            continue;
        }
        struct timespec ts = { 2, 0 };
        struct kevent out;
        int n = kevent(kq, NULL, 0, &out, 1, &ts);
        if (n > 0 || getppid() != parent) {
            break;
        }
    }

    /* AquaLinkが消えた。マウントがまだ残っていれば代わりに片付ける */
    if (!findOurMount((int)port, NULL)) {
        return 0;
    }
    int lfd = listenOnPort((int)port);
    if (lfd < 0) {
        /* 誰かが既にこのポートで応答している(新しいAquaLink等)。手を出さない */
        return 1;
    }
    /* 待ち受けまでの間に別の見張り役が片付け終えていれば、何もしない。
       マウント先もこの時点のOSの記録から取り直す */
    if (!findOurMount((int)port, mountOn)) {
        close(lfd);
        return 0;
    }

    /* 応答係はroot権限を捨てた子プロセスで動かす */
    pid_t server = fork();
    if (server == 0) {
        if (setgid(getgid()) != 0 || setuid(getuid()) != 0 || geteuid() == 0) {
            _exit(1);
        }
        for (;;) {
            int cfd = accept(lfd, NULL, NULL);
            if (cfd < 0) {
                if (errno == EINTR) {
                    continue;
                }
                _exit(0);
            }
            drainOneConnection(cfd);
            close(cfd);
        }
    }
    close(lfd);
    if (server < 0) {
        return 1;
    }

    int result = unmountResolved(mountOn);

    kill(server, SIGTERM);
    waitpid(server, NULL, 0);
    return result;
}

int main(int argc, char *argv[])
{
    if (argc == 3 && strcmp(argv[1], "--watch") == 0) {
        return watchMain(argv[2]);
    }
    if (argc != 2) {
        fprintf(stderr, "usage: %s <mountpoint under /Volumes>\n"
                        "       %s --watch <port>\n",
                argv[0], argv[0]);
        return 2;
    }

    char resolved[PATH_MAX];
    if (!resolveVolumePath(argv[1], resolved)) {
        return 2;
    }
    return unmountResolved(resolved);
}
