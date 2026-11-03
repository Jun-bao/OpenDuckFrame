#pragma once

#include <cstdint>
#include <initializer_list>
#include <string>

namespace spgrow {

enum class Mode : uint8_t { Static = 0, Probing = 1, Growing = 2, Final = 3 };
enum class Action : uint8_t { EndOfFile = 0, Retry = 1, Wait = 2 };

constexpr int64_t kRecentMtimeNs = 5LL * 1000 * 1000 * 1000;

constexpr int64_t kProbeGraceUs = 3 * 1000 * 1000;

constexpr int64_t kIdleFinalUs = 30 * 1000 * 1000;

constexpr int64_t kStalledHintUs = 10 * 1000 * 1000;

constexpr int64_t kIdleFinalAfterHintUs = 1 * 1000 * 1000;

constexpr int64_t kPollUs = 100 * 1000;

constexpr int64_t kPendingZeroRun = 16 * 1024;

constexpr int64_t kWatchRecentNs = 10LL * 60 * 1000 * 1000 * 1000;

struct FileStamp {
    int64_t size = -1;
    int64_t mtimeNs = 0;
    bool operator==(const FileStamp& o) const { return size == o.size && mtimeNs == o.mtimeNs; }
    bool operator!=(const FileStamp& o) const { return !(*this == o); }
};

struct Inputs {
    Mode mode = Mode::Static;
    FileStamp atOpen;
    FileStamp now;
    int64_t readPos = 0;
    bool downloadHint = false;
    bool hadDownloadHint = false;
    int64_t wallNowNs = 0;
    int64_t monoNowUs = 0;
    int64_t lastGrowthUs = 0;
    int64_t probeStartUs = 0;

    int writerOpen = -1;

    bool pendingZero = false;

    bool inPlaceFill = false;

    int64_t openWallNs = 0;
};

struct Decision {
    Mode mode = Mode::Static;
    Action action = Action::EndOfFile;
};

inline bool changedSinceOpen(const Inputs& in) { return in.now.size >= 0 && in.now != in.atOpen; }

inline bool pendingZeroEligible(const FileStamp& atOpen, const FileStamp& now, bool sparseHole) {
    return sparseHole || (now.size >= 0 && now.size == atOpen.size);
}

inline Decision decide(const Inputs& in) {
    Decision d{in.mode, Action::EndOfFile};
    if (in.now.size < 0) return d;
    const bool bytesAhead = !in.pendingZero && in.now.size > in.readPos;

    const bool inPlaceEnd = !in.pendingZero && in.inPlaceFill && in.now.size == in.atOpen.size && !bytesAhead;
    switch (in.mode) {
    case Mode::Static: {
        if (changedSinceOpen(in)) {
            d.mode = Mode::Growing;
            d.action = bytesAhead ? Action::Retry : inPlaceEnd ? Action::EndOfFile : Action::Wait;
            return d;
        }
        const bool recent = in.wallNowNs - in.now.mtimeNs < kRecentMtimeNs;

        if (inPlaceEnd) return d;

        const bool pausedAtOpen = in.openWallNs > 0 && in.openWallNs - in.atOpen.mtimeNs < kRecentMtimeNs &&
                                  in.writerOpen == 1 && in.monoNowUs - in.lastGrowthUs < kIdleFinalUs;
        if ((recent && in.writerOpen != 0) || (in.pendingZero && in.writerOpen == 1) || pausedAtOpen) {

            d.mode = (in.writerOpen == 1 || in.downloadHint) ? Mode::Growing : Mode::Probing;
            d.action = Action::Wait;
        }
        return d;
    }
    case Mode::Probing:
        if (changedSinceOpen(in)) {
            d.mode = Mode::Growing;
            d.action = bytesAhead ? Action::Retry : inPlaceEnd ? Action::EndOfFile : Action::Wait;
            return d;
        }
        if (in.monoNowUs - in.probeStartUs >= kProbeGraceUs) {
            d.mode = Mode::Static;
            return d;
        }
        d.action = Action::Wait;
        return d;
    case Mode::Growing:
    case Mode::Final: {
        if (bytesAhead) {
            d.mode = Mode::Growing;
            d.action = Action::Retry;
            return d;
        }
        if (in.mode == Mode::Final) return d;
        if (inPlaceEnd) { d.mode = Mode::Growing; return d; }

        if (in.writerOpen == 1 || (in.downloadHint && in.writerOpen == -1)) {
            d.action = Action::Wait;
            return d;
        }
        const int64_t idle = in.monoNowUs - in.lastGrowthUs;

        const int64_t limit = (in.hadDownloadHint || in.writerOpen == 0) ? kIdleFinalAfterHintUs : kIdleFinalUs;

        if (idle >= limit) {
            d.mode = Mode::Final;
            return d;
        }
        d.action = Action::Wait;
        return d;
    }
    }
    return d;
}

inline bool pathHasDownloadSuffix(const std::string& path) {
    auto endsWith = [&](const char* suf) {
        const size_t n = std::char_traits<char>::length(suf);
        if (path.size() < n) return false;
        for (size_t i = 0; i < n; ++i) {
            char a = path[path.size() - n + i], b = suf[i];
            if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
            if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
            if (a != b) return false;
        }
        return true;
    };
    for (const char* s : {".part", ".crdownload", ".!qb", ".!ut", ".xltd", ".download"})
        if (endsWith(s)) return true;
    return path.find(".download/") != std::string::npos;
}

} // namespace spgrow
