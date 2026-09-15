#pragma once
#include <stdexcept>

// The same transaction drives the real adapter and no-GPU ownership fixtures.
// Cancellation never returns a surface that the producer/encoder still owns.
namespace spatialpc {
template<class Operations> struct NvencProducerGuard {
    Operations* operations;
    ~NvencProducerGuard() { if (operations) operations->drainAbandonedProducer(); }
};
enum class NvencStage { producer, ready, mapping, mapped, submitted, completed, unmapping, free };

template<class Operations, class Alive>
bool finishNvencFrame(Operations& ops, Alive&& alive) {
    auto stage = NvencStage::producer;
    try {
        ops.waitProducer();
        stage = NvencStage::ready;
        if (!alive()) return false;
        stage = NvencStage::mapping;
        ops.map();
        stage = NvencStage::mapped;
        if (!alive()) { stage = NvencStage::unmapping; ops.unmap(); return false; }
        // A failed submit may have reached the driver: conservatively retain it.
        stage = NvencStage::submitted;
        ops.submit();
        ops.waitEncoder();
        stage = NvencStage::completed;
        const bool deliver = alive();
        if (deliver) ops.deliver();
        stage = NvencStage::unmapping;
        ops.unmap();
        stage = NvencStage::free;
        return deliver;
    } catch (...) {
        if (stage == NvencStage::mapped || stage == NvencStage::completed) {
            try { ops.unmap(); } catch (...) { ops.quarantine(); }
        } else if (stage == NvencStage::producer || stage == NvencStage::mapping ||
                   stage == NvencStage::submitted || stage == NvencStage::unmapping) {
            ops.quarantine();
        }
        throw;
    }
}
}
