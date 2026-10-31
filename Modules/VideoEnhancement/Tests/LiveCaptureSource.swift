import AppKit
import QuartzCore
import WebKit

// Independent source: displayed sequence and input counts do not use any
// capture/processor counters. CADisplayLink requests are best-effort.
final class SourceView: NSView {
    var frameNumber = 0
    var scrollCount = 0
    var clickCount = 0
    var dragCount = 0
    var keyCount = 0
    var targetFPS = 120
    var started = CACurrentMediaTime()
    var callbacks: [CFTimeInterval] = []
    var draws: [CFTimeInterval] = []
    var link: CADisplayLink?
    var lastCallback: CFTimeInterval = 0
    var lastDraw: CFTimeInterval = 0
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { clickCount += 1; window?.makeFirstResponder(self); needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { dragCount += 1; needsDisplay = true }
    override func scrollWheel(with event: NSEvent) { scrollCount += 1; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        keyCount += 1
        if event.charactersIgnoringModifiers == "6" { setRate(60) }
        if event.charactersIgnoringModifiers == "1" { setRate(120) }
        needsDisplay = true
    }
    func setRate(_ fps: Int) {
        targetFPS = fps
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
        callbacks.removeAll(); draws.removeAll()
        print("requestedDisplayLinkHz=\(fps); measured callbacks and draw calls are not physical display proof")
        fflush(stdout)
    }
    func startDisplayLink() {
        let value = displayLink(target: self, selector: #selector(tick(_:)))
        link = value
        setRate(targetFPS)
        value.add(to: .main, forMode: .common)
    }
    @objc func tick(_ displayLink: CADisplayLink) {
        let now = CACurrentMediaTime()
        lastCallback = now
        callbacks.append(now)
        callbacks.removeAll { now - $0 > 2 }
        frameNumber += 1
        needsDisplay = true
    }
    func reportHeartbeat() {
        let now = CACurrentMediaTime()
        callbacks.removeAll { now - $0 > 2 }; draws.removeAll { now - $0 > 2 }
        let callbackAge = lastCallback > 0 ? (now-lastCallback)*1000 : -1
        let drawAge = lastDraw > 0 ? (now-lastDraw)*1000 : -1
        print(String(format: "source=native monotonic=%.3f appActive=%@ windowVisible=%@ sequence=%d requested=%d callbackHz=%.2f drawHz=%.2f lastCallbackAgeMs=%.1f lastDrawAgeMs=%.1f clicks=%d scrolls=%d drags=%d keys=%d", now, String(NSApp.isActive), String(window?.occlusionState.contains(.visible) ?? false), frameNumber, targetFPS, rate(callbacks), rate(draws), callbackAge, drawAge, clickCount, scrollCount, dragCount, keyCount))
        fflush(stdout)
    }
    func rate(_ values: [CFTimeInterval]) -> Double {
        guard values.count > 1, let first = values.first, let last = values.last, last > first else { return 0 }
        return Double(values.count - 1) / (last - first)
    }
    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime()
        lastDraw = now
        draws.append(now); draws.removeAll { now - $0 > 2 }
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill(); bounds.fill()
        let x = CGFloat(frameNumber % max(1, Int(bounds.width - 120)))
        NSColor.systemOrange.setFill(); NSRect(x: x, y: bounds.height * 0.38, width: 100, height: 100).fill()
        let text = String(format: "FRAME %08d  TIME %.3f s\nSCROLL %d   CLICK %d   DRAG %d   KEY %d\nREQUEST %d Hz   CALLBACK %.1f Hz   DRAW %.1f Hz\nKEY 6: 60 Hz   KEY 1: 120 Hz", frameNumber, now-started, scrollCount, clickCount, dragCount, keyCount, targetFPS, rate(callbacks), rate(draws))
        text.draw(at: NSPoint(x: 36, y: bounds.height - 230), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.white])
    }
}

// The WebKit source is deliberately driven only by the page's own RAF.
// Native heartbeats remain independent when WebKit stops responding.
final class WebSource {
    let view: WKWebView
    var evaluationPending = false
    var evaluationStarted: CFTimeInterval = 0
    var lastReply: CFTimeInterval = 0
    var lastSequenceChange: CFTimeInterval = 0
    var lastSequence: Int = -1

    init(frame: NSRect) {
        view = WKWebView(frame: frame)
        view.loadHTMLString(Self.html, baseURL: nil)
    }

