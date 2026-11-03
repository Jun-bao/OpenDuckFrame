import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

@main struct CaptureResizePolicyTests {
    typealias Size = CaptureResizePolicy.Size
    static func rect(_ w: Double, _ h: Double) -> CGRect { CGRect(x: 0, y: 30, width: w, height: h) }
    static let content = CGRect(x: 0, y: 0, width: 2560, height: 1200)
    static func target(_ w: Double, _ h: Double, _ scale: Double = 1) -> Size? {
        CaptureResizePolicy.target(screenRect: rect(w,h), contentRect: content, scaleFactor: scale)
    }
    static func main() {
        // Window generation accumulated activity, then switching to display
        // creates a new generation: no old resize counters may leak.
        var counters = CaptureResizeCounters()
        counters.reset(generation: 1); counters.requested = 3; counters.completed = 2; counters.failed = 1; counters.confirmed = 2
        counters.reset(generation: 2)
        precondition(counters.generation == 2 && counters.requested == 0 && counters.completed == 0 && counters.failed == 0 && counters.confirmed == 0)
        let full = Size(width: 2560, height: 1410), small = Size(width: 2000, height: 1100)
        precondition(target(2560,1410) == full) // Content is shorter: never derive target from contentRect.
        precondition(target(1280,705,2) == full)
        precondition(target(2560,1411) == full)
        precondition(target(.infinity,1410) == nil && target(2560,.nan) == nil && target(2560,1410,0) == nil)
        precondition(target(1,1) == nil)
        precondition(CaptureResizePolicy.target(screenRect: rect(2560,1410), contentRect: CGRect(x:0,y:0,width:Double.nan,height:1200),scaleFactor:1) == nil)
        var same = CaptureResizePolicy(generation: 1, configured: full)
        same.observe(screenRect: rect(2560,1411), contentRect: content, scaleFactor: 1, nowNs: 0)
        precondition(same.tick(nowNs: 1_000_000_000, running: true) == nil)
        var continuous = CaptureResizePolicy(generation: 1, configured: full)
        for i in 0...187 {
            continuous.observe(screenRect: rect(Double(2400-i*2),1100), contentRect: content, scaleFactor: 1, nowNs: Int64(i)*16_000_000)
            precondition(continuous.tick(nowNs: Int64(i)*16_000_000, running: true) == nil)
        }
        let finish: Int64 = 187 * 16_000_000
        precondition(continuous.tick(nowNs: finish + 299_000_000, running: true) == nil)
        let first = continuous.tick(nowNs: finish + 300_000_000, running: true)!
        precondition(first.size == target(Double(2400-187*2),1100))
        precondition(continuous.tick(nowNs: finish + 1_000_000_000, running: true) == nil)
        var pending = CaptureResizePolicy(generation: 1, configured: full)
        pending.observe(screenRect: rect(2000,1100), contentRect: content, scaleFactor:1, nowNs: 0)
        precondition(pending.tick(nowNs: 300_000_000, running: false) == nil)
        let job = pending.tick(nowNs: 300_000_000, running: true)!
        precondition(job.size == small)
        pending.observe(screenRect: rect(2200,1200), contentRect: content, scaleFactor:1, nowNs: 400_000_000)
        precondition(pending.tick(nowNs: 800_000_000, running: true) == nil)
        pending.complete(job, success: true, nowNs: 900_000_000)
        precondition(pending.tick(nowNs: 1_199_999_999, running: true) == nil)
        let latest = pending.tick(nowNs: 1_200_000_000, running: true)!
        precondition(latest.size == Size(width:2200,height:1200))
        pending.complete(latest, success: false, nowNs: 1_300_000_000)
        precondition(pending.tick(nowNs: 9_000_000_000, running: true) == nil)
        pending.observe(screenRect: rect(2100,1150), contentRect: content, scaleFactor:1, nowNs: 10_000_000_000)
        let retry = pending.tick(nowNs: 10_300_000_000, running: true)!
        pending.reset(generation: 2, configured: full)
        pending.complete(retry, success: true, nowNs: 11_000_000_000)
        precondition(pending.configured == full && pending.tick(nowNs: 12_000_000_000, running: true) == nil)
        for biplanar in [false,true] {
            for cap in [0,30,60] {
                let cfg = CaptureStreamConfiguration.make(width: 2560, height: 1410, biplanar: biplanar, capFPS: cap)
                precondition(cfg.width == 2560 && cfg.height == 1410)
                precondition(cfg.pixelFormat == (biplanar ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA))
                precondition(cfg.queueDepth == 3 && !cfg.showsCursor && !cfg.capturesAudio && !cfg.scalesToFit)
                precondition(CMTimeCompare(cfg.minimumFrameInterval, cap == 0 ? .zero : CMTime(value:1,timescale:CMTimeScale(cap))) == 0)
                precondition(cfg.colorMatrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2 && cfg.colorSpaceName == CGColorSpace.itur_709)
            }
        }
        print("CaptureResizePolicy: dimensions, debounce, in-flight, failures, generations and stream configuration pass")
    }
}
