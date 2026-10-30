#include "SPPresentationOrder.hpp"
#include <cassert>
int main() {
    sp::PresentationOrder o;
    o.reset(1, 2, 3);
    auto add=[&](int64_t pts,int64_t time,uint64_t id,bool out=false,bool visible=true,bool held=false,bool original=false){o.add({pts,time,id,out,visible,held,original},1,2,3);};
    add(30,30,3); add(10,10,1); add(20,20,2); // callback order differs
    assert(o.summary(false).backwards==0 && o.events().front().pts==30);
    add(15,40,4); assert(o.summary(false).backwards==1);
    add(15,50,5); add(14,60,6,false,true,true); add(1,0,7); add(1,70,8,false,false);
    auto s=o.summary(false); assert(s.duplicates==1 && s.backwards==1 && s.excluded==1 && s.invalidTimes==1 && s.invisible==1);
    add(1,10,11,true); add(2,20,12,true); assert(o.summary(true).backwards==0);
    add(3,20,13,true); assert(o.summary(true).ambiguousTimes==1);
    add(0,30,14,true); assert(o.summary(true).backwards==0); // tied group cannot prove boundary order
    o.add({0,100,20,false,true,false,false},9,2,3); // stale source
    o.add({0,100,20,false,true,false,false},1,9,3); // stale config
    o.add({0,100,20,false,true,false,false},1,2,9); // stale epoch
    assert(o.events().size()==12);
    sp::PresentationOrder tieA,tieB;
    tieA.add({30,100,1,true,true,false,false});tieA.add({10,100,2,true,true,false,false});tieA.add({20,200,3,true,true,false,false});
    tieB.add({10,100,2,true,true,false,false});tieB.add({30,100,1,true,true,false,false});tieB.add({20,200,3,true,true,false,false});
    assert(tieA.summary(true).backwards == 0 && tieB.summary(true).backwards == 0 && tieA.summary(true).ambiguousTimes == 1 && tieB.summary(true).ambiguousTimes == 1);
    o.reset(2, 3, 4); assert(o.events().empty() && o.summary(false).backwards==0);
    o.add({1,1,1,false,true,false,false},1,2,3); assert(o.events().empty());
    o.reset(1,2,3);
    for (size_t i=0;i<sp::PresentationOrder::capacity+1;i++) add(i,i+1,i+1);
    assert(o.evicted()==1 && o.events().size()==sp::PresentationOrder::capacity);
}
