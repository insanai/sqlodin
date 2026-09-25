#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    int fd = open(argv[1], O_CREAT | O_EXCL | O_RDWR, 0600);
    assert(fd >= 0);
    unsigned char data[56], actual[56];
    for (unsigned i = 0; i < sizeof(data); ++i) data[i] = (unsigned char)(i * 3);
    assert(pwrite(fd, data, 37, 0) == 37);
    assert(pwrite64(fd, data + 37, 19, 37) == 19);
    assert(fsync(fd) == 0 && fdatasync(fd) == 0);
    errno = 0;
    assert(pwrite(-1, data, 1, 0) == -1 && errno == EBADF);
    errno = 0;
    assert(fdatasync(-1) == -1 && errno == EBADF);
    assert(pread(fd, actual, sizeof(actual), 0) == (ssize_t)sizeof(actual));
    assert(memcmp(data, actual, sizeof(data)) == 0);
    assert(close(fd) == 0);
    return 0;
}
