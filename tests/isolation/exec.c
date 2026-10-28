/* Native constants and IPC fixtures used by the daemon sandbox tests. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ipc.h>
#include <sys/msg.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int
main(int argc, char **argv)
{
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
