/* Exercise patch-extracted helpers and launcher policy with native syscalls.
   Nix utilities, process wrappers and error reporting use small adapters. */
#include <sys/types.h>
#include <sys/ipc.h>
#include <sys/msg.h>
#include <sys/resource.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <signal.h>
#include <termios.h>
#include <unistd.h>
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include "sysv-ipc.hh"
#include "nix/util/error.hh"

using namespace nix;
static std::string test;
static const char *path;
static const char *image;
static const char *user;
extern char **environ;
static int failUnveilCall = 0, unveilCalls = 0;

int descriptorClosefrom(int first)
{
    static bool interrupted = false;
    if (test == "fds-interrupted" && !interrupted) {
        interrupted = true;
        errno = EINTR;
        return -1;
    }
    return closefrom(first);
}

#define HAVE_SYSCONF 1
namespace nix {
namespace unix { void closeExtraFDs(); }
// CLOSE_EXTRA_FDS
}

int policyUnveil(const char *name, const char *permissions)
{
    if (++unveilCalls == failUnveilCall) {
        errno = ENOMEM;
        return -1;
    }
    return unveil(name, permissions);
}

int policyPledge(const char *promises, const char *execpromises)
{
    if (test == "launcher-pledge-failure") {
        errno = EPERM;
        return -1;
    }
    return pledge(promises, execpromises);
}

static void require(bool condition, const char *message)
{
    if (!condition) throw std::runtime_error(message);
}

static void writeAll(int fd, const std::string &data)
{
    size_t offset = 0;
    while (offset < data.size()) {
        auto count = write(fd, data.data() + offset, data.size() - offset);
        if (count == -1 && errno == EINTR) continue;
        require(count > 0, "write");
        offset += count;
    }
}

static int waitFor(pid_t pid)
{
    int status;
    while (waitpid(pid, &status, 0) == -1)
        require(errno == EINTR, "waitpid");
    return status;
}

static void challenge()
{
    if (test == "pty-paths")
        require(open(path, O_RDONLY) == -1 && errno == ENOENT, "supervisor can open host file");
    if (test == "pty-lock")
        require(unveil(path, "r") == -1 && errno == EPERM, "supervisor can expand unveil");
    if (test == "pty-fds" || test == "pty-highfd")
        require(fcntl(64, F_GETFD) == -1 && errno == EBADF, "supervisor inherited open file");
    if (test == "pty-pledge-drain")
        require(pledge("stdio tty", nullptr) == 0, "pledge supervisor");
}

static void ignoreSignal(int) {}

static void lowerDescriptorLimit()
{
    struct rlimit limit;
    require(getrlimit(RLIMIT_NOFILE, &limit) == 0, "get descriptor limit");
    limit.rlim_cur = 16;
    require(setrlimit(RLIMIT_NOFILE, &limit) == 0, "lower descriptor limit");
}

static void handleChildException(bool)
{
    try { throw; }
    catch (const std::exception &error) { std::cerr << error.what() << '\n'; }
}

static void postExec(const char *behavior = "", const char *argument = nullptr);

static void checkDescriptors()
{
    for (int fd : {3, 4, 5, 64, 65, 66, 67})
        require(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "extra descriptor survived cleanup");
    for (int fd : {0, 1, 2}) {
        if (fd == 0 && test == "fds-closed-stdin")
            require(fcntl(fd, F_GETFD) == -1 && errno == EBADF, "closed stdin was reopened");
        else require(fcntl(fd, F_GETFD) >= 0, "standard descriptor was closed");
    }
}

