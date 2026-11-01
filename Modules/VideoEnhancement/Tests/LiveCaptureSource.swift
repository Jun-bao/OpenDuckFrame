import AppKit
import QuartzCore
import WebKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

// The half-frame reference is a logical scene sample, not a physical display frame.
enum QualityScene {
    static func valid(_ w: Int, _ h: Int, _ frame: Int) -> Bool {
        w >= 160 && h >= 160 && w <= 4096 && h <= 4096 && w * h <= 4_000_000 && frame >= 0 && frame <= 1_000_000
    }
    static func text(_ value: String, _ x: CGFloat, _ baseline: CGFloat, _ size: CGFloat, _ ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0.95, alpha: 1)]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attrs))
        ctx.saveGState(); ctx.translateBy(x: x, y: baseline); ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero; CTLineDraw(line, ctx); ctx.restoreGState()
    }
    // All coordinates use the same top-left convention for the view and bitmap.
    static func draw(_ ctx: CGContext, _ bounds: CGRect, _ frame: Double) {
        let w = bounds.width, h = bounds.height
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.translateBy(x: bounds.minX, y: bounds.minY)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 1)); ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 1, y: 1, width: w - 2, height: h - 2))
        text("QUALITY SCENE • STATIC HUD • 0123456789", 12, h * 0.07, max(10, min(20, h * 0.035)), ctx)
        let n = Int(frame.rounded(.down)) & 0x00ff_ffff
        let marker = [true, true, false, true, false, false, true, true]
        let payload = (0..<24).map { ((n >> (23 - $0)) & 1) != 0 }
        let bits = marker + payload + payload.map { !$0 } + marker.reversed()
        let left = w * 0.08, width = w * 0.84, top = h * 0.08, height = max(16, h * 0.055)
        ctx.setShouldAntialias(false); ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: left - 4, y: top - 4, width: width + 8, height: height + 8))
        for (i, value) in bits.enumerated() {
            let x0 = left + width * CGFloat(i) / 64, x1 = left + width * CGFloat(i + 1) / 64
            ctx.setFillColor(CGColor(gray: value ? 1 : 0, alpha: 1))
            ctx.fill(CGRect(x: x0, y: top, width: x1 - x0 + 0.1, height: height))
        }
        ctx.setShouldAntialias(true)
        let size = max(12, min(26, h * 0.045))
        for (row, speed) in [0.65, 1.35].enumerated() {
            let y = h * (0.29 + CGFloat(row) * 0.105)
            let phrase = row == 0 ? "Slow: letters 0123456789 / precise edges    " : "Fast: motion punctuation & detail 0123456789    "
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let measured = CTLineCreateWithAttributedString(NSAttributedString(string: phrase,
                attributes: [.init(kCTFontAttributeName as String): font]))
            let period = CGFloat(CTLineGetTypographicBounds(measured, nil, nil, nil))
            let offset = CGFloat(frame * speed).truncatingRemainder(dividingBy: period)
            ctx.saveGState(); ctx.clip(to: CGRect(x: 8, y: y - size * 1.3, width: w - 16, height: size * 1.6))
            var position = 8 - offset
            while position < w { text(phrase, position, y, size, ctx); position += period }
            ctx.restoreGState()
        }
        // Irregular, repeating increments avoid a single-frequency stripe grating.
        ctx.saveGState(); ctx.clip(to: CGRect(x: 8, y: h * 0.48, width: w - 16, height: h * 0.16))
        ctx.setStrokeColor(CGColor(gray: 0.9, alpha: 1)); ctx.setLineWidth(1)
        let gaps: [CGFloat] = [3, 8, 5, 13, 6, 17, 9, 4, 21, 7, 11]
        let shift = CGFloat(frame * 0.9).truncatingRemainder(dividingBy: 104)
        var x: CGFloat = -110 - shift; var index = 0
        while x < w + 20 {
            ctx.move(to: CGPoint(x: x, y: h * 0.49)); ctx.addLine(to: CGPoint(x: x, y: h * 0.63))
            x += gaps[index % gaps.count]; index += 1
        }
        ctx.strokePath(); ctx.restoreGState()
        let objectSize = min(100, h * 0.18), track = max(1, w - objectSize)
        let objectX = CGFloat(frame * 1.1).truncatingRemainder(dividingBy: track)
        ctx.setFillColor(CGColor(red: 1, green: 0.52, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: objectX, y: h * 0.72, width: objectSize, height: objectSize))
        ctx.setFillColor(CGColor(gray: 0.35, alpha: 1)); ctx.fill(CGRect(x: w * 0.55, y: h * 0.68, width: max(6, w * 0.025), height: h * 0.26))
    }
    static func bitmap(_ w: Int, _ h: Int, _ frame: Double) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        draw(ctx, CGRect(x: 0, y: 0, width: w, height: h), frame)
        return ctx.makeImage()
    }
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

