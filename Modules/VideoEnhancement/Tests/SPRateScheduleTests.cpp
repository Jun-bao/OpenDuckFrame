#include "SPRateSchedule.hpp"

#include <stdio.h>
#include <string.h>

#include <string>
#include <cmath>
#include <set>

using sp::SPRational;
using sp::SPRateKind;
using sp::SPRateRequest;
using sp::SPRateScheduler;
using sp::SPScheduleAction;
using sp::SPScheduleInput;
using sp::SPScheduleOutput;
using sp::SPScheduleReject;
using sp::SPScheduleSkipReason;

static int gFailures = 0;

static std::string fmt(SPRational r) {
    return std::to_string(r.num) + "/" + std::to_string(r.den);
}

static void fail(const std::string &message) {
    fprintf(stderr, "FAIL %s\n", message.c_str());
    gFailures += 1;
}

static bool same(SPRational a, SPRational b) { return sp::spCmp(a, b) == 0; }

static SPScheduleInput frame(int64_t n, int64_t d, uint64_t id, uint64_t gen, bool cut = false) {
    SPScheduleInput input;
    input.pts = sp::spMake(n, d);
    input.identity = id;
    input.generation = gen;
    input.sceneCutAfter = cut;
    return input;
}

static SPRateScheduler makeScheduler(SPRateRequest request, uint64_t gen = 1) {
    SPRateScheduler scheduler;
    if (!scheduler.reset(request, gen, sp::spMake(1, 2))) fail("reset rejected a valid request");
    return scheduler;
}

static void expectReject(SPScheduleReject got, SPScheduleReject want, const char *label) {
    if (got != want) fail(std::string(label) + " reject");
}

static void expectEvent(const SPScheduleOutput &event, SPScheduleAction action, SPRational pts, uint64_t a,
                        uint64_t b, SPRational phase, const char *label) {
    if (event.action != action) fail(std::string(label) + " action");
    if (!same(event.pts, pts)) fail(std::string(label) + " pts got " + fmt(event.pts) + " want " + fmt(pts));
    if (event.frameA != a || event.frameB != b) fail(std::string(label) + " pair");
    if (!same(event.phase, phase)) fail(std::string(label) + " phase got " + fmt(event.phase));
}

static void testMultiplier30() {
    SPRateRequest request;
    request.kind = SPRateKind::Multiplier;
    request.multiplier = 2;
    auto scheduler = makeScheduler(request);
    std::vector<SPScheduleOutput> all;
    for (int i = 0; i < 5; ++i) {
        auto result = scheduler.push(frame(i, 30, (uint64_t)i + 1, 1));
        expectReject(result.reject, SPScheduleReject::None, "x2");
        all.insert(all.end(), result.events.begin(), result.events.end());
    }
    if (all.size() != 9) fail("x2 30fps event count");
    expectEvent(all[0], SPScheduleAction::PresentSource, sp::spMake(0, 1), 1, 0, sp::spMake(0, 1), "x2[0]");
    expectEvent(all[1], SPScheduleAction::Interpolate, sp::spMake(1, 60), 1, 2, sp::spMake(1, 2), "x2[1]");
    expectEvent(all[2], SPScheduleAction::PresentSource, sp::spMake(1, 30), 2, 0, sp::spMake(0, 1), "x2[2]");
    expectEvent(all[3], SPScheduleAction::Interpolate, sp::spMake(1, 20), 2, 3, sp::spMake(1, 2), "x2[3]");
    for (size_t i = 1; i < all.size(); ++i) {
        if (sp::spCmp(all[i].pts, all[i - 1].pts) <= 0) fail("x2 order");
    }
    auto done = scheduler.finish();
    if (!done.events.empty() || done.reject != SPScheduleReject::None) fail("finish invented a frame");
}

