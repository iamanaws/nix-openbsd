/* Native constants and IPC fixtures used by the daemon sandbox tests. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ipc.h>
#include <sys/msg.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/sysctl.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
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
