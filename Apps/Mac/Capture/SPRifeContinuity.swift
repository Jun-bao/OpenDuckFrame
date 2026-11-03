import CoreMedia

// The buffer itself is retained separately by the bridge. This key prevents
// matching a recycled address or a frame from another timeline.
struct SPRifeContinuityKey {
    let address: UInt
    let identity: UInt64
    let pts: CMTime
    let generation: UInt64
    let clockEpoch: UInt64

    func matches(_ other: Self) -> Bool {
        address == other.address && identity == other.identity && pts.isNumeric && other.pts.isNumeric &&
            CMTimeCompare(pts, other.pts) == 0 && generation == other.generation && clockEpoch == other.clockEpoch
    }
}