static void testSixtyInputRates() {
    for (int m : {2,3,4}) {
        SPRateRequest request; request.kind=SPRateKind::Multiplier; request.multiplier=m;
        request.fps=sp::spMake(60,1); // stale fixed target must not affect multiplier mode
        auto scheduler=makeScheduler(request);
        scheduler.push(frame(0,60,1,1));
        auto result=scheduler.push(frame(1,60,2,1));
        if (result.events.size() != (size_t)m) { fail("60fps multiplier event count"); continue; }
        for (int i=1;i<m;i++) {
            expectEvent(result.events[i-1],SPScheduleAction::Interpolate,sp::spMake(i,60*m),1,2,sp::spMake(i,m),"60fps multiplier phase");
        }
        expectEvent(result.events[m-1],SPScheduleAction::PresentSource,sp::spMake(1,60),2,0,sp::spMake(0,1),"60fps multiplier source");
    }
    SPRateRequest fixed; fixed.kind=SPRateKind::FixedFPS; fixed.fps=sp::spMake(60,1); fixed.multiplier=4;
    auto scheduler=makeScheduler(fixed); scheduler.push(frame(0,60,1,1)); auto next=scheduler.push(frame(1,60,2,1));
    if (next.events.size()!=1 || next.events[0].action!=SPScheduleAction::PresentSource || !same(next.events[0].pts,sp::spMake(1,60))) fail("fixed60 ignores stale multiplier");
}

static void testX3X4Parents() {
    SPRateRequest x3;
    x3.kind = SPRateKind::Multiplier;
    x3.multiplier = 3;
    auto s3 = makeScheduler(x3);
    auto a = s3.push(frame(0, 30, 10, 1));
    auto b = s3.push(frame(1, 30, 11, 1));
    if (a.events.size() != 1 || b.events.size() != 3) fail("x3 count");
    expectEvent(b.events[0], SPScheduleAction::Interpolate, sp::spMake(1, 90), 10, 11, sp::spMake(1, 3), "x3 1/3");
    expectEvent(b.events[1], SPScheduleAction::Interpolate, sp::spMake(2, 90), 10, 11, sp::spMake(2, 3), "x3 2/3");
    expectEvent(b.events[2], SPScheduleAction::PresentSource, sp::spMake(1, 30), 11, 0, sp::spMake(0, 1), "x3 source");
    for (const auto &event : b.events) {
        if (event.action == SPScheduleAction::Interpolate && (event.frameA != 10 || event.frameB != 11)) {
            fail("x3 used a synthetic parent");
        }
    }

    SPRateRequest x4;
    x4.kind = SPRateKind::Multiplier;
    x4.multiplier = 4;
    auto s4 = makeScheduler(x4);
    s4.push(frame(0, 30, 4, 1));
    auto second = s4.push(frame(1, 30, 5, 1));
    if (second.events.size() != 4) fail("x4 count");
    expectEvent(second.events[0], SPScheduleAction::Interpolate, sp::spMake(1, 120), 4, 5, sp::spMake(1, 4), "x4 1/4");
    expectEvent(second.events[1], SPScheduleAction::Interpolate, sp::spMake(1, 60), 4, 5, sp::spMake(1, 2), "x4 1/2");
    expectEvent(second.events[2], SPScheduleAction::Interpolate, sp::spMake(1, 40), 4, 5, sp::spMake(3, 4), "x4 3/4");
}

static void testNTSC() {
    const int64_t num = 1001;
    SPRateRequest doubled;
    doubled.kind = SPRateKind::FixedFPS;
    doubled.fps = sp::spMake(60000, num);
    auto fixed = makeScheduler(doubled);
    std::vector<SPScheduleOutput> outs;
    for (int n = 0; n < 4; ++n) {
        auto result = fixed.push(frame((int64_t)n * num, 30000, (uint64_t)n + 1, 1));
        expectReject(result.reject, SPScheduleReject::None, "ntsc fixed");
        outs.insert(outs.end(), result.events.begin(), result.events.end());
    }
    if (outs.size() < 4) fail("ntsc short");
    if (same(outs[1].pts, sp::spMake(1, 60))) fail("ntsc collapsed to 1/60");
    expectEvent(outs[1], SPScheduleAction::Interpolate, sp::spMake(num, 60000), 1, 2, sp::spMake(1, 2), "ntsc mid");
    expectEvent(outs[2], SPScheduleAction::PresentSource, sp::spMake(num, 30000), 2, 0, sp::spMake(0, 1), "ntsc source");

    SPRateRequest times;
    times.kind = SPRateKind::Multiplier;
    times.multiplier = 2;
    auto mult = makeScheduler(times);
    mult.push(frame(0, 30000, 1, 1));
    auto mid = mult.push(frame(num, 30000, 2, 1));
    if (mid.events.empty() || !same(mid.events[0].pts, sp::spMake(num, 60000))) fail("ntsc x2 midpoint");
    if (!same(mid.events[0].pts, outs[1].pts)) fail("fixed and multiplier NTSC disagree");
}

