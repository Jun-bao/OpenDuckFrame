#include "SPRateBudget.hpp"
#include <functional>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using sp::RateBudget;
static void expect(bool ok, const char *message) {
    if (!ok) throw std::runtime_error(message);
}
static void feed(RateBudget &budget, int first, int last, double fps, int requested,
                 double serviceMs, uint64_t dropped = 0) {
    for (int tick = first; tick <= last; ++tick)
        budget.update({tick / 10.0, fps, requested, serviceMs, 100, dropped});
}
// Cost fixtures are the C2 measurements stated in the development brief:
// X2 hit median 25.8 ms, X2 miss median 29.6 ms, X3 median 47.6 ms.
// These are deterministic policy tests, not new hardware measurements.
static void x3_at_24() {
    RateBudget b; b.reset(3);
    for (int tick = 0; tick <= 70; ++tick) {
        int before = b.snapshot().effectiveMultiplier;
        b.update({tick / 10.0, 24, 3, before == 3 ? 47.6 : 25.8, 100, before == 3 ? 50u : 0u});
        if (tick < 20) expect(b.snapshot().effectiveMultiplier == 3, "downgraded before two seconds");
        if (tick >= 21) expect(b.snapshot().effectiveMultiplier == 2, "24x3 must settle at x2");
    }
    expect(b.snapshot().downgrades == 1, "24x3 must not repeatedly downgrade");
}
static void x2_at_60() {
    RateBudget b; b.reset(2); feed(b, 0, 21, 60, 2, 25.8, 50);
    expect(b.snapshot().effectiveMultiplier == 1, "60x2 must downgrade to x1");
    expect(b.snapshot().downgrades == 1, "expected one downgrade");
    feed(b, 22, 80, 60, 2, 0, 0);
    expect(b.snapshot().effectiveMultiplier == 1, "60 fps must remain x1");
    expect(b.snapshot().phaseCostMs == 25.8, "x1 must remember phase cost");
}
static void x2_at_30() {
    RateBudget b; b.reset(2); feed(b, 0, 600, 30, 2, 25.8);
    expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().downgrades == 0, "30x2 must stay x2");
}
static void single_spike() {
    RateBudget b; b.reset(2);
    for (int tick = 0; tick <= 80; ++tick) {
        b.update({tick / 10.0, 30, 2, tick == 20 ? 100.0 : 25.8, 100, 60});
        expect(b.snapshot().effectiveMultiplier == 2, "one isolated cost spike must not downgrade");
    }
}
static void only_drops() {
    RateBudget b; b.reset(2); feed(b, 0, 80, 30, 2, 25.8, 70);
    expect(b.snapshot().effectiveMultiplier == 2, "drops without excess service cost must not downgrade");
}
static void over_budget_without_drops() {
    RateBudget b; b.reset(2); feed(b, 0, 80, 60, 2, 25.8, 0);
    expect(b.snapshot().effectiveMultiplier == 2, "sustained cost alone must not downgrade");
}
static void content_60_24() {
    RateBudget b; b.reset(3);
    for (int tick = 0; tick <= 21; ++tick) {
        int effective = b.snapshot().effectiveMultiplier;
        b.update({tick / 10.0, 60, 3, effective == 3 ? 47.6 : 0, 100, 60});
    }
    expect(b.snapshot().effectiveMultiplier == 1, "initial 60 fps overload should reach x1");
    for (int tick = 22; tick <= 130; ++tick) {
        int effective = b.snapshot().effectiveMultiplier;
        b.update({tick / 10.0, 24, 3, effective == 1 ? 0 : 25.8, 100, 0});
        if (tick < 52) expect(b.snapshot().effectiveMultiplier == 1, "upgraded before three seconds");
        if (tick >= 53) expect(b.snapshot().effectiveMultiplier == 2, "24 fps must recover to x2, not x3");
    }
    expect(b.snapshot().upgrades == 1, "expected exactly one recovery step");
}
static void failed_upgrade_cooldown() {
    RateBudget b; b.reset(3);
    feed(b, 0, 21, 24, 3, 47.6, 50);
    expect(b.snapshot().effectiveMultiplier == 2, "cooldown setup downgrade failed");
    feed(b, 22, 54, 24, 3, 17.0);
    expect(b.snapshot().effectiveMultiplier == 3, "cooldown setup upgrade failed");
    feed(b, 55, 77, 24, 3, 47.6, 50);
    expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().upgrades == 1, "failed upgrade must return x2");
    // 23 fps is within the +/-2 band and would otherwise have enough budget.
    feed(b, 78, 200, 23, 3, 17.0);
    feed(b, 201, 374, 24, 3, 17.0);
    expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().upgrades == 1, "same-rate retry occurred within 30 seconds");
    feed(b, 375, 407, 24, 3, 17.0);
    expect(b.snapshot().effectiveMultiplier == 3 && b.snapshot().upgrades == 2, "upgrade should recover after cooldown plus persistence");
}
static void request_reset() {
    RateBudget b; b.reset(2); feed(b, 0, 21, 60, 2, 25.8, 50);
    auto next = b.update({2.2, 24, 3, 47.6, 100, 50});
    expect(next.requestedMultiplier == 3 && next.effectiveMultiplier == 3, "new request must start at requested multiplier");
    expect(next.downgrades == 0 && next.upgrades == 0, "new request must clear counters");
    b.reset(2); next = b.snapshot();
    expect(next.phaseCostMs == 0 && next.effectiveMultiplier == 2, "explicit source/engine reset must clear prior cost");
}
static void threshold_and_suspend() {
    RateBudget b; b.reset(2);
    feed(b, 0, 30, 60, 2, 25.8, 19);
    expect(b.snapshot().effectiveMultiplier == 2, "less than 20 percent drops must not downgrade");
    feed(b, 31, 49, 60, 2, 25.8, 20);
    b.update({5.0, 0, 2, 0, 0, 0});
    feed(b, 51, 69, 60, 2, 25.8, 20);
    expect(b.snapshot().effectiveMultiplier == 2, "suspension must break consecutive overload");
    feed(b, 70, 73, 60, 2, 25.8, 20);
    expect(b.snapshot().effectiveMultiplier == 1, "20 percent sustained overload must downgrade after a fresh two seconds");
}
int main(int argc, char **argv) {
    const std::vector<std::pair<std::string, std::function<void()>>> cases = {
        {"24x3", x3_at_24}, {"60x2", x2_at_60}, {"30x2", x2_at_30},
        {"single_spike", single_spike}, {"only_drops", only_drops},
        {"over_budget_without_drops", over_budget_without_drops},
        {"content_60_24", content_60_24}, {"failed_upgrade_cooldown", failed_upgrade_cooldown},
        {"request_reset", request_reset}, {"threshold_and_suspend", threshold_and_suspend}
    };
    int executed = 0, failed = 0;
    for (const auto &test : cases) {
        if (argc > 1 && test.first != argv[1]) continue;
        ++executed;
        try { test.second(); std::cout << "PASS " << test.first << '\n'; }
        catch (const std::exception &error) { ++failed; std::cerr << "FAIL " << test.first << ": " << error.what() << '\n'; }
    }
    if (!executed) { std::cerr << "Unknown case\n"; return 2; }
    return failed ? 1 : 0;
}
