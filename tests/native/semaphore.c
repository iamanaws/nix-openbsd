#include <sys/types.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s failed at line %d\n", #x, __LINE__); exit(1); } } while (0)

static sem_t local;

static void *wait_local(void *unused)
{
    struct timespec deadline;
    CHECK(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_sec += unused ? 10 : 3;
    CHECK(sem_timedwait(&local, &deadline) == 0);
    return NULL;
}

static void *post_local(void *unused)
{
    (void)unused;
    usleep(200000);
    CHECK(sem_post(&local) == 0);
    return NULL;
}

static void *cancel_wait(void *unused)
{
    (void)unused;
    CHECK(sem_wait(&local) == 0);
    return NULL;
}

int main(void)
{
    /* The two processes get private semaphores at the same virtual address. */
    CHECK(sem_init(&local, 0, 0) == 0);
    int ready[2];
    CHECK(pipe(ready) == 0);
    pid_t child = fork();
    CHECK(child >= 0);
    if (!child) {
        char byte;
        close(ready[1]);
        CHECK(read(ready[0], &byte, 1) == 1);
        close(ready[0]);
        pthread_t poster;
        struct timespec start, finish;
        CHECK(pthread_create(&poster, NULL, post_local, NULL) == 0);
        CHECK(clock_gettime(CLOCK_MONOTONIC, &start) == 0);
        wait_local(NULL);
        CHECK(clock_gettime(CLOCK_MONOTONIC, &finish) == 0);
        CHECK(pthread_join(poster, NULL) == 0);
        double elapsed = finish.tv_sec - start.tv_sec +
            (finish.tv_nsec - start.tv_nsec) / 1e9;
        printf("private semaphore wake: %.3f seconds\n", elapsed);
        fflush(stdout);
        _exit(elapsed < 1.5 ? 0 : 1);
    }
    close(ready[0]);
    pthread_t waiter;
    CHECK(pthread_create(&waiter, NULL, wait_local, &local) == 0);
    /* Queue the parent's waiter first so a shared futex wake reaches it. */
    usleep(200000);
    CHECK(write(ready[1], "r", 1) == 1);
    close(ready[1]);
    int status;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(sem_post(&local) == 0);
    CHECK(pthread_join(waiter, NULL) == 0);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    struct timespec deadline;
    CHECK(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    CHECK(sem_timedwait(&local, &deadline) == -1 && errno == ETIMEDOUT);
    CHECK(pthread_create(&waiter, NULL, cancel_wait, NULL) == 0);
    usleep(100000);
    CHECK(pthread_cancel(waiter) == 0);
    void *result;
    CHECK(pthread_join(waiter, &result) == 0 && result == PTHREAD_CANCELED);
    CHECK(sem_destroy(&local) == 0);

    char name[64];
    snprintf(name, sizeof(name), "/nixopenbsd-sem-%ld", (long)getpid());
    sem_t *shared = sem_open(name, O_CREAT | O_EXCL, 0600, 0);
    CHECK(shared != SEM_FAILED);
    CHECK(sem_unlink(name) == 0);
    child = fork();
    CHECK(child >= 0);
    if (!child) {
        usleep(100000);
        _exit(sem_post(shared) != 0);
    }
    CHECK(clock_gettime(CLOCK_REALTIME, &deadline) == 0);
    deadline.tv_sec += 3;
    CHECK(sem_timedwait(shared, &deadline) == 0);
    CHECK(waitpid(child, &status, 0) == child && status == 0);
    CHECK(sem_close(shared) == 0);
    puts("PASS: private/shared semaphores, timeout, cancellation");
    return 0;
}
