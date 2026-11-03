#include "SPFileCadence.hpp"
#include <cstdio>
using namespace sp;
int main() {
    int errors = 0;
    auto check = [&](bool ok, const char *what) { if (!ok) { std::fprintf(stderr, "FAIL %s\n", what); ++errors; } };
    for (int multiplier : {2, 3, 4}) {
        SPFileCadence c; SPRateRequest r; r.kind = SPRateKind::Multiplier; r.multiplier = multiplier;
        check(c.reset(r, 1), "multiplier reset");
        auto a = c.push(0, 11, 1); auto b = c.push(40000, 12, 1);
        check(a.events.size() == 1 && b.events.size() == (size_t)multiplier, "multiplier count");
        for (int i = 1; i < multiplier && (size_t)(i-1) < b.events.size(); ++i) {
            const auto &e = b.events[i-1];
            check(e.action == SPScheduleAction::Interpolate && e.frameA == 11 && e.frameB == 12 &&
                  spCmp(e.phase, spMake(i, multiplier)) == 0 && e.ptsUs == (40000LL*i + multiplier/2)/multiplier,
                  "original pair, phase and PTS");
        }
    }
    SPFileCadence c; SPRateRequest fixed; fixed.kind = SPRateKind::FixedFPS; fixed.fps = spMake(60000,1001);
    check(c.reset(fixed, 7), "fixed reset");
    std::vector<SPFileCadenceEvent> all;
    for (int i = 0; i <= 24; ++i) {
        auto r = c.push((1000000LL*i + 12)/24, 100+i, 7);
        check(r.reject == SPScheduleReject::None, "fixed accepted");
        all.insert(all.end(), r.events.begin(), r.events.end());
    }
    check(all.size() == 60, "fixed 60000/1001 count in one second");
    for (size_t i = 0; i < all.size(); ++i)
        check(all[i].ptsUs == (int64_t)(((__int128)i*1001*1000000 + 30000)/60000), "fixed rational clock");
    auto stale = c.push(1041667, 125, 6); check(stale.reject == SPScheduleReject::GenerationMismatch, "old generation rejected");
    SPRateRequest x; x.multiplier = 2; check(c.reset(x, 8), "seek reset");
    c.push(3000000, 1, 8); auto cut = c.push(3040000, 2, 8, true);
    check(cut.events.size() == 2 && cut.events[0].action == SPScheduleAction::Hold && cut.events[0].skipReason == SPScheduleSkipReason::SceneCut, "cut holds source");
    c.noteBoundary(); auto boundary = c.push(3080000, 3, 8);
    check(boundary.events.size() == 2 && boundary.events[0].skipReason == SPScheduleSkipReason::Boundary, "boundary clears pair");
    c.cancel(); check(c.push(3120000, 4, 8).reject == SPScheduleReject::Cancelled, "cancel");
    std::printf("file cadence: %s (%d failures)\n", errors ? "FAIL" : "PASS", errors);
    return errors ? 1 : 0;
}
