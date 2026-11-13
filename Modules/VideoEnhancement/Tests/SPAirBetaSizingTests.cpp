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
        assert((long long)r.processingWidth * r.processingHeight <= 1920LL * 1080);
        assert(r.paddedWidth <= 2048 && r.paddedHeight <= 1280);
    }

    // Every supported common capture shape stays inside the model limits.
    {
        const int shapes[][2] = {{3420, 1924}, {3420, 2148}, {3024, 1964}, {3840, 2160},
                                 {1920, 1080}, {1710, 962}, {2560, 1440}, {1280, 720},
                                 {2148, 3420}, {2160, 3840}, {4096, 4096}, {16384, 1024}};
        for (const auto &shape : shapes) {
            const auto r = airBetaSize(shape[0], shape[1]);
            assert(r.valid);
            assert((long long)r.processingWidth * r.processingHeight <= 1920LL * 1080);
            assert(r.paddedWidth <= 2048 && r.paddedHeight <= 1280);
        }
    }

    // The envelope still rejects a capture larger than the supported maximum.
    {
        const auto r = airBetaSize(8192, 8192);
        assert(!r.valid);
        assert(r.failure == AirBetaSizeFailure::outsideEnvelope);
    }

    // Bounds include exact byte limits and both orientations, without overflow.
    assert(airBetaSize(1920, 1080, 1920ULL * 1080 * 4).valid);
    assert(!airBetaSize(1920, 1080, 1920ULL * 1080 * 4 - 1).valid);
    assert(!airBetaSize(16386, 2).valid);
    assert(!airBetaSize(2147483646, 2147483646).valid);
    assert(!airBetaSize(1920, 1080, 0).valid);

    // Degenerate and odd captures are still rejected before scaling.
    {
        assert(airBetaSize(0, 100).failure == AirBetaSizeFailure::invalidCapture);
        assert(airBetaSize(100, 1).failure == AirBetaSizeFailure::invalidCapture);
        assert(airBetaSize(1919, 1000).failure == AirBetaSizeFailure::invalidCapture);
    }

    // An explicit smaller memory budget is honoured for callers that need it.
    {
        const auto r = airBetaSize(3420, 2148, 16ULL * 1024 * 1024);
        assert(!r.valid);
        assert(r.failure == AirBetaSizeFailure::outsideEnvelope);
    }

    std::printf("SPAirBetaSizingTests: OK\n");
    return 0;
}
