import Foundation
import CoreVideo

// Serialized by the capture queue. The borrowed surface is read only during
// evaluate; no CVPixelBuffer or full frame is retained after it returns.
final class ContentFrameGate {
    enum Decision { case accepted, duplicate, forced, unavailable }
    private var generation: UInt64?
    private var width = 0, height = 0
    private var format: OSType = 0
    private var coordinates: [(x: Int, y: Int)] = []
    private var previous: [UInt8] = []
    private var lastAcceptedNs: Int64?
    private var distinctTimes: [Int64] = []
    private var elapsedNs: [UInt64] = []
    private var accepted = 0, duplicates = 0, forced = 0, unavailable = 0
    private var buckets = [0, 0, 0, 0, 0]
    private var timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t(); mach_timebase_info(&value); return value
    }()

    static func sampleCoordinates(width: Int, height: Int) -> [(x: Int, y: Int)] {
        guard width > 0, height > 0 else { return [] }
        let columns = min(width, max(1, Int((8000.0 * Double(width) / Double(height)).squareRoot().rounded())))
        let rows = min(height, max(1, Int((8000.0 / Double(columns)).rounded())))
        var points: [(x: Int, y: Int)] = []; points.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y = (2 * row + 1) * height / (2 * rows)
            for column in 0..<columns { points.append(((2 * column + 1) * width / (2 * columns), y)) }
        }
        return points
    }

    func evaluate(buffer: CVPixelBuffer, generation nextGeneration: UInt64, hostNs: Int64) -> Decision {
        let start = mach_absolute_time()
        defer {
            let delta = mach_absolute_time() - start
            elapsedNs.append(delta * UInt64(timebase.numer) / UInt64(max(1, timebase.denom)))
            if elapsedNs.count > 256 { elapsedNs.removeFirst(elapsedNs.count - 256) }
        }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let f = CVPixelBufferGetPixelFormatType(buffer)
        if generation != nextGeneration || width != w || height != h || format != f {
            generation = nextGeneration; width = w; height = h; format = f
            coordinates = Self.sampleCoordinates(width: w, height: h)
            previous.removeAll(keepingCapacity: true); lastAcceptedNs = nil
            distinctTimes.removeAll(keepingCapacity: true)
            accepted = 0; duplicates = 0; forced = 0; unavailable = 0; buckets = [0, 0, 0, 0, 0]
            elapsedNs.removeAll(keepingCapacity: true)
        }
        let planar = f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard (planar || f == kCVPixelFormatType_32BGRA), !coordinates.isEmpty,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            unavailable += 1; return .unavailable
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer),
              !planar || CVPixelBufferGetPlaneCount(buffer) >= 2 else { unavailable += 1; return .unavailable }
        let chroma = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) : nil
        guard !planar || chroma != nil else { unavailable += 1; return .unavailable }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let chromaStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) : 0
        var values = [UInt8](repeating: 0, count: coordinates.count * 3)
        var changes = 0
        coordinates.withUnsafeBufferPointer { points in
            previous.withUnsafeBufferPointer { prior in
                values.withUnsafeMutableBufferPointer { output in
                    guard let pointBase = points.baseAddress, let out = output.baseAddress else { return }
                    let old = prior.count == output.count ? prior.baseAddress : nil
                    var index = 0
                    while index < points.count {
                        let point = pointBase.advanced(by: index).pointee
                        let a: UInt8, b: UInt8, c: UInt8
                        if planar {
                            let uv = (point.y / 2) * chromaStride + (point.x / 2) * 2
                            a = bytes.advanced(by: point.y * stride + point.x).pointee >> 2
                            b = chroma!.advanced(by: uv).pointee >> 2
                            c = chroma!.advanced(by: uv + 1).pointee >> 2
                        } else {
                            let p = bytes.advanced(by: point.y * stride + point.x * 4)
                            a = p.pointee >> 2; b = p.advanced(by: 1).pointee >> 2; c = p.advanced(by: 2).pointee >> 2
                        }
                        let offset = index * 3
                        if let old, old.advanced(by: offset).pointee != a || old.advanced(by: offset + 1).pointee != b || old.advanced(by: offset + 2).pointee != c { changes += 1 }
                        out.advanced(by: offset).pointee = a
                        out.advanced(by: offset + 1).pointee = b
                        out.advanced(by: offset + 2).pointee = c
                        index += 1
                    }
                }
            }
        }
        prune(nowNs: hostNs)
        guard !previous.isEmpty else {
            previous = values; lastAcceptedNs = hostNs; accepted += 1
            if hostNs > 0 { distinctTimes.append(hostNs) }
            return .accepted
        }
        let ratio = Double(changes) / Double(coordinates.count)
        let bucket = changes == 0 ? 0 : (ratio < 0.001 ? 1 : (ratio < 0.01 ? 2 : (ratio < 0.1 ? 3 : 4)))
        buckets[bucket] += 1
        if changes > 0 {
            previous = values; lastAcceptedNs = hostNs; accepted += 1
            if hostNs > 0 { distinctTimes.append(hostNs) }
            return .accepted
        }
        if let last = lastAcceptedNs, hostNs > last, hostNs - last > 250_000_000 {
            previous = values; lastAcceptedNs = hostNs; accepted += 1; forced += 1
            return .forced
        }
        duplicates += 1; return .duplicate
    }
    private func prune(nowNs: Int64) {
        if nowNs > 0 { distinctTimes.removeAll { $0 > nowNs || nowNs - $0 > 2_000_000_000 } }
    }
    func diagnostics(nowNs: Int64, expectedGeneration: UInt64? = nil) -> [String: Any] {
        if let expectedGeneration, generation != expectedGeneration {
            return ["contentAccepted": 0, "contentDuplicates": 0, "contentForced": 0,
                    "contentDistinctFPS": 0.0, "contentFingerprintP95Ms": -1.0, "contentUnavailable": 0,
                    "contentChangeRatioBuckets": ["0": 0, "lt0.1pct": 0, "lt1pct": 0, "lt10pct": 0, "ge10pct": 0]]
        }
        prune(nowNs: nowNs)
        let span = (distinctTimes.last ?? 0) - (distinctTimes.first ?? 0)
        let fps = distinctTimes.count > 1 && span > 0 ? Double(distinctTimes.count - 1) * 1e9 / Double(span) : 0
        let times = elapsedNs.sorted()
        let p95 = times.isEmpty ? -1 : Double(times[(times.count - 1) * 95 / 100]) / 1e6
        return ["contentAccepted": accepted, "contentDuplicates": duplicates, "contentForced": forced,
                "contentDistinctFPS": fps, "contentFingerprintP95Ms": p95, "contentUnavailable": unavailable,
                "contentChangeRatioBuckets": ["0": buckets[0], "lt0.1pct": buckets[1], "lt1pct": buckets[2], "lt10pct": buckets[3], "ge10pct": buckets[4]]]
    }
}
