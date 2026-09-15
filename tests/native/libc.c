#include <assert.h>
#include <locale.h>
#include <math.h>
#include <netdb.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wchar.h>
#include <wctype.h>

static void *worker(void *argument)
{
    return argument;
}

int main(void)
{
    volatile time_t zero = 0, before_epoch = -432000;
    assert(difftime(zero, before_epoch) == 432000);
    assert(difftime(before_epoch, zero) == -432000);
    assert(setlocale(LC_CTYPE, "C.UTF-8"));
    assert(towupper(0x00e9) == 0x00c9);
    assert(wcwidth(0x754c) == 2);
    assert(wcwidth(0x0301) == 0);
    char *text = strdup("native libc");
    assert(text && strcmp(text, "native libc") == 0);
    pthread_t thread;
    void *result;
    assert(pthread_create(&thread, NULL, worker, text) == 0);
    assert(pthread_join(thread, &result) == 0);
    assert(result == text);
    free(text);
    volatile double base = 2, exponent = 3;
    assert(pow(base, exponent) == 8);
    struct addrinfo hints = { .ai_flags = AI_NUMERICHOST };
    struct addrinfo *address;
    assert(getaddrinfo("127.0.0.1", NULL, &hints, &address) == 0);
    freeaddrinfo(address);
    puts("native libc consumer passed");
    return 0;
}
