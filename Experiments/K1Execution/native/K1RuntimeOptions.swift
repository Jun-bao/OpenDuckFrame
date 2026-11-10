/// Serial research harness only. Captured by each graph at construction.
/// Application integration replaces this switch with an explicit configuration.
public enum K1RuntimeOptions {
    public static var fusedStageWarp = false
    public static var trimFinalFeatures = false
    public static var directCrop = false
    public static var gpuInputPadding = false
}
