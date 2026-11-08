import Foundation

/// Per-interpolator trial options. Defaults retain the product's GPU I/O and
/// accumulated-mask behavior. Model selection remains the configuration's URL.
public struct RifeExperimentOptions: Sendable {
    public let gpuIO: Bool
    public let replaceMask: Bool

    public init(gpuIO: Bool = true, replaceMask: Bool = false) {
        self.gpuIO = gpuIO
        self.replaceMask = replaceMask
    }
}
