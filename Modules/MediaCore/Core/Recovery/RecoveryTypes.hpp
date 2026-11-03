#pragma once

#include "Resilience/ResilienceOpenDiagnosis.hpp" // Reader / AbortFn
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <utility>
#include <vector>

namespace spresil {

struct Patch {
    int64_t offset = 0;
    std::vector<uint8_t> bytes;
};

struct RecoveryPlan {
    std::vector<Patch> patches;
    std::string kind;
    std::string detail;
    bool flvIgnorePrevTag = false;
    int64_t damagedFrom = -1;
    int64_t damagedUntil = -1;
    bool empty() const { return patches.empty() && !flvIgnorePrevTag; }
};

class PatchOverlay {
public:
    PatchOverlay() = default;
    explicit PatchOverlay(std::vector<Patch> list)
        : list_(list.empty() ? nullptr : std::make_shared<const std::vector<Patch>>(std::move(list))) {}
    bool empty() const { return !list_ || list_->empty(); }
    size_t size() const { return list_ ? list_->size() : 0; }
    const std::vector<Patch>& list() const { return list_ ? *list_ : emptyList(); }
    std::vector<Patch>::const_iterator begin() const { return list().begin(); }
    std::vector<Patch>::const_iterator end() const { return list().end(); }
    const std::shared_ptr<const std::vector<Patch>>& shared() const { return list_; }
private:
    static const std::vector<Patch>& emptyList() { static const std::vector<Patch> kEmpty; return kEmpty; }
    std::shared_ptr<const std::vector<Patch>> list_;
};

// ───────────────────────── MP4 / fMP4（RecoveryMp4）─────────────────────────

struct Mp4TrackCfg { uint32_t id = 0; bool video = false, audio = false; int nalLen = 0; bool hevc = false; uint32_t timescale = 0; };

struct Mp4FragAnchors {
    uint32_t sidxTimescale = 0;
    std::vector<std::pair<int64_t, uint64_t>> sidx;
    std::vector<std::pair<int64_t, uint64_t>> tfra;
    bool any() const { return !sidx.empty() && !tfra.empty(); }
};

// ───────────────────────── Matroska（RecoveryMatroska）─────────────────────────

struct MkvTrackDecl {
    uint64_t number = 0, type = 0, defaultDurationNs = 0;
    std::string codecId;
    double samplingHz = 0;
    int channels = 0;
    size_t entryPos = 0, entrySize = 0;
};

// ───────────────────────── MPEG-TS（RecoveryMpeg）─────────────────────────

struct TsGeometry {
    int stride = 0;
    int syncOffset = 0;
    bool valid() const { return stride > 0; }
};

struct TsByteSource {
    const Reader* read = nullptr;
    const uint8_t* data = nullptr;
    int64_t pos = 0;
    size_t len = 0;
    std::vector<uint8_t> tmp;

    size_t span(int64_t p, size_t n, const uint8_t*& out) {
        out = nullptr;
        if (p < 0 || n == 0) return 0;
        if (data && p >= pos && p + (int64_t)n <= pos + (int64_t)len) { out = data + (p - pos); return n; }
        if (!read) return 0;
        tmp.resize(n);
        const int64_t got = (*read)(p, tmp.data(), n);
        out = tmp.data();
        return got > 0 ? (size_t)std::min<int64_t>(got, (int64_t)n) : 0;
    }
};

struct TsPcrQuery {
    int pcrPid = -1;
    int pmtPid = -1;
    int pmtVersion = -1;
};

struct TsVideoPidMap {
    std::map<int, uint8_t> pids; // PID → stream_type
    bool trusted = false;
    std::map<int, uint8_t> audioPids;
    bool programTrusted = false;
};

struct TsHeaderScanState {
    std::map<int, int> lastCc;
    std::set<int> openPes;
};

struct TsAdtsScanState {
    std::vector<uint8_t> carry;
    std::vector<std::pair<size_t, int64_t>> runs;
    bool inPes = false;
};

struct TsPesScanState { std::map<int, int> lastCc; };

struct TsPsiIdentity {
    int transportId = -1, program = -1, pmtPid = -1;
    int patVersion = -1, pmtVersion = -1, pcrPid = -1;
    std::vector<uint8_t> pat, pmt; // exact config identity, including descriptors
    bool operator==(const TsPsiIdentity& o) const {
        return transportId == o.transportId && program == o.program && pmtPid == o.pmtPid &&
               patVersion == o.patVersion && pmtVersion == o.pmtVersion && pcrPid == o.pcrPid && pat == o.pat && pmt == o.pmt;
    }
};

struct TsPsiMap {
    TsVideoPidMap pids;
    TsGeometry geometry;
    TsPsiIdentity identity;
    int64_t anchorBegin = -1; // first complete PAT's starting packet
    int64_t anchorEnd = -1;   // matching PMT's ending packet; dependencies start here
    bool valid() const { return pids.programTrusted && anchorBegin >= 0 && anchorEnd > anchorBegin; }
};

enum class TsRecoveryLane { Header, Adts, Pes };
struct TsPsiSessionBudget { int revalidations = 0; }; // reset ONLY on new user open

// ───────────────────────── FLV（RecoveryFlv）─────────────────────────

struct FlvAvcScanState { int nalLen = 4; bool haveConfig = false; int64_t scannedUntil = 13; int tags = 0; };

// ───────────────────────── ASF（RecoveryAsfRm）─────────────────────────

struct AsfObjectFrag { int64_t pkt = 0; size_t sizePos = 0, foPos = 0; int foWidth = 0; uint32_t fo = 0, len = 0, objSize = 0, pts = 0; };
struct AsfObjectAcc { uint32_t objNum = 0; std::vector<AsfObjectFrag> frags; };
struct AsfObjectScanState { std::map<int, AsfObjectAcc> open; int verified = 0, rejected = 0; };

} // namespace spresil
