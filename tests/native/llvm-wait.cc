// Exercise LLVM's installed process-wait implementation, including ownership
// of child statuses when more than one child is ready to be reaped.
#include <llvm/Support/Program.h>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <csignal>
#include <thread>
#include <sys/wait.h>
#include <unistd.h>

using llvm::sys::ProcessInfo;
using llvm::sys::Wait;

static ProcessInfo child(unsigned seconds, int code) {
  ProcessInfo pi;
  pi.Pid = fork();
  assert(pi.Pid >= 0);
  if (pi.Pid == 0) {
    sleep(seconds);
    _exit(code);
  }
  pi.Process = pi.Pid;
  return pi;
}

static void reaped(ProcessInfo pi) {
  int status;
  assert(waitpid(pi.Pid, &status, WNOHANG) == -1 && errno == ECHILD);
}

static void timeout(ProcessInfo pi) {
  std::string error;
  const auto start = std::chrono::steady_clock::now();
  const auto result = Wait(pi, 1, &error);
  const auto elapsed = std::chrono::steady_clock::now() - start;
  assert(result.ReturnCode == -2);
  assert(error.find("timed out") != std::string::npos);
  assert(elapsed >= std::chrono::seconds(1) && elapsed < std::chrono::seconds(4));
}

static void threadedTimeout(ProcessInfo pi) {
  sigset_t blocked;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGALRM);
  assert(pthread_sigmask(SIG_BLOCK, &blocked, nullptr) == 0);
  timeout(pi);
}

int main() {
  struct sigaction handler{}, previous{}, after{};
  handler.sa_handler = [](int) {};
  sigemptyset(&handler.sa_mask);
  assert(sigaction(SIGALRM, &handler, &previous) == 0);
  alarm(20);

  auto exited = child(0, 23);
  std::optional<llvm::sys::ProcessStatistics> stats;
  auto result = Wait(exited, std::nullopt, nullptr, &stats);
  assert(result.Pid == exited.Pid && result.ReturnCode == 23 && stats);
  reaped(exited);

  auto polling = child(10, 0);
  assert(Wait(polling, 0).Pid == 0);
  assert(Wait(polling, 1, nullptr, nullptr, true).Pid == 0);
  assert(kill(polling.Pid, 0) == 0);
  assert(kill(polling.Pid, SIGTERM) == 0);
  assert(Wait(polling, std::nullopt).ReturnCode == -2);
  reaped(polling);

  auto timed = child(10, 0);
  auto unrelated = child(0, 42);
  usleep(100000); // Let the unrelated child become waitable before the timeout.
  timeout(timed);
  int status;
  const pid_t other = waitpid(unrelated.Pid, &status, 0);
  const bool otherOK = other == unrelated.Pid && WIFEXITED(status) && WEXITSTATUS(status) == 42;
  const pid_t target = waitpid(timed.Pid, &status, 0);
  const bool targetReaped = target == -1 && errno == ECHILD;
  if (!otherOK || !targetReaped) {
    std::fprintf(stderr, "Timeout cleanup: unrelated child preserved=%d, target reaped=%d\n",
                 otherOK, targetReaped);
    return 1;
  }

  auto first = child(10, 0);
  auto second = child(10, 0);
  std::thread a([&] { threadedTimeout(first); });
  std::thread b([&] { threadedTimeout(second); });
  a.join();
  b.join();
  reaped(first);
  reaped(second);
  assert(alarm(0) > 0);
  assert(sigaction(SIGALRM, nullptr, &after) == 0);
  assert(after.sa_handler == handler.sa_handler);
  assert(sigaction(SIGALRM, &previous, nullptr) == 0);
  std::puts("LLVM_WAIT_PASS");
}
