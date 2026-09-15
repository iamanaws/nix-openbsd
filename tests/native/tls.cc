#include <atomic>
#include <cassert>
#include <thread>

static std::atomic<int> destroyed{0};

struct Local {
    int value = 7;
    ~Local() { ++destroyed; }
};

static thread_local Local local;

static void worker(int value)
{
    assert(local.value == 7);
    local.value = value;
    std::this_thread::yield();
    assert(local.value == value);
}

int main()
{
    local.value = 19;
    std::thread first(worker, 11), second(worker, 13);
    first.join();
    second.join();
    assert(local.value == 19);
    assert(destroyed == 2);
}
