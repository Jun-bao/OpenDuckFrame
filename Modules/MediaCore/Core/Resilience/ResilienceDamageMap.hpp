// OpenDuckFrame - resilient playback: damage map (per-track spans with class and confidence, merged main band)
//
// Split out of the umbrella header by section; function bodies, constants and inline
// attributes are unchanged. Callers keep including the umbrella; this file only guarantees
// that it compiles on its own.
#pragma once

#include "ResilienceBitstream.hpp"

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

enum class DamageClass : uint8_t { Unknown = 0, Fluent = 1, Partial = 2, None = 3 };
enum class Confidence : uint8_t { Indexed = 0, ScanValidated = 1, DecodeVerified = 2 };
enum class Track : uint8_t { Video = 0, Audio = 1 };

struct DamageSpan {
    Track track;
    DamageClass cls;
    Confidence conf;
    int64_t fromUs;
    int64_t untilUs;
};

inline int precedence(DamageClass c) {
    switch (c) {
    case DamageClass::None: return 3;
    case DamageClass::Partial: return 2;
    case DamageClass::Fluent: return 1;
    case DamageClass::Unknown: return 0;
    }
    return 0;
}

class DamageMap {
public:
    void clear() { spans_.clear(); }
    bool empty() const { return spans_.empty(); }
    const std::vector<DamageSpan>& spans() const { return spans_; }

    void clearTrack(Track track) {
        spans_.erase(std::remove_if(spans_.begin(), spans_.end(), [track](const DamageSpan& s) { return s.track == track; }), spans_.end());
    }

    void note(Track track, DamageClass cls, Confidence conf, int64_t fromUs, int64_t untilUs) {
        if (untilUs <= fromUs || cls == DamageClass::Unknown) return;
        std::vector<DamageSpan> out;
        out.reserve(spans_.size() + 3);

        std::vector<std::pair<int64_t, int64_t>> keep{{fromUs, untilUs}};
        for (const DamageSpan& s : spans_) {
            if (s.track != track || s.untilUs <= fromUs || s.fromUs >= untilUs) { out.push_back(s); continue; }
            if (precedence(s.cls) > precedence(cls)) {

                out.push_back(s);
                std::vector<std::pair<int64_t, int64_t>> next;
                for (auto& k : keep) {
                    if (k.second <= s.fromUs || k.first >= s.untilUs) { next.push_back(k); continue; }
                    if (k.first < s.fromUs) next.push_back({k.first, s.fromUs});
                    if (k.second > s.untilUs) next.push_back({s.untilUs, k.second});
                }
                keep.swap(next);
            } else {

                if (s.fromUs < fromUs) out.push_back({s.track, s.cls, s.conf, s.fromUs, fromUs});
                if (s.untilUs > untilUs) out.push_back({s.track, s.cls, s.conf, untilUs, s.untilUs});
            }
        }
        for (auto& k : keep) out.push_back({track, cls, conf, k.first, k.second});
        std::sort(out.begin(), out.end(), [](const DamageSpan& a, const DamageSpan& b) {
            if (a.track != b.track) return a.track < b.track;
            return a.fromUs < b.fromUs;
        });

        spans_.clear();
        for (const DamageSpan& s : out) {
            if (!spans_.empty()) {
                DamageSpan& last = spans_.back();
                if (last.track == s.track && last.cls == s.cls && last.untilUs >= s.fromUs) {
                    last.untilUs = std::max(last.untilUs, s.untilUs);
                    last.conf = std::max(last.conf, s.conf);
                    continue;
                }
            }
            spans_.push_back(s);
        }
    }

    DamageClass classAt(Track track, int64_t us) const {
        auto it = std::upper_bound(spans_.begin(), spans_.end(), std::make_pair(track, us),
                                   [](const std::pair<Track, int64_t>& k, const DamageSpan& s) {
                                       return k.first != s.track ? k.first < s.track : k.second < s.fromUs;
                                   });
        if (it == spans_.begin()) return DamageClass::Unknown;
        --it;
        return it->track == track && us < it->untilUs ? it->cls : DamageClass::Unknown;
    }

    struct MainSpan { DamageClass cls; int64_t fromUs; int64_t untilUs; };

    std::vector<MainSpan> composeMain(bool videoSelected, bool audioSelected) const {
        std::vector<int64_t> cuts;
        for (const DamageSpan& s : spans_) {
            if ((s.track == Track::Video && videoSelected) || (s.track == Track::Audio && audioSelected)) {
                cuts.push_back(s.fromUs);
                cuts.push_back(s.untilUs);
            }
        }
        std::sort(cuts.begin(), cuts.end());
        cuts.erase(std::unique(cuts.begin(), cuts.end()), cuts.end());
        std::vector<MainSpan> out;
        for (size_t i = 0; i + 1 < cuts.size(); ++i) {
            const int64_t a = cuts[i], b = cuts[i + 1];
            const int64_t mid = a + (b - a) / 2;
            const DamageClass v = videoSelected ? classAt(Track::Video, mid) : DamageClass::Unknown;
            const DamageClass au = audioSelected ? classAt(Track::Audio, mid) : DamageClass::Unknown;
            DamageClass cls = DamageClass::Unknown;
            const int selected = (videoSelected ? 1 : 0) + (audioSelected ? 1 : 0);
            const int nones = (v == DamageClass::None ? 1 : 0) + (au == DamageClass::None ? 1 : 0);
            const int fluents = (v == DamageClass::Fluent ? 1 : 0) + (au == DamageClass::Fluent ? 1 : 0);
            const bool anyDamage = v == DamageClass::Partial || au == DamageClass::Partial || nones > 0;
            if (selected > 0 && nones == selected) cls = DamageClass::None;
            else if (anyDamage) cls = DamageClass::Partial;
            else if (selected > 0 && fluents == selected) cls = DamageClass::Fluent;
            if (cls == DamageClass::Unknown) continue;
            if (!out.empty() && out.back().cls == cls && out.back().untilUs == a) out.back().untilUs = b;
            else out.push_back({cls, a, b});
        }
        return out;
    }

    static int64_t snapTarget(const std::vector<MainSpan>& main, int64_t targetUs, bool forward,
                              int64_t durationUs) {
        for (const MainSpan& m : main) {
            if (m.cls != DamageClass::None || targetUs < m.fromUs || targetUs >= m.untilUs) continue;
            if (forward) return m.untilUs < durationUs ? m.untilUs : -1;
            return m.fromUs > 0 ? m.fromUs : -1;
        }
        return targetUs;
    }

private:
    std::vector<DamageSpan> spans_;
};

} // namespace spresil
