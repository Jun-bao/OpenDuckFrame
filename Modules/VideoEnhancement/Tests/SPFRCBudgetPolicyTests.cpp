#include "SPFRCBudgetPolicy.hpp"
#include "SPRateSchedule.hpp"
#include <cassert>
#include <cstdio>
int main() {
 using G=sp::FRCBudgetGate; using D=G::Decision;
 G g;
 assert(g.decide(130,78,false,true,1)==D::admit);
 assert(g.decide(130,78,true,false,2)==D::backendBusy && !g.limited());
 assert(g.decide(130,78,true,true,1000000000)==D::probe && g.limited());
 assert(g.decide(130,78,true,true,1500000000)==D::budgetLimited);
 assert(g.decide(130,78,true,false,3000000000)==D::backendBusy);
 assert(g.decide(130,78,true,true,3000000000)==D::probe);
 assert(g.decide(65,78,true,true,3100000000)==D::admit && !g.limited());
 assert(g.decide(130,78,true,true,3200000000)==D::probe);
 g.reset(); assert(!g.limited() && g.decide(130,78,true,true,3300000000)==D::probe);
 assert(g.decide(0,0,false,true,3400000000)==D::admit);
 // Feed actual production scheduler events: budget drops never suppress source.
 sp::SPRateScheduler scheduler; sp::SPRateRequest request; request.kind=sp::SPRateKind::Multiplier; request.multiplier=2;
 assert(scheduler.reset(request,1,sp::spMake(1,2))); G live;
 int sources=0, planned=0, admitted=0, probes=0, rejected=0, busy=0;
 for (int i=0;i<180;i++) {
  sp::SPScheduleInput input; input.identity=i+1; input.generation=1; input.pts=sp::spMake(i,60);
  auto result=scheduler.push(input); assert(result.reject==sp::SPScheduleReject::None);
  for(const auto &event:result.events) {
   if(event.action!=sp::SPScheduleAction::Interpolate) { sources++; continue; }
   planned++;
   auto decision=live.decide(i<130?130:60,78,true,i%10!=0,1'000'000'000LL+i*1'000'000'000LL/60);
   if(decision==D::admit)admitted++;
   else if(decision==D::probe)probes++;
   else if(decision==D::budgetLimited)rejected++;
   else busy++;
  }
 }
 assert(sources>=179 && planned==admitted+probes+rejected+busy);
 assert(rejected>100 && probes>=1 && probes<=2 && busy>0 && admitted>30 && !live.limited());
 std::puts("{\"ok\":true,\"scope\":\"production scheduler events with simulated budget, capacity and recovery; no GPU or GUI\"}");
}