static void testFilmTo60And30() {
    SPRateRequest to60;
    to60.kind = SPRateKind::FixedFPS;
    to60.fps = sp::spMake(60, 1);
    auto s60 = makeScheduler(to60);
    std::vector<SPScheduleOutput> outs;
    for (int n = 0; n < 5; ++n) {
        auto result = s60.push(frame(n, 24, (uint64_t)n + 1, 1));
        outs.insert(outs.end(), result.events.begin(), result.events.end());
    }
    expectEvent(outs[0], SPScheduleAction::PresentSource, sp::spMake(0, 1), 1, 0, sp::spMake(0, 1), "24to60 source");
    expectEvent(outs[1], SPScheduleAction::Interpolate, sp::spMake(1, 60), 1, 2, sp::spMake(2, 5), "24to60 2/5");
    expectEvent(outs[2], SPScheduleAction::Interpolate, sp::spMake(2, 60), 1, 2, sp::spMake(4, 5), "24to60 4/5");
    bool leakedSourceTime = false;
    for (const auto &event : outs) {
        if (same(event.pts, sp::spMake(1, 24))) leakedSourceTime = true;
        if (event.action == SPScheduleAction::Interpolate && event.phase.num == 1 && event.phase.den == 2) {
            fail("24to60 used only the half phase");
        }
    }
    if (leakedSourceTime) fail("24to60 presented 1/24");

    SPRateRequest to30;
    to30.kind = SPRateKind::FixedFPS;
    to30.fps = sp::spMake(30, 1);
    auto s30 = makeScheduler(to30);
    std::vector<SPScheduleOutput> film;
    for (int n = 0; n < 5; ++n) {
        auto result = s30.push(frame(n, 24, (uint64_t)n + 1, 1));
        expectReject(result.reject, SPScheduleReject::None, "24to30");
        film.insert(film.end(), result.events.begin(), result.events.end());
    }
    expectEvent(film[0], SPScheduleAction::PresentSource, sp::spMake(0, 1), 1, 0, sp::spMake(0, 1), "24to30 0");
    expectEvent(film[1], SPScheduleAction::Interpolate, sp::spMake(1, 30), 1, 2, sp::spMake(4, 5), "24to30 4/5");
    expectEvent(film[2], SPScheduleAction::Interpolate, sp::spMake(2, 30), 2, 3, sp::spMake(3, 5), "24to30 3/5");
    expectEvent(film[3], SPScheduleAction::Interpolate, sp::spMake(3, 30), 3, 4, sp::spMake(2, 5), "24to30 2/5");
}

static void testTenSeconds() {
    SPRateRequest request;
    request.kind = SPRateKind::FixedFPS;
    request.fps = sp::spMake(60, 1);
    auto scheduler = makeScheduler(request);
    std::vector<SPScheduleOutput> outs;
    for (int n = 0; n <= 240; ++n) {
        auto result = scheduler.push(frame(n, 24, (uint64_t)n + 1, 1));
        if (result.reject != SPScheduleReject::None) fail("10s push");
        outs.insert(outs.end(), result.events.begin(), result.events.end());
    }
    int inside = 0;
    SPRational previous{0, 1};
    bool have = false;
    for (const auto &event : outs) {
        if (sp::spCmp(event.pts, sp::spMake(10, 1)) < 0) {
            if (have) {
                SPRational step{};
                sp::spSub(event.pts, previous, step);
                if (!same(step, sp::spMake(1, 60))) fail("10s step drifted");
            }
            previous = event.pts;
            have = true;
            inside += 1;
        }
    }
    for (size_t i = 1; i < outs.size(); ++i) {
        if (sp::spCmp(outs[i].pts, outs[i - 1].pts) <= 0) fail("10s duplicate or reverse");
    }
    if (inside != 600) fail("10s count " + std::to_string(inside));
}

