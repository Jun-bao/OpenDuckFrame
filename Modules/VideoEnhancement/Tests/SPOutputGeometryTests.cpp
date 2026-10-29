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
    std::printf("{\"ok\":%s,\"followMapsFourCorners\":%s,\"otherModeAspectFit\":%s,\"scope\":\"quad geometry only; no visible window or input mapping\"}\n",corners&&fit?"true":"false",corners?"true":"false",fit?"true":"false");
    return corners&&fit?0:1;
}
