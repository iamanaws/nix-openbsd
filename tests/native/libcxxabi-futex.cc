// Reuse LLVM's guard tests, selecting futexes explicitly: the default guard
// implementation uses a mutex and would not exercise the OpenBSD futex fix.
#define main upstream_guard_test_main
#include "guard_threaded_test.pass.cpp"
#undef main

#include <unistd.h>

template <class Guard> void check_guard() {
  using Impl = SelectImplementation<Implementation::Futex>::type;
  test_free_for_all<Guard, Impl>(3);
  test_waiting_for_init<Guard, Impl>(3);
  test_aborted_init<Guard, Impl>(3);
  test_completed_init<Guard, Impl>(3);
}

int main() {
  static_assert(PlatformSupportsFutex());
  alarm(60); // Bound failures caused by a waiter that never wakes.
  test_futex_syscall();
  for (int i = 0; i < 10; ++i) {
    check_guard<uint32_t>();
    check_guard<uint64_t>();
  }
  alarm(0);
}
