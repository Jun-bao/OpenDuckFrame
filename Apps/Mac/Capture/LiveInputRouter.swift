import AppKit
@preconcurrency import CoreGraphics
import Foundation
import ApplicationServices

// Keep the original event object and every field except its location.
func p1SetEventLocation(_ event: CGEvent, _ point: CGPoint) { event.location = point }

// Both rects are screen-space snapshots for one active display.
struct P1DisplayMapping {
    let quartz: CGRect
    let appKit: CGRect
    static func appKitPoint(_ point: CGPoint, displays: [P1DisplayMapping]) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let candidates = displays.filter { $0.quartz.contains(point) }
        guard candidates.count == 1, let d = candidates.first,
              d.quartz.minX.isFinite, d.quartz.minY.isFinite, d.quartz.width.isFinite, d.quartz.height.isFinite,
              d.appKit.minX.isFinite, d.appKit.minY.isFinite, d.appKit.width.isFinite, d.appKit.height.isFinite,
              d.quartz.width > 0, d.quartz.height > 0, d.appKit.width > 0, d.appKit.height > 0 else { return nil }
        return CGPoint(x: d.appKit.minX + (point.x-d.quartz.minX)*d.appKit.width/d.quartz.width,
                       y: d.appKit.maxY - (point.y-d.quartz.minY)*d.appKit.height/d.quartz.height)
    }
}

// Pure transition logic: no event posting, permissions or desktop access.
struct P1InputRoutingPolicy {
    enum Kind { case down, drag, up, motion, scroll }
    enum Decision: Equatable { case pass, discard, map(UInt64, Bool) }
    private(set) var held: [Int: UInt64] = [:]
    private(set) var suppressed: Set<Int> = []

    mutating func decide(_ kind: Kind, button: Int, version: UInt64, inside: Bool, relative: Bool) -> Decision {
        if relative { return .pass }
        switch kind {
        case .down:
            if held[button] != nil || suppressed.contains(button) { return .discard }
            if !inside || version == 0 { suppressed.insert(button); return .discard }
            held[button] = version; return .map(version, false)
        case .drag:
            if suppressed.contains(button) { return .discard }
            guard let v = held[button] else { return .discard }
            return .map(v, true)
        case .up:
            if suppressed.remove(button) != nil { return .discard }
            guard let v = held[button] else { return .discard }
            return .map(v, true)
        case .motion, .scroll:
            return inside && version != 0 ? .map(version, false) : .discard
        }
    }
    static func pointOnDisplays(_ point: CGPoint, _ displays: [CGRect]) -> Bool {
        point.x.isFinite && point.y.isFinite && displays.contains { $0.contains(point) }
    }
    mutating func completeUp(_ button: Int) { held.removeValue(forKey: button) }
    mutating func reset() -> [Int: UInt64] {
        let result = held; held.removeAll(); suppressed.removeAll(); return result
    }
}

@MainActor final class LiveInputRouter {
    struct Context {
        let sourcePID: pid_t
        let windowID: UInt32
        let generation: UInt64
        let config: UInt64
        let epoch: UInt64
        let version: UInt64
        let relative: Bool
        let exclusions: [CGRect]
        let sourceDisplays: [P1DisplayMapping]
    }
    struct Permission {
        let listen: Bool
        let post: Bool
        let accessibility: Bool
        func permits(relative: Bool) -> Bool { listen && accessibility && (relative || post) }
        static func preflight() -> Permission { .init(listen: CGPreflightListenEventAccess(), post: CGPreflightPostEventAccess(), accessibility: AXIsProcessTrusted()) }
    }
    typealias Mapper = (CGPoint, UInt64, Bool) -> CGPoint?
    let mapper: Mapper
    let verifyTarget: (Context) -> Bool
    let verifyBootstrap: (Context) -> Bool
    let safeReleaseTarget: (Context) -> Bool
    let hitTest: (CGPoint) -> Int
    let stopped: (String) -> Void
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var context: Context?
    private var policy = P1InputRoutingPolicy()
    private var lastPoints: [Int: CGPoint] = [:]
    private var swallowingEscapeUp = false
    private var failing = false
    private var lifecycle: UInt64 = 0
    private var bootstrapControlWindowID: Int = 0
    private var bootstrapOutputQuartz = CGRect.null
    private var bootstrapSuppressed: Set<Int> = []
    private var bootstrapControlHeld: Set<Int> = []
    private var bootstrapOutsideHeld: Set<Int> = []
    private var lastDown: [String: Any] = [:]
    private(set) var routed: UInt64 = 0
    private(set) var rejected: UInt64 = 0
    private(set) var cleanupUnconfirmed: UInt64 = 0
    private(set) var cleanupPosted: UInt64 = 0
    private(set) var reason = "stopped"
    private(set) var hitQueries: UInt64 = 0
    private(set) var lastHitWindow: Int = 0
    private(set) var lastHitReason = "not_queried"
    private(set) var lastHitMS: Double = 0
    private(set) var maxHitMS: Double = 0
    private var hitSamples: [[String: Any]] = []
    private var lastBlockedHit: [String: Any]?
    private func recordHit(_ reason: String, _ number: Int, _ milliseconds: Double, _ version: UInt64) {
        lastHitReason=reason; lastHitWindow=number; lastHitMS=milliseconds; maxHitMS=max(maxHitMS,milliseconds)
        let sample: [String: Any] = ["reason":reason,"windowID":number,"durationMS":milliseconds,"version":version]
        hitSamples.append(sample)
        if reason != "selected_window" && reason != "cleanup_selected_window" { lastBlockedHit=sample }
        if hitSamples.count > 32 { hitSamples.removeFirst(hitSamples.count-32) }
    }
    private static let marker: Int64 = 0x4b48554150310001

