/* Extract killUser; adapt Nix's process wrapper, logging and exceptions. */
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <unistd.h>
#include <cassert>
#include <cerrno>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static std::string test;
static std::filesystem::path fixture;
static uid_t targetUid;
static int helperStatus = 0;
static void require(bool condition, const char *message)
{
    if (!condition) throw std::runtime_error(message);
}
[[maybe_unused]] static int probePledge(const char *promises, const char *execpromises)
{
    if (test == "pledge-failure") { errno = EPERM; return -1; }
    return pledge(promises, execpromises);
}
static int probeKill(pid_t pid, int signal)
{
    require(getuid() == targetUid && getuid() != 0, "helper did not drop UID");
    if (test == "high-fds") {
        for (int fd : {64, 65, 66})
            require(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "helper retained a high descriptor");
        for (int fd : {0, 1, 2}) require(fcntl(fd, F_GETFD) >= 0, "helper closed standard stream");
    }
    if (test == "open") {
        int fd = open(fixture.c_str(), O_RDONLY);
        if (fd >= 0) close(fd);
        throw std::runtime_error("helper file open was not blocked by pledge");
    }
    if (test == "socket") {
        socket(AF_INET, SOCK_STREAM, 0);
        throw std::runtime_error("helper socket was not blocked by pledge");
    }
    static bool interrupted = false;
    if (test == "interrupted" && !interrupted) { interrupted = true; errno = EINTR; return -1; }
    if (test == "kill-error") { errno = EINVAL; return -1; }
    return kill(pid, signal);
}
namespace nix {
struct Error : std::runtime_error {
    template<class... A> Error(const char *message, A &&...) : std::runtime_error(message) {}
};
using SysError = Error;
template<class... A> static void debug(A &&...) {}
static const char *statusToString(int) { return "helper failed"; }
struct Pid {
    pid_t value;
    int wait()
    {
        int status;
        while (waitpid(value, &status, 0) == -1) require(errno == EINTR, "wait helper");
        helperStatus = status;
        return status;
    }
};
template<class F> static Pid startProcess(F function)
{
    pid_t child = fork();
    require(child >= 0, "fork helper");
    if (child == 0) {
        try { function(); }
        catch (const std::exception &) { _exit(1); }
        _exit(1);
    }
    return {child};
}
// KILL_USER
}
struct Children {
    std::vector<pid_t> pids;
    ~Children()
    {
        for (auto pid : pids) { kill(pid, SIGKILL); while (waitpid(pid, nullptr, 0) == -1 && errno == EINTR) {} }
    }
};
int main(int argc, char **argv)
try {
    require(argc == 4 && geteuid() == 0, "usage: probe CASE DIRECTORY USER (as root)");
    test = argv[1];
    fixture = std::filesystem::path(argv[2]) / "public";
    auto *account = getpwnam(argv[3]);
    require(account && account->pw_uid != 0, "build user lookup");
    targetUid = account->pw_uid;
    gid_t targetGid = account->pw_gid;
    struct rlimit core{0, 0};
    require(setrlimit(RLIMIT_CORE, &core) == 0, "disable cores");
    int file = open(fixture.c_str(), O_RDWR | O_CREAT, 0644);
    require(file >= 0 && chmod(argv[2], 0755) == 0, "public fixture");
    close(file);
    Children children;
    bool expectedFailure = test == "open" || test == "socket" || test == "pledge-failure" || test == "kill-error";
    for (int i = 0; i < (test == "empty" ? 1 : 4); ++i) {
        int ready[2]; require(pipe(ready) == 0, "worker ready pipe");
        pid_t pid = fork(); require(pid >= 0, "fork worker");
        if (pid == 0) {
            close(ready[0]);
            if (i != 0) {
                require(setgroups(0, nullptr) == 0 && setgid(targetGid) == 0 && setuid(targetUid) == 0, "worker UID");
                if (test == "detached") require(setsid() >= 0, "worker session");
            }
            require(write(ready[1], "x", 1) == 1, "worker readiness");
            close(ready[1]);
            if (test == "stopped" && i != 0) raise(SIGSTOP);
            for (;;) pause();
        }
        children.pids.push_back(pid);
        close(ready[1]); char byte; require(read(ready[0], &byte, 1) == 1, "worker started"); close(ready[0]);
        if (test == "stopped" && i != 0) {
            int status;
            require(waitpid(pid, &status, WUNTRACED) == pid && WIFSTOPPED(status), "worker did not stop");
        }
    }
    if (test == "high-fds") {
        int descriptors[] = {open(fixture.c_str(), O_RDONLY), open("/", O_RDONLY | O_DIRECTORY), socket(AF_INET, SOCK_STREAM, 0)};
        for (int i = 0; i < 3; ++i) { require(descriptors[i] >= 0 && dup2(descriptors[i], 64 + i) == 64 + i, "high descriptor"); close(descriptors[i]); }
        struct rlimit limit; require(getrlimit(RLIMIT_NOFILE, &limit) == 0, "read descriptor limit");
        limit.rlim_cur = 16; require(setrlimit(RLIMIT_NOFILE, &limit) == 0, "lower descriptor limit");
    }
    bool failed = false;
    try { nix::killUser(targetUid); }
    catch (const nix::Error &) { failed = true; }
    require(failed == expectedFailure, "missing or unexpected helper failure");
    if (test == "open" || test == "socket")
        require(WIFSIGNALED(helperStatus) && WTERMSIG(helperStatus) == SIGABRT,
                "forbidden helper API did not trigger pledge");
    require(kill(children.pids[0], 0) == 0, "helper killed another UID");
    if (!expectedFailure) {
        for (size_t i = 1; i < children.pids.size(); ++i) {
            int status;
            require(waitpid(children.pids[i], &status, 0) == children.pids[i], "reap killed worker");
            require(WIFSIGNALED(status) && WTERMSIG(status) == SIGKILL, "worker survived helper");
        }
        children.pids.resize(1);
    }
    require(getuid() == 0, "helper changed parent's UID");
    file = open(fixture.c_str(), O_RDONLY); require(file >= 0, "helper restricted parent paths"); close(file);
    file = socket(AF_INET, SOCK_STREAM, 0); require(file >= 0, "helper restricted parent sockets"); close(file);
    if (test == "high-fds") for (int fd : {64, 65, 66}) require(fcntl(fd, F_GETFD) >= 0, "helper closed parent descriptor");
    return 0;
} catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
}
