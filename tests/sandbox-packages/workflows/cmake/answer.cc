#include <thread>
int answer()
{
    int value = 0;
    std::thread worker([&] { value = 42; });
    worker.join();
    return value;
}
