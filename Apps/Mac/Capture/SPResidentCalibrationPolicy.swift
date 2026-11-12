import Foundation

/// Bounded feedback for a kernel whose observed cost can change during warmup.
enum SPResidentCalibrationPolicy {
    static let targetMs = 1.0
    static let minimumMs = 0.5
    static let maximumMs = 2.0
    static let maximumValidationRounds = 3

    static func accepts(_ milliseconds: Double) -> Bool {
        milliseconds.isFinite && milliseconds >= minimumMs && milliseconds <= maximumMs
    }

    static func nextIterations(current: UInt32, observedMs: Double,
                               lower: UInt32? = nil, upper: UInt32? = nil) -> UInt32? {
        guard current > 0, observedMs.isFinite, observedMs > 0 else { return nil }
        if let lower, let upper, lower < upper, upper - lower > 1 {
            return lower + (upper - lower) / 2
        }
        let scaled = (Double(current) * targetMs / observedMs).rounded()
        guard scaled.isFinite, scaled >= 1, scaled <= Double(UInt32.max) else { return nil }
        return UInt32(scaled)
    }
}
