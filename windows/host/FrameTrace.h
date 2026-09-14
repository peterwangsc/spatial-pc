#pragma once
#include <algorithm>
#include <cstdint>
#include <mutex>
#include <ostream>
#include <vector>

// Opt-in, bounded metadata recorder. No per-event I/O and no image data.
// QPC ticks are retained exactly so cross-thread events can be ordered offline.
class FrameTrace {
public:
    enum class Kind { AcquireBegin, AcquireReturn, AcquireTimeout, Acquired, WriteEnter, WriteReturn, Encoded, Delivered };
    struct Event { Kind kind; int64_t ticks; int64_t pts; };
    static constexpr size_t limit = 8192;
private:
    const bool enabled;
    const int64_t epoch, frequency;
    std::mutex mutex;
    std::vector<Event> events;
    uint64_t omitted = 0;
    static const char* name(Kind value) {
        switch(value) {
        case Kind::AcquireBegin:return "acquire_begin";
        case Kind::AcquireReturn:return "acquire_return";
        case Kind::AcquireTimeout:return "acquire_timeout";
        case Kind::Acquired:return "acquired";
        case Kind::WriteEnter:return "write_enter";
        case Kind::WriteReturn:return "write_return";
        case Kind::Encoded:return "encoded";
        case Kind::Delivered:return "delivered";
        }
        return "unknown";
    }
public:
    FrameTrace(bool active, int64_t start, int64_t rate):enabled(active),epoch(start),frequency(rate) {
        if(enabled)events.reserve(limit);
    }
    bool active() const { return enabled; }
    void record(Kind kind, int64_t ticks, int64_t pts=-1) {
        if(!enabled)return;
        std::lock_guard lock(mutex);
        if(events.size()<limit)events.push_back({kind,ticks-epoch,pts});else ++omitted;
    }
    void report(std::ostream& output) {
        if(!enabled)return;
        std::vector<Event> snapshot;uint64_t lost;
        { std::lock_guard lock(mutex);snapshot=events;lost=omitted; }
        // The acquired timestamp can be recorded later, after conversion, and
        // callbacks can race submission. Lock acquisition order is not time order.
        std::stable_sort(snapshot.begin(),snapshot.end(),[](const auto& a,const auto& b){return a.ticks<b.ticks;});
        output<<"frame_trace={\"qpc_frequency\":"<<frequency<<",\"limit\":"<<limit<<",\"omitted\":"<<lost<<",\"events\":[";
        bool first=true;
        for(const auto& event:snapshot) {
            if(!first)output<<',';first=false;
            output<<"{\"event\":\""<<name(event.kind)<<"\",\"ticks\":"<<event.ticks<<",\"pts_100ns\":"<<event.pts<<'}';
        }
        output<<"]}\n";
    }
};
