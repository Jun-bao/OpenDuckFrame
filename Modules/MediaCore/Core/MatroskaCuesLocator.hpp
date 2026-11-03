#pragma once

#include <cstddef>
#include <cstdint>

namespace sp {

struct SPMatroskaCuesScan {
    enum class Status {
        NotMatroska,
        Found,
        NeedSeekHead,
        Unresolved,
    };
    Status status = Status::NotMatroska;
    int64_t cuesOffset = 0;
    int64_t seekHeadOffset = 0;
    int64_t segmentStart = 0;
};

namespace mkvebml {

constexpr int64_t kIdEBML = 0x1A45DFA3;
constexpr int64_t kIdSegment = 0x18538067;
constexpr int64_t kIdSeekHead = 0x114D9B74;
constexpr int64_t kIdSeek = 0x4DBB;
constexpr int64_t kIdSeekID = 0x53AB;
constexpr int64_t kIdSeekPosition = 0x53AC;
constexpr int64_t kIdCues = 0x1C53BB6B;
constexpr int64_t kIdCluster = 0x1F43B675;

inline int64_t readId(const uint8_t* b, size_t len, size_t& p) {
    if (p >= len) return -1;
    const uint8_t f = b[p];
    int n = 0;
    if (f & 0x80) n = 1;
    else if (f & 0x40) n = 2;
    else if (f & 0x20) n = 3;
    else if (f & 0x10) n = 4;
    else return -1;
    if (p + (size_t)n > len) return -1;
    int64_t v = 0;
    for (int i = 0; i < n; ++i) v = (v << 8) | b[p + i];
    p += (size_t)n;
    return v;
}

inline int64_t readSize(const uint8_t* b, size_t len, size_t& p) {
    if (p >= len) return -2;
    const uint8_t f = b[p];
    int n = 0;
    uint8_t mask = 0x80;
    for (n = 1; n <= 8; ++n) {
        if (f & mask) break;
        mask >>= 1;
    }
    if (n > 8 || p + (size_t)n > len) return -2;
    int64_t v = (int64_t)(f & (uint8_t)(mask - 1));
    bool allOnes = (v == (int64_t)(mask - 1));
    for (int i = 1; i < n; ++i) {
        if (b[p + i] != 0xff) allOnes = false;
        v = (v << 8) | b[p + i];
    }
    p += (size_t)n;
    if (allOnes) return -1;
    return v;
}

inline uint64_t readUint(const uint8_t* b, int64_t n) {
    uint64_t v = 0;
    for (int64_t i = 0; i < n; ++i) v = (v << 8) | b[i];
    return v;
}

inline SPMatroskaCuesScan parseSeekHeadBody(const uint8_t* b, size_t len,
                                            int64_t segmentStart, int64_t fileSize) {
    SPMatroskaCuesScan out;
    out.status = SPMatroskaCuesScan::Status::Unresolved;
    out.segmentStart = segmentStart;
    size_t p = 0;
    while (p < len) {
        const int64_t id = readId(b, len, p);
        if (id < 0) break;
        const int64_t sz = readSize(b, len, p);
        if (sz < 0 || (int64_t)(len - p) < sz) break;
        if (id == kIdSeek) {
            size_t q = p;
            const size_t end = p + (size_t)sz;
            int64_t seekId = -1, seekPos = -1;
            while (q < end) {
                const int64_t id2 = readId(b, end, q);
                if (id2 < 0) break;
                const int64_t sz2 = readSize(b, end, q);
                if (sz2 < 0 || (int64_t)(end - q) < sz2 || sz2 > 8) {
                    if (sz2 < 0 || (int64_t)(end - q) < sz2) break;
                    q += (size_t)sz2;
                    continue;
                }
                if (id2 == kIdSeekID) seekId = (int64_t)readUint(b + q, sz2);
                else if (id2 == kIdSeekPosition) seekPos = (int64_t)readUint(b + q, sz2);
                q += (size_t)sz2;
            }
            if (seekPos >= 0) {
                const int64_t abs = segmentStart + seekPos;
                if (abs >= 0 && abs < fileSize) {
                    if (seekId == kIdCues) {
                        out.status = SPMatroskaCuesScan::Status::Found;
                        out.cuesOffset = abs;
                        return out;
                    }
                    if (seekId == kIdSeekHead &&
                        out.status != SPMatroskaCuesScan::Status::NeedSeekHead) {
                        out.status = SPMatroskaCuesScan::Status::NeedSeekHead;
                        out.seekHeadOffset = abs;
                    }
                }
            }
        }
        p += (size_t)sz;
    }
    return out;
}

} // namespace mkvebml

inline SPMatroskaCuesScan spLocateMatroskaCues(const uint8_t* head, size_t len,
                                               int64_t fileSize) {
    using namespace mkvebml;
    SPMatroskaCuesScan out;
    if (!head || len < 16 || fileSize <= 0) return out; // NotMatroska
    size_t p = 0;
    if (readId(head, len, p) != kIdEBML) return out;
    const int64_t ebmlSize = readSize(head, len, p);
    if (ebmlSize < 0 || (int64_t)(len - p) < ebmlSize) return out;
    p += (size_t)ebmlSize;
    if (readId(head, len, p) != kIdSegment) return out;
    const int64_t segSize = readSize(head, len, p);
    if (segSize == -2) return out;
    const int64_t segmentStart = (int64_t)p;
    out.segmentStart = segmentStart;
    if (segSize == -1) {
        out.status = SPMatroskaCuesScan::Status::Unresolved;
        return out;
    }
    out.status = SPMatroskaCuesScan::Status::Unresolved;

    while (p < len) {
        const int64_t elemStart = (int64_t)p;
        const int64_t id = readId(head, len, p);
        if (id < 0) break;
        const int64_t sz = readSize(head, len, p);
        if (sz == -2) break;
        if (id == kIdCues) {
            out.status = SPMatroskaCuesScan::Status::Found;
            out.cuesOffset = elemStart;
            return out;
        }
        if (id == kIdCluster) break;
        if (sz < 0) break;
        if (id == kIdSeekHead && (int64_t)(len - p) >= sz) {
            SPMatroskaCuesScan sub =
                mkvebml::parseSeekHeadBody(head + p, (size_t)sz, segmentStart, fileSize);
            if (sub.status == SPMatroskaCuesScan::Status::Found) return sub;
            if (sub.status == SPMatroskaCuesScan::Status::NeedSeekHead) out = sub;
        }
        if (sz > (int64_t)(len - p)) {
            if (out.status == SPMatroskaCuesScan::Status::NeedSeekHead) return out;
            out.status = SPMatroskaCuesScan::Status::Unresolved;
            return out;
        }
        p += (size_t)sz;
    }
    return out;
}

inline SPMatroskaCuesScan spParseMatroskaSeekHead(const uint8_t* buf, size_t len,
                                                  int64_t segmentStart, int64_t fileSize) {
    using namespace mkvebml;
    SPMatroskaCuesScan out;
    out.status = SPMatroskaCuesScan::Status::Unresolved;
    out.segmentStart = segmentStart;
    if (!buf || len < 4) return out;
    size_t p = 0;
    if (readId(buf, len, p) != kIdSeekHead) return out;
    const int64_t sz = readSize(buf, len, p);
    if (sz < 0) return out;
    const size_t avail = len - p;
    const size_t body = (size_t)(sz < (int64_t)avail ? sz : (int64_t)avail);
    return mkvebml::parseSeekHeadBody(buf + p, body, segmentStart, fileSize);
}

inline int64_t spMatroskaCuesElementLength(const uint8_t* buf, size_t len) {
    using namespace mkvebml;
    if (!buf || len < 5) return -1;
    size_t p = 0;
    if (readId(buf, len, p) != kIdCues) return -1;
    const int64_t sz = readSize(buf, len, p);
    if (sz < 0) return -1;
    return (int64_t)p + sz;
}

} // namespace sp
