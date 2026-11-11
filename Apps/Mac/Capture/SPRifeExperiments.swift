import AppKit
import CryptoKit
import Foundation

/// The legacy profile ID and resource name remain compatible with existing settings.
enum SPRifeProductionModel {
    static let graphID = "odf-ifnet425-fourstage-acc-v1"
    static let sha256 = "729ea555016da98e207bc4570e0be81dddbbd37302f7330c89696da798fba22d"

    static func matchesLoadedIdentity(_ identity: [String: Any]) -> Bool {
        identity["sha256"] as? String == sha256 &&
        identity["graphID"] as? String == graphID && identity["model"] as? String == graphID &&
        identity["stageCount"] as? Int == 4 && identity["tensorCount"] as? Int == 128 &&
        identity["containerVersion"] as? UInt32 == 2 && identity["overrideApplied"] as? Bool == false
    }
}

/// Private trial choices are separate from the shipping application's settings.
struct SPRifeExperimentSelection: Codable, Equatable, Sendable {
    var ioOptimized: Bool = false
    var model: String = "original"
    var replaceMask: Bool = false

    var normalized: Self {
        var value = self
        if !["original", "finetune-a", "finetune-b", "lowrank-initial", "lowrank-trained"].contains(model) {
            value.model = "original"
        }
        return value
    }
}

enum SPRifeExperiments {
    private static var suite: String {
        Bundle.main.object(forInfoDictionaryKey: "ODFExperimentDefaultsSuite") as? String
            ?? "app.openduckframe.ExperimentComparison"
    }
    private static let preferenceKey = "RifeExperimentSelection"

    static var airBeta: Bool { Bundle.main.object(forInfoDictionaryKey: "ODFAirBeta") as? Bool == true }
    static var available: Bool { isAvailable(in: .main) }
    static func isAvailable(in bundle: Bundle) -> Bool {
        bundle.object(forInfoDictionaryKey: "ODFExperimentTrial") as? Bool == true
    }

    static var selection: SPRifeExperimentSelection {
        get {
            if airBeta { return SPRifeExperimentSelection(ioOptimized: true) }
            guard let data = UserDefaults(suiteName: suite)?.data(forKey: preferenceKey),
                  let value = try? JSONDecoder().decode(SPRifeExperimentSelection.self, from: data) else {
                return SPRifeExperimentSelection()
            }
            return value.normalized
        }
        set {
            guard available, !airBeta, let data = try? JSONEncoder().encode(newValue.normalized) else { return }
            let defaults = UserDefaults(suiteName: suite)
            defaults?.set(data, forKey: preferenceKey)
            // The other build reads the same suite immediately after launch.
            defaults?.synchronize()
        }
    }

    static var optimizedBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "ODFExperimentBuild") as? String == "Release"
    }

    struct Resolved {
        let selection: SPRifeExperimentSelection
        let url: URL
        let graphID: String
        let sha256: String

        var diagnostics: [String: Any] {
            ["experimentModel": selection.model, "experimentGraph": graphID,
             "experimentWeightsSHA256": sha256, "experimentIO": selection.ioOptimized,
             "experimentReplaceMask": selection.replaceMask]
        }
    }

    private struct Model: Decodable {
        let id: String
        let fileName: String
        let sha256: String
        let graphID: String
        enum CodingKeys: String, CodingKey {
            case id, sha256
            case fileName = "file_name"
            case graphID = "graph_id"
        }
    }
    private struct Catalog: Decodable { let schema: Int; let models: [Model] }

    static func resolve(modelID: String, originalURL: URL, bundle: Bundle) throws -> Resolved? {
        guard isAvailable(in: bundle) else { return nil }
        let chosen = selection
        if chosen.model == "original" {
            return Resolved(selection: chosen, url: originalURL, graphID: modelID,
                            sha256: digest(originalURL))
        }
        guard modelID == "rife-v4.25" else {
            throw failure("实验模型用于 RIFE 4.25，请先选择 RIFE 4.25。")
        }
        guard let catalogURL = bundle.url(forResource: "experiment-models", withExtension: "json"),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL)),
              catalog.schema == 1, let model = catalog.models.first(where: { $0.id == chosen.model }),
              model.fileName == URL(fileURLWithPath: model.fileName).lastPathComponent,
              let url = bundle.url(forResource: model.fileName, withExtension: nil,
                                   subdirectory: "ExperimentModels") else {
            throw failure("试用包缺少所选模型，请使用完整的方案对比试用包。")
        }
        guard digest(url) == model.sha256 else {
            throw failure("试用模型文件与清单不符，已停止加载。")
        }
        return Resolved(selection: chosen, url: url, graphID: model.graphID, sha256: model.sha256)
    }

    private static func digest(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "app.openduckframe.experiment", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Debug and Release contain separately compiled executables; this is not
    /// an in-process switch that pretends to change compiler optimization.
    @MainActor static func switchBuild() async throws {
        guard available else { throw failure("当前不是方案对比试用版。") }
        let targetBuild = optimizedBuild ? "Debug" : "Release"
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(targetBuild).appendingPathComponent("OpenDuckFrame.app")
        guard let bundle = Bundle(url: appURL), isAvailable(in: bundle),
              bundle.object(forInfoDictionaryKey: "ODFExperimentBuild") as? String == targetBuild else {
            throw failure("没有找到另一种构建，请保留 Debug 与 Release 两个同级文件夹。")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--odf-experiment-comparison"]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if app != nil { continuation.resume() }
                else { continuation.resume(throwing: failure("另一种试用构建未能启动。")) }
            }
        }
    }
}
