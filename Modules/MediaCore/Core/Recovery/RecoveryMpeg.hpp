// OpenDuckFrame - container recovery: MPEG-TS/PS (PES lengths, PMT/PCR, transport headers, ADTS, PES header length), raw elementary streams, MPEG-2 sequence header
//
// Split out of the umbrella header by section; function bodies, constants and inline
// attributes are unchanged. Callers keep including the umbrella; this file only guarantees
// that it compiles on its own.
#pragma once

#include "RecoveryBase.hpp"
#include "RecoveryTypes.hpp"

#include "SPResilience.hpp"
#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <map>
#include <set>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <zlib.h>

namespace spresil {

inline bool psIsSystemCode(uint8_t c) { return c >= 0xB9; }
inline bool psStartCodeAt(const uint8_t* d, size_t n) { return n >= 4 && d[0] == 0 && d[1] == 0 && d[2] == 1 && psIsSystemCode(d[3]); }

inline int64_t psStructureLenFromHeader(const uint8_t* h, size_t hn, uint8_t* codeOut = nullptr) {
    if (!psStartCodeAt(h, hn)) return 0;
    const uint8_t code = h[3];
    if (codeOut) *codeOut = code;
    if (code == 0xB9) return 4;
    if (code == 0xBA) {
        if (hn >= 14 && (h[4] & 0xC4) == 0x44) return 14 + (h[13] & 7);
        if (hn >= 12 && (h[4] & 0xF1) == 0x21) return 12;
        return 0;
    }
    if (hn < 6) return 0;
    const int64_t len = ((int64_t)h[4] << 8) | h[5];
    if (len == 0) return 0;
    if (code == 0xBB) return 6 + len;
    if (code != 0xBE && code != 0xBF && code != 0xBC && hn >= 9 && (h[6] & 0xC0) == 0x80) {
        if (3 + (int64_t)h[8] > len) return 0;
    }
    return 6 + len;
}

inline int64_t psStructureLenAt(const Reader& read, int64_t pos, int64_t fileSize, uint8_t* codeOut = nullptr) {
    if (pos < 0 || pos + 4 > fileSize) return 0;
    auto h = readSpan(read, pos, 14);
    return psStructureLenFromHeader(h.data(), h.size(), codeOut);
}

inline bool psChainOk(const Reader& read, int64_t at, int64_t fileSize, int need) {
    int64_t q = at;
    for (int i = 0; i < need; ++i) {
        if (q >= fileSize) return true;
        const int64_t l = psStructureLenAt(read, q, fileSize);
        if (l <= 0 || q + l > fileSize) return false;
        q += l;
        if (q < fileSize) { auto n = readSpan(read, q, 4); if (!psStartCodeAt(n.data(), n.size())) return false; }
    }
    return true;
}

inline bool psHeaderPlausibleAt(const Reader& read, int64_t q, int64_t fileSize) {
    uint8_t code = 0;
    const int64_t l = psStructureLenAt(read, q, fileSize, &code);
    if (l <= 0) return false;
    if (code == 0xB9) return true;
    if (code == 0xBA || code == 0xBB) {
        if (code == 0xBB) return true;
        if (q + l >= fileSize) return q + l == fileSize;
        auto n = readSpan(read, q + l, 4);
        return psStartCodeAt(n.data(), n.size());
    }
    auto h = readSpan(read, q, 14);
    if (h.size() < 9) return false;
    if (code == 0xBE || code == 0xBF || code == 0xBC) return true;
    const uint8_t b6 = h[6];
    if ((b6 & 0xC0) == 0x80) {
        const int ptsDts = h[7] >> 6;
        const int hdl = h[8];
        if (ptsDts == 1 || hdl > 30) return false;
        if (ptsDts >= 2) {
            if (hdl < 5 || h.size() < 10) return false;
            const uint8_t b9 = h[9];
            if ((b9 >> 4) != ptsDts || !(b9 & 1)) return false;
        }
        return true;
    }
    return b6 == 0xFF || (b6 & 0xC0) == 0x40 || (b6 & 0xF0) == 0x20 || (b6 & 0xF0) == 0x30 || b6 == 0x0F; // MPEG-1
}

inline bool psPesEndConsistent(const Reader& read, int64_t pos, int64_t fileSize) {
    uint8_t code = 0;
    const int64_t l = psStructureLenAt(read, pos, fileSize, &code);
    if (l <= 0 || code < 0xBC) return true;
    const int64_t end = pos + l;
    if (end >= fileSize) return end == fileSize;
    auto n = readSpan(read, end, 4);
    return psStartCodeAt(n.data(), n.size());
}

inline int64_t psChainFirstInconsistentPes(const Reader& read, int64_t from, int64_t until, int64_t fileSize, int maxSteps,
                                           std::vector<uint8_t>& block) {
    constexpr int64_t kBlock = 128 * 1024;
    const int64_t limitEnd = until + 14;
    int64_t blkPos = -1, blkLen = 0;
    auto inBlock = [&](int64_t p, size_t want) { return blkPos >= 0 && p >= blkPos && p + (int64_t)want <= blkPos + blkLen; };
    auto bytesAt = [&](int64_t p, size_t want, uint8_t* out) -> size_t {
        if (p < 0 || want == 0) return 0;
        if (!inBlock(p, want) && p < limitEnd) {
            const int64_t len = std::min<int64_t>(kBlock, std::max<int64_t>(limitEnd - p, (int64_t)want));
            block.resize((size_t)len);
            const int64_t got = read(p, block.data(), (size_t)len);
            blkPos = p; blkLen = got > 0 ? got : 0;
        }
        if (inBlock(p, want)) { std::memcpy(out, block.data() + (p - blkPos), want); return want; }
        const int64_t got = read(p, out, want);
        return got > 0 ? (size_t)std::min<int64_t>(got, (int64_t)want) : 0;
    };
    int64_t q = from;
    for (int steps = 0; steps < maxSteps && q <= until; ++steps) {
        uint8_t h[14];
        uint8_t code = 0;
        const int64_t l = (q < 0 || q + 4 > fileSize) ? 0 : psStructureLenFromHeader(h, bytesAt(q, 14, h), &code);
        if (l <= 0) break;
        if (code >= 0xBC) {
            const int64_t end = q + l;
            bool ok;
            if (end >= fileSize) ok = end == fileSize;
            else { uint8_t n4[4]; ok = psStartCodeAt(n4, bytesAt(end, 4, n4)); }
            if (!ok) return q;
        }
        if (q == until) break;
        q += l;
    }
    return -1;
}

inline RecoveryPlan planMpegPsPesLengths(const Reader& read, int64_t fileSize, int64_t from, const AbortFn* abort) {
    RecoveryPlan p;
    int64_t pos = from;
    int structures = 0, fixed = 0;
    int64_t firstBad = -1, lastBad = -1;
    const int64_t limit = std::min(fileSize, from + 256ll * 1024 * 1024);
    auto endOk = [&](int64_t e) {
        if (e > fileSize) return false;
        if (e == fileSize) return true;
        auto n = readSpan(read, e, 4);
        return psStartCodeAt(n.data(), n.size());
    };
    while (pos + 4 <= limit && structures < 65536) {
        if (aborted(abort)) return p;
        ++structures;
        uint8_t code = 0;
        const int64_t len = psStructureLenAt(read, pos, fileSize, &code);
        if (len <= 0) break;
        if (endOk(pos + len)) { pos += len; continue; }
        if (code < 0xBC) break;

        const int64_t winFrom = pos + 6, winTo = std::min(fileSize, pos + 6 + 65535 + 4);
        if (winTo <= winFrom) break;
        auto win = readSpan(read, winFrom, (size_t)(winTo - winFrom));
        const bool videoPes = code >= 0xE0 && code <= 0xEF;
        int64_t found = -1, firstPlausible = -1;
        for (size_t i = 0; i + 4 <= win.size() && found < 0; ++i) {
            if (win[i] == 0 && win[i + 1] == 0 && win[i + 2] == 1 && psIsSystemCode(win[i + 3])) {
                const int64_t q = winFrom + (int64_t)i;
                if (!psHeaderPlausibleAt(read, q, fileSize)) continue;
                if (videoPes) { found = q; break; }
                if (firstPlausible < 0) firstPlausible = q;
                if (psChainOk(read, q, fileSize, 3)) found = q;
            }
        }
        if (found < 0) found = firstPlausible;
        if (found < 0) break;
        const int64_t newLen = found - pos - 6;
        if (newLen < 3 || newLen > 65535) break;
        Patch pt; pt.offset = pos + 4; pt.bytes = {(uint8_t)(newLen >> 8), (uint8_t)newLen};
        p.patches.push_back(pt);
        ++fixed;
        if (firstBad < 0) firstBad = pos;
        lastBad = found;
        pos = found;
    }
    if (fixed == 0) { p.patches.clear(); return p; }
    p.kind = "ps-pes-length";
    p.detail = "PES 长度与后继系统起始码矛盾 " + std::to_string(fixed) + " 处（走链 " + std::to_string(structures) + " 个结构）：按真实末端覆盖长度字段";
    p.damagedFrom = firstBad; p.damagedUntil = lastBad;
    return p;
}

inline TsGeometry tsGeometryAt(const Reader& read, int64_t pos, int64_t fileSize) {
    static const TsGeometry cands[] = {{188, 0}, {192, 4}, {204, 0}};
    for (const TsGeometry& g : cands) {
        if (pos < 0 || pos + 4 * (int64_t)g.stride > fileSize) continue;
        auto h = readSpan(read, pos, (size_t)g.stride * 4);
        if (h.size() < (size_t)g.stride * 4) continue;
        bool ok = true;
        for (int k = 0; k < 4 && ok; ++k) ok = h[(size_t)g.syncOffset + (size_t)k * (size_t)g.stride] == 0x47;
        if (ok) return g;
    }
    return {};
}

inline uint32_t mpegCrc32(const uint8_t* d, size_t n) { return oggCrc32(d, n, 0xFFFFFFFFu); }

inline bool tsReadPcr(const uint8_t* q, int64_t& pcrOut) {
    if (q[0] != 0x47 || (q[1] & 0x80) || !(q[3] & 0x20) || q[4] < 7 || !(q[5] & 0x10)) return false;
    if ((q[10] & 0x7E) != 0x7E) return false;
    const int ext = ((q[10] & 1) << 8) | q[11];
    if (ext >= 300) return false;
    const int64_t base = ((int64_t)q[6] << 25) | ((int64_t)q[7] << 17) | ((int64_t)q[8] << 9) | ((int64_t)q[9] << 1) | (q[10] >> 7);
    pcrOut = base * 300 + ext;
    return true;
}

inline int64_t tsPcrDeltaUs(const Reader& read, int64_t fileSize, int64_t posA, int64_t posB, const TsPcrQuery& query,
                            const AbortFn* abort) {
    if (posA < 0 || posB < posA || query.pcrPid <= 0 || query.pcrPid >= 0x1FFF) return -1;
    if (posB - posA > 256ll * 1024 * 1024) return -1;
    const TsGeometry g = tsGeometryAt(read, posA, fileSize);
    if (!g.valid() || (posB - posA) % g.stride != 0) return -1;
    constexpr int64_t kMod = (1ll << 33) * 300;
    int64_t pos = posA;
    int64_t prev = -1, total = 0;
    int64_t bPcr = -1;
    int afterB = 0;
    bool haveA = false;
    while (pos + g.stride <= fileSize) {
        if (aborted(abort)) return -1;
        const size_t n = std::min<size_t>(1024, (size_t)((fileSize - pos) / g.stride));
        if (n == 0) break;
        auto buf = readSpan(read, pos, n * (size_t)g.stride);
        const size_t got = buf.size() / (size_t)g.stride;
        if (got == 0) break;
        for (size_t i = 0; i < got; ++i) {
            const int64_t qpos = pos + (int64_t)i * g.stride;
            const uint8_t* q = buf.data() + i * (size_t)g.stride + (size_t)g.syncOffset;
            if (q[0] != 0x47) return -1;
            if (qpos >= posB && ++afterB > 4096) return -1;
            if (!haveA && qpos - posA > 4096ll * g.stride) return -1;
            const int pid = ((q[1] & 0x1f) << 8) | q[2];
            const bool tei = (q[1] & 0x80) != 0;
            if (query.pmtPid >= 0 && pid == query.pmtPid && (q[1] & 0x40) && !tei && haveA) {

                size_t pl = 4;
                if (q[3] & 0x20) pl += 1 + q[4];
                if ((q[3] & 0x10) && pl + 1 < 188) {
                    const size_t st = pl + 1 + q[pl];
                    if (st + 6 <= 188 && q[st] == 0x02 && ((q[st + 5] >> 1) & 0x1f) != query.pmtVersion && query.pmtVersion >= 0) return -1;
                }
            }
            if (pid != query.pcrPid) continue;
            if (haveA && (q[3] & 0x20) && q[4] >= 1 && (q[5] & 0x80)) return -1;
            int64_t pcr = 0;
            if (!tsReadPcr(q, pcr)) continue;
            if (!haveA) {
                if (qpos >= posB) return -1;
                haveA = true; prev = pcr;
            } else {
                int64_t d = (pcr - prev) % kMod;
                if (d < 0) d += kMod;
                if (d > kMod / 2) return -1;
                total += d;
                prev = pcr;
            }
            if (qpos >= posB) { bPcr = pcr; break; }
        }
        if (bPcr >= 0) break;
        pos += (int64_t)got * g.stride;
    }
    if (!haveA || bPcr < 0) return -1;
    return total / 27;
}

inline int annexBSniffCodec(const uint8_t* d, size_t n) {
    int units = 0, h264ok = 0, hevcok = 0;
    bool h264Sps = false, hevcSps = false;
    size_t i = 0;
    while (i + 5 <= n && units < 12) {
        size_t sc = n;
        for (size_t j = i; j + 2 < n; ++j) { if (d[j] == 0 && d[j + 1] == 0 && d[j + 2] == 1) { sc = j; break; } }
        if (sc + 5 > n) break;
        const uint8_t b0 = d[sc + 3], b1 = d[sc + 4];
        ++units;
        if (!(b0 & 0x80)) {
            const int t264 = b0 & 0x1f, nri = (b0 >> 5) & 3;
            if (t264 >= 1 && t264 <= 12 && !(t264 == 5 && nri == 0)) ++h264ok;
            if (t264 == 7 && nri != 0) h264Sps = true;
            const int thevc = (b0 >> 1) & 0x3f, layer = ((b0 & 1) << 5) | (b1 >> 3), tid = b1 & 7;
            if (thevc <= 40 && !(thevc >= 22 && thevc <= 31) && layer == 0 && tid >= 1) ++hevcok;
            if (thevc == 33 && layer == 0 && tid >= 1) hevcSps = true;
        }
        i = sc + 3;
    }
    if (units < 3) return 0;
    if (h264ok == units && h264Sps && hevcok < units) return 1;
    if (hevcok == units && hevcSps && h264ok < units) return 2;
    return 0;
}

inline int tsPayloadOffset(const uint8_t* q) {
    const int afc = (q[3] >> 4) & 3;
    if (!(afc & 1)) return -1;
    const int pl = (afc & 2) ? 5 + (int)q[4] : 4;
    return pl < 188 ? pl : -1;
}

inline bool tsPsiSectionIn(const uint8_t* q, size_t pl, size_t minTotal, std::vector<uint8_t>& section, size_t* sectionAt = nullptr) {
    const size_t st = pl + 1 + q[pl];
    if (st + 3 > 188) return false;
    const size_t total = 3 + ((((size_t)q[st + 1] & 0x0f) << 8) | q[st + 2]);
    if (total < minTotal || st + total > 188) return false;
    section.assign(q + st, q + st + total);
    if (sectionAt) *sectionAt = st;
    return true;
}

struct TsPmtEntry { uint8_t type = 0; uint16_t pid = 0; size_t off = 0; };
struct TsPmtSection {
    std::vector<uint8_t> bytes;
    uint8_t version = 0;
    uint16_t pcrPid = 0;
    std::vector<TsPmtEntry> entries;
};

inline bool tsParsePmt(const std::vector<uint8_t>& s, TsPmtSection& out) {
    if (s.size() < 16 || s[0] != 2) return false;
    const size_t total = 3 + ((((size_t)s[1] & 0x0f) << 8) | s[2]);
    if (total != s.size() || mpegCrc32(s.data(), s.size()) != 0) return false;
    out.bytes = s;
    out.version = (s[5] >> 1) & 0x1f;
    out.pcrPid = (uint16_t)(((s[8] & 0x1f) << 8) | s[9]);
    size_t off = 12 + ((((size_t)s[10] & 0x0f) << 8) | s[11]);
    out.entries.clear();
    while (off + 5 <= s.size() - 4) {
        TsPmtEntry e;
        e.type = s[off]; e.pid = (uint16_t)(((s[off + 1] & 0x1f) << 8) | s[off + 2]); e.off = off;
        const size_t esLen = (((size_t)s[off + 3] & 0x0f) << 8) | s[off + 4];
        off += 5 + esLen;
        out.entries.push_back(e);
    }
    return off == s.size() - 4;
}

inline RecoveryPlan planTsPmtCrossCheck(const Reader& read, int64_t fileSize, const AbortFn* abort) {
    RecoveryPlan p;
    const TsGeometry geo = tsGeometryAt(read, 0, fileSize);
    const int sz = geo.stride;
    if (!sz) return p;

    if (fileSize > 1024ll * 1024 * 1024) return p;
    const int64_t winTo = fileSize, pesWinTo = std::min(fileSize, 8ll * 1024 * 1024);
    int pmtPid = -1, programs = 0;
    std::vector<int64_t> pmtPositions;
    std::vector<uint8_t> pmtFirst;
    bool pmtMismatch = false;
    struct PesAcc { std::vector<uint8_t> es; bool video = false; bool done = false; bool scrambled = false; int pkts = 0; };
    std::map<int, PesAcc> pes;
    std::set<int> pidsSeen;
    for (int64_t pos = 0; pos + sz <= winTo; ) {
        if (aborted(abort)) return p;
        const size_t n = std::min<size_t>(1024, (size_t)((winTo - pos) / sz));
        auto buf = readSpan(read, pos, n * (size_t)sz);
        const size_t got = buf.size() / (size_t)sz;
        if (got == 0) break;
        for (size_t i = 0; i < got; ++i) {
            const uint8_t* q = buf.data() + i * (size_t)sz + (size_t)geo.syncOffset;
            const int64_t qpos = pos + (int64_t)i * sz + geo.syncOffset;
            if (q[0] != 0x47 || (q[1] & 0x80)) continue;
            const bool pusi = (q[1] & 0x40) != 0;
            const int pid = ((q[1] & 0x1f) << 8) | q[2];
            const bool scrambled = (q[3] & 0xC0) != 0;
            const int plo = tsPayloadOffset(q);
            if (plo < 0) continue;
            const size_t pl = (size_t)plo;
            pidsSeen.insert(pid);
            if (pid == 0 || pid == pmtPid) {
                if (!pusi) continue;
                std::vector<uint8_t> sec; size_t st = 0;
                if (!tsPsiSectionIn(q, pl, 3, sec, &st)) continue;
                if (pid == 0) {
                    if (sec[0] != 0 || mpegCrc32(sec.data(), sec.size()) != 0 || pmtPid >= 0) continue;
                    for (size_t o = 8; o + 4 <= sec.size() - 4; o += 4) {
                        const int prog = (sec[o] << 8) | sec[o + 1];
                        if (prog == 0) continue;
                        ++programs;
                        pmtPid = ((sec[o + 2] & 0x1f) << 8) | sec[o + 3];
                    }
                } else {
                    if (pmtFirst.empty()) pmtFirst = sec;
                    else if (sec != pmtFirst) pmtMismatch = true;
                    pmtPositions.push_back(qpos + (int64_t)st);
                }
                continue;
            }
            if (pid == 0x1FFF || qpos >= pesWinTo) continue;
            PesAcc& a = pes[pid];
            if (scrambled) a.scrambled = true;
            if (a.done) continue;
            if (pusi) {
                if (!a.es.empty()) { a.done = true; continue; }
                if (188 - pl < 9 || q[pl] != 0 || q[pl + 1] != 0 || q[pl + 2] != 1) continue;
                const uint8_t sid = q[pl + 3];
                if (sid < 0xE0 || sid > 0xEF) { a.done = true; continue; }
                a.video = true;
                size_t hdr = 6;
                if ((q[pl + 6] & 0xC0) == 0x80) hdr = 9 + q[pl + 8];
                if (pl + hdr > 188) continue;
                a.es.insert(a.es.end(), q + pl + hdr, q + 188);
            } else if (a.video && !a.es.empty()) {
                a.es.insert(a.es.end(), q + pl, q + 188);
                if (a.es.size() >= 32 * 1024) a.done = true;
            }
            if (++a.pkts > 4096) a.done = true;
        }
        pos += (int64_t)got * sz;
    }
    if (programs != 1 || pmtPid < 0 || pmtFirst.empty() || pmtMismatch || pmtPositions.empty()) return p;
    TsPmtSection pmt;
    if (!tsParsePmt(pmtFirst, pmt)) return p;
    int videoEntry = -1;
    for (size_t i = 0; i < pmt.entries.size(); ++i) {
        if (pmt.entries[i].type == 0x1b || pmt.entries[i].type == 0x24) { if (videoEntry >= 0) return p; videoEntry = (int)i; }
    }
    if (videoEntry < 0) return p;
    int detectedPid = -1, detectedCodec = 0;
    for (auto& kv : pes) {
        if (!kv.second.video || kv.second.es.size() < 64) continue;
        const int c = annexBSniffCodec(kv.second.es.data(), kv.second.es.size());
        if (c == 0) continue;
        if (kv.second.scrambled) return p;
        if (detectedPid >= 0) return p;
        detectedPid = kv.first; detectedCodec = c;
    }
    if (detectedPid < 0) return p;
    const uint8_t wantType = detectedCodec == 1 ? 0x1b : 0x24;
    const TsPmtEntry& ve = pmt.entries[(size_t)videoEntry];
    std::vector<uint8_t> fixed = pmtFirst;
    std::string what;
    if (ve.pid == detectedPid) {
        if (ve.type == wantType) return p;
        fixed[ve.off] = wantType;
        char tb[16];
        snprintf(tb, sizeof tb, "0x%02x", ve.type);
        what = std::string("stream_type ") + tb + " → " + (detectedCodec == 1 ? "H.264(0x1b)" : "HEVC(0x24)") + "（PID " + std::to_string(ve.pid) + " 的 PES 是 " + (detectedCodec == 1 ? "H.264" : "HEVC") + "）";
    } else {
        if (pidsSeen.count(ve.pid)) return p;
        for (const TsPmtEntry& e : pmt.entries) if (e.pid == detectedPid) return p;
        fixed[ve.off] = wantType;
        fixed[ve.off + 1] = (uint8_t)((fixed[ve.off + 1] & 0xE0) | (detectedPid >> 8));
        fixed[ve.off + 2] = (uint8_t)detectedPid;
        what = "视频 PID " + std::to_string(ve.pid) + "（窗口内无包）→ " + std::to_string(detectedPid) + "（唯一自描述的 " + (detectedCodec == 1 ? "H.264" : "HEVC") + " PES）";
    }

    const uint32_t crc = mpegCrc32(fixed.data(), fixed.size() - 4);
    fixed[fixed.size() - 4] = (uint8_t)(crc >> 24); fixed[fixed.size() - 3] = (uint8_t)(crc >> 16);
    fixed[fixed.size() - 2] = (uint8_t)(crc >> 8); fixed[fixed.size() - 1] = (uint8_t)crc;
    for (int64_t sp : pmtPositions) {
        Patch a; a.offset = sp + (int64_t)ve.off; a.bytes.assign(fixed.begin() + (long)ve.off, fixed.begin() + (long)ve.off + 3);
        Patch c; c.offset = sp + (int64_t)fixed.size() - 4; c.bytes.assign(fixed.end() - 4, fixed.end());
        p.patches.push_back(a); p.patches.push_back(c);
    }
    p.kind = "ts-pmt";
    p.detail = "PMT 与实际 PES 矛盾：" + what + "，" + std::to_string(pmtPositions.size()) + " 份副本改字段并重算 CRC";
    p.damagedFrom = pmtPositions.front(); p.damagedUntil = pmtPositions.front() + (int64_t)pmtFirst.size();
    return p;
}

inline RecoveryPlan planMpeg2SeqHeader(const Reader& read, int64_t fileSize, const uint8_t* pktHead, size_t pktLen, int64_t scanBytes,
                                       const AbortFn* abort) {
    RecoveryPlan p;
    if (!pktHead || pktLen < 12 || !(pktHead[0] == 0 && pktHead[1] == 0 && pktHead[2] == 1 && pktHead[3] == 0xB3)) return p;
    const uint32_t w0 = ((uint32_t)pktHead[4] << 4) | (pktHead[5] >> 4), h0 = ((uint32_t)(pktHead[5] & 0x0F) << 8) | pktHead[6];
    if (w0 != 0 && h0 != 0) return p;
    static const uint8_t pat[4] = {0, 0, 1, 0xB3};
    int64_t cur = 0, hit = -1, firstAt = -1;
    std::map<std::array<uint8_t, 8>, int> votes;
    const int64_t limit = std::min(fileSize, scanBytes);
    FindCursor fc;
    for (int hits = 0; hits < 4096 && findBytes(read, cur, limit, pat, 4, hit, abort, &fc); ++hits) {
        cur = hit + 4;
        auto hb = readSpan(read, hit + 4, 8);
        if (hb.size() < 8) break;
        if (firstAt < 0) {
            if (std::memcmp(hb.data(), pktHead + 4, 8) != 0) return p;
            firstAt = hit;
            continue;
        }

        const uint32_t w = ((uint32_t)hb[0] << 4) | (hb[1] >> 4), hgt = ((uint32_t)(hb[1] & 0x0F) << 8) | hb[2];
        if (w == 0 || hgt == 0) continue;
        if (w0 != 0 && w != w0) continue;
        if (h0 != 0 && hgt != h0) continue;
        if (std::memcmp(hb.data() + 3, pktHead + 7, 5) != 0) continue;
        std::array<uint8_t, 8> key{}; std::memcpy(key.data(), hb.data(), 8);
        votes[key]++;
    }
    if (firstAt < 0) return p;
    std::vector<std::array<uint8_t, 8>> good;
    for (const auto& kv : votes) if (kv.second >= 2) good.push_back(kv.first);
    if (good.size() != 1) return p;
    Patch pt; pt.offset = firstAt + 4; pt.bytes = {good[0][0], good[0][1], good[0][2]};
    p.patches.push_back(pt);
    p.kind = "mpeg2-seq-size";
    const uint32_t w = ((uint32_t)good[0][0] << 4) | (good[0][1] >> 4), hgt = ((uint32_t)(good[0][1] & 0x0F) << 8) | good[0][2];
    p.detail = "首序列头尺寸 " + std::to_string(w0) + "×" + std::to_string(h0) + " 归零，后续 " + std::to_string(votes[good[0]]) + " 份重复头唯一给出 " +
               std::to_string(w) + "×" + std::to_string(hgt) + "（其余头位逐位相同）";
    p.damagedFrom = firstAt; p.damagedUntil = firstAt + 12;
    return p;
}

inline TsVideoPidMap tsScanDeclaredVideoPids(const Reader& read, int64_t fileSize, int64_t scanBytes, const AbortFn* abort,
                                             int64_t* scannedOut = nullptr, bool stopWhenFound = false) {
    TsVideoPidMap out;
    if (scannedOut) *scannedOut = 0;
    const TsGeometry g = tsGeometryAt(read, 0, fileSize);
    if (!g.valid()) return out;
    const int64_t winTo = std::min(fileSize, scanBytes);
    int pmtPid = -1, programs = 0;
    std::vector<uint8_t> pmtFirst;
    bool mismatch = false;
    for (int64_t pos = 0; pos + g.stride <= winTo; ) {
        if (aborted(abort)) return out;
        const size_t n = std::min<size_t>(1024, (size_t)((winTo - pos) / g.stride));
        auto buf = readSpan(read, pos, n * (size_t)g.stride);
        const size_t got = buf.size() / (size_t)g.stride;
        if (got == 0) break;
        for (size_t i = 0; i < got; ++i) {
            const uint8_t* q = buf.data() + i * (size_t)g.stride + (size_t)g.syncOffset;
            if (q[0] != 0x47 || (q[1] & 0x80) || !(q[1] & 0x40)) continue;
            const int pid = ((q[1] & 0x1f) << 8) | q[2];
            if (pid != 0 && pid != pmtPid) continue;
            const int pl = tsPayloadOffset(q);
            if (pl < 0) continue;
            std::vector<uint8_t> sec;
            if (!tsPsiSectionIn(q, (size_t)pl, 12, sec)) continue;
            if (mpegCrc32(sec.data(), sec.size()) != 0) continue;
            if (pid == 0) {
                if (sec[0] != 0 || pmtPid >= 0) continue;
                for (size_t o = 8; o + 4 <= sec.size() - 4; o += 4) {
                    const int prog = (sec[o] << 8) | sec[o + 1];
                    if (prog == 0) continue;
                    ++programs;
                    pmtPid = ((sec[o + 2] & 0x1f) << 8) | sec[o + 3];
                }
            } else {
                if (sec[0] != 2) continue;
                if (pmtFirst.empty()) pmtFirst = sec; else if (sec != pmtFirst) mismatch = true;
            }
        }
        pos += (int64_t)got * g.stride;
        if (scannedOut) *scannedOut = pos;
        if (stopWhenFound && pmtPid >= 0 && !pmtFirst.empty()) break;
    }
    if (programs != 1 || pmtFirst.empty() || mismatch) return out;
    TsPmtSection pmt;
    if (!tsParsePmt(pmtFirst, pmt)) return out;
    for (const TsPmtEntry& e : pmt.entries) if (e.type == 0x1b || e.type == 0x24) out.pids[e.pid] = e.type;
    for (const TsPmtEntry& e : pmt.entries) if (e.type == 0x0f || e.type == 0x03 || e.type == 0x04 || e.type == 0x81 || e.type == 0x87) out.audioPids[e.pid] = e.type;
    out.programTrusted = true;
    out.trusted = !out.pids.empty();
    return out;
}

namespace detail {

inline bool tsPesStartValid(const uint8_t* q, size_t p, uint8_t streamType) {
    if (p + 14 > 188 || q[p] != 0 || q[p + 1] != 0 || q[p + 2] != 1) return false;
    if (q[p + 3] < 0xE0 || q[p + 3] > 0xEF) return false;
    if ((q[p + 6] & 0xC0) != 0x80) return false;
    const int ptsFlags = q[p + 7] & 0xC0;
    if (ptsFlags != 0x80 && ptsFlags != 0xC0) return false;
    const size_t nh = q[p + 8], e = p + 9 + nh;
    if (nh < 5 || e + 6 > 188) return false;
    const uint8_t* pts = q + p + 9;
    if ((pts[0] >> 4) != (ptsFlags == 0xC0 ? 3 : 2) || !(pts[0] & 1) || !(pts[2] & 1) || !(pts[4] & 1)) return false;
    size_t h;
    if (q[e] == 0 && q[e + 1] == 0 && q[e + 2] == 0 && q[e + 3] == 1) h = e + 4;
    else if (q[e] == 0 && q[e + 1] == 0 && q[e + 2] == 1) h = e + 3;
    else return false;
    if (h >= 188) return false;
    if (streamType == 0x1b) return (q[h] & 0x80) == 0 && (q[h] & 0x1f) >= 1 && (q[h] & 0x1f) <= 23;
    return h + 1 < 188 && (q[h] & 0x80) == 0 && (q[h + 1] & 7) != 0;
}

inline int tsAdaptationMinEnd(const uint8_t* q) {
    const uint8_t flags = q[5];
    size_t p = 6;
    if (flags & 0x10) { if ((q[p + 4] & 0x7E) != 0x7E || (((q[p + 4] & 1) << 8) | q[p + 5]) >= 300) return -1; p += 6; }
    if (flags & 0x08) p += 6;
    if (flags & 0x04) p += 1;
    if (flags & 0x02) { if (p >= 188) return -1; p += 1 + q[p]; }
    if (flags & 0x01) { if (p >= 188) return -1; p += 1 + q[p]; }
    return p <= 188 ? (int)p : -1;
}
} // namespace detail

namespace detail {

inline RecoveryPlan tsTransportHeadersFrom(TsByteSource& src, const TsGeometry& g, int64_t fileSize, int64_t fromPos, int64_t windowBytes,
                                           const TsVideoPidMap& pids, TsHeaderScanState& state, const AbortFn* abort) {
    RecoveryPlan p;
    if (!g.valid() || fromPos % g.stride != 0) return p;
    const int64_t winTo = std::min(fileSize, fromPos + windowBytes);
    int pusiSet = 0, pusiClear = 0, afLen = 0, afc = 0;
    // PID/CC lookup cache, bit-for-bit equivalent to per-packet lookups: packets of one PID arrive in runs (video dominates),
    // so cache the pids.pids iterator and a pointer to the state.lastCc value for the last PID seen. pids does not change
    // during a call and std::map insertions of other keys never invalidate existing nodes; lastCc is still inserted only via
    // operator[] when afc & 1, with the same timing and key set as before. Never erase from lastCc inside this loop.
    int memoPid = -1;
    auto memoIt = pids.pids.end();
    int ccPid = -1;
    int* ccSlot = nullptr;
    for (int64_t pos = fromPos; pos + g.stride <= winTo; ) {
        if (aborted(abort)) { p.patches.clear(); return p; }
        const size_t n = std::min<size_t>(1024, (size_t)((winTo - pos) / g.stride));
        const uint8_t* buf = nullptr;
        const size_t got = src.span(pos, n * (size_t)g.stride, buf) / (size_t)g.stride;
        if (got == 0) break;
        for (size_t i = 0; i < got; ++i) {
            const uint8_t* const pkt = buf + i * (size_t)g.stride + (size_t)g.syncOffset;
            const uint8_t* q = pkt;
            uint8_t cow[188];
            const int64_t qpos = pos + (int64_t)i * g.stride + g.syncOffset;
            if (q[0] != 0x47) continue;
            const int pid = ((q[1] & 0x1f) << 8) | q[2];
            if (pid != memoPid) { memoPid = pid; memoIt = pids.pids.find(pid); }
            const auto it = memoIt;
            if (it == pids.pids.end() || (q[1] & 0x80) || (q[3] & 0xC0)) continue;
            const uint8_t type = it->second;
            int afcv = (q[3] >> 4) & 3;
            const int cc = q[3] & 15;
            auto fix = [&](size_t at, uint8_t v) {
                Patch pt; pt.offset = qpos + (int64_t)at; pt.bytes = {v}; p.patches.push_back(pt);
                if (q == pkt) { std::memcpy(cow, pkt, 188); q = cow; }
                cow[at] = v;
            };
            if ((afcv & 2) && (q[1] & 0x40)) {
                const int minimum = detail::tsAdaptationMinEnd(q);
                if (minimum >= 0) {
                    int hit = -1, hits = 0;
                    for (int e = minimum; e < 174; ++e) {
                        if (!detail::tsPesStartValid(q, (size_t)e, type)) continue;
                        bool stuffing = true;
                        for (int k = minimum; k < e; ++k) if (q[k] != 0xff) { stuffing = false; break; }
                        if (stuffing) { ++hits; hit = e; }
                    }
                    if (hits == 1) {
                        if (q[4] != hit - 5) { fix(4, (uint8_t)(hit - 5)); ++afLen; }
                        if (afcv == 2 && q[4] != 183) { fix(3, (uint8_t)(q[3] | 0x10)); ++afc; afcv = 3; }
                    }
                }
            }
            size_t pl = (afcv & 1) ? ((afcv & 2) ? 5 + (size_t)q[4] : 4) : 188;
            const bool valid = pl < 188 && detail::tsPesStartValid(q, pl, type);
            if (valid) {
                if (!(q[1] & 0x40)) { fix(1, (uint8_t)(q[1] | 0x40)); ++pusiSet; }
                state.openPes.insert(pid);
            } else if ((q[1] & 0x40) && pl < 188) {
                const size_t plen = std::min<size_t>(3, 188 - pl);
                static const uint8_t magic[3] = {0, 0, 1};
                bool partial = true;
                for (size_t k = 0; k < plen; ++k) if (q[pl + k] != magic[k]) partial = false;
                bool nearPes = false;
                if (plen == 3) { int bits = 0; for (size_t k = 0; k < 3; ++k) bits += popcount8((uint8_t)(q[pl + k] ^ magic[k])); nearPes = bits <= 1; }
                const bool discontinuity = (afcv & 2) && q[4] > 0 && (q[5] & 0x80);
                const int* prevCc = ccPid == pid ? ccSlot : nullptr;
                if (!prevCc) {
                    auto cit = state.lastCc.find(pid);
                    if (cit != state.lastCc.end()) { ccPid = pid; ccSlot = &cit->second; prevCc = ccSlot; }
                }
                const bool consistent = prevCc && cc == (*prevCc + 1) % 16;
                if (!partial && !nearPes && !discontinuity && state.openPes.count(pid) && consistent) { fix(1, (uint8_t)(q[1] & ~0x40)); ++pusiClear; }
            }
            if (afcv & 1) {
                if (ccPid != pid) { ccPid = pid; ccSlot = &state.lastCc[pid]; }
                *ccSlot = cc;
            }
        }
        pos += (int64_t)got * g.stride;
    }
    if (p.patches.empty()) return p;
    p.kind = "ts-hdr";
    p.detail = "TS 传输头与载荷结构矛盾：";
    if (pusiSet) p.detail += "补回 PUSI ×" + std::to_string(pusiSet) + " ";
    if (pusiClear) p.detail += "清除误置 PUSI ×" + std::to_string(pusiClear) + " ";
    if (afLen) p.detail += "adaptation 长度 ×" + std::to_string(afLen) + " ";
    if (afc) p.detail += "补回 payload 位 ×" + std::to_string(afc) + " ";
    p.damagedFrom = p.patches.front().offset;
    p.damagedUntil = p.patches.back().offset + 1;
    return p;
}
} // namespace detail

inline RecoveryPlan planTsTransportHeaders(const Reader& read, int64_t fileSize, int64_t fromPos, int64_t windowBytes, const TsVideoPidMap& pids,
                                           TsHeaderScanState& state, const AbortFn* abort) {
    if (!pids.trusted || fromPos < 0) return {};
    TsByteSource src;
    src.read = &read;
    return detail::tsTransportHeadersFrom(src, tsGeometryAt(read, 0, fileSize), fileSize, fromPos, windowBytes, pids, state, abort);
}

inline RecoveryPlan planTsTransportHeaders(TsByteSource& src, const TsGeometry& geom, int64_t fileSize, int64_t fromPos, int64_t windowBytes,
                                           const TsVideoPidMap& pids, TsHeaderScanState& state, const AbortFn* abort) {
    if (!pids.trusted || fromPos < 0) return {};
    return detail::tsTransportHeadersFrom(src, geom, fileSize, fromPos, windowBytes, pids, state, abort);
}

inline RecoveryPlan planRawAudioFrames(const Reader& read, int64_t fileSize, int64_t from, int64_t window, bool adts, const AbortFn* abort,
                                       int64_t* consumedOut) {
    RecoveryPlan p;
    if (consumedOut) *consumedOut = from;
    if (from < 0 || from >= fileSize || window <= 0) return p;
    const int64_t lookahead = adts ? 8192 + 16 : 4096 + 16;
    const int64_t to = std::min(fileSize, from + window + lookahead);
    auto buf = readSpan(read, from, (size_t)(to - from));
    if (buf.size() < 8 || aborted(abort)) return p;
    const bool atEof = from + (int64_t)buf.size() >= fileSize;
    std::vector<ByteFix> fixes;
    size_t consumed = 0;
    int bad = 0;
    if (adts) adtsChainFix(buf.data(), buf.size(), atEof, fixes, consumed, bad);
    else ac3ChainFix(buf.data(), buf.size(), atEof, fixes, consumed, bad);
    if (consumedOut) *consumedOut = from + (int64_t)consumed;
    for (const ByteFix& f : fixes) { Patch pt; pt.offset = from + (int64_t)f.at; pt.bytes = {f.value}; p.patches.push_back(pt); }
    if (p.patches.empty()) return p;
    p.kind = adts ? "raw-adts-length" : "raw-ac3-frmsize";
    p.detail = std::string(adts ? "ADTS 帧长与后继帧头矛盾" : "AC-3/E-AC-3 帧长与后继同步字矛盾且原存 CRC 支持") + "：" +
               std::to_string(p.patches.size()) + " 帧改回（" + std::to_string(bad) + " 帧无法裁决）";
    p.damagedFrom = p.patches.front().offset; p.damagedUntil = p.patches.back().offset + 1;
    return p;
}

namespace detail {
inline RecoveryPlan tsAdtsFramesFrom(TsByteSource& src, const TsGeometry& g, int64_t fileSize, int64_t from, int64_t window, int pid, TsAdtsScanState& st,
                                     const AbortFn* abort) {
    RecoveryPlan p;
    if (!g.valid() || from < 0 || window <= 0) return p;
    const int64_t to = std::min(fileSize, from + window);
    std::vector<uint8_t> es = st.carry;
    std::vector<std::pair<size_t, int64_t>> runs = st.runs;
    for (int64_t pos = from; pos + g.stride <= to;) {
        if (aborted(abort)) return p;
        const size_t n = std::min<size_t>(1024, (size_t)((to - pos) / g.stride));
        const uint8_t* buf = nullptr;
        const size_t got = src.span(pos, n * (size_t)g.stride, buf) / (size_t)g.stride;
        if (got == 0) break;
        for (size_t i = 0; i < got; ++i) {
            const int64_t pktPos = pos + (int64_t)(i * (size_t)g.stride) + g.syncOffset;
            const uint8_t* q = buf + i * (size_t)g.stride + (size_t)g.syncOffset;
            if (q[0] != 0x47 || (q[1] & 0x80) || (q[3] & 0xC0)) continue;
            if ((((q[1] & 0x1f) << 8) | q[2]) != pid) continue;
            const int plo = tsPayloadOffset(q);
            if (plo < 0) continue;
            size_t pl = (size_t)plo;
            if (q[1] & 0x40) {
                if (pl + 9 > 188 || q[pl] != 0 || q[pl + 1] != 0 || q[pl + 2] != 1 || q[pl + 3] < 0xC0 || q[pl + 3] > 0xDF || (q[pl + 6] & 0xC0) != 0x80) { st.inPes = false; continue; }
                pl += 9 + q[pl + 8];
                if (pl > 188) { st.inPes = false; continue; }
                st.inPes = true;
            } else if (!st.inPes) continue;
            if (pl >= 188) continue;
            runs.push_back({es.size(), pktPos + (int64_t)pl});
            es.insert(es.end(), q + pl, q + 188);
        }
        pos += (int64_t)got * g.stride;
    }
    const bool atEof = to >= fileSize;
    std::vector<ByteFix> fixes;
    size_t consumed = 0;
    int bad = 0;
    if (!es.empty()) adtsChainFix(es.data(), es.size(), atEof, fixes, consumed, bad);
    auto mapOff = [&](size_t esOff) -> int64_t {
        size_t lo = 0, hi = runs.size();
        while (lo + 1 < hi) { const size_t mid = (lo + hi) / 2; if (runs[mid].first <= esOff) lo = mid; else hi = mid; }
        if (runs.empty() || runs[lo].first > esOff) return -1;
        return runs[lo].second + (int64_t)(esOff - runs[lo].first);
    };
    for (const ByteFix& f : fixes) {
        const int64_t at = mapOff(f.at);
        if (at < 0) continue;
        Patch pt; pt.offset = at; pt.bytes = {f.value}; p.patches.push_back(pt);
    }

    st.carry.assign(es.begin() + (long)consumed, es.end());
    st.runs.clear();
    for (size_t i = 0; i < runs.size(); ++i) {
        const size_t start = runs[i].first, end = i + 1 < runs.size() ? runs[i + 1].first : es.size();
        if (end <= consumed) continue;
        const size_t s0 = std::max(start, consumed);
        st.runs.push_back({s0 - consumed, runs[i].second + (int64_t)(s0 - start)});
    }
    if (st.carry.size() > 64 * 1024) { st.carry.clear(); st.runs.clear(); st.inPes = false; }
    if (p.patches.empty()) return p;
    p.kind = "ts-adts-length";
    p.detail = "TS 音频 PID 0x" + std::to_string(pid) + " 的 ADTS 帧长与后继帧头矛盾：" + std::to_string(p.patches.size()) + " 帧改回（" +
               std::to_string(bad) + " 帧无法裁决）";
    p.damagedFrom = p.patches.front().offset; p.damagedUntil = p.patches.back().offset + 1;
    return p;
}
} // namespace detail

inline RecoveryPlan planTsAdtsFrames(const Reader& read, int64_t fileSize, int64_t from, int64_t window, int pid, TsAdtsScanState& st, const AbortFn* abort) {
    TsByteSource src;
    src.read = &read;
    return detail::tsAdtsFramesFrom(src, tsGeometryAt(read, 0, fileSize), fileSize, from, window, pid, st, abort);
}

inline RecoveryPlan planTsAdtsFrames(TsByteSource& src, const TsGeometry& geom, int64_t fileSize, int64_t from, int64_t window, int pid,
                                     TsAdtsScanState& st, const AbortFn* abort) {
    return detail::tsAdtsFramesFrom(src, geom, fileSize, from, window, pid, st, abort);
}

namespace detail {
inline RecoveryPlan tsPesHeaderLengthsFrom(TsByteSource& src, const TsGeometry& g, int64_t fileSize, int64_t from, int64_t window,
                                           const TsVideoPidMap& pids, TsPesScanState& st, const AbortFn* abort, int64_t* earliestPts90k) {
    RecoveryPlan p;
    if (!g.valid() || from % g.stride != 0) return p;
    const int64_t to = std::min(fileSize, from + window);
    const int64_t readTo = std::min(fileSize, to + 40ll * g.stride);
    if (readTo <= from) return p;
    const uint8_t* bufData = nullptr;
    const size_t n = src.span(from, (size_t)(readTo - from), bufData) / (size_t)g.stride;
    int checked = 0;
    std::vector<uint8_t> es;
    // PID/CC lookup cache, bit-for-bit equivalent (see tsTransportHeadersFrom): cache the last PID's pids.pids iterator and
    // st.lastCc value pointer; lastCc is read before it is written and inserted only when afc & 1 and the key is absent.
    int memoPid = -1;
    auto memoIt = pids.pids.end();
    int ccPid = -1;
    int* ccSlot = nullptr;
    for (size_t i = 0; i < n; ++i) {
        if (aborted(abort)) { p.patches.clear(); return p; }
        const int64_t pktPos = from + (int64_t)i * g.stride + g.syncOffset;
        if (pktPos - g.syncOffset >= to) break;
        const uint8_t* q = bufData + i * (size_t)g.stride + (size_t)g.syncOffset;
        if (q[0] != 0x47) continue;
        const int pid = ((q[1] & 0x1f) << 8) | q[2];
        if (pid != memoPid) { memoPid = pid; memoIt = pids.pids.find(pid); }
        const auto it = memoIt;
        if (it == pids.pids.end()) continue;
        const int cc = q[3] & 15, afc = (q[3] >> 4) & 3;
        int* prevCc = ccPid == pid ? ccSlot : nullptr;
        if (!prevCc) {
            auto lc = st.lastCc.find(pid);
            if (lc != st.lastCc.end()) { ccPid = pid; ccSlot = &lc->second; prevCc = ccSlot; }
        }
        const bool dup = (afc & 1) && prevCc && *prevCc == cc;
        if (afc & 1) {
            if (!prevCc) { ccPid = pid; ccSlot = &st.lastCc[pid]; prevCc = ccSlot; }
            *prevCc = cc;
        }
        if ((q[1] & 0x80) || (q[3] & 0xC0) || !(afc & 1) || !(q[1] & 0x40) || dup) continue;
        if ((afc & 2) && q[4] > 0 && (q[5] & 0x80)) continue; // discontinuity
        const int plo = tsPayloadOffset(q);
        if (plo < 0 || plo + 14 > 188) continue;
        const size_t pl = (size_t)plo;
        const uint8_t* d = q + pl;
        const size_t avail = 188 - pl;
        if (d[0] || d[1] || d[2] != 1 || d[3] < 0xE0 || d[3] > 0xEF || (d[6] & 0xC0) != 0x80 || (d[6] & 0x30)) continue;
        const int flags = d[7];
        const size_t minimum = flags == 0x80 ? 5 : flags == 0xC0 ? 10 : 0;
        if (minimum == 0 || 9 + minimum > avail) continue;
        const uint8_t* t = d + 9;
        if ((t[0] >> 4) != (minimum == 5 ? 2 : 3) || !(t[0] & 1) || !(t[2] & 1) || !(t[4] & 1)) continue;
        if (minimum == 10 && ((t[5] >> 4) != 1 || !(t[5] & 1) || !(t[7] & 1) || !(t[9] & 1))) continue;
        ++checked;
        size_t e = 9 + minimum;
        while (e < avail && d[e] == 0xff) ++e;
        if (e >= avail) continue;
        const int want = (int)(e - 9), declared = d[8];
        if (want > 255 || declared == want || popcount8((uint8_t)(declared ^ want)) != 1) continue;
        es.assign(d + e, d + avail);
        int last = cc; bool trusted = true;
        for (size_t j = i + 1; j < n && j < i + 40 && es.size() < 8192; ++j) {
            const uint8_t* r = bufData + j * (size_t)g.stride + (size_t)g.syncOffset;
            if (r[0] != 0x47 || ((((r[1] & 0x1f) << 8) | r[2]) != pid)) continue;
            const int rafc = (r[3] >> 4) & 3, rcc = r[3] & 15;
            if ((r[1] & 0x80) || (r[3] & 0xC0) || ((rafc & 2) && r[4] > 0 && (r[5] & 0x80))) { trusted = false; break; }
            if (!(rafc & 1)) continue;
            if (r[1] & 0x40) break;
            if (rcc != (last + 1) % 16) { trusted = false; break; }
            last = rcc;
            const int rpl = tsPayloadOffset(r);
            if (rpl < 0) continue;
            es.insert(es.end(), r + rpl, r + 188);
        }
        if (!trusted || !tsVideoEsChainHasVcl(es.data(), es.size(), it->second == 0x24)) continue;
        Patch pt; pt.offset = pktPos + (int64_t)pl + 8; pt.bytes = {(uint8_t)want};
        p.patches.push_back(pt);
        if (earliestPts90k) {
            const int64_t pts = ((int64_t)((t[0] >> 1) & 7) << 30) | ((int64_t)(((t[1] << 8) | t[2]) >> 1) << 15) | (int64_t)(((t[3] << 8) | t[4]) >> 1);
            if (*earliestPts90k < 0 || pts < *earliestPts90k) *earliestPts90k = pts;
        }
    }
    if (p.patches.empty()) return p;
    p.kind = "ts-pes-header-length";
    p.detail = "TS 视频 PES 可选头长度与时间字段 + 0xff 填充 + Annex-B 起点矛盾：" + std::to_string(p.patches.size()) + " 个 PES 改回（核对 " + std::to_string(checked) + " 个 PES 起点）";
    p.damagedFrom = p.patches.front().offset; p.damagedUntil = p.patches.back().offset + 1;
    return p;
}
} // namespace detail

inline RecoveryPlan planTsPesHeaderLengths(const Reader& read, int64_t fileSize, int64_t from, int64_t window, const TsVideoPidMap& pids,
                                           TsPesScanState& st, const AbortFn* abort, int64_t* earliestPts90k = nullptr) {
    if (earliestPts90k) *earliestPts90k = -1;
    if (!pids.trusted || from < 0 || window <= 0) return {};
    TsByteSource src;
    src.read = &read;
    return detail::tsPesHeaderLengthsFrom(src, tsGeometryAt(read, 0, fileSize), fileSize, from, window, pids, st, abort, earliestPts90k);
}

inline RecoveryPlan planTsPesHeaderLengths(TsByteSource& src, const TsGeometry& geom, int64_t fileSize, int64_t from, int64_t window,
                                           const TsVideoPidMap& pids, TsPesScanState& st, const AbortFn* abort, int64_t* earliestPts90k = nullptr) {
    if (earliestPts90k) *earliestPts90k = -1;
    if (!pids.trusted || from < 0 || window <= 0) return {};
    return detail::tsPesHeaderLengthsFrom(src, geom, fileSize, from, window, pids, st, abort, earliestPts90k);
}

struct Mp3DeclaredBytes {
    int64_t streamStart = -1;
    uint64_t bytes = 0;
};
inline Mp3DeclaredBytes mp3ReadDeclaredBytes(const Reader& read, int64_t fileSize) {
    Mp3DeclaredBytes out;
    int64_t pos = 0;
    for (int i = 0; i < 4; ++i) {
        const auto h = readSpan(read, pos, 10);
        if (h.size() < 10 || std::memcmp(h.data(), "ID3", 3) != 0) break;
        if ((h[6] | h[7] | h[8] | h[9]) & 0x80) return out;
        pos += 10 + (((int64_t)h[6] << 21) | ((int64_t)h[7] << 14) | ((int64_t)h[8] << 7) | h[9]) + ((h[5] & 0x10) ? 10 : 0);
        if (pos >= fileSize) return out;
    }
    const auto f = readSpan(read, pos, 64);
    if (f.size() < 64) return out;
    const uint32_t hdr = be32(f.data());
    if ((hdr & 0xFFE00000u) != 0xFFE00000u) return out;
    const int ver = (hdr >> 19) & 3, layer = (hdr >> 17) & 3, br = (hdr >> 12) & 0xF, sr = (hdr >> 10) & 3;
    if (ver == 1 || layer != 1 || br == 0 || br == 0xF || sr == 3) return out;
    const bool lsf = ver != 3, mono = ((hdr >> 6) & 3) == 3;
    const size_t xo = 4 + (lsf ? (mono ? 9 : 17) : (mono ? 17 : 32));
    if (std::memcmp(f.data() + xo, "Xing", 4) == 0 || std::memcmp(f.data() + xo, "Info", 4) == 0) {
        const uint32_t flags = be32(f.data() + xo + 4);
        const size_t at = xo + 8 + ((flags & 1) ? 4 : 0);
        if (flags & 2) { out.bytes = be32(f.data() + at); out.streamStart = pos; }
        return out;
    }
    if (std::memcmp(f.data() + 36, "VBRI", 4) == 0 && f[40] == 0 && f[41] == 1) {
        out.bytes = be32(f.data() + 46);
        out.streamStart = pos;
    }
    return out;
}

inline bool mp3DeclaredBytesExceedFile(const Mp3DeclaredBytes& d, int64_t fileSize) {
    if (d.streamStart < 0 || d.bytes == 0) return false;
    const int64_t avail = fileSize - (d.streamStart + 4);
    if (avail <= 0) return false;
    return d.bytes > (uint64_t)avail && d.bytes - (uint64_t)avail > ((uint64_t)avail >> 4);
}

} // namespace spresil
