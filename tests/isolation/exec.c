/* Native constants and IPC fixtures used by the daemon sandbox tests. */
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/ipc.h>
#include <sys/msg.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

struct message {
    long type;
    char text[32];
};

static void
initialise_ipc(int mode, int gid)
{
    int shm = shmget(IPC_PRIVATE, 4096, IPC_CREAT | mode);
    int msg = msgget(IPC_PRIVATE, IPC_CREAT | mode);
    int sem = semget(IPC_PRIVATE, 1, IPC_CREAT | mode);
    assert(shm >= 0 && msg >= 0 && sem >= 0);
    struct shmid_ds sd;
    struct msqid_ds md;
    struct semid_ds ed;
    union semun arg;
    assert(shmctl(shm, IPC_STAT, &sd) == 0);
    assert(msgctl(msg, IPC_STAT, &md) == 0);
    arg.buf = &ed;
    assert(semctl(sem, 0, IPC_STAT, arg) == 0);
    sd.shm_perm.gid = md.msg_perm.gid = ed.sem_perm.gid = gid;
    assert(shmctl(shm, IPC_SET, &sd) == 0);
    assert(msgctl(msg, IPC_SET, &md) == 0);
    assert(semctl(sem, 0, IPC_SET, arg) == 0);
    char *data = shmat(shm, NULL, 0);
    assert(data != (void *)-1);
    strcpy(data, "host");
    assert(shmdt(data) == 0);
    struct message message = { .type = 1, .text = "host" };
    assert(msgsnd(msg, &message, sizeof(message.text), IPC_NOWAIT) == 0);
    arg.val = 7;
    assert(semctl(sem, 0, SETVAL, arg) == 0);
    printf("[%d,%d,%d]\n", shm, msg, sem);
}

