#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>

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

// All rectangles supplied to this contract use the same caller-selected,
// top-left coordinate convention. Screen conversions and capture metadata
// must be validated by the caller; no main-screen-height assumption is made.
struct GeometryRect { double x, y, width, height; };
struct GeometryPoint { double x, y; };
struct OutputGeometry {
    GeometryRect sourceCrop;
    GeometryRect image;
    uint64_t version;
    bool valid;
};
inline bool validRect(GeometryRect r) {
    return std::isfinite(r.x) && std::isfinite(r.y) && std::isfinite(r.width) &&
        std::isfinite(r.height) && r.width > 0 && r.height > 0;
}
// Convert within the explicitly selected display, whose AppKit screen frame
// is in bottom-left points. Returned coordinates are top-left drawable pixels
// local to that display; a caller must supply the actual drawable dimensions.
inline bool appKitScreenToDisplayPixels(GeometryRect displayPoints, GeometryPoint drawablePixels,
                                        GeometryPoint screen, GeometryPoint &pixel) {
    if (!validRect(displayPoints) || !std::isfinite(drawablePixels.x) || !std::isfinite(drawablePixels.y) ||
        drawablePixels.x <= 0 || drawablePixels.y <= 0 || !std::isfinite(screen.x) || !std::isfinite(screen.y)) return false;
    double x = (screen.x-displayPoints.x)/displayPoints.width;
    double y = (screen.y-displayPoints.y)/displayPoints.height;
    // A top-left half-open pixel rectangle includes its top, not its bottom.
    if (x < 0 || x >= 1 || y <= 0 || y > 1) return false;
    pixel = {x*drawablePixels.x, (1-y)*drawablePixels.y};
    return true;
}
inline bool displayPixelsToAppKitScreen(GeometryRect displayPoints, GeometryPoint drawablePixels,
                                        GeometryPoint pixel, GeometryPoint &screen) {
    if (!validRect(displayPoints) || !std::isfinite(drawablePixels.x) || !std::isfinite(drawablePixels.y) ||
        drawablePixels.x <= 0 || drawablePixels.y <= 0 || !std::isfinite(pixel.x) || !std::isfinite(pixel.y) ||
        pixel.x < 0 || pixel.x >= drawablePixels.x || pixel.y < 0 || pixel.y >= drawablePixels.y) return false;
    screen = {displayPoints.x + pixel.x*displayPoints.width/drawablePixels.x,
              displayPoints.y + (1-pixel.y/drawablePixels.y)*displayPoints.height};
    return true;
}
inline OutputGeometry outputGeometry(GeometryRect viewport, GeometryRect sourceCrop,
                                     bool fillContent, uint64_t version) {
    if (!version || !validRect(viewport) || !validRect(sourceCrop))
        return {sourceCrop, {}, version, false};
    const auto quad = outputQuad((float)viewport.width, (float)viewport.height,
                                 (float)sourceCrop.width, (float)sourceCrop.height, fillContent);
    const double width = viewport.width * quad.halfWidth, height = viewport.height * quad.halfHeight;
    return {sourceCrop, {viewport.x + (viewport.width-width)/2,
                         viewport.y + (viewport.height-height)/2, width, height}, version, true};
}
// Reject black bars and expired versions. Drag capture across bars is a
// future input-router concern and deliberately not implied by this helper.
inline bool outputToSource(const OutputGeometry &geometry, uint64_t version,
                           GeometryPoint output, GeometryPoint &source) {
    const auto &d = geometry.image; const auto &s = geometry.sourceCrop;
    if (!geometry.valid || geometry.version != version || !std::isfinite(output.x) || !std::isfinite(output.y) ||
        output.x < d.x || output.y < d.y || output.x >= d.x+d.width || output.y >= d.y+d.height) return false;
    source = {s.x + (output.x-d.x)*s.width/d.width, s.y + (output.y-d.y)*s.height/d.height};
    return true;
}
inline bool sourceToOutput(const OutputGeometry &geometry, uint64_t version,
                           GeometryPoint source, GeometryPoint &output) {
    const auto &s = geometry.sourceCrop; const auto &d = geometry.image;
    if (!geometry.valid || geometry.version != version || !std::isfinite(source.x) || !std::isfinite(source.y) ||
        source.x < s.x || source.y < s.y || source.x >= s.x+s.width || source.y >= s.y+s.height) return false;
    output = {d.x + (source.x-s.x)*d.width/s.width, d.y + (source.y-s.y)*d.height/s.height};
    return true;
}
}
