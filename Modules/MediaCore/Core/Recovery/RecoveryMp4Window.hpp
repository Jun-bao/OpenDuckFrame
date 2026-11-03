// Fault-only MP4 table repair. The first bounded subset is one self-contained
// video track in one contiguous mdat. All evidence comes from the same Reader;
// callers must additionally check their source revision and transact open/seek.
#pragma once
#include "RecoveryMp4.hpp"
#include <chrono>
#include <limits>

namespace spresil {

enum class Mp4WindowStatus { NoMatch, Ready, Aborted, Budget, SourceChanged };
struct Mp4WindowLimits {
    uint64_t metadataBytes = 16u << 20, mediaBytes = 16u << 20;
    uint32_t accessUnits = 4096, chunks = 64;
    size_t chunkBytes = 4u << 20;
    int milliseconds = 250;
};
struct Mp4WindowResult {
    RecoveryPlan plan;
    std::vector<Patch> originalFields;
    Mp4WindowStatus status = Mp4WindowStatus::NoMatch;
    uint32_t trackId = 0, firstChunk = 0, chunkCount = 0;
    uint64_t firstSample = 0, sampleCount = 0;
    uint64_t metadataBytes = 0, mediaBytes = 0;
    bool linearPresentationTimeline = false; // no composition offsets or edits; positive stts deltas
};

namespace mp4window {
struct Budget {
    const Reader& source;
    const AbortFn* abort;
    Mp4WindowLimits limits;
    std::chrono::steady_clock::time_point until;
    Mp4WindowStatus failure = Mp4WindowStatus::NoMatch;
    uint64_t metadata = 0, media = 0;
    uint32_t chunks = 0, aus = 0;
    Budget(const Reader& r, const AbortFn* a, const Mp4WindowLimits& l)
        : source(r), abort(a), limits(l), until(std::chrono::steady_clock::now() + std::chrono::milliseconds(l.milliseconds)) {}
    bool okay() {
        if (aborted(abort)) failure = Mp4WindowStatus::Aborted;
        else if (std::chrono::steady_clock::now() >= until && failure == Mp4WindowStatus::NoMatch) failure = Mp4WindowStatus::Budget;
        return failure == Mp4WindowStatus::NoMatch;
    }
    int64_t read(int64_t at, uint8_t* dst, size_t n, bool mediaRead = false) {
        if (!okay() || at < 0) return -1;
        uint64_t& used = mediaRead ? media : metadata;
        const uint64_t cap = mediaRead ? limits.mediaBytes : limits.metadataBytes;
        if (used > cap || n > cap - used) { failure = Mp4WindowStatus::Budget; return -1; }
        const int64_t got = source(at, dst, n);
        if (got > 0) used += (uint64_t)got;
        if (!okay()) return -1;
        return got;
    }
    Reader metadataReader() { return [this](int64_t p, uint8_t* d, size_t n) { return read(p, d, n); }; }
};

// Each table retains only one page. Counts are structural limits, not allocation
// sizes; 200k or larger sample tables never become a vector of samples/chunks.
struct Table {
    Budget& budget;
    int64_t at = 0;
    uint32_t count = 0, stride = 0;
    uint64_t pageAt = UINT64_MAX;
    std::vector<uint8_t> page;
    explicit Table(Budget& b) : budget(b) {}
    bool init(const Box& box, int64_t bodyOffset, uint32_t n, uint32_t s) {
        if (bodyOffset < box.hdr || box.size < (uint64_t)bodyOffset ||
            (uint64_t)n * s > box.size - (uint64_t)bodyOffset) return false;
        at = box.pos + bodyOffset; count = n; stride = s; return true;
    }
    bool get(uint32_t i, uint32_t part, uint32_t width, uint64_t& value) {
        if (!budget.okay() || i >= count || part + width > stride || (width != 4 && width != 8)) return false;
        const uint64_t off = (uint64_t)i * stride + part;
        // A row-sized page prevents a co64/12-byte stsc item crossing pages.
        const uint64_t pageSize = (65536 / stride) * stride;
        const uint64_t base = off / pageSize * pageSize;
        if (pageAt != base) {
            const size_t n = (size_t)std::min<uint64_t>(pageSize, (uint64_t)count * stride - base);
            page.resize(n);
            if (budget.read(at + (int64_t)base, page.data(), n) != (int64_t)n) return false;
            pageAt = base;
        }
        const size_t p = (size_t)(off - base);
        value = width == 8 ? be64(page.data() + p) : be32(page.data() + p);
        return true;
    }
    bool u32(uint32_t i, uint32_t part, uint32_t& v) { uint64_t n = 0; if (!get(i, part, 4, n)) return false; v = (uint32_t)n; return true; }
};

struct Config {
    bool hevc = false;
    int length = 0;
    uint32_t spsId = UINT32_MAX, ppsId = UINT32_MAX;
    std::vector<uint8_t> sps, pps, vps;
};
inline bool h264Progressive(const std::vector<uint8_t>& n, uint32_t& id) {
    if (n.size() < 5 || (n[0] & 31) != 7) return false;
    detail::H264BitReader br(n.data() + 1, n.size() - 1, 512);
    const uint32_t profile = br.bits(8); br.bits(16); id = br.ue();
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44 || profile == 83 || profile == 86 ||
        profile == 118 || profile == 128 || profile == 138 || profile == 139 || profile == 134 || profile == 135) {
        const uint32_t chroma = br.ue(); if (chroma > 2) return false;
        if (br.ue() > 6 || br.ue() > 6) return false;
        br.bits(1);
        if (br.bits(1)) for (int i = 0; i < 8 && !br.bad; ++i) if (br.bits(1)) {
            int last = 8, next = 8;
            for (int j = 0; j < (i < 6 ? 16 : 64) && !br.bad; ++j) { if (next) next = (last + br.se() + 256) % 256; if (next) last = next; }
        }
    }
    if (br.ue() > 12) return false;
    const uint32_t poc = br.ue();
    if (poc == 0) { if (br.ue() > 12) return false; }
    else if (poc == 1) { br.bits(1); br.se(); br.se(); const uint32_t cycle = br.ue(); if (cycle > 255) return false; for (uint32_t i = 0; i < cycle; ++i) br.se(); }
    else if (poc != 2) return false;
    br.ue(); br.bits(1); br.ue(); br.ue(); const bool progressive = br.bits(1) != 0;
    return !br.bad && id <= 31 && progressive;
}
inline bool hevcProgressive(const std::vector<uint8_t>& n, uint32_t& id) {
    if (n.size() < 16 || ((n[0] >> 1) & 63) != 33 || (n[0] & 1) || (n[1] >> 3)) return false;
    detail::H264BitReader br(n.data() + 2, n.size() - 2, 512);
    br.bits(4); const int sub = (int)br.bits(3); br.bits(1);
    br.bits(8); br.bits(32);
    const bool progressive = br.bits(1), interlaced = br.bits(1);
    br.bits(1); const bool frameOnly = br.bits(1); br.skip(44); br.bits(8);
    bool prof[8] = {}, lev[8] = {};
    for (int i = 0; i < sub; ++i) { prof[i] = br.bits(1); lev[i] = br.bits(1); }
    if (sub) for (int i = sub; i < 8; ++i) br.bits(2);
    for (int i = 0; i < sub; ++i) { if (prof[i]) br.skip(88); if (lev[i]) br.bits(8); }
    id = br.ue();
    return !br.bad && progressive && !interlaced && frameOnly && id <= 15;
}
inline bool configuration(const Reader& read, const Mp4TrackTables& t, Config& c, const AbortFn* abort) {
    auto sd = readSpan(read, t.stsd.pos + t.stsd.hdr, 8);
    if (sd.size() != 8 || be32(sd.data() + 4) != 1) return false;
    Box entry;
    if (!readBox(read, t.stsd.pos + t.stsd.hdr + 8, t.stsd.end(), entry) || entry.size <= 94 || entry.end() != t.stsd.end()) return false;
    if (!(entry.is("avc1") || entry.is("avc3") || entry.is("hvc1") || entry.is("hev1"))) return false;
    auto ref = readSpan(read, entry.pos + 14, 2);
    if (ref.size() != 2 || ref[0] || ref[1] != 1) return false;
    Box dinf, dref;
    if (!mp4FindChild(read, t.minf, "dinf", dinf, abort) || !mp4FindChild(read, dinf, "dref", dref, abort)) return false;
    auto dr = readSpan(read, dref.pos + dref.hdr, 20);
    if (dr.size() != 20 || be32(dr.data() + 4) != 1 || be32(dr.data() + 8) != 12 ||
        std::memcmp(dr.data() + 12, "url ", 4) || be32(dr.data() + 16) != 1 || dref.size != (uint64_t)dref.hdr + 20) return false;
    std::vector<Box> cfg;
    if (!boxChildrenClose(read, entry.pos + 86, entry.end(), nullptr, &cfg, abort)) return false;
    int found = 0;
    for (const Box& b : cfg) {
        if (!b.is("avcC") && !b.is("hvcC")) { if (b.is("sinf")) return false; continue; }
        if (++found != 1 || b.size > 65536 || b.size <= (uint64_t)b.hdr) return false;
        auto d = readSpan(read, b.pos + b.hdr, (size_t)b.size - b.hdr);
        if (b.is("avcC")) {
            if (!avccRecordValid(d.data(), (int)d.size()) || (d[5] & 31) != 1) return false;
            c.length = (d[4] & 3) + 1;
            size_t at = 6;
            auto nal = [&](std::vector<uint8_t>& out) {
                if (at + 2 > d.size()) return false;
                size_t n = ((size_t)d[at] << 8) | d[at + 1]; at += 2;
                if (!n || n > 512 || n > d.size() - at) return false;
                out.assign(d.begin() + at, d.begin() + at + n); at += n; return true;
            };
            if (!nal(c.sps) || at >= d.size() || d[at++] != 1 || !nal(c.pps) || !h264Progressive(c.sps, c.spsId)) return false;
            detail::H264BitReader br(c.pps.data() + 1, c.pps.size() - 1);
            c.ppsId = br.ue(); const uint32_t sid = br.ue(); br.bits(1); br.bits(1);
            const uint32_t sliceGroups = br.ue();
            if ((c.pps[0] & 31) != 8 || br.bad || c.ppsId > 255 || sid != c.spsId || sliceGroups) return false;
        } else {
            if (!hvccRecordValid(d.data(), (int)d.size()) || d.size() < 23) return false;
            c.hevc = true; c.length = (d[21] & 3) + 1; size_t at = 23;
            for (uint32_t i = 0; i < d[22]; ++i) {
                if (at + 3 > d.size()) return false;
                const uint8_t type = d[at++] & 63; const uint32_t nn = ((uint32_t)d[at] << 8) | d[at + 1]; at += 2;
                for (uint32_t j = 0; j < nn; ++j) {
                    if (at + 2 > d.size()) return false;
                    const size_t n = ((size_t)d[at] << 8) | d[at + 1]; at += 2;
                    if (n > d.size() - at) return false;
                    std::vector<uint8_t>* out = type == 32 ? &c.vps : type == 33 ? &c.sps : type == 34 ? &c.pps : nullptr;
                    if (out) { if (!out->empty() || n < 3 || n > 512) return false; out->assign(d.begin() + at, d.begin() + at + n); }
                    at += n;
                }
            }
            if (c.vps.empty() || c.pps.empty() || !hevcProgressive(c.sps, c.spsId)) return false;
            detail::H264BitReader br(c.pps.data() + 2, c.pps.size() - 2);
            c.ppsId = br.ue(); const uint32_t sid = br.ue();
            if (br.bad || c.ppsId > 63 || sid != c.spsId) return false;
        }
    }
    return found == 1 && c.length > 0 && (c.hevc == (entry.is("hvc1") || entry.is("hev1")));
}

// Deliberately accepts one first VCL slice per AU. Multi-slice/field pictures are
// refused rather than letting an interior slice become an apparent sample start.
inline bool walk(const std::vector<uint8_t>& data, const Config& c, std::vector<uint32_t>& sizes, Budget& b) {
    sizes.clear(); size_t at = 0, start = 0; bool vcl = false;
    while (at < data.size()) {
        if (!b.okay() || data.size() - at < (size_t)c.length + 2) return false;
        uint32_t n = 0; for (int i = 0; i < c.length; ++i) n = (n << 8) | data[at + i];
        if (n < 2 || n > data.size() - at - c.length) return false;
        const uint8_t* p = data.data() + at + c.length; int type = 0;
        if (!mp4NalHeaderOk(p, c.hevc, type) || (c.hevc && ((p[0] & 1) || (p[1] >> 3)))) return false;
        const bool isVcl = c.hevc ? type <= 31 : (type == 1 || type == 5);
        const bool prefix = c.hevc ? (type >= 32 && type <= 35) || type == 39 : type == 6 || type == 7 || type == 8 || type == 9;
        if (vcl && (isVcl || prefix)) {
            if (++b.aus > b.limits.accessUnits) { b.failure = Mp4WindowStatus::Budget; return false; }
            sizes.push_back((uint32_t)(at - start)); start = at; vcl = false;
        }
        if (isVcl) {
            detail::H264BitReader br(p + (c.hevc ? 2 : 1), n - (c.hevc ? 2 : 1));
            uint32_t pps = 0;
            if (c.hevc) { if (type > 21 || br.bits(1) != 1) return false; if (type >= 16) br.bits(1); pps = br.ue(); }
            else { if (br.ue() != 0 || br.ue() > 9) return false; pps = br.ue(); }
            if (br.bad || pps != c.ppsId) return false;
            vcl = true;
        } else {
            const std::vector<uint8_t>* param = nullptr;
            if (c.hevc) { if (type == 32) param = &c.vps; if (type == 33) param = &c.sps; if (type == 34) param = &c.pps; }
            else { if (type == 7) param = &c.sps; if (type == 8) param = &c.pps; }
            if (param && (n != param->size() || std::memcmp(p, param->data(), n))) return false;
            if (!param && !(c.hevc ? type == 35 || type == 39 || type == 40 : type == 6 || type == 9 || type == 12)) return false;
        }
        at += c.length + n;
    }
    if (!vcl || start == at || ++b.aus > b.limits.accessUnits) { if (b.aus > b.limits.accessUnits) b.failure = Mp4WindowStatus::Budget; return false; }
    sizes.push_back((uint32_t)(at - start)); return true;
}
struct Run { uint32_t first, until, count, index; uint64_t sample; };
inline const Run* runFor(const std::vector<Run>& runs, uint32_t chunk) {
    auto it = std::upper_bound(runs.begin(), runs.end(), chunk, [](uint32_t n, const Run& r) { return n < r.first; });
    return it == runs.begin() ? nullptr : &*--it;
}
inline uint64_t ordinal(const Run& r, uint32_t chunk) { return r.sample + (uint64_t)(chunk - r.first) * r.count; }
} // namespace mp4window

