/* Linux qualification only: forward every SQLite I/O call, preserving errno.
 * Whole-process totals include startup, maintenance and shutdown. Never link
 * this interposer into release binaries or interpret summed I/O time as CPU. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static int (*real_fsync)(int), (*real_fdatasync)(int);
static ssize_t (*real_pwrite)(int, const void *, size_t, off_t);
static ssize_t (*real_pwrite64)(int, const void *, size_t, off64_t);
static _Atomic uint64_t sync_calls, sync_ns, write_calls, write_bytes, write_ns, errors;

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}

__attribute__((constructor)) static void initialize(void) {
    real_fsync = dlsym(RTLD_NEXT, "fsync");
    real_fdatasync = dlsym(RTLD_NEXT, "fdatasync");
    real_pwrite = dlsym(RTLD_NEXT, "pwrite");
    real_pwrite64 = dlsym(RTLD_NEXT, "pwrite64");
    if (!real_fsync || !real_fdatasync || !real_pwrite || !real_pwrite64) _exit(126);
}

#define COUNT(counter, value) atomic_fetch_add_explicit(&(counter), (value), memory_order_relaxed)
#define SYNC(name) \
int name(int fd) { \
    uint64_t start = now_ns(); \
    int rc = real_##name(fd), saved = errno; \
    COUNT(sync_calls, 1); COUNT(sync_ns, now_ns()-start); \
    if (rc < 0) COUNT(errors, 1); \
    errno = saved; return rc; \
}
SYNC(fsync)
SYNC(fdatasync)

#define WRITE(name, offset_type) \
ssize_t name(int fd, const void *buffer, size_t count, offset_type offset) { \
    uint64_t start = now_ns(); \
    ssize_t rc = real_##name(fd, buffer, count, offset); int saved = errno; \
    COUNT(write_calls, 1); COUNT(write_ns, now_ns()-start); \
    if (rc >= 0) COUNT(write_bytes, (uint64_t)rc); else COUNT(errors, 1); \
    errno = saved; return rc; \
}
WRITE(pwrite, off_t)
WRITE(pwrite64, off64_t)

__attribute__((destructor)) static void report(void) {
    char line[512];
    int n = snprintf(line, sizeof(line), "SQLODIN_IO_PROFILE {\"sync_calls\":%llu,"
        "\"sync_ns\":%llu,\"write_calls\":%llu,\"write_bytes\":%llu,"
        "\"write_ns\":%llu,\"errors\":%llu}\n",
        (unsigned long long)atomic_load(&sync_calls), (unsigned long long)atomic_load(&sync_ns),
        (unsigned long long)atomic_load(&write_calls), (unsigned long long)atomic_load(&write_bytes),
        (unsigned long long)atomic_load(&write_ns), (unsigned long long)atomic_load(&errors));
    if (n > 0 && (size_t)n < sizeof(line)) {
        ssize_t ignored = write(STDERR_FILENO, line, (size_t)n);
        (void)ignored;
    }
}
