import Foundation

@main
struct CalibrationPolicyTests {
    static func main() {
        precondition(SPResidentCalibrationPolicy.maximumValidationRounds == 3)
        precondition(SPResidentCalibrationPolicy.accepts(0.5))
        precondition(SPResidentCalibrationPolicy.accepts(2))
        precondition(!SPResidentCalibrationPolicy.accepts(0.499))
        precondition(!SPResidentCalibrationPolicy.accepts(2.001))
        precondition(!SPResidentCalibrationPolicy.accepts(.nan))
        precondition(SPResidentCalibrationPolicy.nextIterations(current: 65536, observedMs: 2.191458363085985) == 29905)
        precondition(SPResidentCalibrationPolicy.nextIterations(current: 65536, observedMs: 4) == 16384)
        precondition(SPResidentCalibrationPolicy.nextIterations(current: 16384, observedMs: 0.25) == 65536)
        let midpoint = SPResidentCalibrationPolicy.nextIterations(current: 65536, observedMs: 4, lower: 16384, upper: 65536)!
        precondition(midpoint == 40960)
        precondition(SPResidentCalibrationPolicy.accepts(4 * pow(Double(midpoint) / 65536, 2)))
        precondition(!SPResidentCalibrationPolicy.accepts(2.2))
        precondition(SPResidentCalibrationPolicy.nextIterations(current: .max, observedMs: 0.1) == nil)
        for invalid in [0.0, -1.0, .nan, .infinity] {
            precondition(SPResidentCalibrationPolicy.nextIterations(current: 65536, observedMs: invalid) == nil)
        }
        print("Calibration limits, observed Air sample, nonlinear oscillation and invalid timing checks passed")
    }
}
