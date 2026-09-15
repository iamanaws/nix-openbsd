#include <atomic>
#include <cassert>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#ifdef SHARED_THROW
extern "C" void throw_from_library()
{
    throw std::runtime_error("native unwind");
}
#else
extern "C" void throw_from_library();
static std::atomic<int> destroyed{0};
static std::atomic<int> tls_destroyed{0};
struct Guard {
    ~Guard() { ++destroyed; }
};
struct Local {
    int value = 7;
    ~Local() { ++tls_destroyed; }
};
static thread_local Local local;

static void recurse(int depth)
{
    Guard guard;
    if (depth) recurse(depth - 1);
    else throw_from_library();
}

static void worker(int value)
{
    assert(local.value == 7);
    local.value = value;
    try {
        recurse(8);
        assert(false);
    } catch (const std::runtime_error &error) {
        assert(std::string(error.what()) == "native unwind");
    }
    assert(local.value == value);
}

int main()
{
    local.value = 19;
    std::vector<std::thread> workers;
    workers.emplace_back(worker, 11);
    workers.emplace_back(worker, 13);
    for (auto &worker : workers) worker.join();
    assert(destroyed == 18);
    assert(tls_destroyed == 2);
    assert(local.value == 19);
}
#endif
