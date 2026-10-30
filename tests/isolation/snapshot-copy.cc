/* Standalone adapter for the materialise methods extracted from the patch.
   Nix utility shims keep the probe independent of a rebuilt Nix. */
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace fs = std::filesystem;
static std::function<void(const struct stat &, bool)> onStat;

namespace nix {
struct Error : std::runtime_error {
    template<class... Args> Error(const char *message, Args &&...) : std::runtime_error(message) {}
};
using SysError = Error;
struct AutoCloseFD {
    int fd;
    AutoCloseFD(int fd = -1) : fd(fd) {}
    AutoCloseFD(const AutoCloseFD &) = delete;
    AutoCloseFD(AutoCloseFD &&other) : fd(other.release()) {}
    ~AutoCloseFD() { if (fd != -1) ::close(fd); }
    int get() const { return fd; }
    int release() { int result = fd; fd = -1; return result; }
    explicit operator bool() const { return fd != -1; }
};
using AutoCloseDir = std::unique_ptr<DIR, decltype([](DIR *dir) { ::closedir(dir); })>;
struct CanonPath {
    fs::path path;
    explicit CanonPath(std::string_view path) : path(path) {}
    static CanonPath fromFilename(std::string_view name) { return CanonPath(name); }
};
AutoCloseFD openFileEnsureBeneathNoSymlinks(int fd, const CanonPath &path, int flags)
{
    AutoCloseFD current(::dup(fd));
    for (const auto &part : path.path.relative_path()) {
        int next = ::openat(current.get(), part.c_str(), flags | O_NOFOLLOW);
        if (next == -1) throw SysError("opening source parent");
        ::close(current.fd);
        current.fd = next;
    }
    return current;
}
void checkInterrupt() {}
std::string PathFmt(const fs::path &path) { return path.string(); }
struct stat lstat(const fs::path &path)
{
    struct stat st;
    if (::lstat(path.c_str(), &st)) throw SysError("lstat");
    if (auto callback = onStat) callback(st, false);
    return st;
}
std::optional<struct stat> maybeLstat(const fs::path &path)
{
    struct stat st;
    if (::lstat(path.c_str(), &st) == 0) return st;
    if (errno != ENOENT) throw SysError("lstat target");
    return {};
}
struct stat fstat(int fd)
{
    struct stat st;
    if (::fstat(fd, &st)) throw SysError("fstat");
    if (auto callback = onStat) callback(st, true);
    return st;
}
struct stat fstatat(int fd, const fs::path &path)
{
    struct stat st;
    if (::fstatat(fd, path.c_str(), &st, AT_SYMLINK_NOFOLLOW)) throw SysError("fstatat");
    if (auto callback = onStat) callback(st, false);
    return st;
}
void createDir(const fs::path &path, mode_t mode) { if (::mkdir(path.c_str(), mode)) throw SysError("mkdir"); }
void chmod(const fs::path &path, mode_t mode) { if (::chmod(path.c_str(), mode)) throw SysError("chmod"); }
void setWriteTime(const fs::path &, const struct stat &) {}
std::string readLink(const fs::path &path) { return fs::read_symlink(path).string(); }
std::string readLinkAt(int fd, const CanonPath &path)
{
    char buffer[4096];
    auto size = ::readlinkat(fd, path.path.c_str(), buffer, sizeof(buffer));
    if (size < 0 || size == sizeof(buffer)) throw SysError("readlinkat");
    return std::string(buffer, size);
}
void createSymlink(const std::string &value, const fs::path &path) { fs::create_symlink(value, path); }
void writeFull(int fd, std::string_view value)
{
    while (!value.empty()) {
        auto size = ::write(fd, value.data(), value.size());
        if (size <= 0) throw SysError("write");
        value.remove_prefix(size);
    }
}
struct DirectoryIterator : fs::directory_iterator {
    explicit DirectoryIterator(const fs::path &path) : fs::directory_iterator(path) {}
};
struct ChrootOpenBSDDerivationBuilder {
    void materialise(const fs::path &, const fs::path &, bool);
    void materialise(int, const fs::path &, const fs::path &, bool);
};

// MATERIALISE_METHODS

} // namespace nix

