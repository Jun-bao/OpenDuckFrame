import Foundation
import CoreVideo
import CryptoKit
import Metal
import RifeMetal
import RifeMetalCore

private func pixelHash(_ frame: CVPixelBuffer) -> String {
    CVPixelBufferLockBaseAddress(frame, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
    let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
    let base = CVPixelBufferGetBaseAddress(frame)!, stride = CVPixelBufferGetBytesPerRow(frame)
    var hash = SHA256()
    for y in 0..<height { hash.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * stride, count: width * 4)) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// A predetermined random schedule; no candidate selection occurs in this runner.
func runControlled(config: [String: Any], outputDir: URL) throws -> [String: Any] {
    let width = config["width"] as! Int, height = config["height"] as! Int
    let first = try pixelBuffer(path: config["first"] as! String, width: width, height: height)
    let second = try pixelBuffer(path: config["second"] as! String, width: width, height: height)
    let variants = config["variants"] as! [[String: Any]]
    let schedule = config["schedule"] as! [[String: Any]]
    let count = config["frames_per_arm"] as! Int, warmup = config["warmup_per_arm"] as! Int
    let tier = RifeQualityTier(rawValue: config["tier"] as! String)!
    let device = MTLCreateSystemDefaultDevice()!
    var models: [String: RifeInterpolator] = [:]
    var streams: [String: RifeStream] = [:]
    var variantMap: [String: [String: Any]] = [:]
    var cold: [[String: Any]] = []
    for variant in variants {
        let id = variant["id"] as! String, path = variant["model"] as! String
        let nativeLeaky = variant["native_leaky"] as? Bool ?? false
        let modelKey = path + "|native_leaky=\(nativeLeaky)"
        K1BenchmarkSubmission.deferIntermediateCommits = false
        K1BenchmarkGraph.nativeLeakyReLU = nativeLeaky
        let start = now()
        let model: RifeInterpolator
        if let existing = models[modelKey] { model = existing }
        else {
            model = try RifeInterpolator(configuration: .init(modelURL: URL(fileURLWithPath: path), qualityTier: tier))
            models[modelKey] = model
        }
        streams[id] = try model.makeStream(width: width, height: height)
        variantMap[id] = variant
        cold.append(["variant": id, "load_or_reuse_and_make_stream_ms": elapsed(start)])
    }
    var records: [[String: Any]] = []
    let journal = outputDir.appendingPathComponent("arms.jsonl")
    guard FileManager.default.createFile(atPath: journal.path, contents: nil) else {
        throw BenchError.configuration("journal creation failed")
    }
    let journalHandle = try FileHandle(forWritingTo: journal)
    defer { try? journalHandle.close() }
    var lastBlock = -1
    for cell in schedule {
        let block = cell["block"] as! Int, alpha = Float(cell["alpha"] as! Double)
        let cadence = cell["cadence"] as! String
        let periodMS = cell["period_ms"] as! Double
        let periodNS = UInt64((periodMS * 1e6).rounded())
        for id in cell["order"] as! [String] {
            let variant = variantMap[id]!, stream = streams[id]!
            K1BenchmarkSubmission.deferIntermediateCommits = variant["defer_commits"] as! Bool
            stream.reset()
            _ = try stream.push(first, timesteps: [])
            for i in 0..<warmup {
                _ = try stream.push(i.isMultiple(of: 2) ? second : first, timesteps: [alpha])
            }
            // An even warmup returns the source cache to A. Every measured push
            // now adds exactly one new Head; there is no per-frame rebase.
            guard warmup.isMultiple(of: 2) else { throw BenchError.configuration("warmup must be even") }
            let nominalBase = now()
            var samples: [[String: Any]] = []
            var output: CVPixelBuffer?
            for frame in 0..<count {
                let nominal = nominalBase + UInt64(frame) * periodNS
                if periodNS > 0 {
                    let current = now()
                    if nominal > current { Thread.sleep(forTimeInterval: Double(nominal - current) / 1e9) }
                }
                let start = now()
                let result = try stream.push(frame.isMultiple(of: 2) ? second : first, timesteps: [alpha])
                let end = now()
                guard result.count == 1 else { throw BenchError.configuration("controlled K1 missing output") }
                output = result[0]
                var sample: [String: Any] = ["frame": frame, "host_ms": Double(end - start) / 1e6,
                                           "start_ns": start, "end_ns": end,
                                           "source_order": frame.isMultiple(of: 2) ? "A_to_B" : "B_to_A"]
                if periodNS > 0 {
                    sample["nominal_arrival_ns"] = nominal
                    sample["start_lag_ms"] = Double(Int64(start) - Int64(nominal)) / 1e6
                    sample["completion_from_nominal_ms"] = Double(Int64(end) - Int64(nominal)) / 1e6
                    sample["completed_before_next_source_arrival"] = end <= nominal + periodNS
                }
                samples.append(sample)
            }
            let row: [String: Any] = ["block": block, "cadence": cadence, "alpha": alpha,
                "variant": id, "defer_commits": variant["defer_commits"]!, "samples": samples,
                "native_leaky": variant["native_leaky"] as? Bool ?? false,
                "last_output_sha256": pixelHash(output!), "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
                "device_current_allocated_bytes": device.currentAllocatedSize]
            records.append(row)
            var line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            line.append(0x0a)
            try journalHandle.write(contentsOf: line)
        }
        if block != lastBlock {
            FileHandle.standardError.write(Data("controlled block=\(block) started\n".utf8))
            lastBlock = block
        }
    }
    K1BenchmarkSubmission.deferIntermediateCommits = false
    return ["records": records, "cold": cold, "frames_per_arm": count,
            "source_contract": "alternating A/B, per-arm warm cache, one new Head per timed push",
            "deadline_scope": "nominal source arrival budget only, not product presentation deadlines",
            "scheduling_intervention": "defer_commits is an isolated benchmark override, not a supported application feature"]
}
