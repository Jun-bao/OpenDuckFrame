// OpenDuckFrame - resilient playback: read callback / abort hook and open-failure diagnosis
//
// Split out of the umbrella header by section; function bodies, constants and inline
// attributes are unchanged. Callers keep including the umbrella; this file only guarantees
// that it compiles on its own.
#pragma once

#include "ResilienceDamageMap.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <string>
#include <utility>
#include <vector>

namespace spresil {

using Reader = std::function<int64_t(int64_t pos, uint8_t* buf, size_t n)>;
using AbortFn = std::function<bool()>;

struct OpenDiagnosis {
    int64_t fileSize = 0;
    int64_t leadingZeroBytes = 0;
    bool zeroScanCapped = false;
    bool mp4Family = false;
    bool sawFtyp = false;
    bool sawMoov = false;
    bool sawMdat = false;
    bool sawMoof = false;
    bool mdatReachesEnd = false;
    bool boxWalkStopped = false;
};

enum class OpenFailureHint : uint8_t {
    None = 0,
    LeadingZeros,
    MissingMetadataIncomplete,
    IndexAtTailNotDownloaded,
};

inline int64_t scanLeadingZeros(const Reader& read, int64_t fileSize, int64_t cap, const AbortFn* abort,
                                bool* capped) {
    if (capped) *capped = false;
    constexpr size_t kChunk = 64 * 1024;
    std::vector<uint8_t> buf(kChunk);
    int64_t pos = 0;
    const int64_t limit = std::min(fileSize, cap);
    while (pos < limit) {
        if (abort && *abort && (*abort)()) return pos;
        const size_t want = (size_t)std::min<int64_t>((int64_t)kChunk, limit - pos);
        const int64_t got = read(pos, buf.data(), want);
        if (got <= 0) return pos;
        for (int64_t i = 0; i < got; ++i) {
            if (buf[(size_t)i] != 0) return pos + i;
        }
        pos += got;
    }
    if (capped && pos >= cap && pos < fileSize) *capped = true;
    return pos;
}

inline bool isBoxType(const uint8_t* t) {
    for (int i = 0; i < 4; ++i) {
        const uint8_t c = t[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ' ' || c == '_' || c == '-' || c == 0xA9))
            return false;
    }
    return true;
}

inline void walkIsoBoxes(const Reader& read, int64_t fileSize, int64_t start, OpenDiagnosis& d,
                         const AbortFn* abort) {
    int64_t pos = start;
    uint8_t h[16] = {};
    for (int hops = 0; hops < 64 && pos + 8 <= fileSize; ++hops) {
        if (abort && *abort && (*abort)()) return;
        const int64_t got = read(pos, h, 16);
        if (got < 8) return;
        uint64_t size = ((uint64_t)h[0] << 24) | ((uint64_t)h[1] << 16) | ((uint64_t)h[2] << 8) | h[3];
        const uint8_t* type = h + 4;
        int64_t hdr = 8;
        if (size == 1) {
            if (got < 16) { d.boxWalkStopped = true; return; }
            size = 0;
            for (int i = 0; i < 8; ++i) size = (size << 8) | h[8 + i];
            hdr = 16;
        } else if (size == 0) {
            size = (uint64_t)(fileSize - pos);
        }
        if (!isBoxType(type) || size < (uint64_t)hdr) { d.boxWalkStopped = true; return; }
        const bool ftyp = std::memcmp(type, "ftyp", 4) == 0;
        const bool moov = std::memcmp(type, "moov", 4) == 0;
        const bool mdat = std::memcmp(type, "mdat", 4) == 0;
        const bool moof = std::memcmp(type, "moof", 4) == 0;
        const bool filler = std::memcmp(type, "free", 4) == 0 || std::memcmp(type, "skip", 4) == 0 ||
                            std::memcmp(type, "wide", 4) == 0 || std::memcmp(type, "uuid", 4) == 0 ||
                            std::memcmp(type, "styp", 4) == 0 || std::memcmp(type, "sidx", 4) == 0 ||
                            std::memcmp(type, "pdin", 4) == 0 || std::memcmp(type, "meta", 4) == 0;
        if (hops == 0) d.mp4Family = ftyp || moov || mdat || moof || filler;
        if (!d.mp4Family) { d.boxWalkStopped = true; return; }
        if (ftyp) d.sawFtyp = true;
        if (moov) d.sawMoov = true;
        if (moof) d.sawMoof = true;
        if (mdat) {
            d.sawMdat = true;
            if ((uint64_t)pos + size >= (uint64_t)fileSize) d.mdatReachesEnd = true;
        }
        if ((uint64_t)pos + size > (uint64_t)fileSize) return;
        pos += (int64_t)size;
    }
}

inline OpenDiagnosis diagnoseOpenFailure(const Reader& read, int64_t fileSize, int64_t zeroCap,
                                         const AbortFn* abort) {
    OpenDiagnosis d;
    d.fileSize = fileSize;
    if (fileSize <= 0) return d;
    bool capped = false;
    d.leadingZeroBytes = scanLeadingZeros(read, fileSize, zeroCap, abort, &capped);
    d.zeroScanCapped = capped;

    if (d.leadingZeroBytes < 64 * 1024) walkIsoBoxes(read, fileSize, 0, d, abort);
    return d;
}

inline OpenFailureHint hintFor(const OpenDiagnosis& d) {
    if (d.leadingZeroBytes >= 64 * 1024) return OpenFailureHint::LeadingZeros;
    if (d.mp4Family && !d.sawMoov && !d.sawMoof) {
        if (d.sawMdat && d.mdatReachesEnd) return OpenFailureHint::IndexAtTailNotDownloaded;
        return OpenFailureHint::MissingMetadataIncomplete;
    }
    return OpenFailureHint::None;
}

inline int64_t zeroHeadProbeSize(int64_t leadingZeroBytes) {
    const int64_t want = leadingZeroBytes + 2 * 1024 * 1024;
    return std::min<int64_t>(want, 32 * 1024 * 1024);
}

} // namespace spresil