    init(mapper: @escaping Mapper, verifyTarget: @escaping (Context) -> Bool,
         verifyBootstrap: @escaping (Context) -> Bool = { _ in false },
         safeReleaseTarget: @escaping (Context) -> Bool,
         hitTest: @escaping (CGPoint) -> Int = { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: 0) },
         stopped: @escaping (String) -> Void) {
        self.mapper=mapper; self.verifyTarget=verifyTarget; self.verifyBootstrap=verifyBootstrap; self.safeReleaseTarget=safeReleaseTarget; self.hitTest=hitTest; self.stopped=stopped
    }
    var active: Bool { tap != nil && context != nil }
    var ready: Bool { active && (context?.version ?? 0) > 0 }
    func diagnostics() -> [String: Any] {
        ["active":ready, "tapActive":active, "bootstrap":active && !ready, "reason":reason, "routed":routed, "rejected":rejected, "cleanupUnconfirmed":cleanupUnconfirmed, "cleanupPosted":cleanupPosted,
         "sourcePID":context.map { Int($0.sourcePID) } ?? 0, "windowID":context.map { Int($0.windowID) } ?? 0,
         "generation":context?.generation ?? 0, "geometryVersion":context?.version ?? 0, "config":context?.config ?? 0, "epoch":context?.epoch ?? 0,
         "inputMode":context.map { $0.relative ? "relative" : "absolute" } ?? "none",
         "phase":active ? (ready ? "mapped" : "preparing") : "stopped", "lastDown":lastDown,
         "hitQueries":hitQueries, "lastHitWindow":lastHitWindow, "lastHitReason":lastHitReason, "lastHitMS":lastHitMS, "maxHitMS":maxHitMS, "hitSamples":hitSamples, "lastBlockedHit":lastBlockedHit ?? [:]]
    }
    static func bootstrapCanPromote(suppressed: Int, controls: Int, buttons: Int) -> Bool {
        suppressed == 0 && controls == 0 && buttons == 0
    }
    static func sameRoutingIdentity(_ a: Context, _ b: Context) -> Bool {
        a.sourcePID == b.sourcePID && a.windowID == b.windowID && a.generation == b.generation &&
            a.config == b.config && a.epoch == b.epoch && a.version == b.version && a.relative == b.relative
    }
    // A preparation tap consumes unverified pointer events before any
    // transparent output can appear; it never maps or synthesizes input.
    func startBootstrap(_ next: Context, controlWindowID: Int, outputQuartz: CGRect) -> Bool {
        guard !next.relative, next.version == 0, verifyBootstrap(next), Permission.preflight().permits(relative:false), !outputQuartz.isEmpty else { reason="bootstrap_unavailable"; return false }
        guard NSEvent.pressedMouseButtons == 0 else { reason="bootstrap_buttons_down"; return false }
        if let current=context, active, current.version == 0 && current.sourcePID == next.sourcePID && current.windowID == next.windowID && current.generation == next.generation && current.config == next.config {
            context=next; bootstrapControlWindowID=controlWindowID; bootstrapOutputQuartz=outputQuartz; return true
        }
        if active { stop(reason:"bootstrap_identity_changed") }
        bootstrapControlWindowID=controlWindowID; bootstrapOutputQuartz=outputQuartz
        guard install(next) else { return false }
        guard NSEvent.pressedMouseButtons == 0 else { stop(reason:"bootstrap_buttons_down"); return false }
        return true
    }
    // Only the matching, presented geometry can promote the blocking tap.
    func start(_ next: Context) -> Bool {
        if let current=context, active {
            if Self.sameRoutingIdentity(current, next) { context=next; return true }
            if current.version == 0 && !next.relative && current.sourcePID == next.sourcePID && current.windowID == next.windowID &&
               current.generation == next.generation && current.config == next.config {
                guard next.version != 0, verifyBootstrap(current), verifyTarget(next), Permission.preflight().permits(relative:false) else { reason="target_or_geometry_unavailable"; return false }
                guard Self.bootstrapCanPromote(suppressed: bootstrapSuppressed.count, controls: bootstrapControlHeld.count + bootstrapOutsideHeld.count, buttons: Int(NSEvent.pressedMouseButtons)) else { reason="bootstrap_buttons_pending"; return false }
                context=next; reason="absolute_mapping"; return true
            }
            stop(reason:"geometry_or_mode_changed")
        }
        let permission = Permission.preflight()
        guard permission.permits(relative: next.relative) else {
            reason = !permission.listen ? "listen_permission_missing" : (!permission.accessibility ? "accessibility_missing" : "post_permission_missing"); return false
        }
        guard next.version != 0, verifyTarget(next) else { reason="target_or_geometry_unavailable"; return false }
        return install(next)
    }
    private func install(_ next: Context) -> Bool {
        let types: [CGEventType] = [.leftMouseDown,.leftMouseUp,.leftMouseDragged,.rightMouseDown,.rightMouseUp,.rightMouseDragged,.otherMouseDown,.otherMouseUp,.otherMouseDragged,.mouseMoved,.scrollWheel,.keyDown,.keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, user in
            guard let user else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<LiveInputRouter>.fromOpaque(user).takeUnretainedValue().handle(type: type, event: event)
            }
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { reason="tap_create_failed"; return false }
        lifecycle &+= 1; context=next; tap=port; tapSource=source; failing=false
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else { stop(reason: "tap_enable_failed"); return false }
        reason = next.version == 0 ? "bootstrap_blocking" : (next.relative ? "relative_native" : "absolute_mapping")
        return true
    }
    func stop(reason why: String) {
        let previous = context
        let held = policy.reset()
        // A targeted release is used only for cleanup while the selected
        // window is still independently verified and truly foreground.
        if !held.isEmpty, let previous, safeReleaseTarget(previous), CGPreflightPostEventAccess() {
            for (button, _) in held {
                guard let point=lastPoints[button], let appPoint=P1DisplayMapping.appKitPoint(point, displays:previous.sourceDisplays) else { cleanupUnconfirmed += 1; continue }
                let started=ProcessInfo.processInfo.systemUptime, hit=hitTest(appPoint)
                let elapsed=max(0,(ProcessInfo.processInfo.systemUptime-started)*1000)
                hitQueries &+= 1
                guard hit == Int(previous.windowID), verifyTarget(previous) else {
                    recordHit("cleanup_target_unconfirmed", hit, elapsed, previous.version); cleanupUnconfirmed += 1; continue
                }
                recordHit("cleanup_selected_window", hit, elapsed, previous.version)
                guard let type=Self.upType(button), let mouse=CGMouseButton(rawValue: UInt32(button)),
                      let release=CGEvent(mouseEventSource:nil, mouseType:type, mouseCursorPosition:point, mouseButton:mouse) else { cleanupUnconfirmed += 1; continue }
                release.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                release.postToPid(previous.sourcePID)
                cleanupPosted += 1; cleanupUnconfirmed += 1 // postToPid has no per-window delivery receipt
            }
        } else { cleanupUnconfirmed += UInt64(held.count) }
        lastPoints.removeAll(); swallowingEscapeUp=false; context=nil; bootstrapControlWindowID=0
        bootstrapOutputQuartz = .null; bootstrapSuppressed.removeAll(); bootstrapControlHeld.removeAll(); bootstrapOutsideHeld.removeAll()
        if let tap { CGEvent.tapEnable(tap:tap,enable:false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(),tapSource,.commonModes) }
        tap=nil; tapSource=nil; failing=false; lifecycle &+= 1; reason=why
    }
    private static func upType(_ button: Int) -> CGEventType? {
        switch button { case 0: return .leftMouseUp; case 1: return .rightMouseUp; case 2...31: return .otherMouseUp; default: return nil }
    }
    // Runs the real callback decision path using unposted event objects.
    static func runObjectContract() -> Bool {
        let router=LiveInputRouter(mapper:{ point, version, clamp in
            guard version == 7 else { return nil }
            if point.x < 100 && !clamp { return nil }
            return CGPoint(x:max(0,point.x-100),y:point.y)
        }, verifyTarget:{ _ in true },safeReleaseTarget:{ _ in false },hitTest:{ _ in 5 },stopped:{ _ in })
        router.context=Context(sourcePID:42,windowID:5,generation:1,config:2,epoch:3,version:7,relative:false,exclusions:[],sourceDisplays:[P1DisplayMapping(quartz:CGRect(x:-100,y:-100,width:1000,height:1000),appKit:CGRect(x:-100,y:-100,width:1000,height:1000))])
        guard let down=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:CGPoint(x:150,y:50),mouseButton:.left),
              let drag=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDragged,mouseCursorPosition:CGPoint(x:10,y:50),mouseButton:.left),
              let up=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:CGPoint(x:10,y:50),mouseButton:.left),
              let black=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:CGPoint(x:10,y:50),mouseButton:.left),
              let blackUp=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:CGPoint(x:10,y:50),mouseButton:.left) else { return false }
        down.flags=[.maskShift]; down.setIntegerValueField(.mouseEventClickState,value:2)
        let accepted=router.handle(type:.leftMouseDown,event:down) != nil && down.location.x==50 && down.flags.contains(.maskShift) && down.getIntegerValueField(.mouseEventClickState)==2
        let crossed=router.handle(type:.leftMouseDragged,event:drag) != nil && drag.location.x==0
        let released=router.handle(type:.leftMouseUp,event:up) != nil && up.location.x==0 && router.policy.held.isEmpty
        let blocked=router.handle(type:.leftMouseDown,event:black)==nil && router.handle(type:.leftMouseUp,event:blackUp)==nil
        black.setIntegerValueField(.eventSourceUserData,value:marker)
        let tagged=router.handle(type:.leftMouseDown,event:black) != nil && black.location.x==10
        router.context=Context(sourcePID:42,windowID:5,generation:1,config:2,epoch:3,version:7,relative:true,exclusions:[],sourceDisplays:[P1DisplayMapping(quartz:CGRect(x:-100,y:-100,width:1000,height:1000),appKit:CGRect(x:-100,y:-100,width:1000,height:1000))])
        let relative=router.handle(type:.leftMouseDown,event:blackUp) != nil && blackUp.location.x==10
        // Exercise the production callback with deterministic hit results; no event is posted.
        var hit = 0, targetValid = true, invalidateInQuery = false
        let tested=LiveInputRouter(mapper:{ point, version, clamp in
            guard version == 9 else { return nil }; if point.x < 100 && !clamp { return nil }
            return CGPoint(x:max(0,point.x-100),y:point.y)
        },verifyTarget:{ _ in targetValid },verifyBootstrap:{ _ in targetValid },safeReleaseTarget:{ _ in false },hitTest:{ _ in
            if invalidateInQuery { targetValid = false }; return hit
        },stopped:{ _ in })
        tested.context=Context(sourcePID:42,windowID:5,generation:1,config:2,epoch:3,version:9,relative:false,exclusions:[],
            sourceDisplays:[P1DisplayMapping(quartz:CGRect(x:-100,y:-100,width:1000,height:1000),appKit:CGRect(x:-100,y:-100,width:1000,height:1000))])
        func mouse(_ type: CGEventType, _ x: CGFloat) -> CGEvent? {
            CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:CGPoint(x:x,y:50),mouseButton:.left)
        }
        func blockedPair(_ number: Int) -> Bool {
            hit = number
            guard let down = mouse(.leftMouseDown,150), let up = mouse(.leftMouseUp,150) else { return false }
            return tested.handle(type:.leftMouseDown,event:down)==nil && down.location.x==150 && tested.handle(type:.leftMouseUp,event:up)==nil
        }
        let noWindow=blockedPair(0), otherWindow=blockedPair(8), ownPanel=blockedPair(99)
        guard let blackDown=mouse(.leftMouseDown,10), let blackRelease=mouse(.leftMouseUp,10),
              let move=mouse(.mouseMoved,150), let wheel=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:4,wheel2:0,wheel3:0) else { return false }
        wheel.location=CGPoint(x:150,y:50)
        let beforeBlack=tested.hitQueries
        let noBlackQuery=tested.handle(type:.leftMouseDown,event:blackDown)==nil && tested.handle(type:.leftMouseUp,event:blackRelease)==nil && tested.hitQueries==beforeBlack
        hit=8
        let noMoveLeak=tested.handle(type:.mouseMoved,event:move)==nil && move.location.x==150
        let noScrollLeak=tested.handle(type:.scrollWheel,event:wheel)==nil && wheel.location.x==150
        guard let acceptedDown=mouse(.leftMouseDown,150), let crossing=mouse(.leftMouseDragged,10), let release=mouse(.leftMouseUp,10),
              let staleDown=mouse(.leftMouseDown,150), let staleUp=mouse(.leftMouseUp,150), let invalidDown=mouse(.leftMouseDown,150) else { return false }
        hit = 5
        let exact=tested.handle(type:.leftMouseDown,event:acceptedDown) != nil && acceptedDown.location.x==50
        let countAfterDown=tested.hitQueries
        hit = 8 // a drag/up stays bound to its accepted down, without a new hit test
        let latched=tested.handle(type:.leftMouseDragged,event:crossing) != nil && tested.handle(type:.leftMouseUp,event:release) != nil && tested.hitQueries==countAfterDown
        hit = 5
        let oldDown=tested.handle(type:.leftMouseDown,event:staleDown) != nil
        targetValid = false
        let noLeak=tested.handle(type:.leftMouseUp,event:staleUp)==nil && staleUp.location.x==150
        tested.stop(reason:"contract_cleanup")
        targetValid=true; invalidateInQuery=true
        tested.context=Context(sourcePID:42,windowID:5,generation:2,config:3,epoch:4,version:9,relative:false,exclusions:[],
            sourceDisplays:[P1DisplayMapping(quartz:CGRect(x:-100,y:-100,width:1000,height:1000),appKit:CGRect(x:-100,y:-100,width:1000,height:1000))])
        let oldQuery=tested.handle(type:.leftMouseDown,event:invalidDown)==nil && invalidDown.location.x==150 && tested.lastHitReason=="target_changed_after_query"
        tested.stop(reason:"contract_cleanup")
        targetValid=true; invalidateInQuery=false; hit=5
        tested.context=Context(sourcePID:42,windowID:5,generation:2,config:3,epoch:0,version:0,relative:false,exclusions:[],
            sourceDisplays:[P1DisplayMapping(quartz:CGRect(x:-100,y:-100,width:1000,height:1000),appKit:CGRect(x:-100,y:-100,width:1000,height:1000))])
        tested.bootstrapOutputQuartz=CGRect(x:0,y:0,width:500,height:500); tested.bootstrapControlWindowID=99
        guard let prepDown=mouse(.leftMouseDown,150), let prepUp=mouse(.leftMouseUp,600),
              let controlDown=mouse(.leftMouseDown,150), let controlUp=mouse(.leftMouseUp,150),
              let outsideDown=mouse(.leftMouseDown,600), let outsideUp=mouse(.leftMouseUp,150) else { return false }
        let prepBlocked=tested.handle(type:.leftMouseDown,event:prepDown)==nil && tested.bootstrapSuppressed.contains(0) &&
            tested.handle(type:.leftMouseUp,event:prepUp)==nil && tested.bootstrapSuppressed.isEmpty
        let outsideUnchanged=tested.handle(type:.leftMouseDown,event:outsideDown) != nil && outsideDown.location.x==600 &&
            tested.bootstrapOutsideHeld.contains(0) && tested.handle(type:.leftMouseUp,event:outsideUp) != nil && tested.bootstrapOutsideHeld.isEmpty
        hit=99
        let stopControl=tested.handle(type:.leftMouseDown,event:controlDown) != nil && tested.bootstrapControlHeld.contains(0) &&
            tested.handle(type:.leftMouseUp,event:controlUp) != nil && tested.bootstrapControlHeld.isEmpty
        tested.stop(reason:"contract_cleanup")
        return accepted && crossed && released && blocked && tagged && relative && noWindow && otherWindow && ownPanel && noBlackQuery && noMoveLeak && noScrollLeak && exact && latched && oldDown && noLeak && oldQuery && tested.cleanupUnconfirmed>0 && prepBlocked && outsideUnchanged && stopControl
    }
    private func fail(_ why: String) {
        guard !failing else { return }
        failing=true
        let token = lifecycle
        DispatchQueue.main.async { [weak self] in
            guard let self, self.failing, self.lifecycle == token else { return }
            self.stop(reason:why); self.stopped(why)
        }
    }
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { fail("tap_disabled"); return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        let isPointer: Bool = [.leftMouseDown,.leftMouseUp,.leftMouseDragged,.rightMouseDown,.rightMouseUp,.rightMouseDragged,.otherMouseDown,.otherMouseUp,.otherMouseDragged,.mouseMoved,.scrollWheel].contains(type)
        guard !failing else { return isPointer && context?.relative != true ? nil : Unmanaged.passUnretained(event) }
        guard let current=context, (current.version == 0 ? verifyBootstrap(current) : verifyTarget(current)) else {
            if [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type) {
                lastDown = ["originalScreenQuartz":[event.location.x,event.location.y], "result":"target_changed",
                    "geometryVersion":context?.version ?? 0, "generation":context?.generation ?? 0, "config":context?.config ?? 0, "epoch":context?.epoch ?? 0]
            }
            fail("target_changed"); return isPointer && context?.relative != true ? nil : Unmanaged.passUnretained(event)
        }
        if type == .keyDown || type == .keyUp {
            let code=event.getIntegerValueField(.keyboardEventKeycode)
            if code == 53 && type == .keyDown && event.flags.contains([.maskControl,.maskAlternate]) {
                swallowingEscapeUp=true
                let token=lifecycle
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lifecycle == token, self.active else { return }
                    self.stopped("emergency_exit")
                }
                return nil
            }
            if code == 53 && type == .keyUp && swallowingEscapeUp { swallowingEscapeUp=false; return nil }
            return Unmanaged.passUnretained(event)
        }
        if current.relative { return Unmanaged.passUnretained(event) }
        if current.version == 0 {
            guard isPointer else { return Unmanaged.passUnretained(event) }
            let button=Int(event.getIntegerValueField(.mouseEventButtonNumber))
            let isDown = [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(type)
            let isUp = [.leftMouseUp,.rightMouseUp,.otherMouseUp].contains(type)
            let isDrag = [.leftMouseDragged,.rightMouseDragged,.otherMouseDragged].contains(type)
            if isUp && bootstrapSuppressed.remove(button) != nil { rejected += 1; return nil }
            if isDrag && bootstrapSuppressed.contains(button) { rejected += 1; return nil }
            if isUp && bootstrapOutsideHeld.remove(button) != nil { return Unmanaged.passUnretained(event) }
            if isDrag && bootstrapOutsideHeld.contains(button) { return Unmanaged.passUnretained(event) }
            if isUp && bootstrapControlHeld.remove(button) != nil { return Unmanaged.passUnretained(event) }
            if isDrag && bootstrapControlHeld.contains(button) { return Unmanaged.passUnretained(event) }
            let within = bootstrapOutputQuartz.contains(event.location)
            if !within { if isDown { bootstrapOutsideHeld.insert(button) }; return Unmanaged.passUnretained(event) }
            guard isDown else { rejected += 1; return nil }
            var controlHit = false, hit = 0, elapsed = 0.0
            if bootstrapControlWindowID > 0, let appPoint=P1DisplayMapping.appKitPoint(event.location,displays:current.sourceDisplays) {
                let start=ProcessInfo.processInfo.systemUptime; hit=hitTest(appPoint)
                elapsed=max(0,(ProcessInfo.processInfo.systemUptime-start)*1000); hitQueries &+= 1
                controlHit = hit == bootstrapControlWindowID && verifyBootstrap(current)
            }
            recordHit(controlHit ? "preparing_control" : "preparing_blocked", hit, elapsed, 0)
            lastDown = ["originalScreenQuartz":[event.location.x,event.location.y], "result":controlHit ? "preparing_control" : "preparing_blocked",
                "hitWindow":hit, "durationMS":elapsed, "geometryVersion":0, "generation":current.generation, "config":current.config]
            if controlHit { bootstrapControlHeld.insert(button); return Unmanaged.passUnretained(event) }
            bootstrapSuppressed.insert(button); rejected += 1; return nil
        }
        let button=Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let kind: P1InputRoutingPolicy.Kind
        switch type {
        case .leftMouseDown,.rightMouseDown,.otherMouseDown: kind = .down
        case .leftMouseDragged,.rightMouseDragged,.otherMouseDragged: kind = .drag
        case .leftMouseUp,.rightMouseUp,.otherMouseUp: kind = .up
        case .mouseMoved: kind = .motion
        case .scrollWheel: kind = .scroll
        default: return Unmanaged.passUnretained(event)
        }
        let direct=mapper(event.location,current.version,false)
        guard verifyTarget(current) else { rejected += 1; fail("geometry_invalidated"); return nil }
        if let direct, !P1InputRoutingPolicy.pointOnDisplays(direct, current.sourceDisplays.map(\.quartz)) {
            if kind == .down { lastDown = ["originalScreenQuartz":[event.location.x,event.location.y], "mappedQuartz":[direct.x,direct.y],
                "result":"source_outside_displays", "geometryVersion":current.version, "generation":current.generation, "config":current.config, "epoch":current.epoch] }
            rejected += 1; fail("source_outside_displays"); return nil
        }
        var inside = direct != nil
        if let direct, kind == .down || kind == .motion || kind == .scroll {
            if let appPoint = P1DisplayMapping.appKitPoint(direct, displays: current.sourceDisplays) {
                let started = ProcessInfo.processInfo.systemUptime
                let number = hitTest(appPoint)
                let elapsed = max(0, (ProcessInfo.processInfo.systemUptime-started)*1000)
                hitQueries &+= 1
                inside = number == Int(current.windowID)
                if kind == .down { lastDown = ["originalScreenQuartz":[event.location.x,event.location.y], "mappedQuartz":[direct.x,direct.y],
                    "mappedAppKit":[appPoint.x,appPoint.y], "hitWindow":number, "durationMS":elapsed,
                    "geometryVersion":current.version, "generation":current.generation, "config":current.config, "epoch":current.epoch,
                    "result":inside ? "selected_window" : (number <= 0 ? "no_window" : "different_window")] }
                guard verifyTarget(current) else {
                    rejected += 1; if kind == .down { lastDown["result"] = "target_changed_after_query" }
                    recordHit("target_changed_after_query", number, elapsed, current.version); fail("geometry_invalidated"); return nil
                }
                recordHit(inside ? "selected_window" : (number <= 0 ? "no_window" : "different_window"), number, elapsed, current.version)
            } else { inside = false; recordHit("display_mapping_unknown", 0, 0, current.version)
                if kind == .down { lastDown = ["originalScreenQuartz":[event.location.x,event.location.y],"mappedQuartz":[direct.x,direct.y],"result":"display_mapping_unknown","geometryVersion":current.version,"generation":current.generation,"config":current.config,"epoch":current.epoch] }
            }
        } else if direct == nil && (kind == .down || kind == .motion || kind == .scroll) {
            recordHit("outside_image", 0, 0, current.version)
            if kind == .down { lastDown = ["originalScreenQuartz":[event.location.x,event.location.y],"result":"outside_image","geometryVersion":current.version,"generation":current.generation,"config":current.config,"epoch":current.epoch] }
        }
        let decision=policy.decide(kind,button:button,version:current.version,inside:inside,relative:false)
        switch decision {
        case .pass: return nil // absolute pointer must never escape at its unmapped location
        case .discard: rejected += 1; return nil
        case let .map(version,clamp):
            guard let point=clamp ? mapper(event.location,version,true) : direct, verifyTarget(current) else {
                rejected += 1; fail("geometry_invalidated"); return nil
            }
            guard P1InputRoutingPolicy.pointOnDisplays(point, current.sourceDisplays.map(\.quartz)) else {
                rejected += 1; fail("source_outside_displays"); return nil
            }
            if kind == .down || kind == .drag { lastPoints[button]=point }
            if kind == .up { policy.completeUp(button); lastPoints.removeValue(forKey:button) }
            p1SetEventLocation(event,point); routed += 1
            return Unmanaged.passUnretained(event)
        }
    }
}
