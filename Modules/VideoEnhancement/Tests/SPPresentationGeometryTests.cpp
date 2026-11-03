#include "SPPresentationGeometry.hpp"
#include <cassert>
int main() {
    sp::PresentationGeometry g;
    sp::PresentationGeometrySample x{2560,1440,1920,1080,1920,1080,2560,1440,100,true};
    g.record(true,x); assert(g.get(true).valid && g.get(true).drawableWidth == 2560 && !g.get(false).valid);
    auto older=x; older.presentedTimeNs=99; older.drawableWidth=800; g.record(true,older); assert(g.get(true).drawableWidth==2560);
    auto zero=x; zero.presentedTimeNs=0; g.record(false,zero); assert(!g.get(false).valid);
    auto tie=x; tie.drawableWidth=1280; g.record(true,tie); assert(!g.get(true).valid);
    auto later=x; later.presentedTimeNs=101; g.record(true,later); assert(g.get(true).valid);
    g.reset(); assert(!g.get(true).valid && !g.get(false).valid);
}
