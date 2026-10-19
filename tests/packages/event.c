#include <event2/event.h>
#include <event2/thread.h>
#include <sys/socket.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>

static int received, expired;

static void readable(evutil_socket_t fd, short events, void *arg) {
  char value;
  (void)events;
  (void)arg;
  if (read(fd, &value, 1) != 1 || value != 'x') abort();
  received++;
}

static void timer(evutil_socket_t fd, short events, void *arg) {
  (void)fd;
  (void)events;
  (void)arg;
  expired++;
}

int main(void) {
  struct event_base *base;
  struct event *read_event, *timer_event;
  struct timeval delay = { 0, 10000 };
  int pair[2];
  alarm(10);
  if (evthread_use_pthreads() != 0 || socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) abort();
  if (!(base = event_base_new())) abort();
  read_event = event_new(base, pair[0], EV_READ, readable, NULL);
  timer_event = evtimer_new(base, timer, NULL);
  if (!read_event || !timer_event || event_add(read_event, NULL) ||
      evtimer_add(timer_event, &delay) || write(pair[1], "x", 1) != 1) abort();
  if (event_base_dispatch(base) != 1 || received != 1 || expired != 1) abort();
  printf("PASS libevent: %s backend, socket readiness, timer and pthread setup\n",
         event_base_get_method(base));
  event_free(read_event);
  event_free(timer_event);
  event_base_free(base);
  close(pair[0]);
  close(pair[1]);
  return 0;
}
