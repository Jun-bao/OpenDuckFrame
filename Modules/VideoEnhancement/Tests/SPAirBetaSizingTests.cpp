#include "SPAirBetaSizing.hpp"
#include <cassert>
#include <cstdio>

using sp::airBetaSize;
using sp::AirBetaSizeFailure;

int main() {
    // The M3 Air reference envelope keeps its exact original mapping.
    {
        const auto r = airBetaSize(2648, 1668);
        assert(r.valid);
        assert(r.failure == AirBetaSizeFailure::none);
        assert(r.processingWidth == 1814);
        assert(r.processingHeight == 1142);
    }

    // A larger panel capture is scaled into the same model area budget
    // instead of being rejected as outside the envelope.
    {
        const auto r = airBetaSize(3420, 2148);
        assert(r.valid);
        assert(r.failure == AirBetaSizeFailure::none);
        assert(r.processingWidth > 0 && r.processingHeight > 0);
        assert((long long)r.processingWidth * r.processingHeight <= 1814LL * 1142);
        assert(r.paddedWidth <= 2048 && r.paddedHeight <= 1280);
    }

    // Every supported common capture shape stays inside the model limits.
    {
        const int shapes[][2] = {{3420, 1924}, {3420, 2148}, {3024, 1964}, {3840, 2160},
                                 {1920, 1080}, {1710, 962}, {2560, 1440}, {1280, 720}};
        for (const auto &shape : shapes) {
            const auto r = airBetaSize(shape[0], shape[1]);
            assert(r.valid);
            assert((long long)r.processingWidth * r.processingHeight <= 1814LL * 1142);
            assert(r.paddedWidth <= 2048 && r.paddedHeight <= 1280);
        }
    }

    // The envelope still rejects a capture larger than the supported maximum.
    {
        const auto r = airBetaSize(8192, 8192);
        assert(!r.valid);
        assert(r.failure == AirBetaSizeFailure::outsideEnvelope);
    }

    // Degenerate and odd captures are still rejected before scaling.
    {
        assert(airBetaSize(0, 100).failure == AirBetaSizeFailure::invalidCapture);
        assert(airBetaSize(100, 1).failure == AirBetaSizeFailure::invalidCapture);
        assert(airBetaSize(1919, 1000).failure == AirBetaSizeFailure::invalidCapture);
    }

    // An explicit narrower envelope is honoured for callers that need it.
    {
        const auto r = airBetaSize(3420, 2148, 2648, 1668);
        assert(!r.valid);
        assert(r.failure == AirBetaSizeFailure::outsideEnvelope);
    }

    std::printf("SPAirBetaSizingTests: OK\n");
    return 0;
}