static void testSceneGapBoundaryAndRepeats() {
    SPRateRequest request;
    request.kind = SPRateKind::Multiplier;
    request.multiplier = 2;
    auto cut = makeScheduler(request);
    cut.push(frame(0, 30, 1, 1, true));
    auto across = cut.push(frame(1, 30, 2, 1));
    auto after = cut.push(frame(2, 30, 3, 1));
    if (across.events.size() != 2) fail("cut count");
    expectEvent(across.events[0], SPScheduleAction::Hold, sp::spMake(1, 60), 1, 0, sp::spMake(0, 1), "cut hold");
    if (across.events[0].skipReason != SPScheduleSkipReason::SceneCut) fail("cut reason");
    if (across.events[0].action == SPScheduleAction::Interpolate) fail("cut synthesized");
    expectEvent(after.events[0], SPScheduleAction::Interpolate, sp::spMake(1, 20), 2, 3, sp::spMake(1, 2), "after cut");

    SPRateRequest x3;
    x3.kind = SPRateKind::Multiplier;
    x3.multiplier = 3;
    auto cut3 = makeScheduler(x3);
    cut3.push(frame(0, 1, 1, 1, true));
    auto held = cut3.push(frame(1, 1, 2, 1));
    int interps = 0, holds = 0;
    for (const auto &event : held.events) {
        if (event.action == SPScheduleAction::Interpolate) interps += 1;
        if (event.action == SPScheduleAction::Hold) holds += 1;
    }
    if (interps != 0 || holds != 2) fail("x3 cut holds");

    auto gap = makeScheduler(request);
    gap.push(frame(0, 1, 1, 1));
    auto jumped = gap.push(frame(2, 1, 2, 1));
    if (jumped.events.empty() || jumped.events[0].action != SPScheduleAction::Hold) fail("long gap interpolated");
    if (jumped.events[0].skipReason != SPScheduleSkipReason::Gap) fail("gap reason");

    auto boundary = makeScheduler(request);
    boundary.push(frame(0, 30, 1, 1));
    boundary.noteBoundary();
    auto next = boundary.push(frame(1, 30, 2, 1));
    if (next.events.empty() || next.events[0].skipReason != SPScheduleSkipReason::Boundary) fail("boundary");
    if (next.events[0].action == SPScheduleAction::Interpolate) fail("boundary synthesized");

    auto dup = makeScheduler(request);
    dup.push(frame(0, 30, 1, 1));
    auto again = dup.push(frame(0, 30, 2, 1));
    expectReject(again.reject, SPScheduleReject::DuplicatePTS, "duplicate pts");
    if (!again.events.empty()) fail("duplicate emitted");
    auto third = dup.push(frame(1, 30, 3, 1));
    expectEvent(third.events[0], SPScheduleAction::Interpolate, sp::spMake(1, 60), 1, 3, sp::spMake(1, 2), "dup parent");

    auto rev = makeScheduler(request);
    rev.push(frame(1, 30, 1, 1));
    auto back = rev.push(frame(0, 30, 2, 1));
    expectReject(back.reject, SPScheduleReject::OutOfOrder, "reverse");
    if (!back.events.empty()) fail("reverse emitted");
    auto forward = rev.push(frame(2, 30, 3, 1));
    expectEvent(forward.events[0], SPScheduleAction::Interpolate, sp::spMake(1, 20), 1, 3, sp::spMake(1, 2), "after reverse");

    auto keep = makeScheduler(request);
    auto first = frame(0, 30, 1, 1);
    keep.push(first);
    auto repeated = frame(1, 30, 2, 1);
    repeated.contentDuplicate = true;
    auto kept = keep.push(repeated);
    if (kept.events.size() != 2 || kept.events[0].action != SPScheduleAction::Interpolate) fail("dropped a held animation frame");
}

