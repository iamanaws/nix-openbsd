/* Extract both cleanup methods. Utility adapters use the same filesystem;
   the chroot adapter has no pending outputs and deletes the private root. */
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <unistd.h>
#include <cerrno>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <optional>
#include <stdexcept>

namespace fs = std::filesystem;
static void require(bool condition, const char *message)
{
    if (!condition) throw std::runtime_error(message);
}
static void put(const fs::path &path, const char *text)
{
    std::ofstream file(path);
    file << text;
    file.close();
    require(bool(file), "write fixture");
}
static mode_t mode(const fs::path &path)
{
    struct stat st;
    require(::stat(path.c_str(), &st) == 0, "fixture stat");
    return st.st_mode & 07777;
}

namespace nix {
struct AutoCloseFD {
    int fd = -1;
    ~AutoCloseFD() { close(); }
    int get() const { return fd; }
    explicit operator bool() const { return fd != -1; }
    void close() { if (fd != -1) ::close(fd); fd = -1; }
};
std::optional<struct stat> maybeLstat(const fs::path &path)
{
    struct stat st;
    if (::lstat(path.c_str(), &st) == 0) return st;
    require(errno == ENOENT, "lstat build directory");
    return {};
}
struct stat fstat(int fd)
{
    struct stat st;
    require(::fstat(fd, &st) == 0, "stat original directory");
    return st;
}
bool pathExists(const fs::path &path) { return fs::exists(path); }
static void chmod(const fs::path &path, mode_t value)
{
    require(::chmod(path.c_str(), value) == 0, "chmod cleanup path");
}
static void deletePath(const fs::path &path) { fs::remove_all(path); }
static void moveFile(const fs::path &source, const fs::path &target) { fs::rename(source, target); }
static const fs::path &PathFmt(const fs::path &path) { return path; }
static void printError(const char *, const fs::path &) {}
static unsigned warnings = 0;
void warn(const char *, const fs::path &) { ++warnings; }

struct DerivationBuilderImpl {
    struct { bool keepFailed = true; } settings;
    struct {
        bool builtin = false;
        bool isBuiltin() const { return builtin; }
    } drv;
    struct { fs::path toRealPath(const fs::path &path) { return path; } } store;
    fs::path tmpDir, topTmpDir, chrootRootDir;
    AutoCloseFD tmpDirFd;
    std::map<std::string, fs::path> redirectedOutputs;
    void cleanupBuild(bool force);
};
// BASE_CLEANUP

struct ChrootDerivationBuilder : DerivationBuilderImpl {
    void cleanupBuild(bool force)
    {
        DerivationBuilderImpl::cleanupBuild(force);
        fs::remove_all(chrootRootDir.parent_path());
    }
};
struct ChrootOpenBSDDerivationBuilder : ChrootDerivationBuilder {
    bool buildUser = true, failStop = false;
    unsigned stopCalls = 0;
    unsigned routingDomain = 0;
    bool processesStopped = true;
    AutoCloseFD routingDomainLock;
    void killSandbox(bool)
    {
        ++stopCalls;
        if (failStop) throw std::runtime_error("injected process cleanup failure");
        processesStopped = true;
    }
    AutoCloseFD networkSocket() { throw std::runtime_error("unexpected routing socket"); }
    void destroyDomain(int, unsigned) { throw std::runtime_error("unexpected routing cleanup"); }
    void cleanupBuild(bool force);
};
// OPENBSD_CLEANUP
}

int main(int argc, char **argv)
try {
    require(argc == 4 && geteuid() == 0, "usage: probe CASE DIRECTORY USER (as root)");
    std::string test = argv[1];
    fs::path work = fs::canonical(argv[2]);
    auto *account = getpwnam(argv[3]);
    require(account && account->pw_uid != 0, "build user lookup");
    uid_t uid = account->pw_uid;
    gid_t gid = account->pw_gid;
    nix::ChrootOpenBSDDerivationBuilder builder;
    builder.chrootRootDir = work / "jail/root";
    builder.topTmpDir = work / "top";
    builder.tmpDir = builder.chrootRootDir / "tmp/nix-build";
    fs::create_directories(builder.tmpDir);
    fs::create_directory(builder.topTmpDir);
    nix::chmod(builder.chrootRootDir.parent_path(), 0700);
    nix::chmod(builder.topTmpDir, 0700);
    nix::chmod(builder.tmpDir.parent_path(), 01777);
    nix::chmod(builder.tmpDir, 0700);
    require(chown(builder.tmpDir.c_str(), uid, gid) == 0, "build directory owner");
    builder.tmpDirFd.fd = open(builder.tmpDir.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    require(bool(builder.tmpDirFd), "open original build directory");
    auto victim = work / "host-private", hostDirectory = work / "host-directory";
    put(victim, "private fixture\n");
    nix::chmod(victim, 0600);
    fs::create_directory(hostDirectory);
    nix::chmod(hostDirectory, 0700);

    pid_t child = fork();
    require(child >= 0, "fork builder");
    if (child == 0) {
        require(chroot(builder.chrootRootDir.c_str()) == 0 && chdir("/") == 0, "enter build root");
        closefrom(3);
        require(setgroups(0, nullptr) == 0 && setgid(gid) == 0 && setuid(uid) == 0, "build credentials");
        put("/tmp/nix-build/kept", "original build\n");
        if (test != "keep" && test != "unopened" && test != "stop-first" && test != "stop-failure") {
            fs::rename("/tmp/nix-build", "/tmp/original");
            if (test == "replaced-directory") fs::create_directory("/tmp/nix-build");
            else if (test == "regular-file") put("/tmp/nix-build", "replacement\n");
            else if (test != "missing") {
                auto target = test == "symlink-directory" ? hostDirectory
                    : test == "symlink-original" ? builder.chrootRootDir / "tmp/original"
                    : test == "dangling" ? work / "nonexistent" : victim;
                fs::create_symlink(target, "/tmp/nix-build");
            }
        }
        _exit(0);
    }
    int status;
    while (waitpid(child, &status, 0) == -1) require(errno == EINTR, "wait builder");
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0, "builder failed to replace its directory");
    if (test == "unopened") builder.tmpDirFd.close();
    builder.settings.keepFailed = test != "disabled";
    builder.drv.builtin = test == "builtin";
    if (test == "stop-first" || test == "stop-failure") builder.processesStopped = false;
    if (test == "stop-failure") {
        builder.failStop = true;
        bool failed = false;
        try { builder.cleanupBuild(false); }
        catch (const std::runtime_error &) { failed = true; }
        require(failed && fs::exists(builder.tmpDir / "kept") && !fs::exists(work / "top/build"),
                "cleanup touched a build directory before processes stopped");
        builder.failStop = false;
    }
    builder.cleanupBuild(test == "force");
    require(builder.stopCalls == (test == "stop-first" ? 1u : test == "stop-failure" ? 2u : 0u),
            "process cleanup skipped or repeated after completion");
    require(mode(victim) == 0600 && mode(hostDirectory) == 0700, "host permissions changed during cleanup");
    require(!fs::exists(work / "jail"), "sandbox root was retained");
    if (test == "keep" || test == "stop-first" || test == "stop-failure") {
        require(fs::is_regular_file(work / "top/build/kept"), "original build directory was lost");
        require(mode(work / "top/build") == 0755 && nix::warnings == 0, "retained directory permissions");
    } else {
        require(!fs::exists(work / "top"), "removed or replaced build directory was retained");
        bool warn = test != "force" && test != "disabled" && test != "builtin";
        require(nix::warnings == unsigned(warn), "missing or unexpected cleanup warning");
    }
    return 0;
} catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
}
