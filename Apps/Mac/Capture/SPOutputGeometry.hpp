#pragma once
#include <algorithm>

namespace sp {
struct OutputQuad { float halfWidth; float halfHeight; };
// Follow-window output maps the full processed image back to the same content
// rectangle. Other output modes preserve aspect ratio for viewing.
inline OutputQuad outputQuad(float viewportWidth, float viewportHeight,
                             float imageWidth, float imageHeight, bool fillContent) {
    if (fillContent) return {1.0f, 1.0f};
    float pane = viewportWidth / std::max(viewportHeight, 1.0f);
    float image = imageWidth / std::max(imageHeight, 1.0f);
    if (image > pane) return {1.0f, pane / image};
    return {image / pane, 1.0f};
}
}
