import Foundation
import CoreGraphics
import CoreVideo
@preconcurrency import ScreenCaptureKit

enum CaptureStreamConfiguration {
    static func make(width: Int, height: Int, biplanar: Bool, capFPS: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = width; c.height = height
        c.pixelFormat = biplanar ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        c.queueDepth = 3
        CaptureRatePolicy.configure(c, capFPS: capFPS)
        c.showsCursor = false; c.capturesAudio = false
        c.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        c.colorSpaceName = CGColorSpace.itur_709
        return c
    }
}

// Counters belong to one source generation, including display sources.
struct CaptureResizeCounters {
    private(set) var generation: UInt64 = 0
    var requested = 0, completed = 0, failed = 0, confirmed = 0
    mutating func reset(generation: UInt64) {
        self.generation = generation; requested = 0; completed = 0; failed = 0; confirmed = 0
    }
}

// Pure state machine; caller owns time, stream lifetime and timer.
struct CaptureResizePolicy {
    struct Size: Equatable, Sendable { let width: Int; let height: Int }
    struct Request: Equatable, Sendable { let size: Size; let generation: UInt64; let token: UInt64 }
    private(set) var generation: UInt64
    private(set) var configured: Size
    private(set) var candidate: Size?
    private(set) var candidateSince: Int64 = 0
    private(set) var inFlight: Request?
    private var failedTarget: Size?
    private var token: UInt64 = 0
    static let quietNs: Int64 = 300_000_000
    init(generation: UInt64, configured: Size) { self.generation = generation; self.configured = configured }
    static func target(screenRect: CGRect, contentRect: CGRect, scaleFactor: Double) -> Size? {
        let all = [screenRect.origin.x, screenRect.origin.y, screenRect.width, screenRect.height,
                   contentRect.origin.x, contentRect.origin.y, contentRect.width, contentRect.height, scaleFactor]
        guard all.allSatisfy({ $0.isFinite }), screenRect.width > 0, screenRect.height > 0,
              contentRect.width > 0, contentRect.height > 0, scaleFactor > 0 else { return nil }
        let w = (screenRect.width * scaleFactor).rounded(), h = (screenRect.height * scaleFactor).rounded()
        guard w.isFinite, h.isFinite, w >= 2, h >= 2, w < Double(Int.max), h < Double(Int.max) else { return nil }
        let width = Int(w) & ~1, height = Int(h) & ~1
        guard width >= 2, height >= 2 else { return nil }
        return Size(width: width, height: height)
    }
    mutating func observe(screenRect: CGRect, contentRect: CGRect, scaleFactor: Double, nowNs: Int64) {
        guard let size = Self.target(screenRect: screenRect, contentRect: contentRect, scaleFactor: scaleFactor) else { return }
        observe(size, nowNs: nowNs)
    }
    mutating func observe(_ size: Size, nowNs: Int64) {
        guard candidate != size else { return }
        candidate = size; candidateSince = nowNs
        if failedTarget != size { failedTarget = nil }
        if inFlight == nil && size == configured { candidate = nil }
    }
    mutating func tick(nowNs: Int64, running: Bool) -> Request? {
        guard running, inFlight == nil, let size = candidate, size != configured, size != failedTarget,
              nowNs >= candidateSince, nowNs - candidateSince >= Self.quietNs else { return nil }
        token &+= 1
        let request = Request(size: size, generation: generation, token: token); inFlight = request
        return request
    }
    mutating func complete(_ request: Request, success: Bool, nowNs: Int64) {
        guard request.generation == generation, inFlight == request else { return }
        inFlight = nil
        if success { configured = request.size; failedTarget = nil }
        else { failedTarget = request.size }
        if candidate == configured { candidate = nil }
        else if candidate != request.size { candidateSince = nowNs }
    }
    mutating func reset(generation: UInt64, configured: Size) {
        self.generation = generation; self.configured = configured
        candidate = nil; inFlight = nil; failedTarget = nil; candidateSince = 0; token &+= 1
    }
}
