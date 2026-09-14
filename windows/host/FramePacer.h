#pragma once
#include <windows.h>
#include <algorithm>
#include <cstdint>
#include <chrono>
#include <stdexcept>

// One-shot high-resolution waits; never accumulate capture debt across an idle
// desktop or backpressure. No busy spin or system-wide timer resolution change.
class FramePacer {
    HANDLE timer;
    int64_t frequency, period, next;
public:
    explicit FramePacer(UINT fps) {
        LARGE_INTEGER value; QueryPerformanceFrequency(&value); frequency = value.QuadPart;
        period = frequency / fps;
        QueryPerformanceCounter(&value); next = value.QuadPart;
        timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_MODIFY_STATE | SYNCHRONIZE);
        if (!timer) throw std::runtime_error("High resolution frame timer unavailable");
    }
    ~FramePacer() { CloseHandle(timer); }
    FramePacer(const FramePacer&) = delete;
    FramePacer& operator=(const FramePacer&) = delete;
    void wait() {
        LARGE_INTEGER now; QueryPerformanceCounter(&now);
        const auto remaining = next - now.QuadPart;
        if (remaining <= 0) return;
        LARGE_INTEGER due; due.QuadPart = -std::max<int64_t>(1, remaining * 10000000 / frequency);
        if (!SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE) || WaitForSingleObject(timer, 1000) != WAIT_OBJECT_0)
            throw std::runtime_error("Frame pacing wait failed");
    }
    void acquired(int64_t now) { next = following(next, now, period); }
    static int64_t following(int64_t deadline, int64_t acquired, int64_t interval) {
        // Keep cadence for normal scheduling jitter, rebase after a missed period.
        return acquired - deadline >= interval ? acquired + interval : deadline + interval;
    }
};
