import CoreMedia

@main struct Test {
    static func main() {
        func key(_ address: UInt, _ id: UInt64, _ time: Int64, _ generation: UInt64 = 1, _ clock: UInt64 = 1) -> SPRifeContinuityKey {
            SPRifeContinuityKey(address: address, identity: id, pts: CMTime(value: time, timescale: 60), generation: generation, clockEpoch: clock)
        }
        let cachedB = key(2, 2, 1)
        precondition(cachedB.matches(key(2, 2, 1))) // A/B -> B/C
        precondition(!cachedB.matches(key(1, 1, 0))) // A/D or repeated A/B
        precondition(!cachedB.matches(key(3, 2, 1))) // identity with different buffer
        precondition(!cachedB.matches(key(2, 3, 1))) // reused address
        precondition(!cachedB.matches(key(2, 2, 2))) // PTS mismatch
        precondition(!cachedB.matches(key(2, 2, 1, 2))) // source change
        precondition(!cachedB.matches(key(2, 2, 1, 1, 2))) // clock reset
        precondition(!cachedB.matches(SPRifeContinuityKey(address: 2, identity: 2, pts: .invalid, generation: 1, clockEpoch: 1)))
        print("RIFE continuity key: ok")
    }
}
