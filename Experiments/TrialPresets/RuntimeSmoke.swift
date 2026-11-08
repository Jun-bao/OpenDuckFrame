import Foundation
import CoreVideo
import CryptoKit
import RifeMetal
import RifeMetalCore

enum SmokeError: Error { case check(String) }

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeError.check(message) }
}

func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func input(width: Int, height: Int, shift: Int) throws -> CVPixelBuffer {
    let frame = try PixelBufferConvert.makeOutputPixelBuffer(width: width, height: height)
    CVPixelBufferLockBaseAddress(frame, [])
    defer { CVPixelBufferUnlockBaseAddress(frame, []) }
    let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(frame)
    for y in 0..<height {
        for x in 0..<width {
            let sx = max(0, x - shift), index = y * stride + x * 4
            base[index] = UInt8((sx * 3 + y * 5) % 256)
            base[index + 1] = UInt8((sx ^ (y * 3)) % 256)
            base[index + 2] = UInt8(((sx / 9 + y / 7) % 2) * 192 + 32)
            base[index + 3] = 255
        }
    }
    return frame
}

func pixels(_ frame: CVPixelBuffer, width: Int, height: Int) throws -> Data {
    try require(CVPixelBufferGetWidth(frame) == width && CVPixelBufferGetHeight(frame) == height, "output dimensions")
    try require(CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA, "output format")
    CVPixelBufferLockBaseAddress(frame, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(frame)!, stride = CVPixelBufferGetBytesPerRow(frame)
    var result = Data(capacity: width * height * 4)
    for row in 0..<height {
        result.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * 4)
    }
    let rgb = result.enumerated().filter { $0.offset % 4 != 3 }.map { Float($0.element) / 255 }
    try require(rgb.allSatisfy(\.isFinite), "finite rendered RGB")
    try require(rgb.min()! < rgb.max()!, "synthetic pattern produced a constant output")
    return result
}

