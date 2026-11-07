import Foundation

/// Dedicated copied diagnostic runtime only. Never included in the cost binary.
/// IFNetGraph performs the existing synchronized readback; this helper separates
/// queries and verifies the four expected accumulated-state files were written.
public enum StudentStateDump {
    public enum DumpError: Error {
        case configuration(String)
        case missingState(String)
    }

    private static var activeDirectory: URL?
    private static let files = ["stage3_flow.npy", "stage3_mask.npy", "stage4_flow.npy", "stage4_mask.npy"]

    public static func requireConfigured() throws {
        guard let root = ProcessInfo.processInfo.environment["ODF_STUDENT_STATE_DUMP_DIR"], !root.isEmpty else {
            throw DumpError.configuration("set ODF_STUDENT_STATE_DUMP_DIR for this diagnostic-only runtime")
        }
    }

    public static func begin(caseID: String, variant: String, targets: [Double],
                             width: Int, height: Int, tier: String) throws {
        try requireConfigured()
        guard targets.count == 1, !caseID.contains("/"), !variant.contains("/"),
              caseID != ".", caseID != "..", variant != ".", variant != ".." else {
            throw DumpError.configuration("state probes require one alpha and plain case/variant ids")
        }
        let root = ProcessInfo.processInfo.environment["ODF_STUDENT_STATE_DUMP_DIR"]!
        let directory = URL(fileURLWithPath: root).appendingPathComponent(caseID)
            .appendingPathComponent(variant).appendingPathComponent("alpha-\(targets[0])")
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw DumpError.configuration("refusing to overwrite an existing state query: \(directory.path)")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata: [String: Any] = [
            "case_id": caseID, "variant": variant, "alpha": targets[0], "tier": tier,
            "source_width": width, "source_height": height,
            "layout": "NHWC", "storage": "native FP16 values converted losslessly to float32 NPY",
            "state": "block3/4 accumulated flow and pre-sigmoid accumulated mask logit",
            "flow_units": "internal-resolution pixels; G4 in Fast",
            "padding": "NPY retains the full padded internal grid; restrict to mapped valid region for comparison",
            "expected_files": files,
            "scope": "synchronized state readback adds stage barriers; diagnostic only, no cost measurement",
        ]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("context.json"), options: .atomic)
        activeDirectory = directory
        setenv("RIFE_DUMP_DIR", directory.path, 1)
    }

    public static func finish() throws {
        guard let directory = activeDirectory else { throw DumpError.configuration("no active state query") }
        for name in files {
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path),
                  data.count >= 10, data.prefix(6) == Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59]) else {
                throw DumpError.missingState(directory.appendingPathComponent(name).path)
            }
        }
        unsetenv("RIFE_DUMP_DIR")
        activeDirectory = nil
    }
}
