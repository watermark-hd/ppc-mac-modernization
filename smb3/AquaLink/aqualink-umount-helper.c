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
 * 安全のため:
 *   - 引数はちょうど1つ(取り外すパス)だけを受け付ける
 *   - シェルを一切経由しない(文字列をそのままunmount(2)に渡すだけ)
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

int main(int argc, char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <mountpoint under /Volumes>\n", argv[0]);
        return 2;
    }

    char resolved[PATH_MAX];
    if (realpath(argv[1], resolved) == NULL) {
        fprintf(stderr, "aqualink-umount-helper: realpath failed: %s\n", strerror(errno));
        return 2;
    }

    static const char prefix[] = "/Volumes/";
    size_t prefixLen = strlen(prefix);
    if (strncmp(resolved, prefix, prefixLen) != 0 || strlen(resolved) <= prefixLen) {
        fprintf(stderr, "aqualink-umount-helper: refusing path outside /Volumes/: %s\n", resolved);
        return 2;
    }

    if (unmount(resolved, 0) == 0) {
        return 0;
    }
    if (unmount(resolved, MNT_FORCE) == 0) {
        return 0;
    }
    fprintf(stderr, "aqualink-umount-helper: unmount failed: %s\n", strerror(errno));
    return 1;
}
