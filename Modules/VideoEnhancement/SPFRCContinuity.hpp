#pragma once
#include <cstdint>

// A session may reuse its previous reference only after a successful pair.
// Buffer ownership and exact CMTime comparison stay with the caller.
inline bool spFRCContinues(bool enabled, const void *cached, const void *frameA,
                           uint64_t cachedID, uint64_t frameIDA, uint64_t frameIDB,
                           uint64_t cachedGeneration, uint64_t generation,
                           uint64_t cachedClock, uint64_t clock, bool ptsEqual) {
    return enabled && cached && cached == frameA && frameIDA != 0 && frameIDB != 0 && frameIDA != frameIDB &&
           cachedID == frameIDA && cachedGeneration == generation && cachedClock == clock && ptsEqual;
}

// The legacy API remains caller-directed; -1 designates the new live API.
inline bool spFRCSelectSequential(int legacyMode, bool liveContinuity) {
    return legacyMode >= 0 ? legacyMode == 1 : liveContinuity;
}
