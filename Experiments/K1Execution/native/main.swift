do {
    guard CommandLine.arguments.count == 2 else { throw BenchError.configuration("usage: k1-runtime CONFIG.json") }
    guard (ProcessInfo.processInfo.environment["ODF_PERF_PROFILE"] ?? "off") == "off",
          ProcessInfo.processInfo.environment["RIFE_DUMP_DIR"] == nil else {
        throw BenchError.configuration("simulation and dumping must be disabled")
    }
    let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
    let mode = config["mode"] as! String
    if mode == "profile" { setenv("ODF_K1_PROFILE", "1", 1) }
    let outputDir = URL(fileURLWithPath: config["output_dir"] as! String)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    var report: [String: Any] = ["mode": mode, "device": MTLCreateSystemDefaultDevice()!.name,
        "simulation_enabled": false, "mask_update": "accumulate", "profiling_enabled": ProcessInfo.processInfo.environment["ODF_K1_PROFILE"] == "1",
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "thermal_before": ProcessInfo.processInfo.thermalState.rawValue]
    if mode == "controlled" {
        guard ProcessInfo.processInfo.environment["ODF_K1_PROFILE"] != "1" else { throw BenchError.configuration("profiling must be off for cost") }
        report["result"] = try runControlled(config: config, outputDir: outputDir)
    } else if mode == "quality" || mode == "profile" {
        let width = config["width"] as! Int, height = config["height"] as! Int
        let tier = RifeQualityTier(rawValue: config["tier"] as! String)!
        let variants = config["variants"] as! [[String: Any]]
        var streams: [String: RifeStream] = [:]
        var models: [RifeInterpolator] = []
        for variant in variants {
            let id = variant["id"] as! String
            K1RuntimeOptions.fusedStageWarp = variant["fused_warp"] as? Bool ?? false
            K1RuntimeOptions.trimFinalFeatures = variant["trim_final_features"] as? Bool ?? false
            K1RuntimeOptions.directCrop = variant["direct_crop"] as? Bool ?? false
            K1RuntimeOptions.gpuInputPadding = variant["gpu_input_padding"] as? Bool ?? false
            let model = try RifeInterpolator(configuration: .init(modelURL: URL(fileURLWithPath: variant["model"] as! String), qualityTier: tier))
            models.append(model)
            streams[id] = try model.makeStream(width: width, height: height)
        }
        var rows: [[String: Any]] = []
        for item in config["cases"] as! [[String: Any]] {
            let caseID = item["id"] as! String
            let a = try pixelBuffer(path: item["first"] as! String, width: width, height: height)
            let b = try pixelBuffer(path: item["second"] as! String, width: width, height: height)
            for targets in config["target_sets"] as! [[Double]] {
                for variant in variants {
                    let id = variant["id"] as! String, stream = streams[id]!
                    stream.reset()
                    _ = try stream.push(a, timesteps: [])
                    let start = now()
                    let useProvided = (config["app_entrypoints"] as? Bool ?? false) && targets == [0.5]
                    let frames: [CVPixelBuffer]
                    if useProvided {
                        let output = try PixelBufferConvert.makeOutputPixelBuffer(width: width, height: height)
                        guard try stream.push(b, into: output) else { throw BenchError.configuration("missing midpoint") }
                        frames = [output]
                    } else { frames = try stream.push(b, timesteps: targets.map(Float.init)) }
                    let ms = elapsed(start)
                    guard frames.count == targets.count else { throw BenchError.configuration("missing target") }
                    for (i, frame) in frames.enumerated() {
                        let path = outputDir.appendingPathComponent("\(caseID)-\(id)-k\(targets.count)-a\(targets[i]).bgra")
                        if config["save_outputs"] as? Bool ?? false { try writePixels(frame, path: path) }
                        rows.append(["case_id": caseID, "variant": id, "K": targets.count, "alpha": targets[i],
                                     "entrypoint": useProvided ? "into" : "returning",
                                     "output_bgra": path.path, "output_sha256": pixelHash(frame),
                                     "call_host_ms": ms, "profile": stream.k1LastProfile])
                    }
                }
            }
            FileHandle.standardError.write(Data("quality \(caseID) complete\n".utf8))
        }
        report["rows"] = rows
        withExtendedLifetime(models) {}
    } else { throw BenchError.configuration("unknown mode") }
    report["thermal_after"] = ProcessInfo.processInfo.thermalState.rawValue
    let file = outputDir.appendingPathComponent("\(mode).json")
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    print(file.path)
} catch {
    FileHandle.standardError.write(Data("runtime bench failed: \(error)\n".utf8))
    exit(1)
}