static void put(const fs::path &path, std::string_view value, mode_t mode = 0644)
{
    std::ofstream stream(path);
    stream << value;
    stream.close();
    if (::chmod(path.c_str(), mode)) throw std::runtime_error("fixture chmod");
}
static std::string get(const fs::path &path)
{
    std::ifstream stream(path);
    return std::string(std::istreambuf_iterator<char>(stream), {});
}

int main(int argc, char **argv)
try {
    if (argc != 3) throw std::runtime_error("usage: probe CASE DIRECTORY");
    std::string test = argv[1];
    fs::path work = fs::canonical(argv[2]), source = work / "source", output = work / "output";
    fs::create_directories(source);
    fs::create_directories(work / "outside");
    put(source / "entry", "declared\n", 0444);
    put(work / "outside/entry", "outside secret\n", 0400);
    nix::ChrootOpenBSDDerivationBuilder builder;
    bool immutable = test == "hardlink" || test == "setid";
    if (test == "file-swap" || test == "fifo-swap") {
        auto original = nix::lstat(source / "entry");
        onStat = [&, original](const struct stat &st, bool opened) {
            if (opened || st.st_ino != original.st_ino) return;
            onStat = {};
            fs::rename(source / "entry", work / "saved");
            if (test == "fifo-swap") {
                if (::mkfifo((source / "entry").c_str(), 0600)) throw std::runtime_error("mkfifo");
            } else fs::rename(work / "outside/entry", source / "entry");
        };
        try { builder.materialise(source / "entry", output, false); }
        catch (const nix::Error &) { std::cout << "PASS " << test << '\n'; return 0; }
        throw std::runtime_error("source replacement was copied");
    }
    if (test == "directory-swap" || test == "directory-after-open") {
        auto original = nix::lstat(source);
        onStat = [&, original](const struct stat &st, bool opened) {
            if (st.st_ino != original.st_ino || opened != (test == "directory-after-open")) return;
            onStat = {};
            fs::rename(source, work / "saved");
            fs::create_directory_symlink(work / "outside", source);
        };
        try { builder.materialise(source, output, false); }
        catch (const nix::Error &) {
            if (test == "directory-after-open") throw;
            std::cout << "PASS " << test << '\n'; return 0;
        }
        if (get(output / "entry") != "declared\n") throw std::runtime_error("directory replacement was traversed");
    } else if (test == "parent-symlink") {
        fs::create_directory_symlink(work / "outside", source / "link");
        try { builder.materialise(source / "link/entry", output, false); }
        catch (const nix::Error &) { std::cout << "PASS " << test << '\n'; return 0; }
        throw std::runtime_error("source parent symlink was followed");
    } else if (test == "tree") {
        fs::create_directory(source / "nested");
        put(source / "nested/file", "nested\n");
        fs::create_symlink("missing", source / "dangling");
        builder.materialise(source, output, false);
        if (get(output / "nested/file") != "nested\n" || fs::read_symlink(output / "dangling") != "missing")
            throw std::runtime_error("tree changed");
        if (nix::lstat(output / "nested/file").st_mode & 0222) throw std::runtime_error("writable snapshot");
    } else {
        if (test == "setid") ::chmod((source / "entry").c_str(), 06555);
        builder.materialise(source / "entry", output, immutable);
        if (get(output) != "declared\n") throw std::runtime_error("file changed");
        auto copied = nix::lstat(output), original = nix::lstat(source / "entry");
        if (copied.st_mode & (0222 | S_ISUID | S_ISGID)) throw std::runtime_error("unsafe snapshot permissions");
        if (test == "hardlink" && getuid() == 0 && copied.st_ino != original.st_ino)
            throw std::runtime_error("immutable input was not linked");
    }
    if (onStat) throw std::runtime_error("race hook was not reached");
    std::cout << "PASS " << test << '\n';
    return 0;
} catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
}