static void descriptorProbe()
{
    if (test == "fds-after-exec") { checkDescriptors(); return; }
    closefrom(3);
    int file = open(path, O_RDONLY);
    int directory = open(".", O_RDONLY | O_DIRECTORY);
    int network = socket(AF_INET, SOCK_STREAM, 0);
    require(file == 3 && directory == 4 && network == 5, "descriptor fixtures");
    require(dup2(file, 64) == 64 && dup2(file, 65) == 65
            && dup2(directory, 66) == 66 && dup2(network, 67) == 67,
            "high descriptor fixtures");
    require(fcntl(65, F_SETFD, FD_CLOEXEC) == 0, "close-on-exec fixture");
    if (test != "fds-ordinary" && test != "fds-empty") {
        struct rlimit limit;
        require(getrlimit(RLIMIT_NOFILE, &limit) == 0, "get descriptor limit");
        limit.rlim_cur = 16;
        if (test == "fds-hard-limit") limit.rlim_max = 16;
        require(setrlimit(RLIMIT_NOFILE, &limit) == 0, "lower descriptor limit");
        require(sysconf(_SC_OPEN_MAX) == 16 && fcntl(64, F_GETFD) >= 0,
                "high descriptor must survive lowering limit");
    }
    if (test == "fds-closed-stdin") close(0);
    if (test == "fds-chroot") {
        require(mkdir("root", 0755) == 0, "create empty root");
        require(chroot("root") == 0 && chdir("/") == 0, "enter empty root");
        require(open(path, O_RDONLY) == -1 && errno == ENOENT, "fixture visible inside root");
    }
    nix::unix::closeExtraFDs();
    if (test == "fds-empty") nix::unix::closeExtraFDs();
    if (test == "fds-chroot") {
        require(fchdir(66) == -1 && errno == EBADF, "host directory survived chroot cleanup");
        char byte;
        require(read(64, &byte, 1) == -1 && errno == EBADF, "host file survived chroot cleanup");
    }
    if (test == "fds-exec") {
        require(pledge("stdio exec", nullptr) == 0, "pledge descriptor launcher");
        execl(image, image, "fds-after-exec", path, user, nullptr);
        throw SysError("exec descriptor probe");
    }
    checkDescriptors();
}

static pid_t workerFork()
{
    if (test == "pty-fork-failure") {
        errno = EAGAIN;
        return -1;
    }
    pid_t child = fork();
    if (child > 0 && test == "pty-prelocked")
        require(unveil(nullptr, nullptr) == 0, "prelock supervisor");
    return child;
}

static void launcher()
{
    // LAUNCHER_POLICY
    if (test == "launcher-open") (void) open(path, O_RDONLY);
    else if (test == "launcher-socket") (void) socket(AF_INET, SOCK_STREAM, 0);
    else if (test == "launcher-fork") {
        if (fork() == 0) _exit(0);
    } else {
        bool payload = test == "launcher-payload";
        std::string argument(payload ? 65536 : test == "launcher-too-large" ? 1024 * 1024 : 0, 'a');
        std::string environment = "LAUNCH_PROBE=" + std::string(65536, 'e');
        char *arguments[] = {const_cast<char *>(image), const_cast<char *>("post-exec"),
                             const_cast<char *>(path), const_cast<char *>(user), test.data(),
                             argument.empty() ? nullptr : argument.data(), nullptr};
        char *environmentStrings[] = {environment.data(), nullptr};
        std::string target = image;
        int expected = 0;
        if (test == "launcher-missing") { target = "/no-such-nix-builder"; expected = ENOENT; }
        if (test == "launcher-denied") { target = std::string(path) + ".denied"; expected = EACCES; }
        if (test == "launcher-format") { target = std::string(path) + ".format"; expected = ENOEXEC; }
        if (test == "launcher-interpreter") { target = std::string(path) + ".interpreter"; expected = ENOENT; }
        if (test == "launcher-script") target = std::string(path) + ".script";
        if (test == "launcher-too-large") expected = E2BIG;
        execve(target.c_str(), arguments, payload ? environmentStrings : environ);
        require(expected && errno == expected, "builder exec errno");
        throw SysError(std::string("executing builder: ") + strerror(errno));
    }
    _exit(97);
}

