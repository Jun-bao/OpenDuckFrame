#include "SPLiveDisplayQueue.h"
#include <cstdio>
#include <cstdlib>

static void require(bool condition, const char *message) {
    if (!condition) { std::fprintf(stderr, "%s\n", message); std::exit(1); }
}

int main() {
    using namespace sp;
    std::vector<DisplayQueueFrame> pending;
    const int64_t tick = 8333333;
    auto add = [&](int phase, int64_t target, uint64_t id) {
        DisplayQueueFrame frame{{phase, 120}, target, id, true};
        require(admitDisplayFrame(pending, frame, false, {}) == DisplayAdmission::accepted, "admission failed");
        pending.insert(pending.begin() + displayFrameInsertionIndex(pending, frame), frame);
    };
    // Completion/frame-ID order does not define media order.
    add(3, tick * 3, 1); add(1, tick, 5); add(2, tick * 2, 4);
    require(pending[0].frameID == 5 && pending[1].frameID == 4, "PTS order lost");
    require(chooseDisplayFrame(pending, tick - 1) == pending.size(), "frame displayed before frozen target");
    require(chooseDisplayFrame(pending, tick) == 0, "exact target was not eligible");
    require(chooseDisplayFrame(pending, tick + 2000000) == 0, "prepare lead discarded a still-future phase");
    require(chooseDisplayFrame(pending, tick * 3) == 2, "missed slots retained an old eligible backlog");
    pending.erase(pending.begin());
    require(chooseDisplayFrame(pending, tick * 2) == 0 && pending[0].pts.num == 2, "phase consumed twice or skipped");
    require(admitDisplayFrame(pending, {{2,120},tick*2,100,true}, false,{}) == DisplayAdmission::duplicatePTS,
            "duplicate PTS accepted");
    require(admitDisplayFrame(pending, {{1,120},tick,101,true}, true,{1,120}) == DisplayAdmission::stalePTS,
            "submitted watermark did not reject old PTS");
    require(admitDisplayFrame(pending, {{1,120},0,0,false}, true,{3,120}) == DisplayAdmission::stalePTS,
            "uncounted preview bypassed media ordering");
    require(admitDisplayFrame(pending, {{3,120},tick*3,0,false,true}, true,{3,120}) == DisplayAdmission::accepted,
            "redraw of the submitted frame was rejected");
    require(admitDisplayFrame(pending, {{4,120},tick*4,0,false,true}, true,{3,120}) == DisplayAdmission::redrawNotCurrent,
            "view-mode redraw early-displayed a future admitted buffer");
    require(admitDisplayFrame(pending, {{1,0},0,102,true}, false,{}) == DisplayAdmission::invalidPTS,
            "invalid PTS accepted");
    add(4,tick*4,2); add(5,tick*5,3);
    require(pending.size() == displayQueueCapacity, "queue capacity fixture wrong");
    require(admitDisplayFrame(pending, {{6,120},tick*6,99,true}, false,{}) == DisplayAdmission::full,
            "full pending queue was not rejected");
    // The prospective scheduled time remains distinct from the frozen target:
    // a slot can be eligible but still miss the original target+2ms definition.
    int64_t scheduled = pending[0].logicalTargetNs + 3000000;
    require(chooseDisplayFrame(pending, scheduled) == 0, "eligible delayed frame disappeared");
    require(scheduled > pending[0].logicalTargetNs + 2000000, "late scheduled slot was relabelled on time");
    pending[0].logicalTargetNs = tick * 10;
    require(chooseDisplayFrame(pending, tick * 5) == pending.size(), "later PTS overtook a future head frame");
    std::puts("display-link pending queue assertions passed (CPU only)");
    return 0;
}
