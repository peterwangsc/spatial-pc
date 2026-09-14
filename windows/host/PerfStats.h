#pragma once
#include <algorithm>
#include <condition_variable>
#include <iomanip>
#include <map>
#include <mutex>
#include <sstream>
#include <vector>
#include "FrameTrace.h"

inline int64_t perfCounter() { LARGE_INTEGER value; QueryPerformanceCounter(&value); return value.QuadPart; }
inline int64_t perfFrequency() { static const auto f = [] { LARGE_INTEGER v; QueryPerformanceFrequency(&v); return v.QuadPart; }(); return f; }
inline double perfMs(int64_t ticks) { return double(ticks) * 1000.0 / double(perfFrequency()); }
inline int64_t perf100ns(int64_t ticks) {
    const auto frequency = perfFrequency();
    return (ticks / frequency) * 10000000 + (ticks % frequency) * 10000000 / frequency;
}
inline uint64_t processCpu100ns() {
    FILETIME created{}, exited{}, kernel{}, user{};
    if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return 0;
    return (uint64_t(kernel.dwHighDateTime) << 32) + kernel.dwLowDateTime +
           (uint64_t(user.dwHighDateTime) << 32) + user.dwLowDateTime;
}

// Metadata only. Storage is bounded even when a session stalls; no desktop bytes.
class PerfStats {
    struct Series { std::vector<double> values; uint64_t total = 0; double sum = 0; double maximum = 0; };
    struct Frame { int64_t acquired; int64_t submitted; };
    std::mutex mutex;
    std::condition_variable changed;
    std::map<std::string, Series> series;
    std::map<int64_t, Frame> pending;
    uint64_t inputs = 0, outputs = 0, bytes = 0, accumulated = 0, timeouts = 0, unmatched = 0;
    size_t peak = 0;
    int64_t began = perfCounter(), lastOutput = 0;
    uint64_t cpuBegan = processCpu100ns();
    void addLocked(const std::string& name, double value) {
        auto& s = series[name]; ++s.total; s.sum += value; s.maximum = std::max(s.maximum, value);
        if (s.values.size() < 36000) s.values.push_back(value);
    }
public:
    FrameTrace trace;
    explicit PerfStats(bool traceEvents=false):trace(traceEvents,began,perfFrequency()) {}
    void add(const std::string& name, double value) { std::lock_guard lock(mutex); addLocked(name, value); }
    void timeout() { std::lock_guard lock(mutex); ++timeouts; }
    void input(int64_t timestamp, int64_t acquired, UINT frames) {
        std::lock_guard lock(mutex);
        if (pending.size() == 1024) { pending.erase(pending.begin()); ++unmatched; }
        const auto submitted = perfCounter();
        pending[timestamp] = { acquired, submitted }; ++inputs; accumulated += frames > 1 ? frames - 1 : 0;
        trace.record(FrameTrace::Kind::Acquired, acquired, timestamp);
        trace.record(FrameTrace::Kind::WriteEnter, submitted, timestamp);
        peak = std::max(peak, pending.size());
    }
    bool capacity(size_t limit) {
        std::unique_lock lock(mutex);
        return changed.wait_for(lock, std::chrono::seconds(5), [&] { return pending.size() < limit; });
    }
    void output(int64_t timestamp, DWORD length) {
        const auto now = perfCounter(); std::lock_guard lock(mutex);
        trace.record(FrameTrace::Kind::Encoded, now, timestamp);
        const auto found = pending.find(timestamp);
        if (found != pending.end()) {
            addLocked("acquire_to_encoded_ms", perfMs(now - found->second.acquired));
            addLocked("submit_to_encoded_ms", perfMs(now - found->second.submitted));
        } else ++unmatched;
        if (lastOutput) addLocked("encoded_interval_ms", perfMs(now - lastOutput));
        lastOutput = now; ++outputs; bytes += length;
    }
    void delivered(int64_t timestamp) { std::lock_guard lock(mutex); if(trace.active())trace.record(FrameTrace::Kind::Delivered,perfCounter(),timestamp);pending.erase(timestamp); changed.notify_all(); }
    void report() {
        std::lock_guard lock(mutex); std::ostringstream out; out << std::fixed << std::setprecision(4);
        const double seconds = perfMs(perfCounter() - began) / 1000;
        out << "perf_summary={\"elapsed_s\":" << seconds << ",\"inputs\":" << inputs << ",\"outputs\":" << outputs
            << ",\"cpu_core_percent\":" << double(processCpu100ns() - cpuBegan) / 100000.0 / seconds
            << ",\"encoded_fps\":" << outputs / seconds << ",\"encoded_bytes\":" << bytes << ",\"pending\":" << pending.size()
            << ",\"peak_pending\":" << peak << ",\"dxgi_coalesced\":" << accumulated << ",\"capture_timeouts\":" << timeouts
            << ",\"unmatched_samples\":" << unmatched << ",\"metrics\":{";
        bool first = true;
        for (const auto& [name, s] : series) {
            auto sorted = s.values; std::sort(sorted.begin(), sorted.end());
            const auto p = [&](double q) { return sorted.empty() ? 0 : sorted[size_t(q * double(sorted.size() - 1))]; };
            if (!first) out << ','; first = false;
            out << '"' << name << "\":{\"n\":" << s.total << ",\"p50\":" << p(.50) << ",\"p95\":" << p(.95)
                << ",\"p99\":" << p(.99) << ",\"max\":" << s.maximum << '}';
        }
        out << "}}"; std::cerr << out.str() << '\n';
    }
};

