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
    bool ok=inputOK&&outputOK&&ignored&&stale&&reset&&duplicate;
    std::printf("{\"ok\":%s,\"inputPTS\":%s,\"physicalOutput\":%s,\"holdsRedrawOccludedExcluded\":%s,\"staleCleared\":%s,\"generationReset\":%s}\n",ok?"true":"false",inputOK&&duplicate?"true":"false",outputOK?"true":"false",ignored?"true":"false",stale?"true":"false",reset?"true":"false");
    return ok?0:1;
}
