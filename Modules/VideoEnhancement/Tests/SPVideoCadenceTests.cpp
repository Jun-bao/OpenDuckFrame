#include "SPVideoCadence.hpp"
#include <cstdio>
#include <cstdlib>

static void require(bool ok, const char *message) { if (!ok) { std::fprintf(stderr,"%s\n",message); std::exit(1); } }
static void feed(sp::VideoCadenceDetector &detector, int fps, int capture, double begin, double seconds, int zones = 6) {
    int previous = -1;
    for (int tick = 0; tick < int(seconds*capture); ++tick) {
        double time = begin + double(tick)/capture;
        int frame = int(std::floor((time + 1e-7)*fps));
        std::array<bool,6> changes{};
        for(int z=0; z<zones; ++z) changes[z] = previous >= 0 && frame != previous;
        detector.observeChanges(changes,std::llround(time*1e9)); previous=frame;
    }
}
int main() {
    for(int fps : {24,25,30}) for(int capture : {48,60}) {
        sp::VideoCadenceDetector detector;
        feed(detector,fps,capture,10,7);
        require(detector.fps()==fps,"common video cadence did not lock");
        for(int i=0;i<240;++i) detector.observeChanges({},17000000000LL+i*16666667LL);
        require(detector.fps()==fps,"still scene discarded the lock");
    }
    sp::VideoCadenceDetector single;
    feed(single,25,60,10,8,1);
    require(single.fps()==0,"one animated control selected a video cadence");
    sp::VideoCadenceDetector high;
    feed(high,60,60,10,8);
    require(high.fps()==0,"60 FPS content was mislabeled as a low-rate video");
    sp::VideoCadenceDetector change;
    feed(change,25,60,10,7);feed(change,30,60,17,8);
    require(change.fps()==30,"video change did not relock");
    feed(change,60,60,25,8);
    require(change.fps()==0,"unsupported sustained motion retained an old lock");
    change.observeChanges({},1000000000);
    require(change.fps()==0,"backwards timestamp retained old evidence");
    for(int fps : {24,25,30}) {
        sp::VideoCadenceClock clock;clock.start(fps,1726814000000000LL,7000000);
        auto first=clock.pts(0);
        for(int64_t i=1;i<500;++i) {
            auto current=clock.pts(i), previous=clock.pts(i-1);sp::SPRational delta;
            require(sp::spSub(current,previous,delta) && sp::spCmp(delta,sp::spMake(1,fps))==0,"normalized timeline was uneven");
            require(current.den<=INT32_MAX,"normalized PTS cannot enter VideoToolbox");
            require(clock.index(clock.closesNs(i)-1000000)==i,"bucket closed too early");
            require(clock.index(clock.closesNs(i)+1000000)==i+1,"next bucket did not open");
        }
        require(first.den>0,"clock origin invalid");
    }
    std::puts("video cadence detection and rational timeline assertions passed");
}
