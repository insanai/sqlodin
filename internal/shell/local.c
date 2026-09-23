/* The upstream SQLite shell is linked, not invoked as an external program. */
#include "sqlite3.h"
#include <stdio.h>
#include <stdlib.h>
extern int sqlite3_vec_init(sqlite3*, char**, const sqlite3_api_routines*);
void sqlodin_shell_init(void) {
    if (sqlite3_initialize() != SQLITE_OK ||
        sqlite3_auto_extension((void(*)(void))sqlite3_vec_init) != SQLITE_OK) {
        fputs("Cannot initialize the SQLodin SQLite/vector shell\n", stderr);
        exit(1);
    }
}
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
int sqlodin_cli_lock(const char *path) {
    int fd = open(path, O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX|LOCK_NB) != 0) { close(fd); return -1; }
    return fd;
}
/* Keep terminal lifecycle small; editing/history remain in Odin. */
#include <termios.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <locale.h>
#include <wchar.h>
static struct termios sqlodin_saved_terminal;
static int sqlodin_terminal_active;
static void sqlodin_terminal_restore(void) {
    if (sqlodin_terminal_active) {
        tcsetattr(STDIN_FILENO, TCSANOW, &sqlodin_saved_terminal);
        sqlodin_terminal_active = 0;
    }
}
static void sqlodin_terminal_signal(int sig) {
    sqlodin_terminal_restore();
    _exit(128 + sig);
}
int sqlodin_terminal_begin(void) {
    struct termios raw;
    if (tcgetattr(STDIN_FILENO, &sqlodin_saved_terminal) != 0) return 0;
    raw = sqlodin_saved_terminal;
    raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
    raw.c_iflag &= ~(IXON | ICRNL);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) return 0;
    sqlodin_terminal_active = 1;
    atexit(sqlodin_terminal_restore);
    signal(SIGTERM, sqlodin_terminal_signal);
    signal(SIGHUP, sqlodin_terminal_signal);
    signal(SIGINT, sqlodin_terminal_signal);
    signal(SIGQUIT, sqlodin_terminal_signal);
    setlocale(LC_CTYPE, "");
    return 1;
}
void sqlodin_terminal_end(void) { sqlodin_terminal_restore(); }
int sqlodin_terminal_columns(void) {
    struct winsize size;
    return ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 20 ? size.ws_col : 80;
}
int sqlodin_terminal_width(int rune) {
    int width = wcwidth((wchar_t)rune);
    return width < 0 ? 1 : width;
}
