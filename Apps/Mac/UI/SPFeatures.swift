// Feature availability = compile-time lane ∧ runtime tier. Build recipes opt
// in by defining SP_ENHANCE, independently of the distribution channel.
// Within an enhanced build, only the full tier (macOS 26+, see
// SPRuntimeGates.hpp::spFullTier) presents the controls; the compatibility
// tier hides the chip, the menu and the shortcuts, and the core clamps every
// entry point to Off. Evaluated once, lazily, off the first-frame path.
enum SPFeatures {
    /// Motion smoothing is unavailable unless the build explicitly opts in
    /// and the system is on the full tier. UI and core share this boundary.
    #if SP_ENHANCE
    static let enhancements: Bool = SPPlayerCore.fullFeatureTier()
    #else
    static let enhancements = false
    #endif
}
