#pragma once
#include "SPOutputGeometry.hpp"
#include <cmath>
#include <cstdint>

namespace sp {
inline bool sameRect(GeometryRect a, GeometryRect b) {
    return a.x==b.x && a.y==b.y && a.width==b.width && a.height==b.height;
}
struct GeometrySource {
    uint64_t generation=0, windowID=0, pid=0;
    int bufferWidth=0, bufferHeight=0;
    GeometryRect screenRect{}, contentRect{};
    double scaleFactor=0, contentScale=0;
};
// SCK contentRect is expressed in surface points; scaleFactor maps those
// points to surface pixels. This validates visual sampling only, not input routing.
inline bool validatedSurfaceCrop(const GeometrySource &s, uint64_t generation, int textureW, int textureH,
                                 GeometryRect &crop, GeometryRect &rawCrop) {
    if (s.generation != generation || !s.windowID || !s.pid || s.bufferWidth < 2 || s.bufferHeight < 2 ||
        textureW < 2 || textureH < 2 || !validRect(s.contentRect) || !validRect(s.screenRect) ||
        !std::isfinite(s.scaleFactor) || s.scaleFactor < 1 || s.scaleFactor > 4 ||
        !std::isfinite(s.contentScale) || s.contentScale <= 0) return false;
    auto r = s.contentRect;
    double x = r.x*s.scaleFactor, y = r.y*s.scaleFactor;
    double right = (r.x+r.width)*s.scaleFactor, bottom = (r.y+r.height)*s.scaleFactor;
    constexpr double tolerance = 2.0;
    if (x < -tolerance || y < -tolerance || right > s.bufferWidth+tolerance || bottom > s.bufferHeight+tolerance ||
        right-x < 2 || bottom-y < 2) return false;
    x=std::max(0.0,x); y=std::max(0.0,y); right=std::min((double)s.bufferWidth,right); bottom=std::min((double)s.bufferHeight,bottom);
    rawCrop={x,y,right-x,bottom-y};
    crop={x*textureW/s.bufferWidth,y*textureH/s.bufferHeight,(right-x)*textureW/s.bufferWidth,(bottom-y)*textureH/s.bufferHeight};
    return validRect(crop);
}

inline bool surfaceCropMatchesViewport(GeometryRect raw, double width, double height) {
    return validRect(raw) && width > 0 && height > 0 &&
        std::abs(raw.width*height - raw.height*width) <= std::max(2.0, raw.width*height*0.002);
}

enum class SurfaceCropState { validated, invalidMetadata, targetAspectMismatch };
inline OutputGeometry visualOutputGeometry(const GeometrySource *source, uint64_t generation,
                                           int textureW, int textureH, double viewportW, double viewportH,
                                           bool follow, SurfaceCropState &state) {
    GeometryRect crop{}, raw{};
    if (!source || !validatedSurfaceCrop(*source,generation,textureW,textureH,crop,raw)) {
        state=SurfaceCropState::invalidMetadata;
        return outputGeometry({0,0,viewportW,viewportH},{0,0,(double)textureW,(double)textureH},follow,1);
    }
    if (follow && !surfaceCropMatchesViewport(raw,viewportW,viewportH)) {
        state=SurfaceCropState::targetAspectMismatch;
        return outputGeometry({0,0,viewportW,viewportH},{0,0,(double)textureW,(double)textureH},true,1);
    }
    state=SurfaceCropState::validated;
    auto geometry=outputGeometry({0,0,viewportW,viewportH},raw,false,1);
    geometry.sourceCrop=crop;
    return geometry;
}

inline bool operator==(const GeometrySource &a, const GeometrySource &b) {
    return a.generation==b.generation && a.windowID==b.windowID && a.pid==b.pid &&
        a.bufferWidth==b.bufferWidth && a.bufferHeight==b.bufferHeight &&
        sameRect(a.screenRect,b.screenRect) && sameRect(a.contentRect,b.contentRect) &&
        a.scaleFactor==b.scaleFactor && a.contentScale==b.contentScale;
}
struct GeometryTarget {
    uint64_t generation=0, windowID=0, pid=0, config=0, epoch=0, displayID=0;
    GeometryRect screenRect{}, windowBounds{}, panelFrame{}, displayFrame{}, displayBoundsQuartz{};
    double backingScale=0;
    bool verified=false;
};
inline bool operator==(const GeometryTarget &a, const GeometryTarget &b) {
    return a.generation==b.generation && a.windowID==b.windowID && a.pid==b.pid &&
        a.config==b.config && a.epoch==b.epoch && a.displayID==b.displayID &&
        sameRect(a.screenRect,b.screenRect) && sameRect(a.windowBounds,b.windowBounds) && sameRect(a.panelFrame,b.panelFrame) &&
        sameRect(a.displayFrame,b.displayFrame) && sameRect(a.displayBoundsQuartz,b.displayBoundsQuartz) && a.backingScale==b.backingScale && a.verified==b.verified;
}
struct SharedGeometry {
    uint64_t version=0, generation=0, config=0, epoch=0, displayID=0, windowID=0, pid=0;
    uint64_t frameID=0; int64_t captureHost=0;
    GeometryRect sourceScreenRect{}, sourceContentRect{}, sourceWindowBounds{}, panelFrame{}, displayFrame{}, displayBoundsQuartz{};
    int sourceBufferWidth=0, sourceBufferHeight=0, drawableWidth=0, drawableHeight=0;
    double scaleFactor=0, contentScale=0;
    OutputGeometry render{}, input{};
    bool valid=false;
};
// Caller serializes access. Issued candidates become available only after the
// matching visible presented callback calls activate(); source/target changes
// revoke both pending and active tickets immediately.
class SharedGeometryAuthority {
    GeometrySource source_{}; GeometryTarget target_{};
    bool haveSource_=false, haveTarget_=false;
    uint64_t serial_=0, pendingVersion_=0, activeVersion_=0;
    SharedGeometry pending_{}, active_{};
    void revoke() { ++serial_; pendingVersion_=activeVersion_=0; pending_={}; active_={}; }
    static bool nearly(double a, double b, double absolute, double relative) {
        return std::isfinite(a) && std::isfinite(b) && std::abs(a-b)<=std::max(absolute,relative*std::max(std::abs(a),std::abs(b)));
    }
public:
    void invalidate() { haveSource_=haveTarget_=false; revoke(); }
    void observeSource(const GeometrySource &s, bool valid) {
        if (!valid) { if (haveSource_ || activeVersion_ || pendingVersion_) revoke(); haveSource_=false; return; }
        if (!haveSource_ || !(source_==s)) { revoke(); source_=s; haveSource_=true; }
    }
    void observeTarget(const GeometryTarget &t, bool valid) {
        if (!valid) { if (haveTarget_ || activeVersion_ || pendingVersion_) revoke(); haveTarget_=false; return; }
        if (!haveTarget_ || !(target_==t)) { revoke(); target_=t; haveTarget_=true; }
    }
    SharedGeometry candidate(const GeometrySource &frame, uint64_t generation, uint64_t config, uint64_t epoch,
                             uint64_t displayID, int drawableWidth, int drawableHeight,
                             int textureWidth, int textureHeight, bool fill) {
        if (!haveSource_ || !haveTarget_ || !(frame==source_) || generation!=source_.generation ||
            generation!=target_.generation || config!=target_.config || epoch!=target_.epoch) return {};
        if (!target_.verified ||
            target_.windowID!=source_.windowID || target_.pid!=source_.pid || displayID!=target_.displayID || !displayID ||
            !source_.pid || !source_.windowID || source_.bufferWidth<=0 || source_.bufferHeight<=0 ||
            drawableWidth<=0 || drawableHeight<=0 || textureWidth<=0 || textureHeight<=0 ||
            !validRect(source_.screenRect) || !validRect(source_.contentRect) || !validRect(target_.windowBounds) || !validRect(target_.panelFrame) || !validRect(target_.displayFrame) || !validRect(target_.displayBoundsQuartz) ||
            !sameRect(source_.screenRect,target_.screenRect) || !std::isfinite(source_.scaleFactor) || source_.scaleFactor<1 || source_.scaleFactor>4 ||
            !std::isfinite(source_.contentScale) || source_.contentScale<=0 || !std::isfinite(target_.backingScale) || target_.backingScale<=0 ||
            !nearly(target_.panelFrame.width*target_.backingScale,drawableWidth,2,.002) ||
            !nearly(target_.panelFrame.height*target_.backingScale,drawableHeight,2,.002) ||
            target_.panelFrame.x < target_.displayFrame.x-.01 || target_.panelFrame.y < target_.displayFrame.y-.01 ||
            target_.panelFrame.x+target_.panelFrame.width > target_.displayFrame.x+target_.displayFrame.width+.01 ||
            target_.panelFrame.y+target_.panelFrame.height > target_.displayFrame.y+target_.displayFrame.height+.01 ||
            source_.screenRect.x < target_.windowBounds.x-4 || source_.screenRect.y < target_.windowBounds.y-4 ||
            source_.screenRect.x+source_.screenRect.width > target_.windowBounds.x+target_.windowBounds.width+4 ||
            source_.screenRect.y+source_.screenRect.height > target_.windowBounds.y+target_.windowBounds.height+4) { revoke(); return {}; }
        // Until a crop/coordinate convention is independently validated, only
        // full-buffer content is routable. Never assume titlebar dimensions.
        if (!nearly(source_.contentRect.x,0,.01,0) || !nearly(source_.contentRect.y,0,.01,0) ||
            !nearly(source_.contentRect.width*source_.scaleFactor,source_.bufferWidth,2,.002) ||
            !nearly(source_.contentRect.height*source_.scaleFactor,source_.bufferHeight,2,.002) ||
            !nearly(source_.screenRect.width*source_.contentScale,source_.contentRect.width,2,.002) ||
            !nearly(source_.screenRect.height*source_.contentScale,source_.contentRect.height,2,.002) ||
            !nearly((double)textureWidth*source_.bufferHeight,(double)textureHeight*source_.bufferWidth,2,.002)) { revoke(); return {}; }
        auto geom=outputGeometry({0,0,(double)drawableWidth,(double)drawableHeight},
                                 {0,0,(double)textureWidth,(double)textureHeight},fill,1);
        if (!geom.valid) return {};
        bool same=pendingVersion_ && pending_.generation==generation && pending_.config==config && pending_.epoch==epoch &&
            pending_.displayID==displayID && pending_.drawableWidth==drawableWidth && pending_.drawableHeight==drawableHeight &&
            sameRect(pending_.render.image,geom.image);
        if (!same) {
            revoke(); pendingVersion_=++serial_;
            pending_.version=pendingVersion_; pending_.generation=generation; pending_.config=config; pending_.epoch=epoch;
            pending_.windowID=source_.windowID; pending_.pid=source_.pid; pending_.displayID=displayID;
            pending_.sourceScreenRect=source_.screenRect; pending_.sourceContentRect=source_.contentRect;
            pending_.sourceWindowBounds=target_.windowBounds;
            pending_.sourceBufferWidth=source_.bufferWidth; pending_.sourceBufferHeight=source_.bufferHeight;
            pending_.scaleFactor=source_.scaleFactor; pending_.contentScale=source_.contentScale;
            pending_.panelFrame=target_.panelFrame; pending_.displayFrame=target_.displayFrame;
            pending_.displayBoundsQuartz=target_.displayBoundsQuartz;
            pending_.drawableWidth=drawableWidth; pending_.drawableHeight=drawableHeight;
            pending_.render=geom; pending_.render.version=pendingVersion_;
            pending_.input={source_.screenRect,geom.image,pendingVersion_,true}; pending_.valid=true;
        }
        return pending_;
    }
    bool activate(uint64_t version, uint64_t frameID=0, int64_t captureHost=0) {
        if (!version || version!=pendingVersion_ || !pending_.valid) return false;
        active_=pending_; active_.frameID=frameID; active_.captureHost=captureHost; activeVersion_=version; return true;
    }
    SharedGeometry active() const { return activeVersion_ ? active_ : SharedGeometry{}; }
};

// Event locations use Quartz global points; the immutable snapshot also has
// AppKit screen and panel frames, so no main-display Y-flip is guessed.
inline bool mapQuartzOutputToSource(const SharedGeometry &g, uint64_t version,
                                    GeometryPoint quartz, bool clamp, GeometryPoint &source) {
    if (!g.valid || version != g.version || !validRect(g.displayBoundsQuartz) || !validRect(g.displayFrame) ||
        !validRect(g.panelFrame) || !std::isfinite(quartz.x) || !std::isfinite(quartz.y)) return false;
    const auto &q=g.displayBoundsQuartz, &d=g.displayFrame, &p=g.panelFrame;
    double appX=d.x+(quartz.x-q.x)*d.width/q.width;
    double appY=d.y+d.height-(quartz.y-q.y)*d.height/q.height;
    GeometryPoint pixel{(appX-p.x)*g.drawableWidth/p.width, (p.y+p.height-appY)*g.drawableHeight/p.height};
    const auto &image=g.input.image;
    if (clamp && validRect(image)) {
        pixel.x=std::clamp(pixel.x,image.x,std::nextafter(image.x+image.width,image.x));
        pixel.y=std::clamp(pixel.y,image.y,std::nextafter(image.y+image.height,image.y));
    }
    return outputToSource(g.input,version,pixel,source);
}
}