static void testDownsampleAndCancel() {
    SPRateRequest request;
    request.kind = SPRateKind::FixedFPS;
    request.fps = sp::spMake(30, 1);
    auto scheduler = makeScheduler(request);
    std::vector<SPScheduleOutput> outs;
    for (int n = 0; n <= 4; ++n) {
        auto result = scheduler.push(frame(n, 60, (uint64_t)n + 1, 1));
        outs.insert(outs.end(), result.events.begin(), result.events.end());
    }
    if (outs.size() != 3) fail("60to30 count");
    for (const auto &event : outs) {
        if (event.action != SPScheduleAction::PresentSource) fail("60to30 interpolated");
    }
    expectEvent(outs[0], SPScheduleAction::PresentSource, sp::spMake(0, 1), 1, 0, sp::spMake(0, 1), "60to30 0");
    expectEvent(outs[1], SPScheduleAction::PresentSource, sp::spMake(1, 30), 3, 0, sp::spMake(0, 1), "60to30 1");
    expectEvent(outs[2], SPScheduleAction::PresentSource, sp::spMake(2, 30), 5, 0, sp::spMake(0, 1), "60to30 2");

    SPRateRequest to24;
    to24.kind = SPRateKind::FixedFPS;
    to24.fps = sp::spMake(24, 1);
    auto odd = makeScheduler(to24);
    std::vector<SPScheduleOutput> oddOuts;
    for (int n = 0; n <= 5; ++n) {
        auto result = odd.push(frame(n, 60, (uint64_t)n + 1, 1));
        oddOuts.insert(oddOuts.end(), result.events.begin(), result.events.end());
    }
    bool sawHalf = false;
    bool sawDropped = false;
    for (const auto &event : oddOuts) {
        if (event.action == SPScheduleAction::Interpolate && same(event.phase, sp::spMake(1, 2)) && event.frameA == 3 &&
            event.frameB == 4) {
            sawHalf = true;
        }
        if (same(event.pts, sp::spMake(1, 60))) sawDropped = true;
    }
    if (!sawHalf) fail("60to24 missing 1/2 between sources 2 and 3");
    if (sawDropped) fail("60to24 emitted an off-grid source");

    auto cancelled = makeScheduler(request, 4);
    cancelled.push(frame(0, 30, 1, 4));
    cancelled.cancel();
    auto stopped = cancelled.push(frame(1, 30, 2, 4));
    expectReject(stopped.reject, SPScheduleReject::Cancelled, "cancel");
    if (!stopped.events.empty()) fail("cancelled event");
    auto mismatch = makeScheduler(request, 9);
    auto wrong = mismatch.push(frame(0, 30, 1, 8));
    expectReject(wrong.reject, SPScheduleReject::GenerationMismatch, "generation");
    if (!wrong.events.empty()) fail("wrong generation emitted");
    auto ok = mismatch.push(frame(0, 30, 1, 9));
    if (ok.events.size() != 1) fail("matching generation dropped");

    SPRateRequest bad;
    bad.kind = SPRateKind::Multiplier;
    bad.multiplier = 5;
    SPRateScheduler rejected;
    if (rejected.reset(bad, 1, sp::spMake(1, 2))) fail("x5 accepted");
}

static void testSceneSamples() {
    uint8_t sameA[64], sameB[64], motionA[64], motionB[64], cutA[64], cutB[64];
    for (int i = 0; i < 64; ++i) {
        sameA[i] = sameB[i] = 40;
        motionA[i] = 40;
        motionB[i] = (uint8_t)(40 + (i % 5));
        cutA[i] = 12;
        cutB[i] = 220;
    }
    if (sp::spDetectSceneCut(sameA, sameB, 64)) fail("identical samples called a cut");
    if (sp::spDetectSceneCut(motionA, motionB, 64)) fail("small motion called a cut");
    if (!sp::spDetectSceneCut(cutA, cutB, 64)) fail("hard cut missed");
}

static void testFixedGridFourPhases() {
    SPRateRequest request;
    request.kind = SPRateKind::FixedFPS;
    request.fps = sp::spMake(60, 1);
    auto scheduler = makeScheduler(request);
    expectReject(scheduler.push(frame(0, 1, 1, 1)).reject, SPScheduleReject::None, "grid open");
    auto closed = scheduler.push(frame(80, 1000, 2, 1));
    expectReject(closed.reject, SPScheduleReject::None, "grid close");
    int interpolations = 0;
    int sources = 0;
    SPRational previous = sp::spMake(0, 1);
    bool havePrevious = false;
    for (const auto &event : closed.events) {
        if (havePrevious && sp::spCmp(event.pts, previous) <= 0) fail("grid order");
        previous = event.pts;
        havePrevious = true;
        if (event.action == SPScheduleAction::Interpolate) interpolations += 1;
        if (event.action == SPScheduleAction::PresentSource) sources += 1;
    }
    if (interpolations != 4) fail("80ms at 60fps should schedule four phases");
    if (sources != 0) fail("off-grid source was labeled as an output tick");
}

