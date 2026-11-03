#pragma once
#include <cstdint>
namespace sp {
struct PresentationGeometrySample {
    int sourceWidth = 0, sourceHeight = 0, processingWidth = 0, processingHeight = 0;
    int bufferWidth = 0, bufferHeight = 0, drawableWidth = 0, drawableHeight = 0;
    int64_t presentedTimeNs = 0;
    bool valid = false;
};
class PresentationGeometry {
    PresentationGeometrySample samples_[2];
public:
    void reset() { samples_[0] = {}; samples_[1] = {}; }
    void record(bool output, PresentationGeometrySample s) {
        if (s.presentedTimeNs <= 0 || s.sourceWidth <= 0 || s.sourceHeight <= 0 ||
            s.processingWidth <= 0 || s.processingHeight <= 0 || s.bufferWidth <= 0 ||
            s.bufferHeight <= 0 || s.drawableWidth <= 0 || s.drawableHeight <= 0) return;
        auto &old = samples_[output ? 1 : 0];
        if (s.presentedTimeNs < old.presentedTimeNs) return;
        if (s.presentedTimeNs == old.presentedTimeNs) {
            if (old.sourceWidth != s.sourceWidth || old.sourceHeight != s.sourceHeight || old.processingWidth != s.processingWidth ||
                old.processingHeight != s.processingHeight || old.bufferWidth != s.bufferWidth || old.bufferHeight != s.bufferHeight ||
                old.drawableWidth != s.drawableWidth || old.drawableHeight != s.drawableHeight) old.valid = false;
            return;
        }
        s.valid = true; old = s;
    }
    PresentationGeometrySample get(bool output) const { return samples_[output ? 1 : 0]; }
};
}
