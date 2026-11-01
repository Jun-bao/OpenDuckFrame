#include "SPOutputGeometry.hpp"
#include <cmath>
#include <cstdio>
int main() {
    auto follow=sp::outputQuad(2560,1410,1920,1080,true);
    auto view=sp::outputQuad(2560,1410,1920,1080,false);
    bool corners=true;
    for (float x : {-1.0f,1.0f}) for (float y : {-1.0f,1.0f}) {
        // Source and scaled texture use the same normalized corner, which
        // must land at the target content rectangle's corresponding corner.
        float drawnX=(x*follow.halfWidth+1)*1280.0f;
        float drawnY=(y*follow.halfHeight+1)*705.0f;
        float expectedX=(x+1)*1280.0f, expectedY=(y+1)*705.0f;
        corners=corners && std::abs(drawnX-expectedX)<0.001 && std::abs(drawnY-expectedY)<0.001;
    }
    bool fit=view.halfWidth<1 && std::abs(view.halfHeight-1)<0.00001;
    // A negative-origin display and a cropped source; points or pixels work
    // only when each rectangle is converted consistently by the caller.
    auto g=sp::outputGeometry({-1920,0,1920,1080},{120,40,800,800},false,17);
    sp::GeometryPoint s{}, out{};
    bool bars=!sp::outputToSource(g,17,{-1900,500},s);
    bool mapped=sp::outputToSource(g,17,{-960,540},s) && std::abs(s.x-520)<0.001 && std::abs(s.y-440)<0.001;
    bool roundtrip=mapped && sp::sourceToOutput(g,17,s,out) && std::abs(out.x+960)<0.001 && std::abs(out.y-540)<0.001;
    bool stale=!sp::outputToSource(g,18,{-960,540},s) && !sp::outputGeometry({0,0,0,10},{0,0,1,1},false,17).valid;
    auto retina=sp::outputGeometry({0,0,3840,2160},{240,80,1600,1600},false,17);
    bool sameScale=sp::outputToSource(retina,17,{1920,1080},s) && std::abs(s.x-1040)<0.001 && std::abs(s.y-880)<0.001;
    sp::GeometryPoint pixel{}, point{};
    bool displayTransform=sp::appKitScreenToDisplayPixels({-1920,-900,1920,1080},{3840,2160},{-960,-360},pixel) &&
        std::abs(pixel.x-1920)<0.001 && std::abs(pixel.y-1080)<0.001 &&
        sp::displayPixelsToAppKitScreen({-1920,-900,1920,1080},{3840,2160},pixel,point) &&
        std::abs(point.x+960)<0.001 && std::abs(point.y+360)<0.001 &&
        !sp::appKitScreenToDisplayPixels({-1920,-900,1920,1080},{3840,2160},{100,100},pixel);
    bool ok=corners&&fit&&bars&&roundtrip&&stale&&sameScale&&displayTransform;
    std::printf("{\"ok\":%s,\"bars\":%s,\"roundtrip\":%s,\"staleRejected\":%s,\"retinaConsistent\":%s,\"scope\":\"pure contract; no capture metadata binding or input routing\"}\n",ok?"true":"false",bars?"true":"false",roundtrip?"true":"false",stale?"true":"false",sameScale?"true":"false");
    return ok?0:1;
}