static void testAbsoluteCapturePTS() {
    const int64_t base = 336876423129125LL;
    const int64_t den = 1000000000LL;
    SPRational first = sp::spMake(base, den);
    SPRational second{};
    if (!sp::spAdd(first, sp::spMake(1, 30), second)) fail("absolute second pts");
    SPRational third{};
    if (!sp::spAdd(second, sp::spMake(1001, 30000), third)) fail("absolute mixed denominator");

    SPRateRequest x2;
    x2.kind = SPRateKind::Multiplier;
    x2.multiplier = 2;
    auto scheduler = makeScheduler(x2);
    auto opened = scheduler.push(frame(first.num, first.den, 1, 1));
    auto closed = scheduler.push(frame(second.num, second.den, 2, 1));
    expectReject(opened.reject, SPScheduleReject::None, "absolute x2 open");
    expectReject(closed.reject, SPScheduleReject::None, "absolute x2 close");
    SPRational mid{};
    if (!sp::spAdd(first, sp::spMake(1, 60), mid)) fail("absolute midpoint");
    bool foundMid = false;
    for (const auto &event : closed.events) {
        if (event.action == SPScheduleAction::Interpolate && same(event.pts, mid) && same(event.phase, sp::spMake(1, 2))) {
            foundMid = true;
        }
    }
    if (!foundMid) fail("absolute x2 midpoint");

    for (int multiplier : {3, 4}) {
        SPRateRequest request;
        request.kind = SPRateKind::Multiplier;
        request.multiplier = multiplier;
        auto rated = makeScheduler(request);
        expectReject(rated.push(frame(first.num, first.den, 1, 1)).reject, SPScheduleReject::None, "absolute open");
        auto result = rated.push(frame(second.num, second.den, 2, 1));
        expectReject(result.reject, SPScheduleReject::None, "absolute close");
        int interpolations = 0;
        SPRational previous = first;
        for (const auto &event : result.events) {
            if (sp::spCmp(event.pts, previous) <= 0) fail("absolute order");
            previous = event.pts;
            if (event.action == SPScheduleAction::Interpolate) interpolations += 1;
        }
        if (interpolations != multiplier - 1) fail("absolute phase count");
    }

    SPRateRequest fixed;
    fixed.kind = SPRateKind::FixedFPS;
    fixed.fps = sp::spMake(60000, 1001);
    auto ntsc = makeScheduler(fixed);
    expectReject(ntsc.push(frame(second.num, second.den, 1, 1)).reject, SPScheduleReject::None, "absolute ntsc open");
    auto ntscClose = ntsc.push(frame(third.num, third.den, 2, 1));
    expectReject(ntscClose.reject, SPScheduleReject::None, "absolute ntsc close");
    SPRational previous = sp::spMake(0, 1);
    bool havePrevious = false;
    for (const auto &event : ntscClose.events) {
        if (havePrevious && sp::spCmp(event.pts, previous) <= 0) fail("absolute ntsc order");
        previous = event.pts;
        havePrevious = true;
    }
}

static void testPhaseFloat() {
    float value = 0;
    if (!sp::spPhaseFitsFloat(sp::spMake(1, 3), value)) fail("1/3 float rejected");
    if (!sp::spPhaseFitsFloat(sp::spMake(2, 3), value)) fail("2/3 float rejected");
    float a = 0, b = 0;
    sp::spPhaseFitsFloat(sp::spMake(1, 3), a);
    sp::spPhaseFitsFloat(sp::spMake(2, 3), b);
    if (a == b) fail("x3 phases collapsed");
    if (!sp::spPhaseFitsFloat(sp::spMake(1, 4), value) || !sp::spPhaseFitsFloat(sp::spMake(1, 2), value) ||
        !sp::spPhaseFitsFloat(sp::spMake(3, 4), value)) {
        fail("x4 float rejected");
    }
    if (sp::spPhaseFitsFloat(sp::spMake(0, 1), value) || sp::spPhaseFitsFloat(sp::spMake(1, 1), value)) {
        fail("endpoint phase accepted as interpolation");
    }
}

