/* Compile the patch's traversal and lifecycle guard with small utility adapters. */
#include <sys/stat.h>
#include <sys/wait.h>
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
    AutoCloseFD(int value) : fd(value) {}
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
struct ChrootOpenBSDDerivationBuilder {
    bool autoDelChroot = true;
    fs::path chrootRootDir;
    BuildUser *buildUser;
    void clearBuildFileFlags();
};
// FILE_FLAGS
}

int main(int argc, char **argv)
try {
    require(argc == 4 && geteuid() == 0, "usage: probe CASE DIRECTORY USER (as root)");
    std::string test = argv[1];
    fs::path work = fs::canonical(argv[2]), root = work / "root", outside = work / "outside";
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
    nix::ChrootOpenBSDDerivationBuilder builder{true, root, &user};
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
    failClear = test == "clear-error";
    bool failed = false;
    try { builder.clearBuildFileFlags(); }
    catch (const nix::SysError &) { failed = true; }
    require(failed == (badRoot || failClear), "missing or unexpected cleanup failure");
    require(info(outside / "private").st_flags == UF_IMMUTABLE, "followed a symlink outside the root");
    require(info(outside / "input").st_flags == input.st_flags, "changed a shared input inode");
    require(info(root / "build").st_mode == original.st_mode, "changed directory permissions");
    if (!failed && !inactive) {
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
