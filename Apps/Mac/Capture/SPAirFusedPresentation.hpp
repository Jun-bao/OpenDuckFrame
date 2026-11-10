#pragma once
#include "SPOutputGeometry.hpp"

namespace sp {
// Fused diagnostics keep source geometry independent of the synthetic buffer.
// Both originals and low-resolution synthetic images use the capture rectangle.
inline OutputGeometry airFusedPresentationGeometry(GeometryRect viewport,
                                                  int textureWidth, int textureHeight,
                                                  bool fillContent, bool fusedEnabled,
                                                  uint64_t version = 1) {
    const GeometryRect source = fusedEnabled
        ? GeometryRect{0, 0, 2648, 1668}
        : GeometryRect{0, 0, (double)textureWidth, (double)textureHeight};
    return outputGeometry(viewport, source, fillContent, version);
}
}
