import Foundation
import CryptoKit
import CoreVideo
import Metal
import RifeMetal
import RifeMetalCore

enum CostError: Error { case invalid(String) }

func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

func image(_ width: Int, _ height: Int, _ shift: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                   kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                             attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let result = buffer else { throw CostError.invalid("source pixel buffer") }
    CVPixelBufferLockBaseAddress(result, [])
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    let stride = CVPixelBufferGetBytesPerRow(result)
    let base = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            let p = base + y * stride + 4 * x
            p[0] = UInt8(((x + shift) ^ y) & 255)
            p[1] = UInt8((3 * x + y + shift) & 255)
            p[2] = UInt8((x + 2 * y + shift) & 255)
            p[3] = 255
        }
    }
    return result
}

func pixelHash(_ buffer: CVPixelBuffer) -> String {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!
    var digest = SHA256()
    for y in 0..<height { digest.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * stride, count: width * 4)) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

var report: [String: Any] = [:]
var destination: URL?
do {
    guard CommandLine.arguments.count == 2 else { throw CostError.invalid("usage: air24-cost CONFIG.json") }
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
    destination = URL(fileURLWithPath: config["output"] as! String)
    guard !FileManager.default.fileExists(atPath: destination!.path) else { throw CostError.invalid("existing result retained") }
    let width = config["width"] as! Int, height = config["height"] as! Int
    guard width == 1814, height == 1142, config["warmup"] as? Int == 20,
          config["pairs"] as? Int == 200 else { throw CostError.invalid("fixed Air cost protocol") }
    guard (ProcessInfo.processInfo.environment["ODF_PERF_PROFILE"] ?? "off") == "off",
          ProcessInfo.processInfo.environment["ODF_K1_PROFILE"] != "1",
          ProcessInfo.processInfo.environment["RIFE_VERBOSE"] != "1",
          ProcessInfo.processInfo.environment["RIFE_DUMP_DIR"] == nil else { throw CostError.invalid("profiling/dumping disabled") }
    let original = URL(fileURLWithPath: config["original_model"] as! String)
    let student = URL(fileURLWithPath: config["student_model"] as! String)
    guard try sha(original) == config["original_sha256"] as! String,
          try sha(student) == config["student_sha256"] as! String else { throw CostError.invalid("model hash mismatch") }
    K1RuntimeOptions.fusedStageWarp = false
    K1RuntimeOptions.trimFinalFeatures = false
    K1RuntimeOptions.gpuInputPadding = true
    K1RuntimeOptions.directCrop = true
    let models = try [original, student].map {
        try RifeInterpolator(configuration: .init(modelURL: $0, qualityTier: .fast))
    }
    let streams = try models.map { try $0.makeStream(width: width, height: height) }
    let first = try image(width, height, 0), second = try image(width, height, 7)
    let outputs = try (0..<2).map { _ in try PixelBufferConvert.makeOutputPixelBuffer(width: width, height: height) }
    report = ["functionalComplete": false, "protocol": "20 AB warmups then200 ABAB paired complete stream.push into calls",
              "width": width, "height": height, "qualityTier": "fast", "alpha": 0.5,
              "mask_update": "accumulate", "weights_dtype": "FP16", "gpu_input_padding": true,
              "direct_crop": true, "fused_warp": false, "trim_final_features": false,
              "device": MTLCreateSystemDefaultDevice()!.name,
              "thermal_before": ProcessInfo.processInfo.thermalState.rawValue,
              "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
              "original_sha256": try sha(original), "student_sha256": try sha(student),
              "first_input_sha256": pixelHash(first), "second_input_sha256": pixelHash(second),
              "scope": "Synchronous complete native stream.push into wall time with one cached previous Head; no capture, presenter, FPS or quality acceptance."]
    for stream in streams { _ = try stream.push(first, timesteps: []) }
    for i in 0..<20 {
        for arm in 0..<2 {
            guard try streams[arm].push(i.isMultiple(of: 2) ? second : first, into: outputs[arm]) else {
                throw CostError.invalid("warmup missing midpoint")
            }
        }
    }
    var rows: [[String: Any]] = []
    for i in 0..<200 {
        let input = i.isMultiple(of: 2) ? second : first
        var times: [UInt64] = []
        for arm in 0..<2 {
            let start = DispatchTime.now().uptimeNanoseconds
            let generated = try streams[arm].push(input, into: outputs[arm])
            times.append(DispatchTime.now().uptimeNanoseconds - start)
            guard generated else { throw CostError.invalid("measured missing midpoint") }
        }
        rows.append(["pair": i+1, "original_ns": times[0], "student_ns": times[1]])
    }
    report["pairs"] = rows
    report["original_last_output_sha256"] = pixelHash(outputs[0])
    report["student_last_output_sha256"] = pixelHash(outputs[1])
    report["thermal_after"] = ProcessInfo.processInfo.thermalState.rawValue
    report["functionalComplete"] = true
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination!, options: .atomic)
    print("Completed200 paired native calls per arm")
} catch {
    report["functionalComplete"] = false
    report["firstFailure"] = String(describing: error)
    if let url = destination, !FileManager.default.fileExists(atPath: url.path),
       let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    }
    FileHandle.standardError.write(Data("air24-cost: \(error)\n".utf8))
    exit(1)
}
