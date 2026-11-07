#include "SPRifePairAffineClock.hpp"
#include <cassert>
#include <cstdio>

int main() {
    using namespace sp;
    RifePairClockContext context{1,2,3,4};
    RifeSourceClockTarget a, b;
    assert(freezeRifeSourceClockTarget(a,context,spMake(0,1),1000,40));
    assert(freezeRifeSourceClockTarget(b,context,spMake(1,30),1100,60));
    auto midpoint=rifePairClockTarget(context,spMake(1,60),1080,60,&a,&b);
    assert(midpoint.binding==RifePairClockBinding::bound && midpoint.selectedTargetHost==1050);
    assert(midpoint.legacyTargetHost==1080 && midpoint.legacyDelayHost==60);
    assert(spCmp(midpoint.alphaTime,spMake(1,2))==0); // D increased.
    auto third=rifePairClockTarget(context,spMake(1,90),1060,60,&a,&b);
    assert(third.selectedTargetHost==1033 && spCmp(third.alphaTime,spMake(1,3))==0);
    auto twoThirds=rifePairClockTarget(context,spMake(1,45),1090,60,&a,&b);
    assert(twoThirds.selectedTargetHost==1067);
    auto odd=b; odd.targetHost=1101;
    assert(rifePairClockTarget(context,spMake(1,60),1080,60,&a,&odd).selectedTargetHost==1051);
    RifeSourceClockTarget c;
    assert(freezeRifeSourceClockTarget(c,context,spMake(2,30),1180,30)); // D decreased.
    assert(!freezeRifeSourceClockTarget(b,context,spMake(1,30),1120,30));
    auto next=rifePairClockTarget(context,spMake(1,20),1120,30,&b,&c);
    assert(next.selectedTargetHost==1140 && next.endpointA.targetHost==1100 && next.endpointA.delayHost==60);
    auto retry=reuseRifePairClockTarget(&next,context,spMake(1,20),1140);
    c.targetHost=9000; c.delayHost=9000;
    assert(retry.selectedTargetHost==1140 && retry.legacyTargetHost==1120 && retry.legacyDelayHost==30);
    assert(retry.endpointB.targetHost==1180 && retry.endpointA.targetHost==1100 && retry.deadlineOverride);
    assert(reuseRifePairClockTarget(&next,context,spMake(1,20),1141).selectedTargetHost==1141);
    auto old=context; old.clock++;
    auto stale=rifePairClockTarget(old,spMake(1,60),2000,70,&a,&b);
    assert(stale.binding==RifePairClockBinding::contextMismatch && stale.selectedTargetHost==2000);
    assert(!freezeRifeSourceClockTarget(a,old,spMake(0,1),8000,70) && a.targetHost==1000);
    for(int field=0;field<4;++field) {
        auto changed=context;
        if(field==0) changed.generation++; else if(field==1) changed.config++;
        else if(field==2) changed.measurement++; else changed.clock++;
        assert(rifePairClockTarget(changed,spMake(1,60),2000,70,&a,&b).binding==RifePairClockBinding::contextMismatch);
    }
    auto missing=rifePairClockTarget(context,spMake(1,60),3000,80,&a,nullptr);
    assert(missing.binding==RifePairClockBinding::missingEndpoint && missing.selectedTargetHost==3000);
    b.targetHost=a.targetHost;
    assert(rifePairClockTarget(context,spMake(1,60),4000,90,&a,&b).selectedTargetHost==4000);
    auto external=reuseRifePairClockTarget(nullptr,context,spMake(1,60),5000);
    assert(external.binding==RifePairClockBinding::frozenOnly && external.selectedTargetHost==5000 && external.legacyTargetHost==0);
    std::puts("RIFE pair affine clock CPU contracts passed");
}