// Timestamp queries measure GPU cursor/conversion work without blocking per frame.
class GpuTimings {
    struct Slot { ComPtr<ID3D11Query> disjoint, begin, end; bool pending = false; };
    std::vector<Slot> slots;
    ID3D11DeviceContext* context;
    PerfStats& stats;
    int active = -1;
public:
    GpuTimings(ID3D11Device* device, ID3D11DeviceContext* c, PerfStats& s) : slots(8), context(c), stats(s) {
        for (auto& slot : slots) {
            D3D11_QUERY_DESC q{ D3D11_QUERY_TIMESTAMP_DISJOINT, 0 }; check(device->CreateQuery(&q, &slot.disjoint), "GPU disjoint query");
            q.Query = D3D11_QUERY_TIMESTAMP; check(device->CreateQuery(&q, &slot.begin), "GPU start query"); check(device->CreateQuery(&q, &slot.end), "GPU end query");
        }
    }
    void collect() {
        for (auto& slot : slots) if (slot.pending) {
            D3D11_QUERY_DATA_TIMESTAMP_DISJOINT d{}; UINT64 begin = 0, end = 0;
            if (context->GetData(slot.disjoint.Get(), &d, sizeof(d), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK &&
                context->GetData(slot.begin.Get(), &begin, sizeof(begin), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK &&
                context->GetData(slot.end.Get(), &end, sizeof(end), D3D11_ASYNC_GETDATA_DONOTFLUSH) == S_OK) {
                if (!d.Disjoint && d.Frequency && end >= begin) stats.add("cursor_convert_gpu_ms", double(end - begin) * 1000 / double(d.Frequency));
                slot.pending = false;
            }
        }
    }
    void begin() {
        collect(); active = -1;
        for (size_t i = 0; i < slots.size(); ++i) if (!slots[i].pending) { active = int(i); break; }
        if (active >= 0) { auto& slot = slots[size_t(active)]; context->Begin(slot.disjoint.Get()); context->End(slot.begin.Get()); }
    }
    void end() {
        if (active >= 0) { auto& slot = slots[size_t(active)]; context->End(slot.end.Get()); context->End(slot.disjoint.Get()); slot.pending = true; active = -1; }
    }
};
