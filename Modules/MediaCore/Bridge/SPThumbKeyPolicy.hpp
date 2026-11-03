#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

namespace spthumb {

inline bool spThumbIndexTrustworthy(const char *formatName) {
    if (!formatName) return true;
    static const char *const kUntrusted[] = {
        "mpegts", "mpegtsraw", "mpeg", "mpegvideo", "h264", "hevc", "vc1", "m4v",
    };
    for (const char *n : kUntrusted) {
        if (std::strcmp(formatName, n) == 0) return false;
    }
    return true;
}

inline int64_t spThumbIndexPtsOffsetUs(const std::vector<int64_t> &idxAbsUs,
                                       int64_t decodedKeyAbsUs) {
    auto it = std::upper_bound(idxAbsUs.begin(), idxAbsUs.end(), decodedKeyAbsUs);
    if (it == idxAbsUs.begin()) return 0;
    const int64_t d = decodedKeyAbsUs - *std::prev(it);
    return d > 0 ? d : 0;
}

inline int64_t spThumbMapTargetToIndexKeyAbsUs(const std::vector<int64_t> &idxAbsUs,
                                               int64_t targetAbsUs,
                                               int64_t ptsOffsetUs) {
    if (idxAbsUs.empty()) return INT64_MIN;
    auto it = std::upper_bound(idxAbsUs.begin(), idxAbsUs.end(),
                               targetAbsUs - ptsOffsetUs);
    const int64_t k = it == idxAbsUs.begin() ? idxAbsUs.front() : *std::prev(it);
    return k + ptsOffsetUs;
}

inline bool spThumbIndexKeyAliasesDecoded(int64_t mappedKeyUs, int64_t decodedKeyUs) {
    const int64_t d = mappedKeyUs - decodedKeyUs;
    return d >= -1000 && d <= 1000;
}

inline int64_t spThumbMaxNeighborDistUs(int64_t durationUs) {
    if (durationUs <= 0) return INT64_MAX;
    return std::max<int64_t>(10 * 1000000LL, durationUs / 20);
}

inline bool spThumbPreviewWithinReach(int64_t tUs, int64_t keyUs, int64_t durationUs,
                                      bool covered) {
    if (covered) return true;
    const int64_t maxDist = spThumbMaxNeighborDistUs(durationUs);
    const int64_t dist = tUs >= keyUs ? tUs - keyUs : keyUs - tUs;
    return dist <= maxDist;
}

inline bool spThumbCoverageContains(int64_t fromUs, int64_t untilUs, int64_t tUs) {
    return tUs >= fromUs - 1 && tUs <= untilUs + 1;
}

struct SPThumbFailNote {
    int64_t fromAbsUs;
    int64_t untilAbsUs;
    int64_t wallUs;
};
inline int64_t spThumbFailNoteTtlUs() { return 10 * 1000000LL; }
inline size_t spThumbFailNoteCap() { return 16; }

inline int64_t spThumbFailNoteHalfSpanUs(int64_t gopUs) {
    return gopUs > 0 ? gopUs : 2500000;
}
inline bool spThumbFailSuppressed(const std::vector<SPThumbFailNote> &notes,
                                  int64_t targetAbsUs, int64_t nowWallUs) {
    for (const auto &n : notes) {
        if (nowWallUs - n.wallUs > spThumbFailNoteTtlUs()) continue;
        if (targetAbsUs >= n.fromAbsUs && targetAbsUs <= n.untilAbsUs) return true;
    }
    return false;
}

inline void spThumbFailNoteAdd(std::vector<SPThumbFailNote> &notes, int64_t targetAbsUs,
                               int64_t gopUs, int64_t nowWallUs) {
    const int64_t half = spThumbFailNoteHalfSpanUs(gopUs);
    if (notes.size() >= spThumbFailNoteCap()) notes.erase(notes.begin());
    notes.push_back({targetAbsUs - half, targetAbsUs + half, nowWallUs});
}

struct SPThumbKeySpan {
    int64_t fromDtsUs;
    int64_t untilDtsUs;
    bool fromHead;
    bool untilEof;
};
struct SPThumbKeyHit {
    bool known = false;
    int64_t ptsAbsUs = INT64_MIN;
    int64_t pos = -1;
};
class SPThumbKeyMap {
public:

    static constexpr size_t kMaxKeys = 65536;
    static constexpr size_t kMaxSpans = 512;

