import AppKit
import CoreGraphics

@main struct LiveInputRouterTests {
    @MainActor static func main() {
        let noPost=LiveInputRouter.Permission(listen:true,post:false,accessibility:true)
        precondition(noPost.permits(relative:true) && !noPost.permits(relative:false))
        precondition(!LiveInputRouter.Permission(listen:true,post:true,accessibility:false).permits(relative:true))
        precondition(!LiveInputRouter.Permission(listen:false,post:true,accessibility:true).permits(relative:false))
        precondition(LiveInputRouter.bootstrapCanPromote(suppressed:0,controls:0,buttons:0))
        precondition(!LiveInputRouter.bootstrapCanPromote(suppressed:1,controls:0,buttons:0))
        precondition(!LiveInputRouter.bootstrapCanPromote(suppressed:0,controls:1,buttons:0))
        precondition(!LiveInputRouter.bootstrapCanPromote(suppressed:0,controls:0,buttons:1))
        let displays = [CGRect(x:-1920,y:0,width:1920,height:1080), CGRect(x:0,y:0,width:2560,height:1440)]
        precondition(P1InputRoutingPolicy.pointOnDisplays(CGPoint(x:-100,y:100),displays))
        precondition(!P1InputRoutingPolicy.pointOnDisplays(CGPoint(x:-2000,y:100),displays))
        precondition(!P1InputRoutingPolicy.pointOnDisplays(CGPoint(x:30,y:1500),displays))
        precondition(!P1InputRoutingPolicy.pointOnDisplays(CGPoint(x:30,y:100),[]))
        let mappedDisplays = [
            P1DisplayMapping(quartz:CGRect(x:-2880,y:-360,width:2880,height:1800),appKit:CGRect(x:-1440,y:180,width:1440,height:900)),
            P1DisplayMapping(quartz:CGRect(x:0,y:0,width:2560,height:1440),appKit:CGRect(x:0,y:0,width:2560,height:1440))
        ]
        precondition(P1DisplayMapping.appKitPoint(CGPoint(x:-2680,y:-160),displays:mappedDisplays)==CGPoint(x:-1340,y:980))
        precondition(P1DisplayMapping.appKitPoint(CGPoint(x:500,y:300),displays:mappedDisplays)==CGPoint(x:500,y:1140))
        precondition(P1DisplayMapping.appKitPoint(CGPoint(x:-3000,y:0),displays:mappedDisplays)==nil)
        precondition(P1DisplayMapping.appKitPoint(CGPoint(x:500,y:300),displays:[mappedDisplays[1],mappedDisplays[1]])==nil)
        func context(_ g: UInt64, _ c: UInt64, _ e: UInt64, _ v: UInt64) -> LiveInputRouter.Context {
            .init(sourcePID:42,windowID:5,generation:g,config:c,epoch:e,version:v,relative:false,exclusions:[],sourceDisplays:mappedDisplays)
        }
        precondition(LiveInputRouter.sameRoutingIdentity(context(1,2,3,4),context(1,2,3,4)))
        precondition(!LiveInputRouter.sameRoutingIdentity(context(1,2,3,4),context(2,2,3,4)))
        precondition(!LiveInputRouter.sameRoutingIdentity(context(1,2,3,4),context(1,3,3,4)))
        precondition(!LiveInputRouter.sameRoutingIdentity(context(1,2,3,4),context(1,2,4,4)))
        precondition(!LiveInputRouter.sameRoutingIdentity(context(1,2,3,4),context(1,2,3,5)))
        var p=P1InputRoutingPolicy()
        precondition(p.decide(.down,button:0,version:11,inside:true,relative:false) == .map(11,false))
        precondition(p.decide(.down,button:0,version:11,inside:true,relative:false) == .discard)
        precondition(p.decide(.drag,button:0,version:12,inside:false,relative:false) == .map(11,true))
        precondition(p.decide(.up,button:0,version:12,inside:false,relative:false) == .map(11,true))
        precondition(p.held[0] == 11); p.completeUp(0); precondition(p.held.isEmpty)
        precondition(p.decide(.down,button:1,version:11,inside:false,relative:false) == .discard)
        precondition(p.decide(.drag,button:1,version:11,inside:true,relative:false) == .discard)
        precondition(p.decide(.up,button:1,version:11,inside:true,relative:false) == .discard)
        precondition(p.decide(.up,button:1,version:11,inside:true,relative:false) == .discard)
        precondition(p.decide(.scroll,button:0,version:11,inside:false,relative:false) == .discard)
        precondition(p.decide(.motion,button:0,version:11,inside:true,relative:true) == .pass)
        _ = p.decide(.down,button:0,version:21,inside:true,relative:false)
        _ = p.decide(.down,button:1,version:21,inside:true,relative:false)
        precondition(p.reset() == [0:21,1:21] && p.reset().isEmpty)
        let router=LiveInputRouter(mapper:{ _,_,_ in nil },verifyTarget:{ _ in false },safeReleaseTarget:{ _ in false },stopped:{ _ in })
        router.stop(reason:"test"); router.stop(reason:"test")
        precondition(!router.active && router.cleanupUnconfirmed == 0 && router.reason == "test")
        precondition(LiveInputRouter.runObjectContract())
        guard let event=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:CGPoint(x:200,y:300),mouseButton:.left) else { fatalError("CGEvent allocation failed") }
        event.flags=[.maskShift,.maskCommand]
        event.setIntegerValueField(.mouseEventClickState,value:2)
        event.setIntegerValueField(.mouseEventDeltaX,value:7)
        event.setIntegerValueField(.mouseEventDeltaY,value:-4)
        event.setIntegerValueField(.eventSourceUserData,value:19)
        let flags=event.flags
        p1SetEventLocation(event,CGPoint(x:20,y:30))
        precondition(event.location == CGPoint(x:20,y:30) && event.flags == flags)
        precondition(event.getIntegerValueField(.mouseEventClickState)==2 && event.getIntegerValueField(.mouseEventDeltaX)==7 && event.getIntegerValueField(.mouseEventDeltaY)==(-4) && event.getIntegerValueField(.eventSourceUserData)==19)
        guard let scroll=CGEvent(scrollWheelEvent2Source:nil, units:.pixel, wheelCount:2, wheel1:5, wheel2:-3, wheel3:0) else { fatalError("scroll allocation failed") }
        scroll.setIntegerValueField(.scrollWheelEventScrollPhase,value:2)
        scroll.setIntegerValueField(.scrollWheelEventMomentumPhase,value:1)
        let delta1=scroll.getIntegerValueField(.scrollWheelEventDeltaAxis1), delta2=scroll.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        p1SetEventLocation(scroll,CGPoint(x:60,y:70))
        precondition(scroll.getIntegerValueField(.scrollWheelEventDeltaAxis1)==delta1 && scroll.getIntegerValueField(.scrollWheelEventDeltaAxis2)==delta2 &&
            scroll.getIntegerValueField(.scrollWheelEventScrollPhase)==2 && scroll.getIntegerValueField(.scrollWheelEventMomentumPhase)==1)
        print("input policy: down/drag/up, black bars, relative bypass, cleanup and CGEvent metadata pass; no tap or event posting")
    }
}
