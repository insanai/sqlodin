/* Linux diagnostic interposer. It forwards every call unchanged; it never disables sync. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    uint64_t calls, nanos, writes, bytes, write_nanos;
} Stats;
static Stats stats;
static bool enabled;
static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
void sync_profile_begin(void) { stats = (Stats){0}; enabled = true; }
void sync_profile_end(Stats *out) { enabled = false; *out = stats; }
/* The benchmark is deliberately single-threaded. These counters are not a server profiler. */
#define SYNC_WRAP(name) \
int name(int fd) { \
    static int (*real_call)(int); \
    if (!real_call) real_call = dlsym(RTLD_NEXT, #name); \
    uint64_t start = enabled ? now_ns() : 0; \
    int rc = real_call(fd); int saved_errno = errno; \
    if (enabled) { stats.calls++; stats.nanos += now_ns() - start; } \
    errno = saved_errno; return rc; \
}
SYNC_WRAP(fsync)
SYNC_WRAP(fdatasync)
#define WRITE_WRAP(name, offset_type) \
ssize_t name(int fd, const void *buf, size_t count, offset_type offset) { \
    static ssize_t (*real_call)(int, const void *, size_t, offset_type); \
    if (!real_call) real_call = dlsym(RTLD_NEXT, #name); \
    uint64_t start = enabled ? now_ns() : 0; \
    ssize_t rc = real_call(fd, buf, count, offset); int saved_errno = errno; \
    if (enabled) { stats.writes++; if (rc > 0) stats.bytes += (uint64_t)rc; \
        stats.write_nanos += now_ns() - start; } \
    errno = saved_errno; return rc; \
}
WRITE_WRAP(pwrite, off_t)
WRITE_WRAP(pwrite64, off64_t)
