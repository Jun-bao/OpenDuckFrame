#include "SPRateBudget.hpp"
#include <algorithm>
#include <cmath>
#include <deque>
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
static double median(std::vector<double> values) {
    expect(!values.empty(), "median requires samples");
    std::sort(values.begin(), values.end());
    size_t n = values.size();
    return (values[(n - 1) / 2] + values[n / 2]) / 2.0;
}
// Recorded frcEwmaMs policy inputs, not individual GPU task samples.
// C2-multiplier-episode.ndjson: 135 original rows, SHA-256
// 11d56d619503578a2cd32e22722695ccc3c924af10bd2d0e59e3549957133ba1.
// Rows are 1-based. Each value is held for one simulated second; this
// replays the observed EWMA sequence, not the original wall-clock timing.
static const std::vector<double> c2_24x2 = { // Rows 14..21.
    27.206039642828728, 26.862490284213436, 27.849079884417463, 26.49617267462655,
    23.6347289702437, 27.036242388991216, 25.306584493779663, 26.188800643467523
};
static const std::vector<double> c2_30x2 = { // Rows 23..31.
    25.806071463336856, 26.990873453144214, 26.116966895899914,
    23.028350772846373, 22.99300310997874, 26.51540162261593,
    22.42891817242946, 26.089703235259986, 22.73856974985492
};
static const std::vector<double> c2_60x2 = { // Rows 34..41.
    26.917327805939077, 29.93830185797397, 30.6153269018176, 29.045901815852538,
    33.101265470304256, 26.896516990900373, 29.272033587271473, 31.07552781342401
};
static const std::vector<double> c2_24x3 = { // Continuous unpaused rows 103..126.
    50.18510022200644, 44.37476236680595, 47.34113087683149, 47.28531714472349,
    47.91457764451817, 49.69403289687868, 47.65856578259921, 46.41913227527687,
    48.95070924429824, 47.029035089412396, 48.70452913204189, 50.569393844762395,
    47.62683044497304, 47.189301778804, 47.51183333414443, 48.12529757136249,
    48.1994308112526, 50.16459465743864, 47.730494514219735, 47.35061756666802,
    50.093882308120705, 44.11553145689265, 49.70094154087975, 49.162116555510934
};
static double sequenceCost(const std::vector<double> &values, int tick) {
    return values[static_cast<size_t>(tick / 10) % values.size()];
}
// Existing policy tests explicitly model a continuing stream with 16
// valid completions in the past two seconds. Dedicated freshness tests
// supply zero, and a8_replay counts actual simulated completions.
static void feed(RateBudget &budget, int first, int last, double fps, int requested,
                 double serviceMs, uint64_t dropped = 0, uint64_t freshSamples = 16) {
    for (int tick = first; tick <= last; ++tick)
        budget.update({tick / 10.0, fps, requested, serviceMs, 100, dropped, freshSamples});
}
static void x3_at_24() {
    RateBudget b; b.reset(3);
    for (int tick = 0; tick <= 100; ++tick) {
        int before = b.snapshot().effectiveMultiplier;
        double cost = sequenceCost(before == 3 ? c2_24x3 : c2_24x2, tick);
        b.update({tick / 10.0, 24, 3, cost, 100, before == 3 ? 50u : 0u, 16});
        if (tick < 50) expect(b.snapshot().effectiveMultiplier == 3, "downgraded before warmup plus two seconds");
        if (tick >= 51) expect(b.snapshot().effectiveMultiplier == 2, "24x3 must settle at x2");
    }
    expect(b.snapshot().downgrades == 1, "24x3 must not repeatedly downgrade");
}
static void x2_at_60() {
    RateBudget b; b.reset(2);
    for (int tick = 0; tick <= 51; ++tick) {
        bool active = b.snapshot().effectiveMultiplier > 1;
        b.update({tick / 10.0, 60, 2, active ? sequenceCost(c2_60x2, tick) : 0,
                  100, active ? 50u : 0u, active ? 16u : 0u});
    }
    expect(b.snapshot().effectiveMultiplier == 1, "60x2 must downgrade to x1");
    expect(b.snapshot().downgrades == 1, "expected one downgrade");
    double remembered = b.snapshot().phaseCostMs;
    expect(remembered > 0, "downgrade must retain a measured phase cost");
    feed(b, 52, 110, 60, 2, 0, 0, 0);
    expect(b.snapshot().effectiveMultiplier == 1, "60 fps must remain x1");
    expect(b.snapshot().phaseCostMs == remembered, "x1 must remember phase cost");
}
static void x2_at_30() {
    RateBudget b; b.reset(2);
    for (int tick = 0; tick <= 600; ++tick)
        b.update({tick / 10.0, 30, 2, sequenceCost(c2_30x2, tick), 100, 0, 16});
    expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().downgrades == 0, "30x2 must stay x2");
}
static void single_spike() {
    RateBudget b; b.reset(2);
    // Put the spike after warmup so warmup cannot conceal this regression.
    for (int tick = 0; tick <= 100; ++tick) {
        b.update({tick / 10.0, 30, 2, tick == 40 ? 100.0 : sequenceCost(c2_30x2, tick), 100, 60, 16});
        expect(b.snapshot().effectiveMultiplier == 2, "one isolated cost spike must not downgrade");
    }
}
static void only_drops() {
    RateBudget b; b.reset(2); feed(b, 0, 100, 30, 2, median(c2_30x2), 70);
    expect(b.snapshot().effectiveMultiplier == 2, "drops without excess service cost must not downgrade");
}
static void over_budget_without_drops() {
    RateBudget b; b.reset(2); feed(b, 0, 100, 60, 2, median(c2_60x2), 0);
    expect(b.snapshot().effectiveMultiplier == 2, "sustained cost alone must not downgrade");
}
static void content_60_24() {
    RateBudget b; b.reset(3);
    for (int tick = 0; tick <= 51; ++tick) {
        bool active = b.snapshot().effectiveMultiplier > 1;
        b.update({tick / 10.0, 60, 3, active ? median(c2_24x3) : 0,
                  100, active ? 60u : 0u, active ? 16u : 0u});
    }
    expect(b.snapshot().effectiveMultiplier == 1, "initial 60 fps overload should reach x1");
    for (int tick = 52; tick <= 160; ++tick) {
        int effective = b.snapshot().effectiveMultiplier;
        b.update({tick / 10.0, 24, 3, effective == 1 ? 0 : sequenceCost(c2_24x2, tick),
                  100, 0, effective == 1 ? 0u : 16u});
        if (tick < 82) expect(b.snapshot().effectiveMultiplier == 1, "upgraded before three seconds");
        if (tick >= 83) expect(b.snapshot().effectiveMultiplier == 2, "24 fps must recover to x2, not x3");
    }
    expect(b.snapshot().upgrades == 1, "expected exactly one recovery step");
}
static void failed_upgrade_cooldown() {
    RateBudget b; b.reset(3);
    feed(b, 0, 51, 24, 3, median(c2_24x3), 50);
    expect(b.snapshot().effectiveMultiplier == 2, "cooldown setup downgrade failed");
    // Synthetic improvement for this boundary, not a C2 measurement.
    feed(b, 52, 84, 24, 3, 17.0);
    expect(b.snapshot().effectiveMultiplier == 3, "cooldown setup upgrade failed");
    // New rate gets three-second warmup plus two-second confirmation.
    feed(b, 85, 136, 24, 3, median(c2_24x3), 50);
    expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().upgrades == 1, "failed upgrade must return x2");
    feed(b, 137, 250, 23, 3, 17.0);
    feed(b, 251, 430, 24, 3, 17.0);
    expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().upgrades == 1, "same-rate retry occurred within 30 seconds");
    feed(b, 431, 470, 24, 3, 17.0);
    expect(b.snapshot().effectiveMultiplier == 3 && b.snapshot().upgrades == 2, "upgrade should recover after cooldown plus persistence");
}
static void request_reset() {
    RateBudget b; b.reset(2); feed(b, 0, 51, 60, 2, median(c2_60x2), 50);
    auto next = b.update({5.2, 24, 3, median(c2_24x3), 100, 50, 16});
    expect(next.requestedMultiplier == 3 && next.effectiveMultiplier == 3, "new request must start at requested multiplier");
    expect(next.downgrades == 0 && next.upgrades == 0, "new request must clear counters");
    b.reset(2); next = b.snapshot();
    expect(next.phaseCostMs == 0 && next.effectiveMultiplier == 2, "explicit source/engine reset must clear prior cost");
}
static void threshold_and_suspend() {
    RateBudget b; b.reset(2);
    double cost = median(c2_60x2);
    feed(b, 0, 30, 60, 2, cost, 19);
    expect(b.snapshot().effectiveMultiplier == 2, "less than 20 percent drops must not downgrade");
    feed(b, 31, 49, 60, 2, cost, 20);
    b.update({5.0, 0, 2, 0, 0, 0, 0});
    feed(b, 51, 69, 60, 2, cost, 20);
    expect(b.snapshot().effectiveMultiplier == 2, "suspension must break consecutive overload");
    feed(b, 70, 73, 60, 2, cost, 20);
    expect(b.snapshot().effectiveMultiplier == 1, "20 percent sustained overload must downgrade after a fresh two seconds");
}
static void idle_never_rejected() {
    expect(sp::shouldAdmitRife(0, 9, 80, 0, 69), "idle RIFE must admit even when the old estimate misses deadline");
    expect(sp::shouldAdmitRife(0, 32, 80, 0, -1), "idle RIFE must keep producing samples even for an expired phase");
}
static void busy_late_rejected() {
    expect(!sp::shouldAdmitRife(1, 9, 80, 0, 69), "busy RIFE must reject predicted late work");
    expect(!sp::shouldAdmitRife(1, 9, 80, 100, 69), "elapsed service does not remove the new task cost");
    expect(sp::shouldAdmitRife(1, 9, 26, 10, 42), "exactly fitting remaining plus new service must be admitted");
    expect(sp::shouldAdmitRife(1, 7, 80, 0, 69), "fewer than eight samples must not predictively reject");
    expect(!sp::shouldAdmitRife(2, 0, 0, 0, 1000), "capacity limit must reject even without cost samples");
}
static void stale_samples_no_downgrade() {
    RateBudget b; b.reset(2);
    for (int tick = 0; tick <= 100; ++tick) {
        b.update({tick / 10.0, 24, 2, 68, 100, 100, 0});
        expect(b.snapshot().effectiveMultiplier == 2, "stale 68ms cost and rejected phases must not cause downgrade");
    }
}
static void warmup_no_downgrade() {
    RateBudget b; b.reset(2);
    for (int tick = 0; tick <= 29; ++tick) {
        b.update({tick / 10.0, 24, 2, 68, 100, 100, 16});
        expect(b.snapshot().effectiveMultiplier == 2, "startup warmup must suppress downgrade");
    }
    b.markRateApplied(3.0);
    for (int tick = 30; tick <= 59; ++tick) {
        b.update({tick / 10.0, 24, 2, 68, 100, 100, 16});
        expect(b.snapshot().effectiveMultiplier == 2, "applied-rate warmup must suppress downgrade");
    }
}
static void real_overload_downgrades() {
    RateBudget b; b.reset(2);
    for (int tick = 0; tick <= 49; ++tick) {
        b.update({tick / 10.0, 24, 2, 68, 100, 100, 16});
        expect(b.snapshot().effectiveMultiplier == 2, "real overload must wait for warmup and two-second confirmation");
    }
    feed(b, 50, 51, 24, 2, 68, 100, 16);
    expect(b.snapshot().effectiveMultiplier == 1 && b.snapshot().downgrades == 1, "fresh sustained real overload must downgrade to x1");
}
static void probe_recovers() {
    RateBudget b; b.reset(2); feed(b, 0, 51, 24, 2, 68, 100, 16);
    expect(b.snapshot().effectiveMultiplier == 1 && b.snapshot().phaseCostMs == 68, "probe recovery setup must reach x1 with old 68ms cost");
    expect(b.recordProbePhaseCost(26), "valid x1 probe cost must be accepted");
    b.update({6.0, 24, 2, 0, 0, 0, 0});
    feed(b, 61, 89, 24, 2, 0, 0, 0);
    expect(b.snapshot().effectiveMultiplier == 1, "probe must not bypass three-second upgrade persistence");
    b.update({9.0, 24, 2, 0, 0, 0, 0});
    expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().upgrades == 1, "26ms probe must recover x2 at 24fps after three seconds");
}
static void probe_no_false_upgrade() {
    RateBudget b; b.reset(2); feed(b, 0, 51, 60, 2, 68, 100, 16);
    expect(b.snapshot().effectiveMultiplier == 1, "false-upgrade setup must reach x1");
    expect(!b.recordProbePhaseCost(0) && !b.recordProbePhaseCost(-1) &&
           !b.recordProbePhaseCost(std::numeric_limits<double>::quiet_NaN()), "invalid probe samples must not become a zero-cost upgrade");
    expect(b.recordProbePhaseCost(26), "valid probe must update remembered phase cost");
    feed(b, 60, 200, 60, 2, 0, 0, 0);
    expect(b.snapshot().effectiveMultiplier == 1 && b.snapshot().upgrades == 0, "26ms probe cannot support x2 at 60fps");
}
// Synthetic mechanism replay specified by the return brief, separate from C2.
// Only admitted jobs complete and create samples. First nine: median68/P80=80;
// later jobs:26ms. A serial GPU has at most two outstanding jobs.
static void a8_replay() {
    struct Job { double started, finished, costMs, deadline; };
    struct Cost { double completed, ms; };
    struct Phase { double when; uint64_t planned, dropped; };
    const std::vector<double> initialCosts = {80, 68, 68, 68, 68, 68, 80, 80, 68};
    std::deque<Job> pending;
    std::deque<Cost> costs;
    std::deque<double> completedTimes;
    std::deque<Phase> phases;
    size_t admitted = 0, completed = 0;
    double nextPair = 0;
    RateBudget b; b.reset(2);
    auto costValues = [&]() {
        std::vector<double> result;
        for (const auto &cost : costs) result.push_back(cost.ms);
        return result;
    };
    for (int tick = 0; tick <= 12000; ++tick) {
        double now = tick / 1000.0;
        while (!pending.empty() && pending.front().finished <= now) {
            Job job = pending.front(); pending.pop_front();
            ++completed;
            costs.push_back({job.finished, job.costMs});
            if (costs.size() > 32) costs.pop_front();
            completedTimes.push_back(job.finished);
            if (job.finished > job.deadline) phases.push_back({job.finished, 0, 1});
        }
        while (!completedTimes.empty() && now - completedTimes.front() > 2.0) completedTimes.pop_front();
        if (now + 1e-9 >= nextPair) {
            nextPair += 1.0 / 24.0;
            phases.push_back({now, 1, 0});
            auto values = costValues();
            double service = 0;
            if (!values.empty()) {
                std::sort(values.begin(), values.end());
                service = values[(values.size() - 1) * 80 / 100];
            }
            double elapsed = pending.empty() ? 0 : std::max(0.0, (now - pending.front().started) * 1000.0);
            bool allowed = sp::shouldAdmitRife((int)pending.size(), costs.size(), service, elapsed, 69);
            if (allowed) {
                double actual = admitted < initialCosts.size() ? initialCosts[admitted] : 26;
                double starts = pending.empty() ? now : std::max(now, pending.back().finished);
                pending.push_back({starts, starts + actual / 1000.0, actual, now + 0.069});
                ++admitted;
            } else phases.push_back({now, 0, 1});
        }
        while (!phases.empty() && now - phases.front().when > 1.0) phases.pop_front();
        uint64_t planned = 0, dropped = 0;
        for (const auto &phase : phases) { planned += phase.planned; dropped += phase.dropped; }
        auto values = costValues();
        if (values.size() > 16) values.erase(values.begin(), values.end() - 16);
        double taskMedian = values.empty() ? 0 : median(values);
        b.update({now, 24, 2, taskMedian, planned, dropped, (uint64_t)completedTimes.size()});
        expect(b.snapshot().effectiveMultiplier == 2, "a8 replay must stay x2 while fresh task costs recover");
    }
    expect(completed > initialCosts.size(), "a8 replay must keep completing tasks after the initial nine");
    expect(b.snapshot().phaseCostMs == 26, "a8 replay must replace the initial estimate with new samples");
    expect(b.snapshot().downgrades == 0, "a8 recovery must not create a self-induced downgrade");
}
static void display_cap_without_cost() {
    RateBudget b; b.reset(2);
    for (int tick = 0; tick <= 10; ++tick) {
        auto s = b.update({tick / 10.0, 114, 2, 0, 0, 0, 0, 120});
        expect(s.effectiveMultiplier == (tick < 10 ? 2 : 1), "114fps must reach x1 after exactly one second without samples or warmup");
        if (tick == 5) b.markRateApplied(0.5);
    }
    auto s = b.snapshot();
    expect(s.displayCap == 1 && s.limit == sp::RateBudgetLimit::Display, "114fps bypass must be limited by display");
    expect(s.displayCapChanges == 1 && s.downgrades == 0 && s.upgrades == 0, "display bypass must not increment compute counters");
    expect(s.phaseCostMs == 0, "display bypass must not invent a phase cost");
}
static void display_cap_boundaries() {
    for (double fps : {60.0, 61.0, 62.0}) {
        RateBudget b; b.reset(2);
        for (int tick = 0; tick <= 20; ++tick) b.update({tick / 10.0, fps, 2, 0, 0, 0, 0, 120});
        int expected = fps < 62 ? 2 : 1;
        expect(b.snapshot().effectiveMultiplier == expected, "60 and 61 fps fit x2, but 62 fps exceeds the 1.02 display allowance");
        expect(b.snapshot().displayCap == expected, "display cap must use the specified floor");
        expect(b.snapshot().limit == (expected == 2 ? sp::RateBudgetLimit::None : sp::RateBudgetLimit::Display), "boundary reason must match the applied rate");
    }
    RateBudget b; b.reset(3);
    for (int tick = 0; tick <= 10; ++tick) b.update({tick / 10.0, 60, 3, 0, 0, 0, 0, 120});
    expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().displayCap == 2 &&
           b.snapshot().limit == sp::RateBudgetLimit::Display, "60fps x3 must stop at display-limited x2");
    for (double hz : {0.0, 1.0, -1.0, std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::infinity()}) {
        b.reset(2);
        for (int tick = 0; tick <= 20; ++tick) b.update({tick / 10.0, 114, 2, 0, 0, 0, 0, hz});
        expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().displayCap == 2 &&
               b.snapshot().limit == sp::RateBudgetLimit::None, "unknown or invalid refresh must not impose a display cap");
    }
}
static void display_recovers_without_cooldown() {
    for (double initialCost : {0.0, 68.0}) {
        RateBudget b; b.reset(2);
        for (int tick = 0; tick <= 10; ++tick) b.update({tick / 10.0, 114, 2, initialCost, 0, 0, 0, 120});
        expect(b.snapshot().effectiveMultiplier == 1, "display recovery setup must reach x1");
        for (int tick = 20; tick <= 30; ++tick) {
            auto s = b.update({tick / 10.0, 24, 2, 0, 0, 0, 0, 120});
            expect(s.effectiveMultiplier == (tick < 30 ? 1 : 2), "display recovery must persist for one second, including with unknown P");
        }
        expect(b.snapshot().limit == sp::RateBudgetLimit::None && b.snapshot().displayCapChanges == 2 &&
               b.snapshot().upgrades == 0, "display recovery must have its own counter and clear the limit");
        // A real overload after this recovery must not classify it as a failed
        // compute upgrade and block the next probe-based recovery for 30s.
        for (int tick = 31; tick <= 81; ++tick) b.update({tick / 10.0, 24, 2, 68, 100, 100, 16, 120});
        expect(b.snapshot().effectiveMultiplier == 1 && b.snapshot().limit == sp::RateBudgetLimit::Compute,
               "fresh overload after display recovery must still downgrade by compute");
        expect(b.recordProbePhaseCost(26), "compute-limited x1 must accept a fresh recovery probe");
        for (int tick = 82; tick <= 113; ++tick) b.update({tick / 10.0, 24, 2, 0, 0, 0, 0, 120});
        expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().upgrades == 1,
               "display recovery must not create a failed-upgrade cooldown");
    }
}
static void display_flicker_debounce() {
    RateBudget b; b.reset(2);
    for (int tick = 0; tick <= 100; ++tick) {
        double fps = (tick / 6) % 2 ? 60.5 : 62.5;
        b.update({tick / 10.0, fps, 2, 0, 0, 0, 0, 120});
        expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().displayCapChanges == 0,
               "sub-second 60.5/62.5fps changes must not trigger a display downgrade");
    }
    b.reset(2);
    for (int tick = 0; tick <= 10; ++tick) b.update({tick / 10.0, 114, 2, 0, 0, 0, 0, 120});
    for (int tick = 20; tick <= 120; ++tick) {
        double fps = ((tick - 20) / 6) % 2 ? 62.5 : 60.5;
        b.update({tick / 10.0, fps, 2, 0, 0, 0, 0, 120});
        expect(b.snapshot().effectiveMultiplier == 1 && b.snapshot().displayCapChanges == 1,
               "sub-second cap changes must also debounce display recovery");
    }
    b.reset(2);
    b.update({0, 114, 2, 0, 0, 0, 0, 120});
    b.update({0.6, 114, 2, 0, 0, 0, 0, 120});
    b.update({0.9, 0, 2, 0, 0, 0, 0, 120});
    b.update({1.0, 114, 2, 0, 0, 0, 0, 120});
    b.update({1.9, 114, 2, 0, 0, 0, 0, 120});
    expect(b.snapshot().effectiveMultiplier == 2, "unknown content FPS must interrupt display persistence");
    b.update({2.0, 114, 2, 0, 0, 0, 0, 120});
    expect(b.snapshot().effectiveMultiplier == 1, "display persistence must restart after unknown FPS");
}
static void display_preserves_compute_policy() {
    RateBudget b; b.reset(2);
    for (int tick = 0; tick <= 51; ++tick) {
        b.update({tick / 10.0, 24, 2, 68, 100, 100, 16, 120});
        if (tick < 50) expect(b.snapshot().effectiveMultiplier == 2, "display support must not shorten compute warmup or persistence");
    }
    auto s = b.snapshot();
    expect(s.effectiveMultiplier == 1 && s.displayCap == 2 && s.limit == sp::RateBudgetLimit::Compute &&
           s.downgrades == 1 && s.displayCapChanges == 0, "24fps real overload must remain a compute downgrade");
    // At 60fps the display permits only x2 even if the GPU could sustain x3.
    b.reset(3);
    for (int tick = 0; tick <= 100; ++tick) {
        b.update({tick / 10.0, 60, 3, 2, 100, 0, 16, 120});
        if (tick >= 10) expect(b.snapshot().effectiveMultiplier <= 2, "compute recovery cannot briefly cross the display cap");
    }
    expect(b.snapshot().effectiveMultiplier == 2 && b.snapshot().limit == sp::RateBudgetLimit::Display &&
           b.snapshot().upgrades == 0, "compute upgrades must never exceed the display cap");
    expect(std::string(sp::rateBudgetLimitName(sp::RateBudgetLimit::None)) == "none" &&
           std::string(sp::rateBudgetLimitName(sp::RateBudgetLimit::Display)) == "display" &&
           std::string(sp::rateBudgetLimitName(sp::RateBudgetLimit::Compute)) == "compute", "limit names must match the log contract");
}
int main(int argc, char **argv) {
    const std::vector<std::pair<std::string, std::function<void()>>> cases = {
        {"24x3", x3_at_24}, {"60x2", x2_at_60}, {"30x2", x2_at_30},
        {"single_spike", single_spike}, {"only_drops", only_drops},
        {"over_budget_without_drops", over_budget_without_drops},
        {"content_60_24", content_60_24}, {"failed_upgrade_cooldown", failed_upgrade_cooldown},
        {"request_reset", request_reset}, {"threshold_and_suspend", threshold_and_suspend},
        {"idle_never_rejected", idle_never_rejected}, {"busy_late_rejected", busy_late_rejected},
        {"stale_samples_no_downgrade", stale_samples_no_downgrade}, {"warmup_no_downgrade", warmup_no_downgrade},
        {"a8_replay", a8_replay}, {"real_overload_downgrades", real_overload_downgrades},
        {"probe_recovers", probe_recovers}, {"probe_no_false_upgrade", probe_no_false_upgrade},
        {"display_cap_without_cost", display_cap_without_cost}, {"display_cap_boundaries", display_cap_boundaries},
        {"display_recovers_without_cooldown", display_recovers_without_cooldown},
        {"display_flicker_debounce", display_flicker_debounce}, {"display_preserves_compute_policy", display_preserves_compute_policy}
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
