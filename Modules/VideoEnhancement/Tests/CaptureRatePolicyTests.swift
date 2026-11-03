import CoreMedia
@preconcurrency import ScreenCaptureKit

@main struct CaptureRatePolicyTests {
    static func main() {
        for cap in [0, 30, 60] {
            let configuration = SCStreamConfiguration()
            CaptureRatePolicy.configure(configuration, capFPS: cap)
            let expected = cap == 0 ? CMTime.zero : CMTime(value: 1, timescale: CMTimeScale(cap))
            precondition(CMTimeCompare(configuration.minimumFrameInterval, expected) == 0)
            print("cap=\(cap) value=\(configuration.minimumFrameInterval.value) timescale=\(configuration.minimumFrameInterval.timescale)")
        }
    }
}
