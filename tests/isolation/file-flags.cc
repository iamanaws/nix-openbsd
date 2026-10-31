/* Compile the patch's traversal and lifecycle guard with small utility adapters. */
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/file.h>
#include <dirent.h>
#include <fcntl.h>
#include <grp.h>
#include <pwd.h>
#include <unistd.h>
#include <cerrno>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <optional>
#include <vector>

namespace fs = std::filesystem;
static void require(bool condition, const char *message)
{
    if (!condition) throw std::runtime_error(message);
}
static void put(const fs::path &path)
{
    std::ofstream file(path);
    file << "flagged fixture\n";
    file.close();
    require(bool(file), "write fixture");
}
static struct stat info(const fs::path &path)
{
    struct stat st;
    require(lstat(path.c_str(), &st) == 0, "stat fixture");
    return st;
}
static void flags(const fs::path &path, unsigned value)
{
    require(chflagsat(AT_FDCWD, path.c_str(), value, AT_SYMLINK_NOFOLLOW) == 0, "set fixture flags");
}
static bool failClear = false;
static bool failStop = false;
static uid_t stoppedUID = 0;
static int probeChflagsat(int fd, const char *name, unsigned value, int options)
{
    if (failClear) { errno = EIO; return -1; }
    return chflagsat(fd, name, value, options);
}
struct FixturesCleanup {
    fs::path work;
    ~FixturesCleanup()
    {
        for (auto &entry : fs::recursive_directory_iterator(work))
            chflagsat(AT_FDCWD, entry.path().c_str(), 0, AT_SYMLINK_NOFOLLOW);
    }
};

