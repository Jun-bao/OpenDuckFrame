#pragma once

#include <algorithm>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>
#include <mach/mach_time.h>

namespace spAirMeasurement {

enum class Kind : uint32_t {
    slotInsert, timerCreate, timerPark, timerArm, timerCancel, timerFire, drainEntry,
    choiceBegin, choiceCandidate, choiceEnd, leaseRequest, leaseClaim, leaseMap,
    leaseReady, leaseCancel, leaseCompleteRequest, leaseRelease, inlineMap, gpuCallback, targetCreated
};

inline const char *name(Kind kind) {
    switch (kind) {
        case Kind::slotInsert: return "slot-insert";
        case Kind::timerCreate: return "timer-create";
        case Kind::timerPark: return "timer-park";
        case Kind::timerArm: return "timer-arm";
        case Kind::timerCancel: return "timer-cancel";
        case Kind::timerFire: return "timer-fire";
        case Kind::drainEntry: return "drain-entry";
        case Kind::choiceBegin: return "choice-begin";
        case Kind::choiceCandidate: return "choice-candidate";
        case Kind::choiceEnd: return "choice-end";
        case Kind::leaseRequest: return "lease-request";
        case Kind::leaseClaim: return "lease-claim";
        case Kind::leaseMap: return "lease-map";
        case Kind::leaseReady: return "lease-ready";
        case Kind::leaseCancel: return "lease-cancel";
        case Kind::leaseCompleteRequest: return "lease-complete-request";
        case Kind::leaseRelease: return "lease-release";
        case Kind::inlineMap: return "inline-map";
        case Kind::gpuCallback: return "gpu-completion-callback";
        case Kind::targetCreated: return "target-created";
    }
    return "unknown";
}

// Instant observations use equal begin/end. Intervals retain both endpoints.
// The payload's per-kind meaning is declared by the native JSON formatter.
struct Event {
    uint64_t sequence = 0, beginHostTicks = 0, endHostTicks = 0, recordHostTicks = 0;
    uint64_t frameID = 0, generation = 0, config = 0, epoch = 0, clock = 0;
    int64_t ptsNum = 0, ptsDen = 0, targetHostTicks = 0;
    uint64_t groupID = 0, relatedID = 0, clockLifeID = 0, armID = 0;
    uint64_t sampleHostTicks = 0, values[4] = {};
    double gpuStartSeconds = 0, gpuEndSeconds = 0;
    Kind kind = Kind::slotInsert;
    uint32_t flags = 0;
};
static_assert(sizeof(Event) == 192, "Measurement POD layout is part of the trace contract");

struct Snapshot {
    std::vector<Event> rows;
    uint64_t total = 0, postSealAttempts = 0, sealedHostTicks = 0;
    bool sealed = false;
};

class Trace {
public:
    explicit Trace(size_t capacity) : capacity_(capacity), rows_(std::make_unique<Event[]>(capacity)) {}
    size_t capacity() const { return capacity_; }
    uint64_t identity() {
        std::lock_guard<std::mutex> lock(mutex_);
        return ++identity_;
    }
    void append(Event event) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (sealed_) { ++postSealAttempts_; return; }
        event.sequence = ++total_;
        event.recordHostTicks = mach_absolute_time();
        rows_[(total_ - 1) % capacity_] = event;
    }
    Snapshot snapshot() const {
        std::lock_guard<std::mutex> lock(mutex_);
        Snapshot value;
        value.total = total_; value.sealed = sealed_;
        value.postSealAttempts = postSealAttempts_; value.sealedHostTicks = sealedHostTicks_;
        const uint64_t count = std::min(total_, uint64_t(capacity_));
        value.rows.reserve(count);
        for (uint64_t index = total_ - count; index < total_; ++index)
            value.rows.push_back(rows_[index % capacity_]);
        return value;
    }
    void seal() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!sealed_) { sealed_ = true; sealedHostTicks_ = mach_absolute_time(); }
    }
    void reset() {
        std::lock_guard<std::mutex> lock(mutex_);
        total_ = postSealAttempts_ = sealedHostTicks_ = 0;
        sealed_ = false;
        // Identity values remain monotonic across a controlled session reset.
    }
private:
    size_t capacity_;
    std::unique_ptr<Event[]> rows_;
    mutable std::mutex mutex_;
    uint64_t total_ = 0, identity_ = 0, postSealAttempts_ = 0, sealedHostTicks_ = 0;
    bool sealed_ = false;
};
using TracePtr = std::shared_ptr<Trace>;
constexpr size_t processorCapacity = 65536, viewCapacity = 262144;

} // namespace spAirMeasurement
