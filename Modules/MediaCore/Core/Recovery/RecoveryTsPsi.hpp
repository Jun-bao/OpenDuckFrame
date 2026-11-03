#pragma once

#include "RecoveryMpeg.hpp"
#include "RecoveryTypes.hpp" // TsPsiIdentity / TsPsiMap / TsRecoveryLane / TsPsiSessionBudget
#include "RecoveryOgg.hpp" // MPEG CRC implementation shared with the legacy TS helpers
#include <chrono>
#include <memory>

namespace spresil {

namespace tspsi_detail {
inline bool stuffing(const uint8_t* p, size_t n) {
    for (size_t i = 0; i < n; ++i) if (p[i] != 0xff) return false;
    return true;
}

// Deliberately small descriptor subset. CA and unknown descriptors are not
// ignored: they can alter payload interpretation. Exact bytes remain identity.
inline bool descriptors(const uint8_t* p, size_t n) {
    for (size_t i = 0; i < n;) {
        if (n - i < 2 || (size_t)p[i + 1] > n - i - 2) return false;
        const int tag = p[i], len = p[i + 1];
        const uint8_t* d = p + i + 2;
        bool ok = (tag == 0x0a && len > 0 && len % 4 == 0) || (tag == 0x52 && len == 1) || (tag == 0x28 && len == 4);
        if (tag == 5 && len == 4) {
            for (const char* id : {"HEVC", "AC-3", "EAC3", "HDMV", "DTS1", "DTS2", "DTS3"})
                if (std::memcmp(d, id, 4) == 0) ok = true;
        }
        if (!ok) return false;
        i += 2 + (size_t)len;
    }
    return true;
}

inline bool sectionHeader(const std::vector<uint8_t>& s, int table, size_t minimum) {
    return s.size() >= minimum && s.size() <= 1024 && s[0] == table && (s[1] & 0xf0) == 0xb0 &&
           3 + ((((size_t)s[1] & 15) << 8) | s[2]) == s.size() && (s[5] & 0xc1) == 0xc1 &&
           s[6] == 0 && s[7] == 0 && mpegCrc32(s.data(), s.size()) == 0;
}

// Stateful only within ONE explicitly bounded walk. Nothing is carried from a
// cached map, a previous fault attempt, a seek or a source revision.
class Walk {
public:
    explicit Walk(TsGeometry g) { result.geometry = g; }
    TsPsiMap result;
    bool bad = false;

    void packet(const uint8_t* q, int64_t pos) {
        if (bad) return;
        if (q[0] != 0x47) { bad = true; return; }
        const int pid = ((q[1] & 31) << 8) | q[2];
        if (pid != 0 && pid != result.identity.pmtPid) return;
        Channel& c = pid == 0 ? pat_ : pmt_;
        const int afc = (q[3] >> 4) & 3, cc = q[3] & 15;
        if ((q[1] & 0x80) || (q[3] & 0xc0) || afc == 0) { bad = true; return; }
        size_t pl = 4;
        if (afc & 2) {
            const size_t len = q[4];
            if (len > 183 || (afc == 2 && len != 183) || (afc == 3 && len > 182) || (len && (q[5] & 0x80))) { bad = true; return; }
            pl = 5 + len;
        }
        if (!(afc & 1)) {
            if ((q[1] & 0x40) || (c.cc >= 0 && cc != c.cc)) bad = true;
            return;
        }
        const bool pusi = (q[1] & 0x40) != 0;
        const size_t count = 188 - pl;
        if (c.cc == cc) {
            if (pusi != c.pusi || c.payload.size() != count || std::memcmp(c.payload.data(), q + pl, count) != 0) bad = true;
            return; // only an identical payload duplicate is legal
        }
        if (c.cc >= 0 && cc != (c.cc + 1) % 16) { bad = true; return; }
        c.cc = cc; c.pusi = pusi; c.payload.assign(q + pl, q + 188);
        if (pusi) {
            const size_t pointer = q[pl];
            if (pointer > count - 1) { bad = true; return; }
            const uint8_t* prefix = q + pl + 1;
            if (!c.section.empty()) {
                const size_t used = feed(c, prefix, pointer, pos, pid);
                if (bad || !c.section.empty() || !stuffing(prefix + used, pointer - used)) { bad = true; return; }
            } else if (result.valid() && !stuffing(prefix, pointer)) {
                bad = true; return;
            }
            size_t off = pl + 1 + pointer;
            while (off < 188 && !bad) {
                if (q[off] == 0xff) { if (!stuffing(q + off, 188 - off)) bad = true; break; }
                const size_t used = feed(c, q + off, 188 - off, pos, pid);
                off += used;
                if (!used || !c.section.empty()) break;
            }
        } else if (!c.section.empty()) {
            const size_t used = feed(c, q + pl, count, pos, pid);
            if (!bad && !c.section.empty()) return;
            if (!stuffing(q + pl + used, count - used)) bad = true;
        } else if (result.valid() && !stuffing(q + pl, count)) {
            bad = true; // a continuation without its section cannot authorize anything
        }
    }

