import Foundation
import CoreVideo
import CryptoKit
import Metal
import RifeMetal
import RifeMetalCore

enum ProductionProbeError: Error { case invalid(String) }

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func pixelHash(_ frame: CVPixelBuffer) -> String {
    CVPixelBufferLockBaseAddress(frame, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
    let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
    let base = CVPixelBufferGetBaseAddress(frame)!, stride = CVPixelBufferGetBytesPerRow(frame)
    var hash = SHA256()
    for y in 0..<height {
        hash.update(bufferPointer: UnsafeRawBufferPointer(start: base + y * stride, count: width * 4))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private func pixelInfo(_ frame: CVPixelBuffer) -> [String: Any] {
    let format = CVPixelBufferGetPixelFormatType(frame)
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: format >> $0) }
    return ["width": CVPixelBufferGetWidth(frame), "height": CVPixelBufferGetHeight(frame),
            "bytes_per_row": CVPixelBufferGetBytesPerRow(frame), "pixel_format": Int(format),
            "pixel_format_fourcc": String(bytes: bytes, encoding: .ascii) ?? "non-ascii",
            "iosurface": CVPixelBufferGetIOSurface(frame) != nil]
}

private func allocate(width: Int, height: Int, surface: Bool) throws -> CVPixelBuffer {
    let buffer: CVPixelBuffer
    if surface {
        buffer = try PixelBufferConvert.makeOutputPixelBuffer(width: width, height: height)
    } else {
        var value: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &value)
        guard status == kCVReturnSuccess, let value else {
            throw ProductionProbeError.invalid("no-IOSurface allocation failed: \(status)")
        }
        buffer = value
    }
    guard (CVPixelBufferGetIOSurface(buffer) != nil) == surface else {
        throw ProductionProbeError.invalid("allocated IOSurface state differs from requested state \(surface)")
    }
    return buffer
}

private func inputBuffer(path: String, width: Int, height: Int, surface: Bool) throws -> CVPixelBuffer {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count == width * height * 4 else {
        throw ProductionProbeError.invalid("BGRA size differs: \(path)")
    }
    let buffer = try allocate(width: width, height: height, surface: surface)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let destination = CVPixelBufferGetBaseAddress(buffer)!, stride = CVPixelBufferGetBytesPerRow(buffer)
    data.withUnsafeBytes { source in
        for y in 0..<height {
            memcpy(destination + y * stride, source.baseAddress! + y * width * 4, width * 4)
        }
    }
    return buffer
}

private func baselineKey(_ caseID: String, _ count: Int, _ alpha: Double, _ entrypoint: String) -> String {
    "\(caseID)|\(count)|\(alpha)|\(entrypoint)"
}

