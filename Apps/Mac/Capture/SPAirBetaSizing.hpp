#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include "SPOutputGeometry.hpp"

namespace sp {
enum class AirBetaSizeFailure { none, invalidCapture, outsideEnvelope, invalidProcessing, paddingExceeded };
struct AirBetaSizeChoice {
    bool valid = false;
    int captureWidth = 0, captureHeight = 0;
    int processingWidth = 0, processingHeight = 0;
    int paddedWidth = 0, paddedHeight = 0;
    int areaCorrections = 0;
    double scale = 0;
    AirBetaSizeFailure failure = AirBetaSizeFailure::invalidCapture;
};

// The Air recipe's verified envelope was measured on the M3 Air panel
// (2648x1668). The adaptive downscale below already keeps every input inside
// the model's own limits, so the capture envelope follows the panel instead of
// one board's size: larger captures are scaled down to the same area budget
// instead of being rejected outright.
inline AirBetaSizeChoice airBetaSize(int width, int height, int envelopeWidth = 4096, int envelopeHeight = 2560) {
    AirBetaSizeChoice result;
    result.captureWidth = width; result.captureHeight = height;
    if (width < 2 || height < 2 || (width & 1) || (height & 1)) return result;
    if (width > envelopeWidth || height > envelopeHeight) {
        result.failure = AirBetaSizeFailure::outsideEnvelope;
        return result;
    }
    constexpr int64_t maximumArea = 1814LL * 1142;
    const double area = (double)width * (double)height;
    result.scale = std::min({1.0, std::sqrt((double)maximumArea / area), 2048.0 / width, 1280.0 / height});
    int processingWidth = 2 * (int)std::floor(width * result.scale / 2.0 + 0.5);
    int processingHeight = 2 * (int)std::floor(height * result.scale / 2.0 + 0.5);
    while ((int64_t)processingWidth * processingHeight > maximumArea && processingWidth >= 4 && processingHeight >= 4) {
        processingWidth -= 2; processingHeight -= 2; result.areaCorrections++;
    }
    if (processingWidth < 2 || processingHeight < 2 || (processingWidth & 1) || (processingHeight & 1) ||
        (int64_t)processingWidth * processingHeight > maximumArea) {
        result.failure = AirBetaSizeFailure::invalidProcessing;
        return result;
    }
    result.processingWidth = processingWidth; result.processingHeight = processingHeight;
    result.paddedWidth = ((processingWidth + 255) / 256) * 256;
    result.paddedHeight = ((processingHeight + 255) / 256) * 256;
    if (result.paddedWidth > 2048 || result.paddedHeight > 1280) {
        result.failure = AirBetaSizeFailure::paddingExceeded;
        return result;
    }
    result.valid = true; result.failure = AirBetaSizeFailure::none;
    return result;
}

inline OutputGeometry airBetaPresentationGeometry(GeometryRect viewport, int captureWidth, int captureHeight,
                                                  bool fillContent, uint64_t version = 1) {
    return outputGeometry(viewport, {0, 0, (double)captureWidth, (double)captureHeight}, fillContent, version);
}
}
