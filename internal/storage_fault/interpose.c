/* Linux qualification only. Never linked into the SQLodin release binary.
 * Arm after acknowledged seed writes. Affect one exact WAL pathname, and leave
 * a durable marker proving the selected syscall boundary was actually reached.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static const char *target, *armed, *marker, *mode;
static _Atomic int fired;
__attribute__((constructor)) static void configure(void) {
    target = getenv("SQLODIN_FAULT_TARGET");
    armed = getenv("SQLODIN_FAULT_ARMED");
    marker = getenv("SQLODIN_FAULT_MARKER");
    mode = getenv("SQLODIN_FAULT_MODE");
}
static int selected(int fd) {
    if (!target || !armed || !marker || !mode || access(armed, F_OK)) return 0;
    char link[64], path[4096];
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(link, path, sizeof(path)-1);
    if (n < 0) return 0;
    path[n] = 0;
    return !strcmp(path, target);
}
static int record(void) {
    int first = !atomic_exchange(&fired, 1);
    if (first) {
        int fd = open(marker, O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC, 0600);
        if (fd >= 0) {
            syscall(SYS_write, fd, mode, strlen(mode));
            syscall(SYS_fsync, fd);
            close(fd);
        }
    }
    return first;
}
static ssize_t write_at(int fd, const void *buf, size_t count, off64_t offset) {
    if (selected(fd) && strcmp(mode, "sync-eio")) {
        int first = record();
        if (!strcmp(mode, "short-write") && first && count > 1) {
            ssize_t n = syscall(SYS_pwrite64, fd, buf, count/2, offset);
            char path[4096], evidence[128];
            snprintf(path, sizeof(path), "%s.partial", marker);
            int proof = open(path, O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC, 0600);
            if (proof >= 0) {
                int length = snprintf(evidence, sizeof(evidence), "%zd/%zu", n, count);
                syscall(SYS_write, proof, evidence, length);
                syscall(SYS_fsync, proof);
                close(proof);
            }
            return n;
        }
        errno = !strcmp(mode, "write-enospc") ? ENOSPC : EIO;
        return -1;
    }
    return syscall(SYS_pwrite64, fd, buf, count, offset);
}
ssize_t pwrite(int fd, const void *buf, size_t n, off_t offset) {
    return write_at(fd, buf, n, offset);
}
ssize_t pwrite64(int fd, const void *buf, size_t n, off64_t offset) {
    return write_at(fd, buf, n, offset);
}
int fsync(int fd) {
    if (selected(fd) && !strcmp(mode, "sync-eio")) { record(); errno = EIO; return -1; }
    return syscall(SYS_fsync, fd);
}
int fdatasync(int fd) {
    if (selected(fd) && !strcmp(mode, "sync-eio")) { record(); errno = EIO; return -1; }
    return syscall(SYS_fdatasync, fd);
}