// Independent source: displayed sequence and input counts do not use any
// capture/processor counters. CADisplayLink requests are best-effort.
final class SourceView: NSView {
    var frameNumber = 0
    var drawnSequence = 0
    var drawCount = 0
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
    var logInput = false
    var qualityScene = false
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    func recordInput(_ kind: String, _ event: NSEvent) {
        guard logInput, let window else { return }
        let local = convert(event.locationInWindow, from: nil)
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        let polled = NSEvent.mouseLocation
        let isKey = kind == "keyDown" || kind == "keyUp" || kind == "modifiers"
        let isScroll = kind == "scroll"
        let value: [String: Any] = ["kind": kind, "monotonic": CACurrentMediaTime(), "mach": mach_absolute_time(),
            "pid": ProcessInfo.processInfo.processIdentifier, "windowNumber": window.windowNumber,
            "localFlippedPoints": [local.x, local.y], "eventWindowPoints": [event.locationInWindow.x, event.locationInWindow.y],
            "eventAppKitScreenPoints": [screen.x, screen.y], "polledAppKitScreenPoints": [polled.x, polled.y],
            "button": (!isKey && !isScroll) ? event.buttonNumber : -1,
            "clickCount": (!isKey && !isScroll) ? event.clickCount : 0, "modifiers": event.modifierFlags.rawValue,
            "delta": !isKey ? [event.deltaX, event.deltaY] : [],
            "scrollDelta": isScroll ? [event.scrollingDeltaX, event.scrollingDeltaY] : [],
            "preciseScroll": isScroll && event.hasPreciseScrollingDeltas, "phase": isScroll ? event.phase.rawValue : 0,
            "momentumPhase": isScroll ? event.momentumPhase.rawValue : 0,
            "keyCode": (kind == "keyDown" || kind == "keyUp") ? Int(event.keyCode) : -1]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print("sourceInput \(json)"); fflush(stdout) }
    }
    override func mouseDown(with event: NSEvent) { recordInput("down", event); clickCount += 1; window?.makeFirstResponder(self); needsDisplay = true }
    override func mouseUp(with event: NSEvent) { recordInput("up", event) }
    override func mouseDragged(with event: NSEvent) { recordInput("drag", event); dragCount += 1; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) { recordInput("move", event) }
    override func rightMouseDown(with event: NSEvent) { recordInput("rightDown", event) }
    override func rightMouseUp(with event: NSEvent) { recordInput("rightUp", event) }
    override func rightMouseDragged(with event: NSEvent) { recordInput("rightDrag", event) }
    override func otherMouseDown(with event: NSEvent) { recordInput("otherDown", event) }
    override func otherMouseUp(with event: NSEvent) { recordInput("otherUp", event) }
    override func otherMouseDragged(with event: NSEvent) { recordInput("otherDrag", event) }
    override func scrollWheel(with event: NSEvent) { recordInput("scroll", event); scrollCount += 1; needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        recordInput("keyDown", event)
        keyCount += 1
        if event.charactersIgnoringModifiers == "6" { setRate(60) }
        if event.charactersIgnoringModifiers == "1" { setRate(120) }
        needsDisplay = true
    }
    override func keyUp(with event: NSEvent) { recordInput("keyUp", event) }
    override func flagsChanged(with event: NSEvent) { recordInput("modifiers", event) }
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
        print(String(format: "source=native monotonic=%.3f appActive=%@ windowVisible=%@ callbackSequence=%d drawnSequence=%d drawCount=%d requested=%d callbackHz=%.2f drawHz=%.2f lastCallbackAgeMs=%.1f lastDrawAgeMs=%.1f clicks=%d scrolls=%d drags=%d keys=%d", now, String(NSApp.isActive), String(window?.occlusionState.contains(.visible) ?? false), frameNumber, drawnSequence, drawCount, targetFPS, rate(callbacks), rate(draws), callbackAge, drawAge, clickCount, scrollCount, dragCount, keyCount))
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
        drawnSequence = frameNumber
        drawCount += 1
        if qualityScene, let context = NSGraphicsContext.current?.cgContext {
            QualityScene.draw(context, bounds, Double(drawnSequence))
            print(String(format: "sourceDraw qualityScene=true monotonic=%.9f mach=%llu callbackSequence=%d drawnSequence=%d encodedSequence=%d drawCount=%d contentPoints=%.1fx%.1f", now, mach_absolute_time(), frameNumber, drawnSequence, drawnSequence & 0x00ff_ffff, drawCount, bounds.width, bounds.height))
            return
        }
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill(); bounds.fill()
        let x = CGFloat(frameNumber % max(1, Int(bounds.width - 120)))
        NSColor.systemOrange.setFill(); NSRect(x: x, y: bounds.height * 0.38, width: 100, height: 100).fill()
        let text = String(format: "FRAME %08d  TIME %.3f s\nSCROLL %d   CLICK %d   DRAG %d   KEY %d\nREQUEST %d Hz   CALLBACK %.1f Hz   DRAW %.1f Hz\nKEY 6: 60 Hz   KEY 1: 120 Hz", frameNumber, now-started, scrollCount, clickCount, dragCount, keyCount, targetFPS, rate(callbacks), rate(draws))
        text.draw(at: NSPoint(x: 36, y: bounds.height * 0.20), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 30, weight: .bold), .foregroundColor: NSColor.white])
        // 64 high-contrast cells: 8-bit marker, 24-bit draw sequence,
        // its complement, 8-bit marker. Coordinates are normalized to the
        // native content rectangle; decoder verifies markers and complement.
        let marker: [Bool] = [true, true, false, true, false, false, true, true]
        let payload = (0..<24).map { bit in ((drawnSequence >> (23 - bit)) & 1) != 0 }
        let bits = marker + payload + payload.map { !$0 } + marker.reversed()
        let left = bounds.width * 0.08, width = bounds.width * 0.84
        let top = bounds.height * 0.08, height = max(16, bounds.height * 0.055)
        NSGraphicsContext.current?.shouldAntialias = false
        NSColor.black.setFill()
        NSRect(x: left - 4, y: top - 4, width: width + 8, height: height + 8).fill()
        for (index, value) in bits.enumerated() {
            (value ? NSColor.white : NSColor.black).setFill()
            let x0 = left + width * CGFloat(index) / 64
            let x1 = left + width * CGFloat(index + 1) / 64
            NSRect(x: x0, y: top, width: x1 - x0 + 0.1, height: height).fill()
        }
        NSGraphicsContext.current?.shouldAntialias = true
        // Draw callback is not proof of window-server or display presentation.
        print(String(format: "sourceDraw monotonic=%.9f mach=%llu callbackSequence=%d drawnSequence=%d encodedSequence=%d drawCount=%d contentPoints=%.1fx%.1f",
                     now, mach_absolute_time(), frameNumber, drawnSequence, drawnSequence & 0x00ff_ffff,
                     drawCount, bounds.width, bounds.height))
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
    static func qualitySelfTest() {
        guard QualityScene.valid(640, 480, 42), !QualityScene.valid(159, 480, 42),
              !QualityScene.valid(4096, 4096, 42), !QualityScene.valid(640, 480, -1),
              let a = QualityScene.bitmap(640, 480, 42).flatMap(QualityScene.png),
              let again = QualityScene.bitmap(640, 480, 42).flatMap(QualityScene.png),
              let mid = QualityScene.bitmap(640, 480, 42.5).flatMap(QualityScene.png),
              let b = QualityScene.bitmap(640, 480, 43).flatMap(QualityScene.png),
              a == again, a != mid, mid != b, a != b else {
            fputs("quality self-test failed\n", stderr); exit(1)
        }
        print("quality-self-test=pass width=640 height=480 logicalFrames=42,42.5,43 deterministic=true no-window=true")
    }
    static func qualityExport(_ args: [String]) {
        func value(_ flag: String) -> String? {
            let indices = args.indices.filter { args[$0] == flag }
            guard indices.count == 1, let i = indices.first, i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let allowed = ["--quality-scene", "--quality-export", "--quality-width", "--quality-height", "--quality-frame"]
        guard args.count == 10, args.filter({ $0 == "--quality-scene" }).count == 1,
              args.dropFirst().filter({ $0.hasPrefix("--") }).allSatisfy({ allowed.contains($0) }),
              args.contains("--quality-scene"), let directory = value("--quality-export"),
              directory.hasPrefix("/"), let ws = value("--quality-width"), let w = Int(ws),
              let hs = value("--quality-height"), let h = Int(hs),
              let fs = value("--quality-frame"), let frame = Int(fs), QualityScene.valid(w, h, frame) else {
            fputs("usage: --quality-scene --quality-export ABS_EXISTING_DIR --quality-width W --quality-height H --quality-frame N\n", stderr); exit(2)
        }
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            fputs("export directory must already exist\n", stderr); exit(2)
        }
        let names = ["A.png", "midpoint.png", "B.png", "manifest.json"]
        guard names.allSatisfy({ !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) else {
            fputs("refusing to overwrite reference files\n", stderr); exit(2)
        }
        let frames = [Double(frame), Double(frame) + 0.5, Double(frame) + 1]
        do {
            let data = try frames.map { f -> Data in
                guard let image = QualityScene.bitmap(w, h, f), let bytes = QualityScene.png(image) else { throw NSError(domain: "quality.bitmap", code: 1) }
                return bytes
            }
            let manifest: [String: Any] = ["width": w, "height": h, "logicalFrames": frames, "files": Array(names.prefix(3)),
                "scope": "same scene function, logical references only; not captured pixels or physical display timing"]
            let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            for i in 0..<3 { try data[i].write(to: dir.appendingPathComponent(names[i]), options: .withoutOverwriting) }
            try json.write(to: dir.appendingPathComponent(names[3]), options: .withoutOverwriting)
            print("quality-export=success directory=\(directory) logicalFrames=\(frames)")
        } catch { fputs("quality export failed: \(error)\n", stderr); exit(1) }
    }
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--quality-self-test") {
            guard args.count == 2 else { fputs("self-test takes no additional options\n", stderr); exit(2) }
            qualitySelfTest(); return
        }
        if args.contains("--quality-export") { qualityExport(args); return }
        if args.contains("--quality-scene") {
            guard args.filter({ $0 == "--quality-scene" }).count == 1, !args.contains("--web") else {
                fputs("quality scene requires a single native source flag\n", stderr); exit(2)
            }
            for option in ["--width-points", "--height-points", "--fps"] {
                let positions = args.indices.filter { args[$0] == option }
                if positions.isEmpty { continue }
                guard positions.count == 1, let i = positions.first, i + 1 < args.count,
                      let value = Double(args[i + 1]), value.isFinite,
                      option == "--fps" ? (value == 60 || value == 120) : (value >= 160 && value <= 8192) else {
                    fputs("invalid quality source parameter: \(option)\n", stderr); exit(2)
                }
            }
        }
        if args.contains(where: { $0.hasPrefix("--quality-") && $0 != "--quality-scene" }) {
            fputs("invalid quality option\n", stderr); exit(2)
        }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        func dimension(_ option: String, fallback: CGFloat) -> CGFloat {
            guard let i = args.firstIndex(of: option), i + 1 < args.count,
                  let n = Double(args[i + 1]), n.isFinite, n >= 160, n <= 8192 else { return fallback }
            return CGFloat(n)
        }
        let frame = NSRect(x: 0, y: 0, width: dimension("--width-points", fallback: 2560 / scale),
                           height: dimension("--height-points", fallback: 1440 / scale))
        let view = SourceView(frame: frame)
        view.logInput = args.contains("--input-events")
        view.qualityScene = args.contains("--quality-scene")
        if let index = args.firstIndex(of: "--fps"), index + 1 < args.count, let fps = Int(args[index + 1]), [60, 120].contains(fps) { view.targetFPS = fps }
        let web = args.contains("--web") ? WebSource(frame: frame) : nil
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = web == nil ? "Khua Controlled 1440p Source" : "Khua WebKit 1440p Source"
        window.contentView = web?.view ?? view
        window.acceptsMouseMovedEvents = view.logInput
        window.center(); window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web?.view ?? view); app.activate(ignoringOtherApps: true)
        if web == nil { view.startDisplayLink() }
        let heartbeat = Timer(timeInterval: 1, repeats: true) { _ in
            if let web { web.reportHeartbeat() } else { view.reportHeartbeat() }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        print("source pid=\(ProcessInfo.processInfo.processIdentifier) mode=\(web == nil ? "native" : "web") backingScale=\(scale) requestedContentPoints=\(frame.width)x\(frame.height) inputEvents=\(view.logInput); callback and draw are not physical presentation; actual window size and content rate must be verified")
        fflush(stdout)
        app.run()
    }
}
