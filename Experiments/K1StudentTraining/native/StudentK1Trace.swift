import Foundation
import os

/// Copied runtime only. The underlying controlled push/cache/graph is unchanged.
/// Signposts surround the existing host timestamps and exclude the 32 warmups.
enum StudentK1Trace {
    static let subsystem = "app.openduckframe.k1-attribution"
    static let log = OSLog(subsystem: subsystem, category: .pointsOfInterest)

    static func validate(config: [String: Any]) throws {
        guard ProcessInfo.processInfo.environment["ODF_K1_SIGNPOST_TRACE"] == "1",
              config["mode"] as? String == "controlled",
              config["app_entrypoints"] as? Bool == true,
              config["warmup_per_arm"] as? Int == 32,
              config["frames_per_arm"] as? Int == 100,
              let cases = config["cases"] as? [[String: Any]], cases.count == 1,
              let variants = config["variants"] as? [[String: Any]], variants.count == 1,
              let schedule = config["schedule"] as? [[String: Any]], schedule.count == 1,
              let id = variants[0]["id"] as? String,
              schedule[0]["alpha"] as? Double == 0.5,
              schedule[0]["cadence"] as? String == "continuous",
              schedule[0]["period_ms"] as? Double == 0,
              schedule[0]["order"] as? [String] == [id],
              schedule[0]["case_id"] as? String == cases[0]["id"] as? String,
              variants[0]["direct_crop"] as? Bool == true,
              variants[0]["gpu_input_padding"] as? Bool == true,
              variants[0]["fused_warp"] as? Bool != true,
              variants[0]["trim_final_features"] as? Bool != true,
              variants[0]["defer_commits"] as? Bool != true,
              variants[0]["native_leaky"] as? Bool != true,
              ProcessInfo.processInfo.environment["ODF_K1_PROFILE"] != "1" else {
            throw BenchError.configuration("trace-only runtime requires ODF_K1_SIGNPOST_TRACE=1, one continuous midpoint/provided-output arm, IO=true, 32 warmups and 100 records")
        }
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
}