static void ptyProbe()
{
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    require(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0, "PTY master");
    int slave = open(ptsname(master), O_RDWR | O_NOCTTY);
    require(slave >= 0, "PTY slave");
    struct termios term;
    require(tcgetattr(slave, &term) == 0, "tcgetattr");
    cfmakeraw(&term);
    require(tcsetattr(slave, TCSANOW, &term) == 0, "tcsetattr");
    std::string payload(test == "pty-output" ? 1024 * 1024 : 32, 'x');
    pid_t supervisor = fork();
    require(supervisor >= 0, "fork supervisor");
    if (supervisor == 0) {
        require(dup2(slave, 0) == 0 && dup2(slave, 1) == 1 && dup2(slave, 2) == 2, "dup slave");
        closefrom(3);
        int inherited = open(path, O_RDONLY);
        require(inherited >= 0 && dup2(inherited, 64) == 64, "supervisor inherited fixture");
        close(inherited);
        if (test == "pty-highfd") lowerDescriptorLimit();
        struct passwd *account = getpwnam(user);
        require(account && account->pw_uid != 0, "PTY build user");
        require(setgroups(0, nullptr) == 0 && setgid(account->pw_gid) == 0
                && setuid(account->pw_uid) == 0, "PTY credentials");
        if (test == "pty-interrupt") {
            struct sigaction action{};
            action.sa_handler = ignoreSignal;
            sigemptyset(&action.sa_mask);
            require(sigaction(SIGALRM, &action, nullptr) == 0, "sigaction");
            struct itimerval timer{{0, 1000}, {0, 1000}};
            require(setitimer(ITIMER_REAL, &timer, nullptr) == 0, "setitimer");
        }
        bool sendException = false;
        // SUPERVISION_STATE
        try {
            // SUPERVISOR
            close(64);
            if (test.starts_with("launcher-")) launcher();
            if (test == "pty-builtin") { postExec(); _exit(0); }
            if (test == "pty-interrupt") usleep(100000);
            // The real builder child must retain APIs forbidden to its supervisor.
            int fd = open(path, O_RDONLY);
            require(fd >= 0, "worker inherited supervisor policy");
            close(fd);
            writeAll(2, payload);
            if (test == "pty-signal") raise(SIGUSR1);
            _exit(test == "pty-exit" ? 37 : 0);
        // CHILD_CATCH
    }
    close(slave);
    std::string output;
    char buffer[8192];
    for (;;) {
        auto count = read(master, buffer, sizeof(buffer));
        if (count == -1 && errno == EINTR) continue;
        if (count == -1 && errno == EIO) break;
        require(count >= 0, "read master");
        if (!count) break;
        output.append(buffer, count);
    }
    close(master);
    int status = waitFor(supervisor);
    if (test == "pty-pledge-drain"
        || test == "launcher-open" || test == "launcher-socket" || test == "launcher-fork")
        require(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT,
                "expected pledge violation missing");
    else if (test == "pty-fail-rule" || test == "pty-fail-lock" || test == "pty-prelocked") {
        require(WIFEXITED(status) && WEXITSTATUS(status) == 1, "unveil failure was ignored");
        require(output.find("restricting OpenBSD builder supervisor") != std::string::npos,
                "unveil setup error was lost");
    } else if (test == "pty-fork-failure") {
        require(WIFEXITED(status) && WEXITSTATUS(status) == 1, "fork failure status");
        require(output.find("forking OpenBSD builder") != std::string::npos, "fork error output lost");
    } else if (test == "launcher-missing" || test == "launcher-denied" || test == "launcher-format"
               || test == "launcher-interpreter" || test == "launcher-too-large") {
        require(WIFEXITED(status) && WEXITSTATUS(status) == 1, "exec failure status");
        require(output.starts_with("executing builder: "), "exec failure output lost");
    } else if (test == "launcher-pledge-failure") {
        require(WIFEXITED(status) && WEXITSTATUS(status) == 1, "pledge failure was ignored");
        require(output.find("restricting OpenBSD builder launcher") != std::string::npos,
                "pledge setup error was lost");
    } else {
        if (test == "pty-signal" || test == "launcher-signal")
            require(WIFSIGNALED(status) && WTERMSIG(status) == SIGUSR1, "signal forwarding");
        else require(WIFEXITED(status) && WEXITSTATUS(status) ==
                     (test == "pty-exit" || test == "launcher-exit" ? 37 : 0),
                     "exit forwarding");
        if (test == "launcher-output") payload.assign(1024 * 1024, 'x');
        require(output == payload, ("PTY output lost or changed: " + output.substr(0, 512)).c_str());
    }
}

struct IPC {
    int shm = -1, msg = -1, sem = -1;
    void create()
    {
        shm = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600);
        msg = msgget(IPC_PRIVATE, IPC_CREAT | 0600);
        sem = semget(IPC_PRIVATE, 1, IPC_CREAT | 0600);
        require(shm >= 0 && msg >= 0 && sem >= 0, "create IPC");
    }
    void remove()
    {
        if (shm >= 0) shmctl(shm, IPC_RMID, nullptr);
        if (msg >= 0) msgctl(msg, IPC_RMID, nullptr);
        if (sem >= 0) semctl(sem, 0, IPC_RMID);
    }
    ~IPC() { remove(); }
    bool present()
    {
        struct shmid_ds a;
        struct msqid_ds b;
        struct semid_ds c;
        union { int val; struct semid_ds *buf; unsigned short *array; } argument;
        argument.buf = &c;
        return shmctl(shm, IPC_STAT, &a) == 0 && msgctl(msg, IPC_STAT, &b) == 0
            && semctl(sem, 0, IPC_STAT, argument) == 0;
    }
    bool removed()
    {
        return shmctl(shm, IPC_RMID, nullptr) == -1 && (errno == EINVAL || errno == EIDRM)
            && msgctl(msg, IPC_RMID, nullptr) == -1 && (errno == EINVAL || errno == EIDRM)
            && semctl(sem, 0, IPC_RMID) == -1 && (errno == EINVAL || errno == EIDRM);
    }
    void transfer(uid_t uid, gid_t gid)
    {
        struct shmid_ds a;
        struct msqid_ds b;
        struct semid_ds c;
        union { int val; struct semid_ds *buf; unsigned short *array; } argument;
        argument.buf = &c;
        require(shmctl(shm, IPC_STAT, &a) == 0 && msgctl(msg, IPC_STAT, &b) == 0
                && semctl(sem, 0, IPC_STAT, argument) == 0, "read IPC ownership");
        a.shm_perm.uid = b.msg_perm.uid = c.sem_perm.uid = uid;
        a.shm_perm.gid = b.msg_perm.gid = c.sem_perm.gid = gid;
        require(shmctl(shm, IPC_SET, &a) == 0 && msgctl(msg, IPC_SET, &b) == 0
                && semctl(sem, 0, IPC_SET, argument) == 0, "transfer IPC ownership");
    }
};