@main struct ProductionRuntimeProbe {
    static func main() {
        do { exit(try run()) }
        catch {
            FileHandle.standardError.write(Data("production probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws -> Int32 {
        guard CommandLine.arguments.count == 4 else {
            throw ProductionProbeError.invalid("usage: production-runtime-probe CONFIG BASELINE_QUALITY OUTPUT_JSON")
        }
        guard (ProcessInfo.processInfo.environment["ODF_PERF_PROFILE"] ?? "off") == "off",
              ProcessInfo.processInfo.environment["RIFE_DUMP_DIR"] == nil else {
            throw ProductionProbeError.invalid("simulation and dumping must be disabled")
        }
        let configURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let baselineURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: baselineURL)) as! [String: Any]
        guard config["tier"] as? String == "fast", config["app_entrypoints"] as? Bool == true else {
            throw ProductionProbeError.invalid("probe requires the frozen Fast app-entrypoint config")
        }
        let width = config["width"] as! Int, height = config["height"] as! Int
        let cases = config["cases"] as! [[String: Any]]
        let targetSets = config["target_sets"] as! [[Double]]
        guard !cases.isEmpty else { throw ProductionProbeError.invalid("no input cases") }
        var expected: [String: String] = [:]
        for row in baseline["rows"] as! [[String: Any]] where row["variant"] as? String == "d0" {
            let key = baselineKey(row["case_id"] as! String, row["K"] as! Int,
                                  row["alpha"] as! Double, row["entrypoint"] as! String)
            guard expected.updateValue(row["output_sha256"] as! String, forKey: key) == nil else {
                throw ProductionProbeError.invalid("duplicate frozen d0 key: \(key)")
            }
        }
        let modelURL = RifeConfiguration.bundledModelURL
        let outputCountPerCase = targetSets.reduce(0) { $0 + $1.count }
        let plannedRows = (cases.count + 1) * outputCountPerCase
        var rows: [[String: Any]] = []
        var report: [String: Any] = [
            "mode": "production_runtime_hash_parity", "tier": "fast", "baseline_variant": "d0",
            "device": MTLCreateSystemDefaultDevice()?.name ?? "unavailable",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundled_model_url": modelURL.path,
            "bundled_model_sha256": digest(try Data(contentsOf: modelURL)),
            "config_sha256": digest(try Data(contentsOf: configURL)),
            "baseline_quality_sha256": digest(try Data(contentsOf: baselineURL)),
            "target_sets": targetSets, "planned_rows": plannedRows,
            "hash_scope": "SHA256 of width*4 active BGRA bytes per row; excludes row padding",
            "timing_measured": false, "complete": false,
        ]
        func save() throws {
            report["rows"] = rows
            report["mismatch_count"] = rows.filter { !($0["matches_baseline"] as! Bool) }.count
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: outputURL, options: .atomic)
        }
        do {
            // This is the production package's bundled configuration, with no
            // experiment switches, supplied model override, or second baseline model.
            let model = try RifeInterpolator(configuration: .bundled(qualityTier: .fast))
            let stream = try model.makeStream(width: width, height: height)
            func runCase(_ item: [String: Any], surface: Bool) throws {
                let caseID = item["id"] as! String
                let first = try inputBuffer(path: item["first"] as! String, width: width, height: height, surface: surface)
                let second = try inputBuffer(path: item["second"] as! String, width: width, height: height, surface: surface)
                var firstInfo = pixelInfo(first), secondInfo = pixelInfo(second)
                firstInfo["active_rows_sha256"] = pixelHash(first)
                secondInfo["active_rows_sha256"] = pixelHash(second)
                for targets in targetSets {
                    stream.reset()
                    guard try stream.push(first, timesteps: []).isEmpty else {
                        throw ProductionProbeError.invalid("initial push unexpectedly returned frames")
                    }
                    let provided = targets == [0.5]
                    let frames: [CVPixelBuffer]
                    if provided {
                        // The extra no-surface case also forces the production
                        // CPU-crop fallback for the caller-provided midpoint output.
                        let output = try allocate(width: width, height: height, surface: surface)
                        guard try stream.push(second, into: output) else {
                            throw ProductionProbeError.invalid("midpoint output missing")
                        }
                        frames = [output]
                    } else {
                        frames = try stream.push(second, timesteps: targets.map(Float.init))
                    }
                    guard frames.count == targets.count else {
                        throw ProductionProbeError.invalid("target output count differs")
                    }
                    let entrypoint = provided ? "into" : "returning"
                    for (index, frame) in frames.enumerated() {
                        guard CVPixelBufferGetWidth(frame) == width,
                              CVPixelBufferGetHeight(frame) == height,
                              CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else {
                            throw ProductionProbeError.invalid("output dimensions or format differ")
                        }
                        let key = baselineKey(caseID, targets.count, targets[index], entrypoint)
                        guard let frozenHash = expected[key] else {
                            throw ProductionProbeError.invalid("missing frozen d0 key: \(key)")
                        }
                        let actualHash = pixelHash(frame)
                        rows.append([
                            "case_id": caseID, "scenario": surface ? "normal_iosurface" : "no_iosurface_input",
                            "variant": "production_local_bundled", "K": targets.count, "alpha": targets[index],
                            "target_set": targets, "entrypoint": entrypoint,
                            "actual_entrypoint": provided ? "RifeStream.push(_:into:)" : "RifeStream.push(_:timesteps:)",
                            "initial_entrypoint": "RifeStream.push(_:timesteps: [])",
                            "first_input": firstInfo, "second_input": secondInfo, "output": pixelInfo(frame),
                            "provided_output": provided, "provided_output_iosurface": provided ? surface : NSNull(),
                            "output_sha256": actualHash, "baseline_output_sha256": frozenHash,
                            "matches_baseline": actualHash == frozenHash,
                        ])
                    }
                }
                try save()
                FileHandle.standardError.write(Data("production probe \(caseID) iosurface=\(surface) complete\n".utf8))
            }
            for item in cases { try runCase(item, surface: true) }
            // Same first case and target sets, now with verified absent IOSurfaces.
            try runCase(cases[0], surface: false)
            report["complete"] = rows.count == plannedRows
            withExtendedLifetime(model) {}
        } catch {
            report["execution_error"] = String(describing: error)
        }
        try save()
        print(outputURL.path)
        let passed = report["complete"] as! Bool && report["execution_error"] == nil
            && rows.allSatisfy { $0["matches_baseline"] as! Bool }
        return passed ? 0 : 1
    }
}
