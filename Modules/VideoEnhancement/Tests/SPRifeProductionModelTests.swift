import Foundation
import CryptoKit

@main
struct ProductionModelTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let version = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
        let length = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian }
        let header = try JSONSerialization.jsonObject(with: data.subdata(in: 12..<(12 + Int(length)))) as! [String: Any]
        var identity: [String: Any] = [
            "containerVersion": version, "graphID": header["graph_id"]!, "model": header["model"]!,
            "stageCount": (header["scale_list"] as! [Int]).count,
            "tensorCount": (header["tensors"] as! [[String: Any]]).count,
            "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "overrideApplied": false]
        precondition(SPRifeProductionModel.matchesLoadedIdentity(identity))
        let frozen = identity
        identity["sha256"] = "ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74"
        precondition(!SPRifeProductionModel.matchesLoadedIdentity(identity))
        identity = frozen; identity["stageCount"] = 5
        precondition(!SPRifeProductionModel.matchesLoadedIdentity(identity))
        identity = frozen; identity["overrideApplied"] = true
        precondition(!SPRifeProductionModel.matchesLoadedIdentity(identity))
        print("Frozen four-stage RMW2 identity and original/override rejection passed")
    }
}
