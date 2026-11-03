// OpenDuckFrame - budget and retry policy for the video recovery lane (hardware to software replay and back); pure constants and functions
//
// Execution (GOP packet retention, software replay, returning to the hardware decoder, decoder ownership) stays in the
// player core; only the thresholds that decide over-budget and give-up live here.
#pragma once

#include <cstddef>
#include <vector>
#include <new>

namespace sp {

constexpr size_t kGopReplayMaxBytes = 12u * 1024 * 1024;
constexpr size_t kGopReplayMaxPackets = 600;

constexpr int kLaneReturnFailureLimit = 3;
constexpr int kLaneReplayFailureLimit = 2;

inline bool gopReplayBudgetAccepts(size_t bytes, size_t count, size_t pktSize) {
    return bytes <= kGopReplayMaxBytes && pktSize <= kGopReplayMaxBytes - bytes && count < kGopReplayMaxPackets;
}

// A failed clone creates a hole, not a usable shorter replay. This helper owns
// the all-or-nothing cache rule and permits deterministic allocation-failure
// injection without changing the decoder or adding a production test switch.
template<class Packet, class Clone, class Release>
bool appendGopReplayPacket(std::vector<Packet*>& packets, size_t& bytes,
                           size_t packetBytes, Clone clone, Release release) {
    Packet* copy = nullptr;
    try {
        if (gopReplayBudgetAccepts(bytes, packets.size(), packetBytes)) {
            copy = clone();
            if (copy) packets.push_back(copy);
        }
    } catch (const std::bad_alloc&) {
        if (copy) release(copy);
        copy = nullptr;
    }
    if (!copy) {
        for (Packet* packet : packets) release(packet);
        packets.clear();
        bytes = 0;
        return false;
    }
    bytes += packetBytes;
    return true;
}
inline bool laneMayAttemptReturnToVT(int returnFailures) { return returnFailures < kLaneReturnFailureLimit; }
inline bool laneShouldDisarmAfterReplayFailure(int replayFailures) { return replayFailures >= kLaneReplayFailureLimit; }

} // namespace sp
