import Foundation
import CoreVideo
import Metal
import RifeMetal
import RifeMetalCore

enum BenchError: Error { case configuration(String) }

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func elapsed(_ start: UInt64) -> Double { Double(now() - start) / 1e6 }

func pixelBuffer(path: String, width: Int, height: Int) throws -> CVPixelBuffer {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count == width * height * 4 else { throw BenchError.configuration("BGRA size differs") }
    var value: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                              kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &value) == kCVReturnSuccess,
          let buffer = value else { throw BenchError.configuration("pixel buffer allocation") }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let dst = CVPixelBufferGetBaseAddress(buffer)!
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    data.withUnsafeBytes { src in
        for y in 0..<height { memcpy(dst + y * stride, src.baseAddress! + y * width * 4, width * 4) }
    }
    return buffer
}

func writePixels(_ buffer: CVPixelBuffer, path: URL) throws {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer), base = CVPixelBufferGetBaseAddress(buffer)!
    var data = Data(capacity: width * height * 4)
    for y in 0..<height { data.append(base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self), count: width * 4) }
    try data.write(to: path)
}

do {
    guard CommandLine.arguments.count == 2 else { throw BenchError.configuration("usage: k1-bench CONFIG.json") }
    guard (ProcessInfo.processInfo.environment["ODF_PERF_PROFILE"] ?? "off") == "off",
          ProcessInfo.processInfo.environment["RIFE_DUMP_DIR"] == nil else {
        throw BenchError.configuration("simulation or activation dumping must be disabled")
    }
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
    let urls = (config["models"] as! [String]).map { URL(fileURLWithPath: $0) }
    let mode = config["mode"] as! String
    if mode == "profile" { setenv("ODF_K1_PROFILE", "1", 1) }
    K1BenchmarkSubmission.deferIntermediateCommits = config["defer_commits"] as? Bool ?? false
    K1BenchmarkGraph.nativeLeakyReLU = config["native_leaky"] as? Bool ?? false
    let outputDir = URL(fileURLWithPath: config["output_dir"] as! String)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    var report: [String: Any] = ["mode": mode, "device": MTLCreateSystemDefaultDevice()!.name,
        "simulation_enabled": false, "host_timing_source": "DispatchTime.uptimeNanoseconds, synchronous completed call",
        "gpu_timing_scope": "last MTLCommandBuffer only; not asserted to cover all MPS internal buffers",
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "thermal_state_before": ProcessInfo.processInfo.thermalState.rawValue,
        "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        "graph_mode": mode == "controlled" ? "per-variant" : (K1BenchmarkGraph.nativeLeakyReLU ? "native_leaky" : "expanded_leaky"),
        "profiling_enabled": ProcessInfo.processInfo.environment["ODF_K1_PROFILE"] == "1"]
    if mode == "validate" {
        report["models"] = try urls.map { url -> [String: Any] in
            let weights = try WeightStore(url: url)
            return ["path": url.path, "graph_id": weights.graphID, "mask_update": weights.maskUpdate,
                    "container_version": weights.containerVersion, "tensors": weights.header.tensors.count]
        }
    } else if mode == "activation" {
        report["result"] = try K1ActivationAudit.run(outputDir: outputDir)
    } else if mode == "micro" {
        report["rows"] = try K1Microbench.run(urls: urls, outputDir: outputDir,
                                            warmup: config["warmup"] as! Int, rounds: config["rounds"] as! Int)
    } else if mode == "controlled" {
        guard ProcessInfo.processInfo.environment["ODF_K1_PROFILE"] != "1" else {
            throw BenchError.configuration("controlled cost comparisons require profiling off")
        }
        report["result"] = try runControlled(config: config, outputDir: outputDir)
    } else if mode == "stream" || mode == "profile" {
        let width = config["width"] as! Int, height = config["height"] as! Int
        let first = try pixelBuffer(path: config["first"] as! String, width: width, height: height)
        let second = try pixelBuffer(path: config["second"] as! String, width: width, height: height)
        let tier = RifeQualityTier(rawValue: config["tier"] as! String)!
        let alphas = (config["alphas"] as! [Double]).map(Float.init)
        let rounds = config["rounds"] as! Int, warmup = config["warmup"] as! Int
        var streams: [RifeStream] = []
        var cold: [[String: Any]] = []
        for url in urls {
            let started = now()
            let model = try RifeInterpolator(configuration: .init(modelURL: url, qualityTier: tier))
            let stream = try model.makeStream(width: width, height: height)
            let loadCompile = elapsed(started)
            let cacheStart = now()
            _ = try stream.push(first, timesteps: [])
            cold.append(["model": url.path, "load_compile_ms": loadCompile, "initial_head_ms": elapsed(cacheStart)])
            streams.append(stream)
        }
        var rows: [[String: Any]] = []
        for alpha in alphas {
            var samples = Array(repeating: [[String: Double]](), count: streams.count)
            var outputs: [CVPixelBuffer?] = Array(repeating: nil, count: streams.count)
            var profiles = Array(repeating: [[String: Any]](), count: streams.count)
            for iteration in (-warmup)..<rounds {
                let order = iteration.isMultiple(of: 2) ? Array(streams.indices) : Array(streams.indices.reversed())
                for i in order {
                    let stream = streams[i]
                    stream.reset()
                    _ = try stream.push(first, timesteps: []) // previous Head outside timed interval
                    let start = now()
                    let frames = try stream.push(second, timesteps: [alpha]) // one NEW Head + full query
                    let hostMS = elapsed(start)
                    guard frames.count == 1 else { throw BenchError.configuration("K1 output missing") }
                    if iteration >= 0 {
                        var sample = stream.k1LastBufferTiming
                        sample["host_ms"] = hostMS
                        samples[i].append(sample)
                        if mode == "profile" { profiles[i].append(stream.k1LastProfile) }
                    }
                    outputs[i] = frames[0]
                }
            }
            for i in streams.indices {
                let file = outputDir.appendingPathComponent("stream-m\(i)-a\(alpha).bgra")
                try writePixels(outputs[i]!, path: file)
                rows.append(["model": urls[i].path, "alpha": alpha, "K": 1, "samples": samples[i],
                             "profiles": profiles[i], "output_bgra": file.path])
            }
            FileHandle.standardError.write(Data("stream alpha=\(alpha) complete\n".utf8))
        }
        report["rows"] = rows
        report["cold"] = cold
        report["width"] = width
        report["height"] = height
        report["tier"] = tier.rawValue
        report["warm_cache_contract"] = "same exact endpoints each trial; one previous Head cached, new Head included; synchronized one-frame return"
        report["device_current_allocated_bytes"] = MTLCreateSystemDefaultDevice()!.currentAllocatedSize
    } else { throw BenchError.configuration("unknown benchmark mode") }
    report["thermal_state_after"] = ProcessInfo.processInfo.thermalState.rawValue
    let file = outputDir.appendingPathComponent("\(mode).json")
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    print(file.path)
} catch {
    FileHandle.standardError.write(Data("k1-bench failed: \(error)\n".utf8))
    exit(1)
}
