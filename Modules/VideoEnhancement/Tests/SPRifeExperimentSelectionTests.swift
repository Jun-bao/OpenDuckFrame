import Foundation

@main struct SPRifeExperimentSelectionTests {
    static func main() throws {
        precondition(SPRifeExperiments.available)
        let defaults = UserDefaults(suiteName: "app.openduckframe.ExperimentComparison")!
        let key = "RifeExperimentSelection"
        let saved = defaults.data(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            defaults.synchronize()
        }
        let models = ["original", "finetune-a", "finetune-b", "lowrank-initial", "lowrank-trained"]
        var checks = 0
        for model in models {
            for io in [false, true] {
                for mask in [false, true] {
                    let value = SPRifeExperimentSelection(ioOptimized: io, model: model, replaceMask: mask)
                    SPRifeExperiments.selection = value
                    precondition(SPRifeExperiments.selection == value)
                    checks += 1
                }
            }
        }
        SPRifeExperiments.selection = .init(ioOptimized: true, model: "missing", replaceMask: true)
        precondition(SPRifeExperiments.selection == .init(ioOptimized: true, model: "original", replaceMask: true))
        let normal = SingleInstancePolicy.namespace(experimentTrial: false, bundleID: "app.openduckframe.OpenDuckFrame")
        let debug = SingleInstancePolicy.namespace(experimentTrial: true, bundleID: "app.openduckframe.ExperimentTrial.debug")
        let release = SingleInstancePolicy.namespace(experimentTrial: true, bundleID: "app.openduckframe.ExperimentTrial.release")
        precondition(normal.isEmpty && !debug.isEmpty && !release.isEmpty && debug != release)
        print("\(checks) model/IO/mask choices persisted; invalid model normalized; normal and trial instance namespaces isolated")
    }
}
