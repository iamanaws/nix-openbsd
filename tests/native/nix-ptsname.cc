// Link against the native libnixutil to exercise its actual PTY implementation.
#include <atomic>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>
#include <util.h>

namespace nix {
std::string getPtsName(int fd);
}

int main()
{
    constexpr int workers = 8;
    constexpr int iterations = 2000;
    int masters[workers];
    std::string names[workers];
    for (int i = 0; i < workers; ++i) {
        int slave;
        char name[128];
        if (openpty(&masters[i], &slave, name, nullptr, nullptr) != 0) {
            perror("openpty");
            return 1;
        }
        names[i] = name;
        close(slave);
        if (nix::getPtsName(masters[i]) != names[i]) return 1;
    }
    bool rejected = false;
    try {
        nix::getPtsName(-1);
    } catch (const std::exception &) {
        rejected = true;
    }
    if (!rejected) return 1;

    std::atomic<int> ready{0};
    std::atomic<int> failures{0};
    std::vector<std::thread> threads;
    for (int i = 0; i < workers; ++i) {
        threads.emplace_back([&, i] {
            ++ready;
            while (ready != workers) std::this_thread::yield();
            try {
                for (int j = 0; j < iterations; ++j) {
                    if (nix::getPtsName(masters[i]) != names[i]) ++failures;
                }
            } catch (...) {
                ++failures;
            }
        });
    }
    for (auto &thread : threads) thread.join();
    for (int fd : masters) close(fd);
    if (failures != 0) return 1;
    puts("NIX_PTSNAME_PASS: invalid fd, distinct PTYs, 16000 concurrent lookups");
}