inline Mp4WindowResult planMp4SampleTableWindow(const Reader& source, int64_t fileSize, uint32_t trackId,
                                               int64_t faultPacketPos, const AbortFn* abort = nullptr,
                                               const Mp4WindowLimits& limits = {}) {
    using namespace mp4window;
    Mp4WindowResult out; out.trackId = trackId;
    Budget budget(source, abort, limits); const Reader read = budget.metadataReader();
    auto finish = [&]() { out.metadataBytes = budget.metadata; out.mediaBytes = budget.media; if (budget.failure != Mp4WindowStatus::NoMatch) { out.plan = {}; out.originalFields.clear(); out.status = budget.failure; } return out; };
    if (fileSize <= 0 || faultPacketPos < 0 || !trackId || !budget.okay()) return finish();
    Box moov, mdat; int moovs = 0, mdats = 0; int64_t pos = 0;
    for (int hops = 0; pos < fileSize && hops < 64; ++hops) {
        Box x; if (!readBox(read, pos, fileSize, x) || x.end() > fileSize || x.end() <= pos || x.is("moof")) return finish();
        if (x.is("moov")) { moov = x; ++moovs; } if (x.is("mdat")) { mdat = x; ++mdats; } pos = x.end();
    }
    if (pos != fileSize || moovs != 1 || mdats != 1) return finish();
    std::vector<Box> kids; if (!boxChildrenClose(read, moov.pos + moov.hdr, moov.end(), nullptr, &kids, abort)) return finish();
    Mp4TrackTables t; int tracks = 0;
    for (const Box& x : kids) if (x.is("trak")) { if (++tracks != 1 || !mp4TrackTables(read, x, t, abort)) return finish(); }
    if (tracks != 1 || !t.haveTkhd || std::memcmp(t.handler, "vide", 4)) return finish();
    auto tk = readSpan(read, t.tkhd.pos + t.tkhd.hdr, 24);
    if (tk.size() != 24 || tk[0] > 1 || be32(tk.data() + (tk[0] ? 20 : 12)) != trackId) return finish();
    Config config; if (!configuration(read, t, config, abort)) return finish();
    auto z = readSpan(read, t.stsz.pos + t.stsz.hdr, 12);
    auto co = readSpan(read, t.stco.pos + t.stco.hdr, 8);
    auto sc = readSpan(read, t.stsc.pos + t.stsc.hdr, 8);
    auto ts = readSpan(read, t.stts.pos + t.stts.hdr, 8);
    if (z.size() != 12 || co.size() != 8 || sc.size() != 8 || ts.size() != 8 || be32(z.data() + 4)) return finish();
    const uint32_t ns = be32(z.data() + 8), nc = be32(co.data() + 4), nr = be32(sc.data() + 4), nt = be32(ts.data() + 4);
    if (!ns || !nc || !nr || nr > 16384 || nc == UINT32_MAX) return finish();
    Table sizes(budget), offsets(budget), counts(budget), times(budget);
    if (!sizes.init(t.stsz, t.stsz.hdr + 12, ns, 4) || !offsets.init(t.stco, t.stco.hdr + 8, nc, t.co64 ? 8 : 4) ||
        !counts.init(t.stsc, t.stsc.hdr + 8, nr, 12) || !times.init(t.stts, t.stts.hdr + 8, nt, 8)) return finish();
    uint64_t timeSamples = 0;
    for (uint32_t i = 0; i < nt; ++i) { uint32_t n, delta; if (!times.u32(i, 0, n) || !times.u32(i, 4, delta) || !n || !delta) return finish(); timeSamples += n; if (timeSamples > ns) return finish(); }
    if (timeSamples != ns) return finish();
    std::vector<Run> runs; uint64_t total = 0;
    for (uint32_t i = 0; i < nr; ++i) {
        uint32_t first, n, desc, until = nc + 1;
        if (!counts.u32(i, 0, first) || !counts.u32(i, 4, n) || !counts.u32(i, 8, desc) ||
            (i + 1 < nr && !counts.u32(i + 1, 0, until)) || !first || first >= until || until > nc + 1 || !n || desc != 1 || (!i && first != 1)) return finish();
        runs.push_back({first - 1, until - 1, n, i, total});
        const uint64_t add = (uint64_t)(until - first) * n;
        if (add > UINT64_MAX - total) return finish(); total += add;
    }
    const int64_t mediaStart = mdat.pos + mdat.hdr, mediaEnd = mdat.end();
    uint32_t chosen = UINT32_MAX; uint64_t last = 0;
    for (uint32_t i = 0; i < nc; ++i) {
        uint64_t off; if (!offsets.get(i, 0, offsets.stride, off) || off < (uint64_t)mediaStart || off >= (uint64_t)mediaEnd || (i && off <= last)) return finish();
        if (off <= (uint64_t)faultPacketPos) chosen = i; last = off;
    }
    if (chosen == UINT32_MAX || faultPacketPos >= mediaEnd) return finish();
    const Run* selected = runFor(runs, chosen); if (!selected) return finish();
    auto offset = [&](uint32_t i, int64_t& v) { uint64_t n; if (!offsets.get(i, 0, offsets.stride, n) || n > INT64_MAX) return false; v = (int64_t)n; return true; };
    auto declared = [&](uint64_t from, uint32_t n, std::vector<uint32_t>& v, uint64_t& bytes) {
        if (n > limits.accessUnits) { budget.failure = Mp4WindowStatus::Budget; return false; }
        if (from > ns || n > ns - from) return false; v.clear(); bytes = 0;
        for (uint32_t k = 0; k < n; ++k) { uint32_t s; if (!sizes.u32((uint32_t)from + k, 0, s) || !s) return false; v.push_back(s); bytes += s; }
        if (bytes > limits.chunkBytes) { budget.failure = Mp4WindowStatus::Budget; return false; }
        return true;
    };
    auto scan = [&](int64_t start, int64_t end, std::vector<uint32_t>& actual) {
        if (start < mediaStart || end <= start || end > mediaEnd) return false;
        if ((uint64_t)(end - start) > limits.chunkBytes) { budget.failure = Mp4WindowStatus::Budget; return false; }
        if (++budget.chunks > limits.chunks) { budget.failure = Mp4WindowStatus::Budget; return false; }
        std::vector<uint8_t> bytes((size_t)(end - start));
        if (budget.read(start, bytes.data(), bytes.size(), true) != (int64_t)bytes.size()) return false;
        return walk(bytes, config, actual, budget);
    };
    // Guards are read from the unmodified source; their declared sample chain
    // must exactly match semantic AUs. Their end is never taken from bad stco.
    auto guard = [&](uint32_t chunk, int64_t& start, int64_t& end) {
        const Run* r = runFor(runs, chunk); if (!r || !offset(chunk, start)) return false;
        std::vector<uint32_t> expected, actual; uint64_t bytes;
        if (!declared(ordinal(*r, chunk), r->count, expected, bytes) || bytes > (uint64_t)(mediaEnd - start)) return false;
        end = start + (int64_t)bytes;
        return scan(start, end, actual) && actual == expected;
    };
    uint32_t from = chosen, until = chosen + 1;
    // A count inconsistency can only be explained by changing the entire run.
    const bool countMode = total != ns;
    if (countMode) { from = selected->first; until = selected->until; if (until - from > limits.chunks - std::min<uint32_t>(2, limits.chunks)) { budget.failure = Mp4WindowStatus::Budget; return finish(); } }
    int64_t begin = mediaStart, end = mediaEnd, ignored;
    if (from && !guard(from - 1, ignored, begin)) return finish();
    if (until < nc && (countMode ? !offset(until, end) : !guard(until, end, ignored))) return finish();
    // At a file edge the opposite complete guard is mandatory.
    if (from == 0 && until == nc) return finish();
    int64_t stated; if (!offset(from, stated)) return finish();
    if (begin >= end || (countMode ? stated != begin : std::llabs(stated - begin) > 8)) return finish();
    std::vector<uint32_t> actual;
    uint64_t firstSample = ordinal(*selected, from);
    if (!countMode) {
        // Establish the local sample ordinal independently of stsc. Otherwise
        // a compensated earlier count error can make equal-sized guards refer
        // to the wrong entries and invite a false local stsz repair.
        uint64_t prefixBytes = 0;
        if (firstSample > ns) return finish();
        for (uint32_t i = 0; i < firstSample; ++i) {
            uint32_t n;
            if (!sizes.u32(i, 0, n) || !n || n > UINT64_MAX - prefixBytes) return finish();
            prefixBytes += n;
        }
        if (prefixBytes != (uint64_t)(begin - mediaStart)) return finish();
        std::vector<uint32_t> expected; uint64_t bytes;
        if (!declared(firstSample, selected->count, expected, bytes) || !scan(begin, end, actual)) return finish();
        if (actual == expected && begin == stated) return finish();
        if (actual.size() != selected->count) return finish(); // H3 would require a full-run proof; never assume it is absent.
        if (begin != stated && actual == expected) {
            Patch p; p.offset = offsets.at + (int64_t)from * offsets.stride;
            if (t.co64) putBe64(p.bytes, (uint64_t)begin); else { if (begin > UINT32_MAX) return finish(); putBe32(p.bytes, (uint32_t)begin); }
            Patch original; original.offset = p.offset; if (t.co64) putBe64(original.bytes, (uint64_t)stated); else putBe32(original.bytes, (uint32_t)stated);
            out.originalFields.push_back(std::move(original));
            out.plan.patches.push_back(std::move(p)); out.plan.kind = "mp4-stco-window";
        } else if (begin == stated && actual != expected) {
            for (uint32_t i = 0; i < actual.size(); ++i) if (actual[i] != expected[i]) {
                Patch p; p.offset = sizes.at + (int64_t)(firstSample + i) * 4; putBe32(p.bytes, actual[i]);
                Patch original; original.offset = p.offset; putBe32(original.bytes, expected[i]); out.originalFields.push_back(std::move(original));
                out.plan.patches.push_back(std::move(p));
            }
            out.plan.kind = "mp4-stsz-window";
        } else return finish(); // Simultaneous stco/stsz damage is not one hypothesis.
        out.sampleCount = actual.size();
    } else {
        // A positive stsz sequence uniquely maps absolute contiguous media byte
        // boundaries to sample ordinals, independent of all stsc run counts.
        uint64_t sum = 0, prefix = UINT64_MAX, suffix = UINT64_MAX;
        for (uint32_t i = 0; i <= ns; ++i) {
            if (sum == (uint64_t)(begin - mediaStart)) prefix = i;
            if (sum == (uint64_t)(end - mediaStart)) suffix = i;
            if (i == ns) break;
            uint32_t n; if (!sizes.u32(i, 0, n) || !n || n > UINT64_MAX - sum) return finish(); sum += n;
        }
        if (sum != (uint64_t)(mediaEnd - mediaStart) || prefix != firstSample || suffix == UINT64_MAX || suffix <= prefix) return finish();
        const uint64_t n = (suffix - prefix) / (until - from);
        if (!n || n > limits.accessUnits || n * (until - from) != suffix - prefix ||
            total - (uint64_t)(until - from) * selected->count + (suffix - prefix) != ns || n == selected->count) return finish();
        // The right guard used old ordinals above. Its metadata ordinal shifts
        // under the candidate, so validate it again with the corrected suffix.
        if (until < nc) {
            const Run* r = runFor(runs, until); std::vector<uint32_t> want, got; uint64_t bytes;
            if (!r || !declared(suffix, r->count, want, bytes) || bytes > (uint64_t)(mediaEnd - end) || !scan(end, end + (int64_t)bytes, got) || got != want) return finish();
        }
        uint64_t s = prefix;
        for (uint32_t i = from; i < until; ++i) {
            int64_t a, zoff = end;
            if (!offset(i, a) || (i + 1 < until && !offset(i + 1, zoff)) || !scan(a, zoff, actual) || actual.size() != n) return finish();
            std::vector<uint32_t> want; uint64_t bytes;
            if (!declared(s, (uint32_t)n, want, bytes) || want != actual) return finish(); s += n;
        }
        Patch p; p.offset = counts.at + (int64_t)selected->index * 12 + 4; putBe32(p.bytes, (uint32_t)n);
        Patch original; original.offset = p.offset; putBe32(original.bytes, selected->count); out.originalFields.push_back(std::move(original));
        out.plan.patches.push_back(std::move(p)); out.plan.kind = "mp4-stsc-window"; out.sampleCount = suffix - prefix;
    }
    if (out.plan.patches.empty() || out.plan.patches.size() > 4096) { out.plan = {}; return finish(); }
    // Coalesce adjacent fields before they enter LocalIO's overlay scan.
    std::vector<Patch> merged;
    for (const Patch& p : out.plan.patches) {
        if (!merged.empty() && merged.back().offset + (int64_t)merged.back().bytes.size() == p.offset) merged.back().bytes.insert(merged.back().bytes.end(), p.bytes.begin(), p.bytes.end());
        else merged.push_back(p);
    }
    size_t covered = 0;
    for (const Patch& p : merged) {
        covered += p.bytes.size(); if (covered > 65536) { out.plan = {}; return finish(); }
    }
    for (const Patch& original : out.originalFields) {
        const auto now = readSpan(read, original.offset, original.bytes.size());
        if (now != original.bytes) { out.plan = {}; out.originalFields.clear(); out.status = Mp4WindowStatus::SourceChanged; return finish(); }
    }
    out.plan.patches = std::move(merged); out.firstChunk = from; out.chunkCount = until - from; out.firstSample = firstSample;
    out.plan.damagedFrom = begin; out.plan.damagedUntil = end;
    out.plan.detail = "局部样本表：完整原始 guard 与单视频 mdat 边界互证；仅修复 " + std::to_string(out.chunkCount) + " 个 chunk，保留原时轴";
    // Absence is evidence only after both complete child walks succeed. Even
    // identity edits or all-zero ctts remain outside the anchor-discard subset.
    std::vector<Box> sampleChildren, trackChildren;
    if (boxChildrenClose(read, t.stbl.pos + t.stbl.hdr, t.stbl.end(), nullptr, &sampleChildren, abort) &&
        boxChildrenClose(read, t.trak.pos + t.trak.hdr, t.trak.end(), nullptr, &trackChildren, abort)) {
        out.linearPresentationTimeline =
            std::none_of(sampleChildren.begin(), sampleChildren.end(), [](const Box& b) { return b.is("ctts"); }) &&
            std::none_of(trackChildren.begin(), trackChildren.end(), [](const Box& b) { return b.is("edts"); });
    }
    out.status = Mp4WindowStatus::Ready;
    return finish();
}

// Commit-time check: caller must charge these reads to its shared transaction
// budget and validate source.current() before and after this operation.
inline bool mp4WindowOriginalFieldsMatch(const Reader& read, const Mp4WindowResult& result, const AbortFn* abort = nullptr) {
    if (result.status != Mp4WindowStatus::Ready || result.plan.empty()) return false;
    for (const Patch& original : result.originalFields) {
        if (aborted(abort)) return false;
        const auto now = readSpan(read, original.offset, original.bytes.size());
        if (now != original.bytes) return false;
    }
    return !aborted(abort);
}
} // namespace spresil