static void createOwnedIPC()
{
    IPC objects;
    objects.create();
    writeAll(1, std::to_string(objects.shm) + " " + std::to_string(objects.msg) + " "
             + std::to_string(objects.sem) + "\n");
    // Leave ownership to the actual cleanup function, including on test failure.
    objects.shm = objects.msg = objects.sem = -1;
}

static void checkCleanup()
{
    require(getuid() != 0 && getgid() != 0 && getgroups(0, nullptr) == 0, "cleanup credentials");
    if (test == "ipc-paths") {
        require(open(path, O_RDONLY) == -1 && errno == ENOENT, "cleanup can open host file");
        require(open((std::string(path) + "-new").c_str(), O_WRONLY | O_CREAT, 0600) == -1
                && (errno == ENOENT || errno == EACCES), "cleanup can create host file");
    }
    if (test == "ipc-lock")
        require(unveil(path, "r") == -1 && errno == EPERM, "cleanup can expand unveil");
    if (test == "ipc-fds" || test == "ipc-highfd")
        require(fcntl(64, F_GETFD) == -1 && errno == EBADF, "cleanup inherited open file");
}

static void ipcProbe(const char *user)
{
    struct passwd *account = getpwnam(user);
    require(account && account->pw_uid != 0 && account->pw_gid != 0, "build user lookup");
    struct BuildUser {
        uid_t uid; gid_t gid;
        uid_t getUID() { return uid; }
        gid_t getGID() { return gid; }
    } fixture{account->pw_uid, account->pw_gid};
    auto buildUser = &fixture;
    IPC controls;
    controls.create();
    int inherited = open(path, O_RDONLY);
    require(inherited >= 0 && dup2(inherited, 64) == 64, "inherited file fixture");
    close(inherited);
    int channel[2];
    require(pipe(channel) == 0, "IPC result pipe");
    pid_t child = fork();
    require(child >= 0, "fork cleanup");
    if (child == 0) {
        require(dup2(channel[1], 1) == 1, "redirect IPC IDs");
        if (test == "ipc-highfd") lowerDescriptorLimit();
        // IPC_CALLER
    }
    close(channel[1]);
    close(64);
    char data[128]{};
    auto length = read(channel[0], data, sizeof(data) - 1);
    close(channel[0]);
    int status = waitFor(child);
    IPC owned;
    require(length > 0 && sscanf(data, "%d %d %d", &owned.shm, &owned.msg, &owned.sem) == 3,
            "missing owned IPC IDs");
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0, "cleanup helper failed");
    require(owned.removed(), "owned IPC survived cleanup");
    require(controls.present(), "another UID's IPC was removed");
    int fd = open(path, O_RDONLY);
    require(fd >= 0, "helper policy affected parent");
    close(fd);
}

