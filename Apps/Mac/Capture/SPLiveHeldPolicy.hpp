#pragma once
#include <algorithm>
#include <cstdint>
#include <vector>

namespace sp {
struct HeldLease { uint64_t identity; int pins; };
// Keep the two most recent source identities for the next input pair. Pins
// represent actual asynchronous consumers, not a history-size target.
inline std::vector<uint64_t> reclaimableHeld(std::vector<HeldLease> leases) {
    std::sort(leases.begin(), leases.end(), [](const HeldLease &a, const HeldLease &b) { return a.identity < b.identity; });
    const size_t protectedStart = leases.size() > 2 ? leases.size() - 2 : 0;
    std::vector<uint64_t> result;
    for (size_t i = 0; i < protectedStart; ++i)
        if (leases[i].pins == 0) result.push_back(leases[i].identity);
    return result;
}
}