    static constexpr int64_t kReorderSlopUs = 100000;

    void noteReorder(int64_t ptsMinusDtsUs) {
        if (ptsMinusDtsUs > reorderMaxUs_) reorderMaxUs_ = ptsMinusDtsUs;
    }
    void noteKey(int64_t ptsAbsUs, int64_t pos) {
        if (pos < 0 || saturated_) return;
        auto it = std::lower_bound(keys_.begin(), keys_.end(), ptsAbsUs,
                                   [](const Key &k, int64_t v) { return k.ptsAbsUs < v; });
        if (it != keys_.end() && it->ptsAbsUs == ptsAbsUs) { it->pos = pos; return; }
        if (keys_.size() >= kMaxKeys) {

            saturated_ = true;
            spans_.clear();
            return;
        }
        keys_.insert(it, Key{ptsAbsUs, pos});
    }

    void noteSpan(int64_t fromDtsUs, int64_t untilDtsUs, bool fromHead, bool untilEof) {
        if (saturated_ || untilDtsUs < fromDtsUs) return;
        SPThumbKeySpan s{fromDtsUs, untilDtsUs, fromHead, untilEof};
        for (;;) {
            bool merged = false;
            for (size_t i = 0; i < spans_.size(); ++i) {
                const SPThumbKeySpan &o = spans_[i];
                const int64_t oFrom = o.fromHead ? INT64_MIN : o.fromDtsUs;
                const int64_t oUntil = o.untilEof ? INT64_MAX : o.untilDtsUs;
                const int64_t sFrom = s.fromHead ? INT64_MIN : s.fromDtsUs;
                const int64_t sUntil = s.untilEof ? INT64_MAX : s.untilDtsUs;
                if (sFrom > oUntil || oFrom > sUntil) continue;
                s.fromHead = s.fromHead || o.fromHead;
                s.untilEof = s.untilEof || o.untilEof;
                s.fromDtsUs = std::min(s.fromDtsUs, o.fromDtsUs);
                s.untilDtsUs = std::max(s.untilDtsUs, o.untilDtsUs);
                spans_.erase(spans_.begin() + (long)i);
                merged = true;
                break;
            }
            if (!merged) break;
        }
        if (spans_.size() >= kMaxSpans) spans_.erase(spans_.begin());
        spans_.push_back(s);
    }
    SPThumbKeyHit resolve(int64_t targetAbsUs) const {
        SPThumbKeyHit hit;
        const int64_t margin = reorderMaxUs_ + kReorderSlopUs;
        for (const SPThumbKeySpan &sp : spans_) {
            const int64_t from = sp.fromHead ? INT64_MIN : sp.fromDtsUs + margin;
            const int64_t until = sp.untilEof ? INT64_MAX : sp.untilDtsUs;
            if (targetAbsUs < from || targetAbsUs > until) continue;
            auto it = std::upper_bound(keys_.begin(), keys_.end(), targetAbsUs,
                                       [](int64_t v, const Key &k) { return v < k.ptsAbsUs; });
            if (it == keys_.begin()) {

                if (!sp.fromHead || keys_.empty()) return hit;
                hit.known = true;
                hit.ptsAbsUs = keys_.front().ptsAbsUs;
                hit.pos = keys_.front().pos;
                return hit;
            }
            --it;
            if (it->ptsAbsUs < from) return hit;
            hit.known = true;
            hit.ptsAbsUs = it->ptsAbsUs;
            hit.pos = it->pos;
            return hit;
        }
        return hit;
    }
    size_t keyCount() const { return keys_.size(); }
    size_t spanCount() const { return spans_.size(); }
    int64_t reorderMaxUs() const { return reorderMaxUs_; }
    bool saturated() const { return saturated_; }

private:
    struct Key { int64_t ptsAbsUs; int64_t pos; };
    std::vector<Key> keys_;
    std::vector<SPThumbKeySpan> spans_;
    int64_t reorderMaxUs_ = 0;
    bool saturated_ = false;
};

inline int64_t spThumbCoverageTargetUs(bool scanComplete, int64_t keyUs, int64_t targetUs) {
    return scanComplete ? std::max(keyUs, targetUs) : keyUs;
}

inline bool spThumbReadBudgetExhausted(int64_t videoPkts, int64_t bytes) {
    return videoPkts >= 96 || bytes >= 16LL * 1024 * 1024;
}

} // namespace spthumb