    func reportHeartbeat() {
        let now = CACurrentMediaTime()
        let pendingAge = evaluationPending ? (now - evaluationStarted) * 1000 : -1
        let replyAge = lastReply > 0 ? (now - lastReply) * 1000 : -1
        let sequenceAge = lastSequenceChange > 0 ? (now - lastSequenceChange) * 1000 : -1
        print(String(format: "source=web monotonic=%.3f appActive=%@ windowVisible=%@ jsPending=%@ jsPendingAgeMs=%.1f jsReplyAgeMs=%.1f lastRAFSequence=%d sequenceUnchangedMs=%.1f", now, String(NSApp.isActive), String(view.window?.occlusionState.contains(.visible) ?? false), String(evaluationPending), pendingAge, replyAge, lastSequence, sequenceAge))
        fflush(stdout)
        guard !evaluationPending else { return }
        evaluationPending = true
        evaluationStarted = now
        view.evaluateJavaScript("window.fixtureSnapshot ? window.fixtureSnapshot() : null") { [weak self] result, error in
            guard let self else { return }
            let received = CACurrentMediaTime()
            self.evaluationPending = false
            self.lastReply = received
            if let snapshot = result as? [String: Any], let sequence = (snapshot["rafSequence"] as? NSNumber)?.intValue {
                if sequence != self.lastSequence { self.lastSequenceChange = received }
                self.lastSequence = sequence
                if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) {
                    print(String(format: "webReply monotonic=%.3f data=%@", received, json))
                }
            } else {
                print(String(format: "webReply monotonic=%.3f error=%@", received, error?.localizedDescription ?? "snapshot unavailable"))
            }
            fflush(stdout)
        }
    }

    static let html = #"""
    <!doctype html><html><head><meta charset="utf-8"><style>
    * { box-sizing: border-box; } body { margin: 0; background: #171b24; color: white; font: 24px ui-monospace, monospace; }
    header { position: sticky; top: 0; z-index: 2; background: #111c; padding: 20px 30px; }
    #frame { font-weight: bold; font-size: 46px; } #status { line-height: 1.5; }
    #track { height: 160px; position: relative; background: #303949; overflow: hidden; }
    #moving { position: absolute; top: 25px; width: 110px; height: 110px; background: #ff962d; }
    main { padding: 24px 30px; min-height: 2300px; background: repeating-linear-gradient(#202737, #202737 90px, #334057 90px, #334057 180px); }
    </style></head><body tabindex="0"><header><div id="frame">Waiting for RAF</div><div id="status"></div></header>
    <div id="track"><div id="moving"></div></div><main>Click, scroll, drag and type in this page. Scroll down to test a moving WebKit source.</main>
    <script>
    let seq=0, clicks=0, scrolls=0, drags=0, keys=0, down=false, lastRaf=0, samples=[];
    const frame=document.getElementById('frame'), status=document.getElementById('status'), moving=document.getElementById('moving');
    document.addEventListener('click',()=>clicks++);
    document.addEventListener('pointerdown',()=>down=true);
    document.addEventListener('pointerup',()=>down=false);
    document.addEventListener('pointercancel',()=>down=false);
    document.addEventListener('pointermove',()=>{if(down) drags++});
    document.addEventListener('scroll',()=>scrolls++, {passive:true});
    document.addEventListener('keydown',()=>keys++);
    function hz() { return samples.length>1 ? (samples.length-1)*1000/(samples[samples.length-1]-samples[0]) : 0; }
    function tick(t) {
      seq++; lastRaf=t; samples.push(t); while(samples.length && t-samples[0]>2000) samples.shift();
      frame.textContent=`RAF ${String(seq).padStart(8,'0')}  TIME ${(t/1000).toFixed(3)} s`;
      status.textContent=`VISIBILITY ${document.visibilityState}   MEASURED RAF ${hz().toFixed(1)} Hz   CLICK ${clicks}   SCROLL ${scrolls}   DRAG ${drags}   KEY ${keys}`;
      moving.style.transform=`translateX(${seq % Math.max(1, document.getElementById('track').clientWidth-110)}px)`;
      requestAnimationFrame(tick);
    }
    window.fixtureSnapshot=()=>({rafSequence:seq, rafAgeMs:lastRaf ? performance.now()-lastRaf : -1, measuredRAFHz:hz(), pageMonotonicSeconds:performance.now()/1000, visibility:document.visibilityState, clicks, scrolls, drags, keys});
    requestAnimationFrame(tick);
    </script></body></html>
    """#
}
@main struct LiveCaptureSource {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        let args = CommandLine.arguments
        let frame = NSRect(x: 0, y: 0, width: 2560 / scale, height: 1440 / scale)
        let view = SourceView(frame: frame)
        if let index = args.firstIndex(of: "--fps"), index + 1 < args.count, let fps = Int(args[index + 1]), [60, 120].contains(fps) { view.targetFPS = fps }
        let web = args.contains("--web") ? WebSource(frame: frame) : nil
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = web == nil ? "Khua Controlled 1440p Source" : "Khua WebKit 1440p Source"
        window.contentView = web?.view ?? view
        window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web?.view ?? view); app.activate(ignoringOtherApps: true)
        if web == nil { view.startDisplayLink() }
        let heartbeat = Timer(timeInterval: 1, repeats: true) { _ in
            if let web { web.reportHeartbeat() } else { view.reportHeartbeat() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        print("source pid=\(ProcessInfo.processInfo.processIdentifier) mode=\(web == nil ? "native" : "web") backingScale=\(scale) requestedContentPixels=2560x1440; actual window size and draw rate must be verified")
        fflush(stdout)
        app.run()
    }
}
