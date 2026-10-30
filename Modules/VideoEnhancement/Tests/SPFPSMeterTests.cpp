#include "SPFPSMeter.hpp"
#include <cmath>
#include <cstdio>
int main() {
    sp::FPSMeter m; const int64_t base=1000000000LL;
    for(int i=0;i<31;i++)m.input(i*33333333LL,base+i*33333333LL);
    double input=m.inputRate(base+1000000000LL);bool inputOK=std::fabs(input-30)<.01;
    for(int i=0;i<61;i++)m.presented(i*16666667LL,base+i*16666667LL,i+1,false,false,true);
    double output=m.outputRate(base+1000000020LL);bool outputOK=std::fabs(output-60)<.01;
    m.presented(1000000020LL,base+1016666687LL,61,false,false,true); // duplicate id
    m.presented(1016666687LL,base+1033333354LL,62,true,false,true); // held image
    m.presented(1033333354LL,base+1050000021LL,63,false,true,true); // synthetic shown in original mode
    m.presented(1050000021LL,base+1066666688LL,64,false,false,false); // occluded
    bool ignored=std::fabs(m.outputRate(base+1066666688LL)-output)<.001;
    bool stale=m.inputRate(base+3000000000LL)<0 && m.outputRate(base+3000000000LL)<0;
    m.reset();bool reset=m.inputRate(base+1000000000LL)<0&&m.outputRate(base+1000000000LL)<0;
    m.input(0,base);m.input(0,base+1);m.input(33333333LL,base+33333333LL);bool duplicate=std::fabs(m.inputRate(base+33333333LL)-30)<.01;
    sp::FPSMeter ordered, shuffled;
    const int seq[] = {0,2,1,3};
    for (int i=0;i<4;i++) ordered.presented(i*10000000LL,base+i*10000000LL,i+1,false,false,true);
    for (int i:seq) shuffled.presented(i*10000000LL,base+i*10000000LL,i+1,false,false,true);
    bool reorder=std::fabs(ordered.outputRate(base+40000000LL)-shuffled.outputRate(base+40000000LL))<1e-9;
    // A real PTS reversal still represents a displayed distinct frame; the
    // separate presentation-order tracker reports the reversal.
    sp::FPSMeter reversed; reversed.presented(20,base,1,false,false,true); reversed.presented(10,base+10000000LL,2,false,false,true);
    bool reversedCounted=std::fabs(reversed.outputRate(base+10000000LL)-100)<1e-9;
    for(int i=0;i<600;i++) shuffled.presented(30000000LL,base+50000000LL+i,4,false,false,true);
    bool duplicateBounded=std::fabs(shuffled.outputRate(base+60000000LL)-100)<1e-9;
    shuffled.resetOutput(); bool endpointReset=shuffled.outputRate(base+60000000LL)<0;
    sp::FPSMeter late; late.presented(0,base,1,false,false,true);late.presented(1,base+1600000000LL,2,false,false,true);
    late.presented(0,base,1,false,false,true); bool oldRejected=late.outputRate(base+1600000000LL)<0;
    bool ok=inputOK&&outputOK&&ignored&&stale&&reset&&duplicate&&reorder&&reversedCounted&&duplicateBounded&&endpointReset&&oldRejected;
    std::printf("{\"ok\":%s,\"inputPTS\":%s,\"physicalOutput\":%s,\"holdsRedrawOccludedExcluded\":%s,\"staleCleared\":%s,\"generationReset\":%s}\n",ok?"true":"false",inputOK&&duplicate?"true":"false",outputOK?"true":"false",ignored?"true":"false",stale?"true":"false",reset?"true":"false");
    return ok?0:1;
}
