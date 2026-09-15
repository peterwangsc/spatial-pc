#pragma once
#include <windows.h>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <chrono>

// Vendor calls and synchronous pipe writes have no general cancellation API.
// Bound a wedged optional capture CHILD, never terminate the UI/backend/other apps.
// Normal shutdown drains and destroys in order. This is the last-resort guard.
class NvencDeadline {
    std::mutex mutex;
    std::condition_variable changed;
    bool stopping = false, armed = false;
    unsigned long long generation = 0;
    std::chrono::steady_clock::time_point until;
    const std::chrono::milliseconds limit;
    std::thread watcher;
public:
    explicit NvencDeadline(std::chrono::milliseconds budget = std::chrono::seconds(6))
        : limit(budget), watcher([this] {
            std::unique_lock lock(mutex);
            while (!stopping) {
                if (!armed) { changed.wait(lock, [&] { return stopping || armed; }); continue; }
                const auto version = generation;
                if (!changed.wait_until(lock, until, [&] { return stopping || !armed || generation != version; }))
                    TerminateProcess(GetCurrentProcess(), 72);
            }
        }) {}
    ~NvencDeadline() {
        { std::lock_guard lock(mutex); stopping = true; }
        changed.notify_all(); watcher.join();
    }
    NvencDeadline(const NvencDeadline&) = delete;
    NvencDeadline& operator=(const NvencDeadline&) = delete;
    class Guard {
        NvencDeadline& owner;
    public:
        explicit Guard(NvencDeadline& d) : owner(d) {
            std::lock_guard lock(owner.mutex);
            owner.until = std::chrono::steady_clock::now() + owner.limit;
            owner.armed = true; ++owner.generation; owner.changed.notify_all();
        }
        ~Guard() {
            std::lock_guard lock(owner.mutex); owner.armed = false; ++owner.generation; owner.changed.notify_all();
        }
    };
};
