#include "SPLiveDisplayQueue.h"
#include "SPAirDisplayPolicyB.hpp"
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
    // Absolute media time, not callback-relative time or source-PTS rebasing.
    const int64_t absolute = 1139402000000000LL;
    DisplaySlotContext context{7, 5, 4, 11};
    DisplaySlotWindow slot{42, context, absolute + 8000000, absolute + 25000000};
    require(displayPreparationLeadNs(slot) == 19000000, "prepare lead used callback-to-display horizon");
    require(displaySlotDecision(slot,42,context,absolute) == DisplaySlotDecision::waiting, "selected at callback instead of near deadline");
    std::vector<DisplayQueueFrame> arriving;
    arriving.push_back({{10,120},absolute+17000000,1,true});
    // This frame is delivered after the callback, within its live submit window.
    arriving.push_back({{11,120},absolute+25000000,2,true});
    const int64_t selectionTime = slot.deadlineNs - displaySelectionGuardNs;
    require(displaySlotDecision(slot,42,context,selectionTime-1) == DisplaySlotDecision::waiting, "late-ready frame consumed before decision guard");
    require(displaySlotDecision(slot,42,context,selectionTime) == DisplaySlotDecision::ready &&
            chooseDisplayFrame(arriving,slot.displayNs) == 1, "callback cutoff lost a frame ready before deadline");
    require(displaySlotDecision(slot,42,context,absolute+8000000) == DisplaySlotDecision::expired, "expired deadline could claim submission success");
    require(!canReplaceDisplaySlot(slot,context,absolute+7000000), "new update displaced a viable old slot");
    require(canReplaceDisplaySlot(slot,context,absolute+8000000), "expired drawable ticket was retained");
    auto retired = context; retired.clockEpoch++;
    require(displaySlotDecision(slot,42,retired,absolute+7000000) == DisplaySlotDecision::retired, "old clock consumed a deferred drawable");
    require(canReplaceDisplaySlot(slot,retired,absolute+1000000), "retired clock blocked new ticket");
    slot.token = 43; slot.context = retired;
    require(displaySlotDecision(slot,42,retired,absolute+7000000) == DisplaySlotDecision::staleToken, "old timer consumed a replacement slot");
    require(!canArmDisplaySlot(slot,42,retired), "a delayed old arm overwrote the replacement slot timer");
    require(canArmDisplaySlot(slot,43,retired), "current token could not arm its timer");
    require(!canArmDisplaySlot(slot,43,context), "retired clock rearmed a current-context timer");
    for (int boundary = 0; boundary < 3; ++boundary) {
        auto changed = retired;
        if (boundary == 0) changed.generation++;
        else if (boundary == 1) changed.config++;
        else changed.measurementEpoch++;
        require(displaySlotDecision(slot,43,changed,absolute+7000000) == DisplaySlotDecision::retired, "context change did not retire the pending ticket");
    }
    // An interpolated frame and the following original may both become due
    // within one refresh. Keep each while it is within the bounded lag window.
    spAirDisplayPolicyB::RefreshHistory refresh;
    refresh.observe(absolute); refresh.observe(absolute + 16666667);
    std::vector<DisplayQueueFrame> temporal={{{1,60},absolute+10000000,101,true},
                                            {{2,60},absolute+18000000,102,true}};
    auto bounded=spAirDisplayPolicyB::decide(temporal,absolute+20000000,refresh.intervals,refresh.count,true);
    require(bounded.selected==0 && bounded.branch==spAirDisplayPolicyB::Branch::boundedLag,"a viable midpoint was superseded by its original");
    temporal.erase(temporal.begin());
    auto following=spAirDisplayPolicyB::decide(temporal,absolute+36666667,refresh.intervals,refresh.count,true);
    require(following.selected==0,"the following original could not use the next slot");
    temporal={{{1,60},absolute-50000000,101,true},{{2,60},absolute-40000000,102,true}};
    auto stale=spAirDisplayPolicyB::decide(temporal,absolute,refresh.intervals,refresh.count,true);
    require(stale.selected==1 && stale.branch==spAirDisplayPolicyB::Branch::allStaleLatest,"bounded output accumulated expired frames");
    auto unchanged=spAirDisplayPolicyB::decide(temporal,absolute,refresh.intervals,refresh.count,false);
    require(unchanged.selected==chooseDisplayFrame(temporal,absolute),"disabled policy changed legacy latest-frame selection");
    temporal={{{1,60},absolute+1,101,true}};
    require(spAirDisplayPolicyB::decide(temporal,absolute,refresh.intervals,refresh.count,true).selected==temporal.size(),"a future frame was selected early");
    std::puts("display-link pending queue and bounded temporal assertions passed (CPU only)");
    return 0;
}