struct Pid {
    pid_t pid;
    int wait() { return waitFor(pid); }
};

template<class F> static Pid startProcess(F function)
{
    pid_t child = fork();
    require(child >= 0, "fork cleanup transaction");
    if (child == 0) {
        if (test == "ipc-prelocked") unveil(nullptr, nullptr);
        try { function(); }
        catch (const std::exception &error) { std::cerr << error.what() << '\n'; }
        _exit(1);
    }
    return {child};
}

static bool statusOk(int status) { return WIFEXITED(status) && WEXITSTATUS(status) == 0; }

struct BuildUser {
    uid_t uid; gid_t gid;
    uid_t getUID() { return uid; }
    gid_t getGID() { return gid; }
};

static bool fileFlagsCleared = false;
static void clearBuildFileFlags()
{
    if (test == "ipc-flags-failure") throw Error("injected file flag cleanup failure");
    fileFlagsCleared = true;
}

static void cleanupTransaction(BuildUser *buildUser, bool &processesStopped)
{
    bool live = false;
    // IPC_TRANSACTION
}

static void failureProbe()
{
    struct passwd *account = getpwnam(user);
    require(account && account->pw_uid != 0, "transaction build user");
    BuildUser buildUser{account->pw_uid, account->pw_gid};
    IPC owned;
    owned.create();
    owned.transfer(buildUser.uid, buildUser.gid);
    bool complete = false, failed = false;
    try { cleanupTransaction(&buildUser, complete); }
    catch (const Error &) { failed = true; }
    require(failed && !complete && !fileFlagsCleared, "failed cleanup marked complete");
    if (test == "ipc-flags-failure") require(owned.removed(), "IPC cleanup did not precede flag cleanup");
    else require(owned.present(), "failed unveil setup removed IPC");
    failUnveilCall = 0;
    test = "ipc-retry";
    cleanupTransaction(&buildUser, complete);
    require(complete && owned.removed() && fileFlagsCleared, "cleanup retry failed");
    int fd = open(path, O_RDONLY);
    require(fd >= 0, "failed helper policy affected parent");
    close(fd);
}

static void postExec(const char *behavior, const char *argument)
{
    int fd = open(path, O_RDONLY);
    require(fd >= 0, "exec retained launcher path restriction");
    close(fd);
    fd = socket(AF_INET, SOCK_STREAM, 0);
    require(fd >= 0, "exec retained launcher network restriction");
    close(fd);
    {
        IPC objects;
        objects.create();
    }
    if (std::string(behavior) == "launcher-payload") {
        const char *environment = getenv("LAUNCH_PROBE");
        require(argument && strlen(argument) == 65536 && environment && strlen(environment) == 65536,
                "argument or environment changed across exec");
    }
    writeAll(2, std::string(std::string(behavior) == "launcher-output" ? 1024 * 1024 : 32, 'x'));
    if (std::string(behavior) == "launcher-signal") raise(SIGUSR1);
    if (std::string(behavior) == "launcher-exit") _exit(37);
}

