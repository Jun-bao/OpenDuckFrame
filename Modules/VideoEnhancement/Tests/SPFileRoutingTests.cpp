#include "SPInterpolationRoutingPolicy.hpp"
#include <cstdio>
int main() {
    sp::SPInterpolationRoutingContext context;
    context.requested=true;context.apiAvailable=true;context.videoFPS=60;context.displayMaximumFPS=60;
    context.supportedPixelFormat=true;context.supportedChromaSiting=true;context.hasIOSurface=true;
    bool normal=sp::spEvaluateInterpolationRouting(context)==sp::SPInterpolationPolicyCode::DisplayCadence;
    context.enforceDisplayLimit=false;
    bool experimental=sp::spEvaluateInterpolationRouting(context)==sp::SPInterpolationPolicyCode::Active;
    context.interlaced=true;
    bool safety=sp::spEvaluateInterpolationRouting(context)==sp::SPInterpolationPolicyCode::Interlaced;
    const bool ok=normal&&experimental&&safety;
    std::printf("{\"ok\":%s,\"legacyDisplayGate\":%s,\"explicitExtendedCadence\":%s,\"interlacedStillRejected\":%s}\n",ok?"true":"false",normal?"true":"false",experimental?"true":"false",safety?"true":"false");
    return ok?0:1;
}
