import CoreMedia
@preconcurrency import ScreenCaptureKit

enum CaptureRatePolicy {
    static func configure(_ configuration: SCStreamConfiguration, capFPS: Int) {
        switch capFPS {
        case 30, 60:
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(capFPS))
        default:
            // Explicitly remove the artificial limit; the system and source
            // still determine the achieved capture cadence.
            configuration.minimumFrameInterval = .zero
        }
    }
}