var rows: [[String: Any]] = []
var modelRows: [[String: Any]] = []
var checks: [[String: Any]] = []
var errorText: String?
var reportPath: URL?
do {
    try require(CommandLine.arguments.count == 2, "usage: runtime-trial-smoke CONFIG.json")
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
    reportPath = URL(fileURLWithPath: config["output"] as! String)
    try require(!FileManager.default.fileExists(atPath: reportPath!.path), "output already exists")
    let width = config["width"] as? Int ?? 300, height = config["height"] as? Int ?? 180
    let tier = RifeQualityTier(rawValue: config["tier"] as? String ?? "fast")!
    let first = try input(width: width, height: height, shift: 0)
    let second = try input(width: width, height: height, shift: 11)
    let alphas: [Float] = [0.25, 0.5, 0.75]
    var hashes: [String: String] = [:]
    let models = config["models"] as! [[String: Any]]
    for item in models + (config["load_only_models"] as? [[String: Any]] ?? []) {
        let id = item["id"] as! String, path = item["path"] as! String
        let weights = try WeightStore(url: URL(fileURLWithPath: path))
        let raw = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        modelRows.append(["id": id, "path": path, "sha256": sha(raw),
            "model": weights.header.model, "graph_id": weights.graphID, "container_version": weights.containerVersion,
            "declared_mask_update": weights.header.maskUpdate as Any? ?? NSNull(), "tensors": weights.header.tensors.count,
            "gpu_exercised": models.contains { $0["id"] as? String == id }])
    }
    for item in models {
        let id = item["id"] as! String, path = item["path"] as! String
        for replace in [false, true] {
            // Retain both instances while switching between them: graph options
            // cannot depend on a later process-wide option assignment.
            let engines = try [false, true].map { io in
                try RifeInterpolator(configuration: .init(modelURL: URL(fileURLWithPath: path), qualityTier: tier,
                    experimentOptions: RifeMetal.RifeExperimentOptions(gpuIO: io, replaceMask: replace)))
            }
            for (index, io) in [false, true].enumerated() {
                let engine = engines[index]
                func record(_ frame: CVPixelBuffer, path: String, alpha: Float) throws {
                    let data = try pixels(frame, width: width, height: height), digest = sha(data)
                    let key = "\(id)|\(replace)|\(path)|\(alpha)"
                    if io {
                        let equal = hashes[key] == digest
                        checks.append(["kind": "io_pixel_equality", "model": id, "replace_mask": replace,
                                       "path": path, "alpha": alpha, "equal": equal])
                        try require(equal, "IO on/off pixels differ: \(key)")
                    } else { hashes[key] = digest }
                    rows.append(["model_id": id, "gpu_io": io, "replace_mask": replace, "path": path,
                                 "alpha": alpha, "width": width, "height": height, "output_sha256": digest,
                                 "finite_rendered_rgb": true, "nonconstant_synthetic_output": true])
                }
                let stream = try engine.makeStream(width: width, height: height)
                try require(try stream.push(first, timesteps: []).isEmpty, "stream seed count")
                let streamOutputs = try stream.push(second, timesteps: alphas)
                try require(streamOutputs.count == 3, "stream returning count")
                for (alpha, frame) in zip(alphas, streamOutputs) { try record(frame, path: "stream-returning", alpha: alpha) }
                let output = try PixelBufferConvert.makeOutputPixelBuffer(width: width, height: height)
                stream.reset()
                try require(!(try stream.push(first, into: output)), "provided seed must not output")
                try require(try stream.push(second, into: output), "provided midpoint missing")
                try record(output, path: "stream-provided", alpha: 0.5)
                let stateless = try engine.interpolate(previous: first, current: second, timesteps: alphas)
                try require(stateless.count == 3, "stateless returning count")
                for (alpha, frame) in zip(alphas, stateless) { try record(frame, path: "stateless-returning", alpha: alpha) }
                try engine.interpolate(previous: first, current: second, output: output)
                try record(output, path: "stateless-provided", alpha: 0.5)
            }
        }
    }
    // Same graph, same I/O: replacement must affect at least one actual target.
    for item in models {
        let id = item["id"] as! String
        let selected = rows.filter { $0["model_id"] as? String == id && $0["gpu_io"] as? Bool == true }
        let accumulated = selected.filter { $0["replace_mask"] as? Bool == false }
        let replaced = selected.filter { $0["replace_mask"] as? Bool == true }
        let different = zip(accumulated, replaced).filter { $0.0["output_sha256"] as? String != $0.1["output_sha256"] as? String }.count
        checks.append(["kind": "mask_has_output_effect", "model": id, "different_outputs": different])
        try require(different > 0, "mask switch had no observed output effect for \(id)")
    }
    let baselineID = models[0]["id"] as! String
    for item in models.dropFirst() {
        let id = item["id"] as! String
        let reference = rows.filter { $0["model_id"] as? String == baselineID }
        let selected = rows.filter { $0["model_id"] as? String == id }
        let different = zip(reference, selected).filter { $0.0["output_sha256"] as? String != $0.1["output_sha256"] as? String }.count
        checks.append(["kind": "model_has_output_effect", "model": id, "reference": baselineID, "different_outputs": different])
        try require(different > 0, "model switch had no observed output effect for \(id)")
    }
} catch { errorText = String(describing: error) }

let report: [String: Any] = ["scope": "small synthetic-frame backend function smoke; no performance or quality acceptance",
    "passed": errorText == nil, "error": errorText as Any? ?? NSNull(), "models": modelRows, "rows": rows,
    "checks": checks, "output_count": rows.count, "holdout_accessed": false, "training_run": false,
    "finite_scope": "rendered BGRA8 RGB channels; internal FP16 flow/mask finiteness is not asserted"]
if let reportPath {
    try FileManager.default.createDirectory(at: reportPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: reportPath, options: .atomic)
    print(reportPath.path)
}
if let errorText { FileHandle.standardError.write(Data("runtime smoke failed: \(errorText)\n".utf8)); exit(1) }
