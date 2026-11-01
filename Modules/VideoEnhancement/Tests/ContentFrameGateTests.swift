import Foundation
import CoreVideo

@main struct ContentFrameGateTests {
    static func buffer(_ width: Int, _ height: Int, _ format: OSType, _ value: UInt8) -> CVPixelBuffer {
        var image: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess)
        let b = image!; CVPixelBufferLockBaseAddress(b, [])
        if CVPixelBufferIsPlanar(b) {
            for plane in 0..<CVPixelBufferGetPlaneCount(b) {
                let p = CVPixelBufferGetBaseAddressOfPlane(b, plane)!
                memset(p, plane == 0 ? Int32(value) : 128, CVPixelBufferGetBytesPerRowOfPlane(b, plane) * CVPixelBufferGetHeightOfPlane(b, plane))
            }
        } else {
            memset(CVPixelBufferGetBaseAddress(b)!, Int32(value), CVPixelBufferGetBytesPerRow(b) * height)
        }
        CVPixelBufferUnlockBaseAddress(b, []); return b
    }
    static func checkSequence(_ fps: Int, _ format: OSType) {
        let gate = ContentFrameGate(); var accepted = 0
        for i in 0..<120 {
            let sequence = i / (120 / fps)
            let value = UInt8((sequence % 64) * 4)
            let result = gate.evaluate(buffer: buffer(160, 90, format, value), generation: 1, hostNs: Int64(i) * 1_000_000_000 / 120 + 1)
            if result != .duplicate { accepted += 1 }
        }
        precondition(accepted == fps, "\(fps)fps: accepted \(accepted)")
        let fpsValue = gate.diagnostics(nowNs: 1_000_000_000)["contentDistinctFPS"] as? Double ?? -1
        precondition(abs(fpsValue - Double(fps)) < 0.1, "distinctFPS \(fpsValue)")
    }
    static func benchmark() {
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            let gate = ContentFrameGate(), image = buffer(2560, 1440, format, 32)
            let point = ContentFrameGate.sampleCoordinates(width: 2560, height: 1440)[0]
            for i in 0..<600 {
                CVPixelBufferLockBaseAddress(image, [])
                let planar = CVPixelBufferIsPlanar(image)
                let base = (planar ? CVPixelBufferGetBaseAddressOfPlane(image, 0) : CVPixelBufferGetBaseAddress(image))!.assumingMemoryBound(to: UInt8.self)
                let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, 0) : CVPixelBufferGetBytesPerRow(image)
                base[point.y * stride + point.x * (planar ? 1 : 4)] = UInt8((i % 2) * 8 + 32)
                CVPixelBufferUnlockBaseAddress(image, [])
                _ = gate.evaluate(buffer: image, generation: 1, hostNs: Int64(i) * 8_333_333 + 1)
            }
            let d = gate.diagnostics(nowNs: 5_000_000_000)
            print("A7 2560x1440 format=\(format == kCVPixelFormatType_32BGRA ? "BGRA" : "420v") samples=600 measuredLast=256 p95_ms=\(d["contentFingerprintP95Ms"]!) includes=lock,sampling,comparison,unlock,gate_diagnostics_bookkeeping actualSCK=false")
        }
    }
    static func main() {
        if CommandLine.arguments.contains("--benchmark") { benchmark(); return }
        precondition((7900...8100).contains(ContentFrameGate.sampleCoordinates(width:2560,height:1440).count))
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            checkSequence(30, format); checkSequence(24, format)
            let all = ContentFrameGate()
            for i in 0..<120 {
                let result = all.evaluate(buffer: buffer(160, 90, format, UInt8((i % 64) * 4)), generation: 1, hostNs: Int64(i) * 8_333_333 + 1)
                precondition(result == .accepted)
            }
            let still = ContentFrameGate(); let b = buffer(160, 90, format, 32)
            precondition(still.evaluate(buffer:b,generation:1,hostNs:1) == .accepted)
            precondition(still.evaluate(buffer:b,generation:1,hostNs:250_000_001) == .duplicate)
            precondition(still.evaluate(buffer:b,generation:1,hostNs:250_000_002) == .forced)
            precondition(still.evaluate(buffer:b,generation:1,hostNs:250_000_003) == .duplicate)
            let d = still.diagnostics(nowNs:250_000_003)
            precondition((d["contentAccepted"] as? Int) == 2 && (d["contentDuplicates"] as? Int) == 2 && (d["contentForced"] as? Int) == 1)
            precondition((d["contentDistinctFPS"] as? Double) == 0)
            let one = ContentFrameGate(); let a = buffer(160, 90, format, 32); let c = buffer(160, 90, format, 32)
            precondition(one.evaluate(buffer:a,generation:1,hostNs:1) == .accepted)
            let point = ContentFrameGate.sampleCoordinates(width:160,height:90)[0]
            CVPixelBufferLockBaseAddress(c, [])
            let base = (CVPixelBufferIsPlanar(c) ? CVPixelBufferGetBaseAddressOfPlane(c, 0) : CVPixelBufferGetBaseAddress(c))!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferIsPlanar(c) ? CVPixelBufferGetBytesPerRowOfPlane(c, 0) : CVPixelBufferGetBytesPerRow(c)
            base[point.y * stride + point.x * (CVPixelBufferIsPlanar(c) ? 1 : 4)] = 40
            CVPixelBufferUnlockBaseAddress(c, [])
            let quant = buffer(160, 90, format, 32)
            CVPixelBufferLockBaseAddress(quant, [])
            let qbase = (CVPixelBufferIsPlanar(quant) ? CVPixelBufferGetBaseAddressOfPlane(quant, 0) : CVPixelBufferGetBaseAddress(quant))!.assumingMemoryBound(to: UInt8.self)
            qbase[point.y * stride + point.x * (CVPixelBufferIsPlanar(quant) ? 1 : 4)] = 35
            CVPixelBufferUnlockBaseAddress(quant, [])
            precondition(one.evaluate(buffer:quant,generation:1,hostNs:5) == .duplicate, "two-bit quantization")
            precondition(one.evaluate(buffer:c,generation:1,hostNs:10) == .accepted, "compare with previous accepted, not prior callback")
            if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
                let chromaOnly = buffer(160, 90, format, 32)
                let cg = ContentFrameGate()
                precondition(cg.evaluate(buffer:chromaOnly,generation:1,hostNs:1) == .accepted)
                CVPixelBufferLockBaseAddress(chromaOnly, [])
                let uv = CVPixelBufferGetBaseAddressOfPlane(chromaOnly, 1)!.assumingMemoryBound(to: UInt8.self)
                uv[(point.y / 2) * CVPixelBufferGetBytesPerRowOfPlane(chromaOnly, 1) + (point.x / 2) * 2 + 1] = 136
                CVPixelBufferUnlockBaseAddress(chromaOnly, [])
                precondition(cg.evaluate(buffer:chromaOnly,generation:1,hostNs:2) == .accepted, "chroma-only change")
            }
            let stale = one.diagnostics(nowNs:10,expectedGeneration:2)
            precondition((stale["contentAccepted"] as? Int) == 0, "old generation diagnostics hidden")
            precondition(one.evaluate(buffer:buffer(162,90,format,32),generation:1,hostNs:20) == .accepted, "size resets")
            precondition(one.evaluate(buffer:c,generation:2,hostNs:30) == .accepted, "generation resets")
        }
        let changedFormat = ContentFrameGate()
        precondition(changedFormat.evaluate(buffer:buffer(160,90,kCVPixelFormatType_32BGRA,32),generation:1,hostNs:1) == .accepted)
        precondition(changedFormat.evaluate(buffer:buffer(160,90,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,32),generation:1,hostNs:2) == .accepted)
        let stats: [String: Any] = ["sourceGeneration": UInt64(7), "configVersion": UInt64(13),
            "overlayInputEstimateFPS": 30.0, "overlayPresentedFPS": 60.0, "estimatedRequestedFPS": 60.0,
            "rateKind": "multiplier", "rateMultiplier": 2, "requestedFPSIsEstimated": true, "displayRefreshHz": 120.0]
        for chinese in [true, false] {
            let label = LiveFPSOverlay.text(stats:stats,now:10,receipt:9,generation:7,config:13,running:true,paused:false,
                committed:true,interpolation:true,canObserve:true,outputObservable:true,chinese:chinese)
            precondition(label.contains(chinese ? "内容≈ 30.0" : "Content≈ 30.0"))
        }
        print("ContentFrameGate: 24/30/120, keepalive, point, quantization, chroma, generation, size, HUD, BGRA and 420v pass")
    }
}
