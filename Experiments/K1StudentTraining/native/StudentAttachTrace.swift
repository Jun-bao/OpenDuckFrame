import Foundation
import CoreVideo
import RifeMetal
import RifeMetalCore
import Darwin
import os

// Darwin's Swift overlay exposes the C struct with the same name. Bind the BSD
// function directly, preserving compatibility with the project's Python flock.
@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// CPU orchestration for the copied attach-only runtime. No graph/kernel edits.
enum StudentAttachTrace {
    static let subsystem = "app.openduckframe.k1-attribution"
    static let log = OSLog(subsystem: subsystem, category: .pointsOfInterest)
    private static var progress: FileHandle?
    private static var progressPath = ""
    private static var gatePath = ""
    private static var lockDescriptor: Int32 = -1
    private static var runName = "bootstrap"

    static func start() throws {
        guard let path = ProcessInfo.processInfo.environment["ODF_K1_ATTACH_PROGRESS"], !path.isEmpty else {
            throw BenchError.configuration("set ODF_K1_ATTACH_PROGRESS to this run's new progress.jsonl")
        }
        progressPath = URL(fileURLWithPath: path).standardizedFileURL.path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: progressPath).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let descriptor = Darwin.open(progressPath, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw BenchError.configuration("new progress log open failed errno=\(errno)") }
        progress = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try mark("START")
    }

    static func mark(_ event: String, extra: [String: Any] = [:]) throws {
        guard let progress else { throw BenchError.configuration("progress log is not open") }
        var row = extra
        row["event"] = event
        row["pid"] = ProcessInfo.processInfo.processIdentifier
        row["timestamp_utc"] = ISO8601DateFormatter().string(from: Date())
        row["epoch_seconds"] = Date().timeIntervalSince1970
        row["uptime_ns"] = DispatchTime.now().uptimeNanoseconds
        row["run"] = runName
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(0x0a)
        try progress.write(contentsOf: data)
        guard Darwin.fsync(progress.fileDescriptor) == 0 else {
            throw BenchError.configuration("progress fsync failed errno=\(errno)")
        }
    }

    static func configure(_ config: [String: Any]) throws {
        guard ProcessInfo.processInfo.environment["ODF_K1_SIGNPOST_TRACE"] == "1",
              config["mode"] as? String == "controlled", config["app_entrypoints"] as? Bool == true,
              config["warmup_per_arm"] as? Int == 32, config["rewarm_per_arm"] as? Int == 8,
              config["frames_per_arm"] as? Int == 100,
              let cases = config["cases"] as? [[String: Any]], cases.count == 1,
              let variants = config["variants"] as? [[String: Any]], variants.count == 2,
              variants.compactMap({ $0["id"] as? String }) == ["d0", "trained"],
              let schedule = config["schedule"] as? [[String: Any]], schedule.count == 1,
              schedule[0]["alpha"] as? Double == 0.5,
              schedule[0]["cadence"] as? String == "continuous", schedule[0]["period_ms"] as? Double == 0,
              schedule[0]["order"] as? [String] == ["d0", "trained"],
              schedule[0]["case_id"] as? String == cases[0]["id"] as? String,
              variants.allSatisfy({ $0["direct_crop"] as? Bool == true && $0["gpu_input_padding"] as? Bool == true
                  && $0["fused_warp"] as? Bool != true && $0["trim_final_features"] as? Bool != true
                  && $0["defer_commits"] as? Bool != true && $0["native_leaky"] as? Bool != true }),
              let gate = config["attach_gate"] as? String,
              let expectedProgress = config["attach_progress"] as? String,
              URL(fileURLWithPath: expectedProgress).standardizedFileURL.path == progressPath,
              let gpuLock = config["gpu_lock"] as? String,
              ProcessInfo.processInfo.environment["ODF_K1_PROFILE"] != "1" else {
            throw BenchError.configuration("attach harness requires fixed d0/trained midpoint arms, IO=true, warm32/rewarm8/record100, and matching progress path")
        }
        gatePath = URL(fileURLWithPath: gate).standardizedFileURL.path
        guard !FileManager.default.fileExists(atPath: gatePath) else {
            throw BenchError.configuration("gate already exists; use a fresh run")
        }
        runName = config["attach_run_name"] as? String ?? "attach"
        try mark("CONFIG_VALIDATED", extra: ["gate": gatePath, "phase": config["attach_phase"] ?? "unknown"])
        let descriptor = Darwin.open(gpuLock, O_RDWR | O_CREAT, mode_t(0o600))
        guard descriptor >= 0 else { throw BenchError.configuration("GPU lock open failed errno=\(errno)") }
        guard systemFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw BenchError.configuration("GPU lock is held elsewhere, errno=\(code); launcher must not pre-hold it")
        }
        lockDescriptor = descriptor
        try mark("GPU_LOCK_ACQUIRED", extra: ["gpu_lock": gpuLock])
    }

    static func warm(config: [String: Any], inputs: [String: (CVPixelBuffer, CVPixelBuffer)],
                     streams: [String: RifeStream], count: Int, reset: Bool) throws {
        let width = config["width"] as! Int, height = config["height"] as! Int
        let caseID = (config["cases"] as! [[String: Any]])[0]["id"] as! String
        let (first, second) = inputs[caseID]!
        K1BenchmarkSubmission.deferIntermediateCommits = false
        for variant in config["variants"] as! [[String: Any]] {
            let id = variant["id"] as! String, stream = streams[id]!
            try mark(reset ? "WARM32_BEGIN" : "REWARM8_BEGIN", extra: ["variant": id, "case_id": caseID])
            let output = try PixelBufferConvert.makeOutputPixelBuffer(width: width, height: height)
            if reset {
                stream.reset()
                _ = try stream.push(first, timesteps: [])
            }
            for index in 0..<count {
                guard try stream.push(index.isMultiple(of: 2) ? second : first, into: output) else {
                    throw BenchError.configuration("provided-output warmup returned no midpoint")
                }
            }
            try mark(reset ? "WARM32_DONE" : "REWARM8_DONE", extra: ["variant": id, "calls": count])
        }
    }

    static func readyAndWait() throws {
        try mark("READY", extra: ["gate": gatePath, "GPU_lock_held": lockDescriptor >= 0])
        while !FileManager.default.fileExists(atPath: gatePath) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        try mark("GATE_OPEN")
    }

    static func recordingBegin() throws {
        try mark("RECORDING_BEGIN", extra: ["calls_per_arm": 100, "arms": ["d0", "trained"]])
        os_signpost(.event, log: log, name: "K1 recording begin")
    }

    static func recordingEnd() throws {
        os_signpost(.event, log: log, name: "K1 recording end")
        try mark("RECORDING_END", extra: ["expected_K1_intervals": 200])
    }

    static func begin(caseID: String, variant: String, frame: Int, alpha: Float) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        let context = "case=\(caseID) variant=\(variant) frame=\(frame) alpha=\(alpha)" as NSString
        os_signpost(.begin, log: log, name: "K1 provided-output", signpostID: id, "%{public}@", context)
        return id
    }

    static func end(_ id: OSSignpostID) {
        os_signpost(.end, log: log, name: "K1 provided-output", signpostID: id)
    }

    static func finished(report: URL) throws {
        let handle = try FileHandle(forWritingTo: report)
        defer { try? handle.close() }
        guard Darwin.fsync(handle.fileDescriptor) == 0 else {
            throw BenchError.configuration("controlled.json fsync failed errno=\(errno)")
        }
        try mark("CONTROLLED_JSON_FSYNC", extra: ["report": report.path])
        try mark("DONE", extra: ["report": report.path])
        releaseLock()
    }

    static func failed(_ error: Error) {
        try? mark("ERROR", extra: ["error": String(describing: error)])
        releaseLock()
    }

    private static func releaseLock() {
        if lockDescriptor >= 0 {
            _ = systemFlock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }
}