static void testLiveSourceReuse() {
    struct Case { int numerator, denominator, expectedSynthetic; bool jitter; };
    for (auto test : std::vector<Case>{{24,1,360,false}, {28,1,320,false}, {30,1,300,false},
                                      {30,1,300,true}, {28,1,320,true}, {60,1,0,false},
                                      {120,1,0,false}, {30000,1001,-1,false}}) {
        SPRateRequest request; request.kind=SPRateKind::FixedFPS; request.fps=sp::spMake(60,1); request.reuseSources=true;
        auto scheduler=makeScheduler(request);
        std::vector<SPRational> timestamps;
        std::set<uint64_t> reused;
        int output=0, generated=0, originals=0;
        auto anchor=sp::spMake(2000001,1);
        for (int i=0;i<=int(10.0*test.numerator/test.denominator)+3;++i) {
            auto pts=sp::spMake((int64_t)i*test.denominator,test.numerator);
            if (test.jitter && i>0) { auto delta=sp::spMake((int64_t)std::llround(1800000*std::sin(i*1.731)),1000000000); auto old=pts; sp::spAdd(old,delta,pts); }
            auto local=pts; sp::spAdd(anchor,local,pts); timestamps.push_back(pts);
            auto result=scheduler.push(frame(pts.num,pts.den,i+1,1));
            expectReject(result.reject,SPScheduleReject::None,"live reuse accepted input");
            for (auto event:result.events) {
                sp::SPRational relative{}; sp::spSub(event.pts,anchor,relative);
                if (sp::spCmp(relative,sp::spMake(0,1))<=0 || sp::spCmp(relative,sp::spMake(10,1))>0) continue;
                ++output;
                if (!same(relative,sp::spMake(output,60))) fail("live output clock drifted");
                if (event.action==SPScheduleAction::PresentSource) {
                    ++originals;
                    if (!reused.insert(event.sourceIdentity).second) fail("live source reused twice");
                    sp::SPRational error{}; sp::spSub(event.pts,timestamps[event.sourceIdentity-1],error);
                    if (error.num<0) error.num=-error.num;
                    if (sp::spCmp(error,sp::spMake(1,120))>0) fail("live source exceeded half-period error");
                } else if (event.action==SPScheduleAction::Interpolate) {
                    ++generated;
                    const auto a=timestamps[event.frameA-1], b=timestamps[event.frameB-1];
                    sp::SPRational into{},span{},phase{};sp::spSub(event.pts,a,into);sp::spSub(b,a,span);sp::spDiv(into,span,phase);
                    if (!same(phase,event.phase) || sp::spCmp(phase,sp::spMake(0,1))<=0 || sp::spCmp(phase,sp::spMake(1,1))>=0) fail("live phase lost source timestamp");
                } else fail("live normal cadence unexpectedly held");
            }
        }
        if (output!=600 || originals+generated!=600) fail("live target grid count");
        if (test.expectedSynthetic>=0 && generated!=test.expectedSynthetic) fail("live model generation count");
        if (test.numerator==30000 && (generated<299 || generated>301)) fail("live NTSC source reuse");
        printf("live reuse %d/%d ->60 jitter=%d: originals=%d generated=%d\n",test.numerator,test.denominator,test.jitter,originals,generated);
    }
    SPRateRequest request;request.kind=SPRateKind::FixedFPS;request.reuseSources=true;
    auto live=makeScheduler(request);live.push(frame(0,1,1,1));
    auto early=live.push(frame(31,1000,2,1));bool immediate=false;
    for(auto e:early.events)if(e.action==SPScheduleAction::PresentSource && e.sourceIdentity==2 && same(e.pts,sp::spMake(1,30)))immediate=true;
    if(!immediate)fail("captured source waited for a future input frame");
    auto scheduler=makeScheduler(request);scheduler.push(frame(0,1,1,1));
    auto cut=frame(1,24,2,1);cut.sceneCutBefore=true;
    for(auto e:scheduler.push(cut).events) if(e.action==SPScheduleAction::Interpolate)fail("live reused across scene cut");
    scheduler.noteBoundary();
    for(auto e:scheduler.push(frame(1,12,3,1)).events)if(e.action==SPScheduleAction::Interpolate)fail("live reused across boundary");
    for(auto e:scheduler.push(frame(1,1,4,1)).events)if(e.action==SPScheduleAction::Interpolate)fail("live reused across gap");
}

extern "C" int spRunRateScheduleTests(void) {
    gFailures = 0;
    testMultiplier30();
    testSixtyInputRates();
    testX3X4Parents();
    testNTSC();
    testFilmTo60And30();
    testTenSeconds();
    testSceneGapBoundaryAndRepeats();
    testDownsampleAndCancel();
    testSceneSamples();
    testFixedGridFourPhases();
    testAbsoluteCapturePTS();
    testPhaseFloat();
    testLiveSourceReuse();
    if (gFailures != 0) {
        fprintf(stderr, "%d schedule assertions failed\n", gFailures);
        return gFailures;
    }
    printf("schedule assertions passed\n");
    return 0;
}

#ifdef SP_RATE_SCHEDULE_STANDALONE
int main() { return spRunRateScheduleTests() == 0 ? 0 : 1; }
#endif
