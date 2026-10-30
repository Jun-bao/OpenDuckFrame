#include "SPFRCContinuity.hpp"
#include <cassert>
#include <cstdio>

int main() {
    int a, b, c;
    auto hit = [&](const void *cached, const void *input, uint64_t oldID, uint64_t idA, uint64_t idB,
                   uint64_t oldGen, uint64_t gen, uint64_t oldClock, uint64_t clock, bool pts) {
        return spFRCContinues(true, cached, input, oldID, idA, idB, oldGen, gen, oldClock, clock, pts);
    };
    assert(!hit(nullptr, &a, 0, 1, 2, 1, 1, 1, 1, false)); // first pair A/B
    assert(hit(&b, &b, 2, 2, 3, 1, 1, 1, 1, true)); // B/C
    assert(!hit(&b, &a, 2, 1, 4, 1, 1, 1, 1, true)); // A/D discontinuity
    assert(!hit(&b, &b, 2, 2, 2, 1, 1, 1, 1, true)); // repeated identity
    assert(!hit(&b, &c, 2, 2, 3, 1, 1, 1, 1, true)); // recycled identity, other buffer
    assert(!hit(&b, &b, 2, 2, 3, 1, 2, 1, 1, true)); // source switch
    assert(!hit(&b, &b, 2, 2, 3, 1, 1, 1, 2, true)); // clock reset
    assert(!hit(&b, &b, 2, 2, 3, 1, 1, 1, 1, false)); // out-of-order PTS
    assert(!hit(nullptr, &b, 2, 2, 3, 1, 1, 1, 1, true)); // failure invalidates cache
    assert(!spFRCContinues(false, &b, &b, 2, 2, 3, 1, 1, 1, 1, true));
    // Legacy caller claims are unaffected by the live candidate or env mode.
    assert(spFRCSelectSequential(1, false));
    assert(spFRCSelectSequential(1, true));
    assert(!spFRCSelectSequential(0, true));
    assert(!spFRCSelectSequential(0, false));
    assert(spFRCSelectSequential(-1, true));
    assert(!spFRCSelectSequential(-1, false));
    puts("FRC continuity predicate: ok");
}
