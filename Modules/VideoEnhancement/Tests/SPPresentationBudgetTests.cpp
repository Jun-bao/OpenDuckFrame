#include "SPFPSMeter.hpp"
#include "SPPresentationBudget.hpp"
#include "SPRateSchedule.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>

static constexpr int64_t S=1000000000LL, start=10000000000LL;
static void feed(sp::NativeCadenceGate &g, int count, int fps, int64_t &pts, int64_t &host,
                 bool phase=false, bool periodic=false, int omit=-1, uint64_t gen=1, int width=2560, int height=1410) {
    for (int i=0;i<count;i++) {
        pts += S/fps; host += S/fps;
        if (i==omit) { pts += S/fps; host += S/fps; }
        int64_t jitter = phase ? (i%2 ? 400000 : -400000) : 0;
        if (periodic && i%30==0) jitter += 1000000;
        g.observe(pts,host+jitter,gen,width,height);
    }
}
int main() {
    for (int variant=0;variant<4;variant++) {
        sp::NativeCadenceGate g; g.configure(120,0); int64_t pts=0,host=start;
        feed(g,620,120,pts,host,variant==1,variant==2,variant==3 ? 70 : -1);
        auto s=g.query(host+2000000); assert(s.active && s.ptsFPS>117.6 && s.hostFPS>114);
    }
    sp::NativeCadenceGate gate; gate.configure(120,0); int64_t pts=0,host=start;
    feed(gate,120,120,pts,host); assert(gate.query(host).active);
    feed(gate,1,120,pts,host,false,false,0); assert(gate.query(host).active); // isolated miss
    // Recorded delayed callback followed by two early catch-up callbacks:
    // evaluate immediately after each callback, not just after averaging.
    sp::NativeCadenceGate delayed; delayed.configure(120,0); int64_t dp=0,dh=start;
    feed(delayed,200,120,dp,dh); assert(delayed.query(dh).active);
    for (int64_t hostInterval : {29161375LL,2327166LL,1005375LL}) {
        dp+=S/120; dh+=hostInterval; delayed.observe(dp,dh,1,2560,1410);
        assert(delayed.query(dh).active);
    }
    feed(delayed,45,110,dp,dh); assert(!delayed.query(dh).active);
    feed(delayed,85,120,dp,dh); assert(delayed.query(dh).active);
    // Repeated long intervals without catch-up reduce the actual rate even
    // when each short window sees at most one anomaly. Test both clocks.
    for (bool slowPTS : {false, true}) {
        sp::NativeCadenceGate repeated; repeated.configure(120,0);
        int64_t rp=0,rh=start; feed(repeated,200,120,rp,rh); assert(repeated.query(rh).active);
        int exitedAt=-1;
        for (int i=0;i<600;i++) {
            const int64_t interval=i%30==0 ? 29161375LL : S/120;
            rp += slowPTS ? interval : S/120; rh += slowPTS ? S/120 : interval;
            repeated.observe(rp,rh,1,2560,1410);
            if (!repeated.query(rh).active && exitedAt<0) exitedAt=i;
        }
        assert(exitedAt>=0 && exitedAt<120 && !repeated.query(rh).active);
        feed(repeated,85,120,rp,rh); assert(repeated.query(rh).active);
    }
    for (int fps : {60,30}) {
        feed(gate,3,fps,pts,host); assert(!gate.query(host).active);
        feed(gate,80,fps,pts,host); assert(!gate.query(host).active);
        feed(gate,85,120,pts,host); assert(gate.query(host).active);
    }
    feed(gate,45,110,pts,host); assert(!gate.query(host).active);
    feed(gate,85,120,pts,host); assert(gate.query(host).active);
    assert(!gate.query(host+151000000).active);
    host += 151000000; pts += 151000000;
    feed(gate,85,120,pts,host); assert(gate.query(host).active);
    gate.observe(pts+S/120,host+S/120,2,2560,1410); assert(!gate.query(host+S/120).active);
    pts+=S/120; host+=S/120; feed(gate,85,120,pts,host,false,false,-1,2); assert(gate.query(host).active);
    gate.observe(pts+S/120,host+S/120,2,1920,1080); assert(!gate.query(host+S/120).active);
    pts+=S/120; host+=S/120; feed(gate,85,120,pts,host,false,false,-1,2,1920,1080); assert(gate.query(host).active);
    gate.configure(119.88,0); assert(!gate.query(host).active);
    feed(gate,85,120,pts,host,false,false,-1,2,1920,1080); assert(gate.query(host).active);
    gate.configure(119.88,60); assert(!gate.query(host).active);
    feed(gate,85,120,pts,host,false,false,-1,2,1920,1080); assert(gate.query(host).active);
    gate.configure(119.88,60,2); assert(!gate.query(host).active);
    feed(gate,85,120,pts,host,false,false,-1,2,1920,1080); assert(gate.query(host).active);
    gate.configure(119.88,60,3); assert(!gate.query(host).active); // same Hz, different screen
    feed(gate,85,120,pts,host,false,false,-1,2,1920,1080); assert(gate.query(host).active);
    gate.observe(pts,host+S/120,2,1920,1080); assert(!gate.query(host+S/120).active);
    auto after=gate.query(host+S/120); assert(!std::strcmp(after.reason,"timestamp_discontinuity"));
    // A slow pump/acceptance stream does not change the independently observed raw cadence.
    sp::NativeCadenceGate raw; raw.configure(120,0); sp::FPSMeter pump;
    int64_t rp=0,rh=start;
    for(int i=0;i<120;i++) { rp+=S/120; rh+=S/120; raw.observe(rp,rh,1,2560,1410); if(i%4==0) pump.input(rp,rh); }
    assert(raw.query(rh).active && pump.inputArrivalRate(rh)<35);
    // Scheduler still preserves its original multiplier and phase ordering.
    sp::SPRateScheduler scheduler; sp::SPRateRequest rate; rate.kind=sp::SPRateKind::Multiplier; rate.multiplier=2;
    assert(scheduler.reset(rate,1,sp::spMake(1,2)));
    sp::SPScheduleInput a; a.identity=1; a.generation=1; a.pts=sp::spMake(0,120);
    assert(scheduler.push(a).reject==sp::SPScheduleReject::None);
    a.identity=2; a.pts=sp::spMake(1,120); auto next=scheduler.push(a);
    assert(next.reject==sp::SPScheduleReject::None && next.events.size()==2);
    assert(next.events[0].action==sp::SPScheduleAction::Interpolate && next.events[1].action==sp::SPScheduleAction::PresentSource);
    std::puts("{\"ok\":true,\"scope\":\"production raw cadence gate and scheduler, simulated timestamps only\"}");
}
