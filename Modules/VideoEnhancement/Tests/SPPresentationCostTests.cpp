#include "SPPresentationOrder.hpp"
#include "SPFPSMeter.hpp"
#include <cassert>
#include <chrono>
#include <cstdio>
int main() {
    sp::PresentationOrder order; order.reset(1,1,1);
    for (int i=0;i<513;i++) order.add({i*10000000LL,1000000000LL+i*10000000LL,(uint64_t)i+1,true,true,false,false},1,1,1);
    assert(order.events().size()==512 && order.evicted()==1 && order.summary(true).backwards==0);
    sp::FPSMeter fps;
    auto start=std::chrono::steady_clock::now();
    uint64_t guard=0;
    for(int n=0;n<1000;n++) {
        auto time=7000000000LL+n*8333333LL;
        order.add({time,time,(uint64_t)n+1000,true,true,false,false},1,1,1);
        fps.presented(time,time,(uint64_t)n+1000,false,false,true);
        if(n%24==0) { guard+=order.summary(true).backwards; guard+=order.summary(false).backwards; (void)fps.outputRate(time); }
    }
    double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    std::printf("{\"scope\":\"synthetic C++ meter and bounded summaries; no Objective-C serialization or HUD\",\"eventCount\":1000,\"summaryCalls\":%d,\"windowSize\":%zu,\"evicted\":%llu,\"elapsedMs\":%.3f,\"guard\":%llu}\n",84,order.events().size(),(unsigned long long)order.evicted(),ms,(unsigned long long)guard);
}