int
main(int argc, char **argv)
{
    if (argc == 2 && (strcmp(argv[1], "limits") == 0 || strcmp(argv[1], "limit-state") == 0)) {
        struct rlimit processes, files, data;
        assert(getrlimit(RLIMIT_NPROC, &processes) == 0);
        assert(getrlimit(RLIMIT_NOFILE, &files) == 0);
        assert(getrlimit(RLIMIT_DATA, &data) == 0);
        FILE *out = stdout;
        if (strcmp(argv[1], "limits") == 0) {
            assert(getuid() != 0);
            out = fopen(getenv("out"), "w");
            assert(out != NULL);
        }
        assert(fprintf(out, "{\"nproc\":[%ju,%ju],\"nofile\":[%ju,%ju],\"data\":[%ju,%ju]}\n",
            (uintmax_t)processes.rlim_cur, (uintmax_t)processes.rlim_max,
            (uintmax_t)files.rlim_cur, (uintmax_t)files.rlim_max,
            (uintmax_t)data.rlim_cur, (uintmax_t)data.rlim_max) > 0);
        assert(fclose(out) == 0);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "limits-raise") == 0) {
        int resources[] = {RLIMIT_NPROC, RLIMIT_NOFILE, RLIMIT_DATA};
        for (size_t i = 0; i < sizeof(resources) / sizeof(resources[0]); ++i) {
            struct rlimit limit;
            assert(getrlimit(resources[i], &limit) == 0);
            assert(limit.rlim_max < RLIM_INFINITY);
            ++limit.rlim_max;
            assert(setrlimit(resources[i], &limit) == -1 && errno == EPERM);
        }
        return 0;
    }
    if (argc >= 7 && strcmp(argv[1], "exec-policy") == 0) {
        /* Exercise inherited policies in test children, not in Nix itself. */
        if (strcmp(argv[3], "none") != 0) {
            assert(unveil("/", "rx") == 0);
            assert(unveil(argv[5], "rwxc") == 0);
            assert(unveil("/dev/null", "rw") == 0);
            assert(unveil(argv[4], "") == 0);
            if (strcmp(argv[3], "locked") == 0)
                assert(unveil(NULL, NULL) == 0);
            else
                assert(strcmp(argv[3], "open") == 0);
        }
        if (strcmp(argv[2], "-") != 0)
            assert(pledge(argv[2], argv[2]) == 0);
        execv(argv[6], argv + 6);
        perror("exec policy child");
        return 1;
    }
    if (argc == 6 && strcmp(argv[1], "exec-visibility") == 0) {
        unsigned int count = strtoul(argv[2], NULL, 10);
        if (count) {
            char next[20];
            snprintf(next, sizeof(next), "%u", count - 1);
            execl(argv[0], argv[0], "exec-visibility", next, argv[3], argv[4], argv[5], (char *)NULL);
            perror("exec visibility child");
            return 1;
        }
        struct stat st;
        assert(stat(argv[4], &st) == 0);
        errno = 0;
        int visible = stat(argv[3], &st) == 0;
        int error = errno;
        assert(visible == atoi(argv[5]));
        if (!visible)
            assert(error == ENOENT || error == EACCES);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "pledge-expand") == 0) {
        assert(pledge(argv[2], NULL) == -1 && errno == EPERM);
        assert(pledge(NULL, argv[2]) == -1 && errno == EPERM);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "unveil-reveal") == 0) {
        struct stat st;
        assert(stat(argv[2], &st) == -1);
        assert(errno == EACCES || errno == ENOENT);
        assert(unveil(argv[2], "r") == 0);
        assert(stat(argv[2], &st) == 0);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "policy-ipc") == 0) {
        int id;
        errno = 0;
        if (strcmp(argv[2], "shm") == 0) {
            id = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600);
            if (id >= 0)
                assert(shmctl(id, IPC_RMID, NULL) == 0);
        } else if (strcmp(argv[2], "msg") == 0) {
            id = msgget(IPC_PRIVATE, IPC_CREAT | 0600);
            if (id >= 0)
                assert(msgctl(id, IPC_RMID, NULL) == 0);
        } else {
            assert(strcmp(argv[2], "sem") == 0);
            id = semget(IPC_PRIVATE, 1, IPC_CREAT | 0600);
            if (id >= 0)
                assert(semctl(id, 0, IPC_RMID) == 0);
        }
        if (id >= 0)
            return 0;
        assert(errno == ENOSYS);
        return 2;
    }
    if (argc == 2 && strcmp(argv[1], "fd-audit") == 0) {
        /* Check the exec boundary before opening the output or other files. */
        for (int fd = 3; fd < getdtablesize(); ++fd)
            assert(fcntl(fd, F_GETFD) == -1 && errno == EBADF);
        FILE *out = fopen(getenv("out"), "w");
        assert(out != NULL);
        assert(fputs("FD_AUDIT_PASS\n", out) >= 0);
        assert(fclose(out) == 0);
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "process-visible") == 0) {
        pid_t pid = atoi(argv[2]);
        struct kinfo_proc process;
        size_t size = sizeof(process);
        int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid, sizeof(process), 1 };
        assert(sysctl(mib, 6, &process, &size, NULL, 0) == 0);
        assert(size == sizeof(process) && process.p_pid == pid && process.p_uid == 0);
        assert(kill(pid, 0) == -1 && errno == EPERM);
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "ipc-fixture") == 0) {
        initialise_ipc(strtol(argv[2], NULL, 8), atoi(argv[3]));
        return 0;
    }
    if (argc == 5 && strcmp(argv[1], "ipc-denied") == 0) {
        struct message message;
        assert(shmat(atoi(argv[2]), NULL, 0) == (void *)-1 && errno == EACCES);
        assert(shmat(atoi(argv[2]), NULL, SHM_RDONLY) == (void *)-1 && errno == EACCES);
        assert(msgrcv(atoi(argv[3]), &message, sizeof(message.text), 0, IPC_NOWAIT) == -1 && errno == EACCES);
        message.type = 1;
        memset(message.text, 0, sizeof(message.text));
        assert(msgsnd(atoi(argv[3]), &message, sizeof(message.text), IPC_NOWAIT) == -1 && errno == EACCES);
        assert(semctl(atoi(argv[4]), 0, GETVAL) == -1 && errno == EACCES);
        union semun argument;
        argument.val = 0;
        assert(semctl(atoi(argv[4]), 0, SETVAL, argument) == -1 && errno == EACCES);
        return 0;
    }
    if (argc == 5 && strcmp(argv[1], "ipc-access") == 0) {
        int shm = atoi(argv[2]), msg = atoi(argv[3]), sem = atoi(argv[4]);
        char *data = shmat(shm, NULL, 0);
        assert(data != (void *)-1 && strcmp(data, "host") == 0);
        strcpy(data, "builder");
        assert(shmdt(data) == 0);
        struct message message;
        assert(msgrcv(msg, &message, sizeof(message.text), 0, IPC_NOWAIT) == (ssize_t)sizeof(message.text));
        assert(strcmp(message.text, "host") == 0);
        strcpy(message.text, "builder");
        assert(msgsnd(msg, &message, sizeof(message.text), IPC_NOWAIT) == 0);
        assert(semctl(sem, 0, GETVAL) == 7);
        union semun arg;
        arg.val = 8;
        assert(semctl(sem, 0, SETVAL, arg) == 0);
        assert(shmctl(shm, IPC_RMID, NULL) == -1 && errno == EPERM);
        assert(msgctl(msg, IPC_RMID, NULL) == -1 && errno == EPERM);
        assert(semctl(sem, 0, IPC_RMID) == -1 && errno == EPERM);
        return 0;
    }
    if (argc == 6 && strcmp(argv[1], "ipc-verify") == 0) {
        const char *expected = argv[2];
        char *data = shmat(atoi(argv[3]), NULL, SHM_RDONLY);
        assert(data != (void *)-1 && strcmp(data, expected) == 0);
        assert(shmdt(data) == 0);
        struct message message;
        assert(msgrcv(atoi(argv[4]), &message, sizeof(message.text), 0, IPC_NOWAIT) == (ssize_t)sizeof(message.text));
        assert(strcmp(message.text, expected) == 0);
        assert(semctl(atoi(argv[5]), 0, GETVAL) == (strcmp(expected, "host") == 0 ? 7 : 8));
        return 0;
    }
    if (argc == 5 && strcmp(argv[1], "ipc-destroy") == 0) {
        assert(shmctl(atoi(argv[2]), IPC_RMID, NULL) == 0);
        assert(msgctl(atoi(argv[3]), IPC_RMID, NULL) == 0);
        assert(semctl(atoi(argv[4]), 0, IPC_RMID) == 0);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "rtable-option") == 0) {
        printf("%d\n", SO_RTABLE);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "ipc-create") == 0) {
        int shm = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600);
        int msg = msgget(IPC_PRIVATE, IPC_CREAT | 0600);
        int sem = semget(IPC_PRIVATE, 1, IPC_CREAT | 0600);
        assert(shm >= 0 && msg >= 0 && sem >= 0);
        printf("[%d,%d,%d]\n", shm, msg, sem);
        return 0;
    }
    if (argc == 5 && strcmp(argv[1], "ipc-removed") == 0) {
        struct shmid_ds shm;
        struct msqid_ds msg;
        struct semid_ds sem;
        union semun argument;
        argument.buf = &sem;
        assert(shmctl(atoi(argv[2]), IPC_STAT, &shm) == -1 && (errno == EINVAL || errno == EIDRM));
        assert(msgctl(atoi(argv[3]), IPC_STAT, &msg) == -1 && (errno == EINVAL || errno == EIDRM));
        assert(semctl(atoi(argv[4]), 0, IPC_STAT, argument) == -1 && (errno == EINVAL || errno == EIDRM));
        return 0;
    }
    return 2;
}
