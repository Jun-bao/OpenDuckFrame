// Shared runtime gates and monotonic clock for the media core.
// Debug logging is cached and remains available in store builds. Behavior-
// changing automation is compiled out of that lane, including each hook body.
// The clock returns CLOCK_UPTIME_RAW microseconds. The full feature tier starts
// at macOS 26; individual system APIs still require their own availability checks.
#pragma once

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <time.h>

static inline bool spDebug() {
    static const bool on = getenv("SP_DEBUG") != nullptr;
    return on;
}

static inline bool spAutomation() {
#if SP_APP_STORE
    return false;
#else
    static const bool on = spDebug() || getenv("SP_AUTOMATION") != nullptr;
    return on;
#endif
}

static inline int64_t spNowUs() {
    return (int64_t)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000);
}

static inline bool spFullTier() {
    static const bool full = [] {
#if !SP_APP_STORE
        if (spAutomation()) {
            const char *t = getenv("SP_TIER");
            if (t && strcmp(t, "compat") == 0) return false;
        }
#endif
        if (__builtin_available(macOS 26.0, *)) return true;
        return false;
    }();
    return full;
}