namespace nix {
struct AutoCloseFD {
    int fd;
    AutoCloseFD(int value = -1) : fd(value) {}
    AutoCloseFD(const AutoCloseFD &) = delete;
    AutoCloseFD &operator=(AutoCloseFD &&other)
    {
        if (fd != -1) close(fd);
        fd = other.release();
        return *this;
    }
    ~AutoCloseFD() { if (fd != -1) close(fd); }
    int get() const { return fd; }
    int release() { int value = fd; fd = -1; return value; }
    explicit operator bool() const { return fd != -1; }
};
struct AutoCloseDir {
    DIR *directory;
    AutoCloseDir(DIR *value) : directory(value) {}
    ~AutoCloseDir() { if (directory) closedir(directory); }
    DIR *get() const { return directory; }
    explicit operator bool() const { return directory; }
};
struct SysError : std::runtime_error {
    template<class... A> SysError(const char *message, A &&...) : std::runtime_error(message) {}
};
static const fs::path &PathFmt(const fs::path &path) { return path; }
static void checkInterrupt() {}
static struct stat fstatat(int fd, const fs::path &path)
{
    struct stat st;
    require(::fstatat(fd, path.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0, "stat cleanup entry");
    return st;
}
struct BuildUser {
    uid_t uid;
    uid_t getUID() const { return uid; }
};
static AutoCloseFD openLockFile(const fs::path &path, bool)
{
    int fd = open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    require(fd != -1, "open recovery lock");
    return fd;
}
static constexpr int ltWrite = LOCK_EX;
static bool lockFile(int fd, int operation, bool wait)
{
    return flock(fd, operation | (wait ? 0 : LOCK_NB)) == 0;
}
using Strings = std::vector<std::string>;
struct Error : std::runtime_error {
    template<class... A> Error(const char *message, A &&...) : std::runtime_error(message) {}
};
static struct stat fstat(int fd)
{
    struct stat st;
    require(::fstat(fd, &st) == 0, "stat recovery descriptor");
    return st;
}
struct ChrootOpenBSDDerivationBuilder {
    bool autoDelChroot = true;
    fs::path chrootRootDir;
    BuildUser *buildUser;
    fs::path drvPath;
    struct {
        std::string toRealPath(const fs::path &path) { return path; }
    } store;
    struct {
        struct {
            const std::string &get() { static const std::string group = "nixbld"; return group; }
        } buildUsersGroup;
    } localSettings;
    struct { fs::path nixStateDir; } settings;
    void clearBuildFileFlags();
    void recoverChroot();
    static void stopBuildUser(uid_t uid, gid_t)
    {
        if (failStop) throw Error("injected process cleanup failure");
        stoppedUID = uid;
    }
};
// FILE_FLAGS
// RECOVERY
}

int main(int argc, char **argv)
try {
    require(argc == 4 && geteuid() == 0, "usage: probe CASE DIRECTORY USER (as root)");
    std::string test = argv[1];
    fs::path work = fs::canonical(argv[2]), outside = work / "outside";
    bool recovery = test.starts_with("recover-");
    fs::path parent = work / "derivation.chroot", root = recovery ? parent / "root" : work / "root";
    FixturesCleanup cleanup{work};
    auto *account = getpwnam(argv[3]);
    require(account && account->pw_uid != 0, "build user lookup");
    nix::BuildUser user{account->pw_uid};
    gid_t gid = account->pw_gid;
    fs::create_directories(root / "build");
    fs::create_directory(outside);
    put(outside / "private");
    require(chown((outside / "private").c_str(), user.uid, gid) == 0, "outside fixture owner");
    flags(outside / "private", UF_IMMUTABLE);
    put(outside / "input");
    fs::create_hard_link(outside / "input", root / "input");
    flags(outside / "input", UF_NODUMP);
    require(chown((root / "build").c_str(), user.uid, gid) == 0, "build directory owner");
    nix::ChrootOpenBSDDerivationBuilder builder;
    builder.chrootRootDir = root;
    builder.buildUser = &user;
    builder.drvPath = work / "derivation";
    builder.settings.nixStateDir = work / "state";
    auto *otherAccount = getpwnam("nixbld2");
    require(otherAccount && otherAccount->pw_uid != user.uid, "other build user lookup");
    nix::BuildUser other{otherAccount->pw_uid};
    if (recovery) {
        require(chmod(parent.c_str(), 0700) == 0, "private recovery parent");
        require(chown(root.c_str(), 0, gid) == 0, "recovery root owner");
        fs::create_directories(work / "state/userpool");
        if (test == "recover-other-user" || test == "recover-busy") builder.buildUser = &other;
    }
    bool inactive = test == "inactive", badRoot = test == "root-symlink";
    if (inactive) builder.autoDelChroot = false;
    if (inactive || badRoot) {
        fs::create_directory_symlink(outside, work / "root-link");
        builder.chrootRootDir = work / "root-link";
    }

    pid_t child = fork();
    require(child >= 0, "fork builder");
    if (child == 0) {
        require(chroot(root.c_str()) == 0 && chdir("/build") == 0, "enter build root");
        closefrom(3);
        require(setgroups(0, nullptr) == 0 && setgid(gid) == 0 && setuid(user.uid) == 0, "build credentials");
        if (test == "symlink" || test == "symlink-directory" || test == "dangling") {
            fs::create_symlink(test == "symlink-directory" ? outside
                : test == "dangling" ? outside / "missing" : outside / "private", "entry");
        } else if (test == "fifo") {
            require(mkfifo("entry", 0600) == 0, "create FIFO");
        } else {
            put("entry");
        }
        if (test == "hardlinks") fs::create_hard_link("entry", "alias");
        flags("entry", test == "append" ? UF_APPEND : test == "nodump" ? UF_NODUMP : UF_IMMUTABLE);
        if (test == "directory-immutable" || test == "directory-append") {
            require(chmod("/build", 0000) == 0, "inaccessible directory");
            flags("/build", test == "directory-immutable" ? UF_IMMUTABLE : UF_APPEND);
        }
        _exit(0);
    }
    int status;
    while (waitpid(child, &status, 0) == -1) require(errno == EINTR, "wait builder");
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0, "builder failed to set flags");
    if (test == "foreign-input") flags(outside / "input", UF_IMMUTABLE);
    auto original = info(root / "build");
    auto input = info(outside / "input");
    failClear = test == "clear-error" || test == "recover-clear-error";
    failStop = test == "recover-stop-error";
    nix::AutoCloseFD held(-1);
    if (test == "recover-busy") {
        held.fd = nix::openLockFile(work / "state/userpool" / std::to_string(user.uid), true).release();
        require(flock(held.fd, LOCK_EX | LOCK_NB) == 0, "hold old build user lock");
    }
    if (test == "recover-parent-owner") require(chown(parent.c_str(), user.uid, gid) == 0, "unsafe parent owner");
    if (test == "recover-parent-mode") require(chmod(parent.c_str(), 0755) == 0, "unsafe parent mode");
    if (test == "recover-root-owner") require(chown(root.c_str(), user.uid, gid) == 0, "unsafe root owner");
    if (test == "recover-root-mode") require(chmod(root.c_str(), 0770) == 0, "unsafe root mode");
    if (test == "recover-unknown-group") require(chown(root.c_str(), 0, 65534) == 0, "unknown root group");
    if (test == "recover-shared-group") require(chown(root.c_str(), 0, getgrnam("nixbld")->gr_gid) == 0, "shared root group");
    bool skipped = test == "recover-missing-parent" || test == "recover-missing-root" || test == "recover-incomplete";
    if (test == "recover-incomplete") require(chown(root.c_str(), 0, 0) == 0, "incomplete root owner");
    bool replaced = test == "recover-root-symlink" || test == "recover-parent-symlink";
    bool missing = test == "recover-missing-parent" || test == "recover-missing-root";
    fs::path replacedPath = test == "recover-parent-symlink" || test == "recover-missing-parent" ? parent : root;
    if (replaced || missing) {
        fs::rename(replacedPath, work / "original");
        if (replaced) fs::create_directory_symlink(outside, replacedPath);
    }
    bool failed = false;
    try {
        if (recovery) builder.recoverChroot();
        else builder.clearBuildFileFlags();
    }
    catch (const nix::SysError &) { failed = true; }
    catch (const nix::Error &) { failed = true; }
    bool rejected = recovery && !skipped && test != "recover-current-user" && test != "recover-other-user";
    require(failed == (badRoot || failClear || rejected), "missing or unexpected cleanup failure");
    if (replaced || missing) {
        if (replaced) fs::remove(replacedPath);
        fs::rename(work / "original", replacedPath);
    }
    if (recovery) {
        bool stopped = (!rejected && !skipped) || failClear;
        require(stoppedUID == (stopped ? user.uid : 0), "stopped the wrong build user or stopped before validation");
        if (rejected || skipped) require(info(root / "build/entry").st_flags == UF_IMMUTABLE, "changed flags after rejected recovery");
    }
    require(info(outside / "private").st_flags == UF_IMMUTABLE, "followed a symlink outside the root");
    require(info(outside / "input").st_flags == input.st_flags, "changed a shared input inode");
    require(info(root / "build").st_mode == original.st_mode, "changed directory permissions");
    if (!failed && !inactive && !skipped) {
        require(info(root / "build/entry").st_flags == 0 && info(root / "build").st_flags == 0,
                "builder flags survived cleanup");
        if (test == "hardlinks") require(info(root / "build/alias").st_flags == 0, "hardlink flags survived");
        if (S_ISREG(info(root / "build/entry").st_mode)) {
            require(chmod((root / "build/entry").c_str(), 0444) == 0, "output chmod blocked");
            require(lchown((root / "build/entry").c_str(), 0, 0) == 0, "output chown blocked");
        }
        fs::rename(root / "build", work / "kept");
        fs::remove_all(work / "kept");
    } else {
        // Restore the fixtures after the negative controls.
        flags(root / "build/entry", 0);
    }
    flags(outside / "private", 0);
    flags(outside / "input", 0);
    fs::remove_all(root);
    return 0;
} catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
}
