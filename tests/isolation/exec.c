/* Test exec inheritance only. This program is never installed as a sandbox. */
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int
visible(const char *path)
{
    struct stat st;
    if (stat(path, &st) == 0)
        return 1;
    assert(errno == ENOENT);
    return 0;
}

int
main(int argc, char **argv)
{
    const char *promises = "stdio rpath wpath cpath exec proc prot_exec";
    if (argc == 2 && strcmp(argv[1], "rtable-option") == 0) {
        printf("%d\n", SO_RTABLE);
        return 0;
    }
    assert(argc >= 4);
    if (strcmp(argv[1], "read") == 0) {
        assert(visible(argv[2]) == atoi(argv[3]));
        puts("EXEC_VISIBILITY_CHECK_PASS");
        return 0;
    }
    assert(unveil("/nix/store", "rx") == 0);
    assert(unveil("/usr/libexec", "rx") == 0);
    assert(unveil("/bin", "rx") == 0);
    assert(unveil("/dev/null", "rw") == 0);
    assert(unveil(argv[2], "rwc") == 0);
    assert(unveil(NULL, NULL) == 0);
    assert(!visible(argv[3]));
    if (strcmp(argv[1], "unveil") != 0)
        assert(pledge(promises, promises) == 0);
    if (strcmp(argv[1], "command") == 0) {
        assert(argc >= 5);
        execv(argv[4], argv + 4);
    } else {
        execl(argv[0], argv[0], "read", argv[3],
            strcmp(argv[1], "unveil") == 0 ? "1" : "0", (char *)NULL);
    }
    perror("exec");
    return 1;
}
