#include "SPSharedGeometry.hpp"
#include <cassert>
#include <cstdio>
int main() {
    sp::SharedGeometryAuthority a;
    sp::GeometrySource s{3,101,77,1280,960,{100,200,640,480},{0,0,640,480},2,1};
    sp::GeometryTarget t; t.generation=3;t.windowID=101;t.pid=77;t.config=4;t.epoch=5;t.displayID=8;
    t.screenRect=s.screenRect;t.windowBounds={100,168,640,512};t.panelFrame={-640,0,640,480};t.displayFrame={-1920,0,1920,1080};t.displayBoundsQuartz={-1920,0,1920,1080};t.backingScale=2;t.verified=true;
    auto make=[&](sp::GeometrySource frame){return a.candidate(frame,3,4,5,8,1280,960,1280,960,false);};
    assert(!make(s).valid); a.observeSource(s,true); a.observeTarget(t,true);
    auto first=make(s); assert(first.valid && first.version && !a.active().valid); assert(a.activate(first.version));
    sp::GeometryPoint p{}; assert(sp::outputToSource(a.active().input,first.version,{640,480},p));
    assert(std::abs(p.x-420)<.001 && std::abs(p.y-440)<.001);
    assert(sp::mapQuartzOutputToSource(a.active(),first.version,{-320,840},false,p));
    assert(std::abs(p.x-420)<.001 && std::abs(p.y-440)<.001);
    assert(!sp::mapQuartzOutputToSource(a.active(),first.version,{-900,840},false,p));
    assert(sp::mapQuartzOutputToSource(a.active(),first.version,{-900,840},true,p) && std::abs(p.x-100)<.001);
    auto again=make(s); assert(again.version==first.version);
    assert(!a.candidate(s,3,99,5,8,1280,960,1280,960,false).valid && a.active().version==first.version);
    auto changedConfig=t;changedConfig.config=6; a.observeTarget(changedConfig,true); assert(!a.active().valid && !a.activate(first.version));
    assert(!make(s).valid); a.observeTarget(t,true); auto restored=make(s); assert(restored.valid && a.activate(restored.version));
    auto wrongGeneration=s;wrongGeneration.generation=2; assert(!make(wrongGeneration).valid && a.active().valid);
    auto moved=s;moved.screenRect.x+=10; a.observeSource(moved,true); assert(!a.active().valid); assert(!a.activate(first.version));
    assert(!make(s).valid); assert(!make(moved).valid);
    auto movedTarget=t;movedTarget.screenRect=moved.screenRect;movedTarget.windowBounds.x+=10; a.observeTarget(movedTarget,true);
    auto second=make(moved); assert(second.valid && second.version!=first.version); assert(a.activate(second.version));
    auto invalid=moved; invalid.contentRect.x=3; a.observeSource(invalid,true); a.observeTarget(movedTarget,true);
    assert(!make(invalid).valid && !a.active().valid);
    a.observeSource(moved,true); a.observeTarget(movedTarget,true);
    auto third=make(moved); assert(third.valid && a.activate(third.version));
    auto spanning=movedTarget;spanning.panelFrame.x=-100; a.observeTarget(spanning,true);assert(!make(moved).valid && !a.active().valid);
    a.observeTarget(movedTarget,true); third=make(moved); assert(third.valid && a.activate(third.version));
    auto resized=moved;resized.bufferWidth=640; a.observeSource(resized,true);assert(!a.active().valid && !make(resized).valid);
    a.observeSource(moved,true); a.observeTarget(movedTarget,true); third=make(moved);assert(third.valid && a.activate(third.version));
    assert(!a.candidate(moved,3,4,5,9,1280,960,1280,960,false).valid && !a.active().valid);
    a.observeTarget(t,false); assert(!a.active().valid); a.invalidate();
    sp::SharedGeometryAuthority full;
    sp::GeometrySource fs{9,303,404,640,512,{960,255,640,512},{0,0,640,512},1,1};
    sp::GeometryTarget ft;ft.generation=9;ft.windowID=303;ft.pid=404;ft.config=2;ft.epoch=3;ft.displayID=1;
    ft.screenRect=fs.screenRect;ft.windowBounds=fs.screenRect;ft.panelFrame={0,0,2560,1440};ft.displayFrame=ft.panelFrame;
    ft.displayBoundsQuartz=ft.panelFrame;ft.backingScale=1;ft.verified=true;full.observeSource(fs,true);full.observeTarget(ft,true);
    auto fg=full.candidate(fs,9,2,3,1,2560,1440,640,512,false);assert(fg.valid && full.activate(fg.version));
    assert(std::abs(fg.input.image.x-380)<.01 && !sp::mapQuartzOutputToSource(full.active(),fg.version,{100,300},false,p));
    // x=500 is inside the enlarged image but outside the original window.
    assert(sp::mapQuartzOutputToSource(full.active(),fg.version,{500,300},false,p) &&
           p.x>=960 && p.x<1600 && p.y>=255 && p.y<767);
    std::puts("shared geometry: only matching visible activation, stale version rejection, move, crop, display and invalidation pass");
}
