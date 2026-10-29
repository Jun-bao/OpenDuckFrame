#include "SPFrameSelectionPolicy.hpp"
#include <cstdio>
int main() {
    sp::SPFrameCandidateMetadata held{}; held.synthetic=true; held.interpolationEpoch=3;
    sp::SPSyntheticFramePolicy current{}; current.enforce=true; current.acceptsSynthetic=true; current.interpolationEpoch=4;
    const bool stale=sp::spIsStaleSyntheticFrame(held,current);
    held.interpolationEpoch=4;
    const bool accepted=!sp::spIsStaleSyntheticFrame(held,current);
    held.synthetic=false; held.interpolationEpoch=3;
    const bool source=!sp::spIsStaleSyntheticFrame(held,current);
    const bool ok=stale&&accepted&&source;
    std::printf("{\"ok\":%s,\"oldHoldRejected\":%s,\"currentHoldAccepted\":%s,\"sourcePreserved\":%s}\n",ok?"true":"false",stale?"true":"false",accepted?"true":"false",source?"true":"false");
    return ok?0:1;
}