static void drainProbe()
{
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    require(master >= 0 && grantpt(master) == 0 && unlockpt(master) == 0, "drain master");
    int slave = open(ptsname(master), O_RDWR | O_NOCTTY);
    require(slave >= 0, "drain slave");
    struct termios saved, changed, after;
    require(tcgetattr(slave, &saved) == 0, "read drain attributes");
    if (test == "drain-attributes") {
        changed = saved;
        changed.c_lflag ^= ECHO;
        require(tcsetattr(slave, TCSANOW, &changed) == 0, "concurrent termios change");
    }
    require(pledge("stdio tty", nullptr) == 0, "pledge alternative drain");
    require(tcsetattr(slave, TCSADRAIN | TCSASOFT, &saved) == 0, "pledged TCSADRAIN");
    require(tcgetattr(slave, &after) == 0, "read final attributes");
    require(after.c_lflag == saved.c_lflag, "saved attributes were not restored");
    if (test == "drain-attributes")
        require(after.c_lflag != changed.c_lflag, "stale-attribute race not reproduced");
}

static void unveilProbe()
{
    int fd = open(path, O_RDONLY);
    int directory = open("/", O_RDONLY | O_DIRECTORY);
    require(fd >= 0 && directory >= 0, "unveil fixtures");
    if (test == "unveil-inherited-rule") require(unveil(path, "r") == 0, "inherited allow rule");
    if (test != "unveil-lock-only") require(unveil("/", "") == 0, "deny root");
    require(unveil(nullptr, nullptr) == 0, "lock unveil");
    if (test == "unveil-fork") {
        pid_t child = fork();
        require(child >= 0, "fork unveiled child");
        if (child != 0) {
            int status = waitFor(child);
            require(WIFEXITED(status) && WEXITSTATUS(status) == 0, "unveil fork inheritance");
            return;
        }
    }
    int opened = open(path, O_RDONLY);
    if (test == "unveil-lock-only" || test == "unveil-inherited-rule")
        require(opened >= 0, "existing visibility changed");
    else require(opened == -1 && errno == ENOENT, "deny rule left path visible");
    if (opened >= 0) close(opened);
    require(unveil(path, "r") == -1 && errno == EPERM, "unveil lock allowed expansion");
    if (test == "unveil-fds") {
        char byte;
        require(read(fd, &byte, 1) == 1, "unveil revoked preopened file");
        require(openat(directory, path + 1, O_RDONLY) == -1 && errno == ENOENT,
                "directory descriptor bypassed unveil");
    }
    if (test == "unveil-mutations") {
        std::string target = std::string(path) + "-new";
        require(unlink(path) == -1 && errno == ENOENT, "unveil allowed unlink");
        require(rename(path, target.c_str()) == -1 && errno == ENOENT, "unveil allowed rename");
        require(link(path, target.c_str()) == -1 && errno == ENOENT, "unveil allowed link");
        require(chmod(path, 0600) == -1 && errno == ENOENT, "unveil allowed chmod");
        require(open(target.c_str(), O_WRONLY | O_CREAT, 0600) == -1
                && (errno == ENOENT || errno == EACCES), "unveil allowed file creation");
    }
    if (test == "unveil-fork") _exit(0);
}

int main(int argc, char **argv)
try {
    require(argc >= 4, "usage: probe CASE FILE USER [BEHAVIOR [ARGUMENT]]");
    struct rlimit core{0, 0};
    require(setrlimit(RLIMIT_CORE, &core) == 0, "disable cores");
    test = argv[1];
    path = argv[2];
    image = argv[0];
    user = argv[3];
    if (test.ends_with("-fail-rule")) failUnveilCall = 1;
    if (test.ends_with("-fail-lock")) failUnveilCall = 2;
    if (test == "post-exec") postExec(argc >= 5 ? argv[4] : "", argc >= 6 ? argv[5] : nullptr);
    else if (test.starts_with("fds-")) descriptorProbe();
    else if (test.starts_with("pty-") || test.starts_with("launcher-")) ptyProbe();
    else if (test == "ipc-fail-rule" || test == "ipc-fail-lock" || test == "ipc-prelocked"
             || test == "ipc-flags-failure") failureProbe();
    else if (test.starts_with("ipc-")) ipcProbe(argv[3]);
    else if (test.starts_with("drain-")) drainProbe();
    else unveilProbe();
    return 0;
} catch (const std::exception &error) {
    std::cerr << error.what() << ": " << strerror(errno) << '\n';
    return 1;
}