    bool complete() const { return !bad && result.valid() && pat_.section.empty() && pmt_.section.empty(); }

private:
    struct Channel {
        int cc = -1;
        bool pusi = false;
        int64_t start = -1;
        std::vector<uint8_t> payload, section;
    } pat_, pmt_;

    size_t feed(Channel& c, const uint8_t* p, size_t n, int64_t pos, int pid) {
        if (c.section.empty()) c.start = pos;
        size_t used = 0;
        while (used < n && !bad) {
            c.section.push_back(p[used++]);
            if (c.section.size() < 3) continue;
            const size_t total = 3 + ((((size_t)c.section[1] & 15) << 8) | c.section[2]);
            if ((c.section[1] & 0xf0) != 0xb0 || total < 12 || total > 1024) { bad = true; break; }
            if (c.section.size() == total) {
                accept(c.section, c.start, pos + result.geometry.stride, pid);
                c.section.clear();
                break;
            }
        }
        return used;
    }

    void accept(const std::vector<uint8_t>& s, int64_t begin, int64_t end, int pid) {
        TsPsiIdentity& id = result.identity;
        if (pid == 0) {
            if (!sectionHeader(s, 0, 16) || (s.size() - 12) % 4) { bad = true; return; }
            int program = -1, pmt = -1;
            for (size_t i = 8; i < s.size() - 4; i += 4) {
                if ((s[i + 2] & 0xe0) != 0xe0) { bad = true; return; }
                const int number = (s[i] << 8) | s[i + 1], target = ((s[i + 2] & 31) << 8) | s[i + 3];
                if (target < 0x10 || target == 0x1fff) { bad = true; return; }
                if (!number) continue; // defined PAT network PID, not a program
                if (program >= 0) { bad = true; return; }
                program = number; pmt = target;
            }
            if (program < 0 || (!id.pat.empty() && id.pat != s)) { bad = true; return; }
            if (id.pat.empty()) {
                id.pat = s; id.transportId = (s[3] << 8) | s[4];
                id.program = program; id.pmtPid = pmt; id.patVersion = (s[5] >> 1) & 31;
                result.anchorBegin = begin;
            }
            return;
        }
        if (!sectionHeader(s, 2, 16) || ((s[3] << 8) | s[4]) != id.program ||
            (s[8] & 0xe0) != 0xe0 || (s[10] & 0xf0) != 0xf0 || (!id.pmt.empty() && id.pmt != s)) { bad = true; return; }
        const int pcrPid = ((s[8] & 31) << 8) | s[9];
        if (pcrPid < 0x10 || pcrPid == id.pmtPid) { bad = true; return; }
        const size_t stop = s.size() - 4, infoLen = ((s[10] & 15) << 8) | s[11];
        if (infoLen > stop - 12 || !descriptors(s.data() + 12, infoLen)) { bad = true; return; }
        std::set<int> seen;
        TsVideoPidMap map;
        for (size_t i = 12 + infoLen; i < stop;) {
            if (stop - i < 5 || (s[i + 1] & 0xe0) != 0xe0 || (s[i + 3] & 0xf0) != 0xf0) { bad = true; return; }
            const int esPid = ((s[i + 1] & 31) << 8) | s[i + 2];
            const size_t esLen = ((s[i + 3] & 15) << 8) | s[i + 4];
            if (esPid < 0x10 || esPid == 0x1fff || esPid == id.pmtPid || !seen.insert(esPid).second ||
                esLen > stop - i - 5 || !descriptors(s.data() + i + 5, esLen)) { bad = true; return; }
            const uint8_t type = s[i];
            if (type == 0x1b || type == 0x24) map.pids[esPid] = type;
            if (type == 0x0f || type == 3 || type == 4 || type == 0x81 || type == 0x87) map.audioPids[esPid] = type;
            i += 5 + esLen;
        }
        if (id.pmt.empty()) {
            id.pmt = s; id.pmtVersion = (s[5] >> 1) & 31; id.pcrPid = ((s[8] & 31) << 8) | s[9];
            map.programTrusted = true; map.trusted = !map.pids.empty();
            result.pids = std::move(map); result.anchorEnd = end;
        }
    }
};

inline Reader memoryReader(const std::vector<uint8_t>& bytes) {
    return [&bytes](int64_t off, uint8_t* dst, size_t n) -> int64_t {
        if (off < 0 || (uint64_t)off > bytes.size()) return -1;
        n = std::min(n, bytes.size() - (size_t)off);
        if (n) std::memcpy(dst, bytes.data() + off, n);
        return (int64_t)n;
    };
}
} // namespace tspsi_detail

inline TsPsiMap tsScanStablePsi(const Reader& read, int64_t fileSize, int64_t scanBytes, const AbortFn* abort,
                                int64_t* scannedOut = nullptr, bool stopWhenComplete = false) try {
    TsPsiMap none;
    if (scannedOut) *scannedOut = 0;
    if (!read || fileSize <= 0 || scanBytes <= 0) return none;
    const TsGeometry g = tsGeometryAt(read, 0, fileSize);
    if (!g.valid()) return none;
    tspsi_detail::Walk walk(g);
    const int64_t end = std::min(fileSize, scanBytes);
    for (int64_t pos = 0; end - pos >= g.stride;) {
        if (aborted(abort)) return none;
        const size_t count = std::min<size_t>(1024, (size_t)((end - pos) / g.stride));
        auto b = readSpan(read, pos, count * (size_t)g.stride);
        if (b.size() != count * (size_t)g.stride) return none;
        if (scannedOut) *scannedOut = pos + (int64_t)b.size();
        for (size_t i = 0; i < count && !walk.bad; ++i)
            walk.packet(b.data() + i * (size_t)g.stride + (size_t)g.syncOffset, pos + (int64_t)i * g.stride);
        if (walk.bad) return none;
        pos += (int64_t)b.size();
        if (stopWhenComplete && walk.complete()) break;
    }
    return walk.complete() && !aborted(abort) ? walk.result : none;
} catch (const std::bad_alloc&) {
    return {};
}

using TsPsiNow = std::function<int64_t()>;
inline int64_t tsPsiNowUs() {
    return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct TsPsiTransaction {
    Reader read;
    AbortFn sourceCurrent, abort;
    TsPsiNow now;
    int64_t startUs = 0, bytes = 0;
    int64_t maxBytes = 4ll * 1024 * 1024, maxUs = 250000;
    bool failed = false;
    bool usable() {
        if (failed || (abort && abort()) || !sourceCurrent || !sourceCurrent() || now() - startUs >= maxUs) { failed = true; return false; }
        return true;
    }
    bool readExact(int64_t pos, uint8_t* dst, size_t n) {
        if (!usable() || pos < 0 || bytes > maxBytes || (uint64_t)n > (uint64_t)(maxBytes - bytes)) { failed = true; return false; }
        bytes += (int64_t)n; // charge before I/O, including failed/short reads
        if (read(pos, dst, n) != (int64_t)n || !usable()) { failed = true; return false; }
        return true;
    }
};

struct TsValidatedPlan {
    RecoveryPlan plan;
    std::vector<Patch> originals; // exact bytes from the fresh proof snapshot
    TsPsiMap map;
    int64_t provenFrom = -1, provenUntil = -1, earliestPts90k = -1;
    std::shared_ptr<TsPsiTransaction> transaction;
    // REQUIRED immediately before installation/reopen, not merely at planning.
    // Rechecks original fields, source revision, cancellation and the SAME budget.
    bool confirm() const try {
        if (plan.empty() || !transaction || !transaction->usable()) return false;
        for (const Patch& old : originals) {
            std::vector<uint8_t> b(old.bytes.size());
            if (!transaction->readExact(old.offset, b.data(), b.size()) || b != old.bytes) { transaction->failed = true; return false; }
        }
        return transaction->usable();
    } catch (const std::bad_alloc&) {
        if (transaction) transaction->failed = true;
        return false;
    }
};

// Only a nonempty unproven plan may invoke this. Caller clears lane carry on
// rejection AND on user seek. Remote callers retain the legacy subset and must
// not pass a cross-packet map without the approved local source view.
inline TsValidatedPlan tsRevalidateTsPlan(const Reader& read, int64_t fileSize, const AbortFn& sourceCurrent,
    const AbortFn& abort, const TsPsiMap& expected, const RecoveryPlan& unproven, TsRecoveryLane lane,
    int64_t scannedUntil, int audioPid, TsPsiSessionBudget& session, TsPsiNow now = tsPsiNowUs) try {
    TsValidatedPlan out;
    if (unproven.empty() || unproven.patches.empty() || !expected.valid() || !read || !sourceCurrent || !now || session.revalidations >= 8) return out;
    ++session.revalidations;
    auto tx = std::make_shared<TsPsiTransaction>();
    tx->read = read; tx->sourceCurrent = sourceCurrent; tx->abort = abort; tx->now = std::move(now); tx->startUs = tx->now();
    const TsGeometry g = expected.geometry;
    if ((g.stride != 188 && g.stride != 192 && g.stride != 204) || (g.syncOffset != (g.stride == 192 ? 4 : 0)) ||
        fileSize <= 0 || scannedUntil < 0 || scannedUntil > fileSize) return out;
    int64_t first = fileSize, last = -1;
    for (const Patch& p : unproven.patches) {
        if (p.offset < 0 || p.bytes.empty() || p.offset >= fileSize || (uint64_t)p.bytes.size() > (uint64_t)(fileSize - p.offset)) return out;
        first = std::min(first, p.offset); last = std::max(last, p.offset + (int64_t)p.bytes.size());
    }
    const int64_t targetPacket = first / g.stride * g.stride;
    // Never exceed the approved 256 KiB lookback by rounding down.
    const int64_t low = std::max<int64_t>(0, targetPacket - 256 * 1024);
    // Both round-ups are bounded by an already representable complete packet.
    const int64_t begin = low + (g.stride - low % g.stride) % g.stride;
    const int64_t fullEnd = fileSize / g.stride * g.stride;
    if (last > fullEnd) return out;
    const int64_t packetEnd = last + (g.stride - last % g.stride) % g.stride;
    const int64_t runEnd = std::max(scannedUntil / g.stride * g.stride, packetEnd);
    if (runEnd > fileSize || runEnd < begin) return out;
    const int64_t guard = lane == TsRecoveryLane::Pes ? 40ll * g.stride : 0;
    const int64_t end = std::min(fileSize / g.stride * g.stride, runEnd + std::min(guard, fileSize - runEnd));
    if (end <= begin || end - begin > tx->maxBytes) return out;
    std::vector<uint8_t> snapshot((size_t)(end - begin));
    for (size_t off = 0; off < snapshot.size();) {
        const size_t n = std::min<size_t>(64 * 1024, snapshot.size() - off);
        if (!tx->readExact(begin + (int64_t)off, snapshot.data() + off, n)) return out;
        off += n;
    }
    const Reader memory = tspsi_detail::memoryReader(snapshot);
    AbortFn stopped = [tx] { return !tx->usable(); };
    TsPsiMap actual = tsScanStablePsi(memory, (int64_t)snapshot.size(), (int64_t)snapshot.size(), &stopped);
    if (!actual.valid() || !(actual.identity == expected.identity) || actual.geometry.stride != g.stride || actual.geometry.syncOffset != g.syncOffset ||
        actual.pids.pids != expected.pids.pids || actual.pids.audioPids != expected.pids.audioPids) return out;
    actual.anchorBegin += begin; actual.anchorEnd += begin;
    if (actual.anchorEnd > targetPacket) return out; // complete evidence must precede candidate dependencies
    if (lane == TsRecoveryLane::Adts) {
        auto it = actual.pids.audioPids.find(audioPid);
        if (it == actual.pids.audioPids.end() || it->second != 0x0f) return out;
    }
    const int64_t base = actual.anchorBegin;
    bool escaped = false;
    // A rebased view lets legacy geometryAt(0) remain INSIDE this proof. The
    // actual remaining file size is retained so ADTS cannot mistake a cap for EOF.
    Reader bounded = [&](int64_t pos, uint8_t* dst, size_t n) -> int64_t {
        if (!tx->usable() || pos < 0 || pos > end - base || (uint64_t)n > (uint64_t)(end - base - pos)) { escaped = true; return -1; }
        return memory(base - begin + pos, dst, n);
    };
    const int64_t from = actual.anchorEnd - base, length = runEnd - actual.anchorEnd;
    if (length <= 0) return out;
    RecoveryPlan fresh;
    if (lane == TsRecoveryLane::Header) { TsHeaderScanState state; fresh = planTsTransportHeaders(bounded, fileSize - base, from, length, actual.pids, state, &stopped); }
    else if (lane == TsRecoveryLane::Adts) { TsAdtsScanState state; fresh = planTsAdtsFrames(bounded, fileSize - base, from, length, audioPid, state, &stopped); }
    else { TsPesScanState state; fresh = planTsPesHeaderLengths(bounded, fileSize - base, from, length, actual.pids, state, &stopped, &out.earliestPts90k); }
    if (escaped || fresh.empty() || !tx->usable()) return TsValidatedPlan{};
    for (Patch& p : fresh.patches) {
        if (p.offset < from || p.bytes.empty() || p.offset >= runEnd - base || (uint64_t)p.bytes.size() > (uint64_t)(runEnd - base - p.offset)) return TsValidatedPlan{};
        p.offset += base;
        const size_t at = (size_t)(p.offset - begin);
        out.originals.push_back({p.offset, std::vector<uint8_t>(snapshot.begin() + (long)at, snapshot.begin() + (long)(at + p.bytes.size()))});
    }
    if (fresh.damagedFrom >= 0) fresh.damagedFrom += base;
    if (fresh.damagedUntil >= 0) fresh.damagedUntil += base;
    out.plan = std::move(fresh); out.map = std::move(actual); out.provenFrom = begin; out.provenUntil = end; out.transaction = std::move(tx);
    return out;
} catch (const std::bad_alloc&) {
    return {};
}
} // namespace spresil
