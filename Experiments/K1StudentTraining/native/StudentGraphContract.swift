import Foundation

/// Fixed accumulated-mask product students. RMW1 is reserved for the packaged D0.
/// No graph aliases, inferred ranks, or legacy replace-mask models are accepted.
enum StudentGraphContract {
    static let ranks = [
        "odf-ifnet425-acc-b3r32-b4r16-v1": [32, 16],
        "odf-ifnet425-acc-b3r64-b4r32-diag-v1": [64, 32],
    ]

    static func schema(ranks: [Int]?) -> [[String: Any]] {
        var entries: [[String: Any]] = []
        var offset = 0
        func append(_ name: String, _ shape: [Int]) {
            let size = shape.reduce(2, *)
            entries.append(["name": name, "dtype": "f16", "shape": shape,
                            "offset": offset, "size": size])
            offset += size
        }
        for (i, shape) in [[3, 3, 3, 16], [3, 3, 16, 16], [3, 3, 16, 16], [4, 4, 4, 16]].enumerated() {
            append("encode.cnn\(i).weight", shape)
            append("encode.cnn\(i).bias", [i == 3 ? 4 : 16])
        }
        for (i, c) in [192, 128, 96, 64, 32].enumerated() {
            let p = "block\(i)."
            append(p + "conv0.0.0.weight", [3, 3, i == 0 ? 15 : 28, c / 2])
            append(p + "conv0.0.0.bias", [c / 2])
            append(p + "conv0.1.0.weight", [3, 3, c / 2, c])
            append(p + "conv0.1.0.bias", [c])
            for j in 0..<8 {
                let r = p + "convblock.\(j)."
                if i >= 3, let ranks {
                    append(r + "conv_a.weight", [3, 3, c, ranks[i - 3]])
                    append(r + "conv_b.weight", [1, 1, ranks[i - 3], c])
                    append(r + "conv_b.bias", [c])
                } else {
                    append(r + "conv.weight", [3, 3, c, c])
                    append(r + "conv.bias", [c])
                    append(r + "beta", [1, 1, 1, c])
                }
            }
            append(p + "lastconv.0.weight", [4, 4, 52, c])
            append(p + "lastconv.0.bias", [52])
        }
        return entries
    }

    static func validate(version: UInt32, raw: [String: Any], alignment: Data,
                         payloadBytes: Int) throws {
        let baseKeys: Set<String> = ["model", "ifblock_channels", "scale_list", "input_layout", "tensors"]
        let expected: [[String: Any]]
        if version == 1 {
            guard Set(raw.keys) == baseKeys, raw["model"] as? String == "rife-v4.25" else {
                throw WeightStoreError.headerParseFailed("RMW1 is reserved for the original product D0")
            }
            expected = schema(ranks: nil)
        } else {
            guard version == 2, Set(raw.keys) == baseKeys.union(["graph_id", "mask_update"]),
                  let graph = raw["graph_id"] as? String, let ranks = ranks[graph],
                  raw["model"] as? String == graph,
                  raw["mask_update"] as? String == "accumulate" else {
                throw WeightStoreError.headerParseFailed("unknown student graph or accumulated-mask contract")
            }
            expected = schema(ranks: ranks)
        }
        guard raw["ifblock_channels"] as? [Int] == [192, 128, 96, 64, 32],
              raw["scale_list"] as? [Int] == [16, 8, 4, 2, 1],
              raw["input_layout"] as? String == "NHWC",
              let entries = raw["tensors"] as? [[String: Any]], entries.count == expected.count,
              zip(entries, expected).allSatisfy({ NSDictionary(dictionary: $0.0).isEqual(to: $0.1) }),
              alignment.allSatisfy({ $0 == 0 }),
              payloadBytes == expected.reduce(0, { $0 + ($1["size"] as! Int) }) else {
            throw WeightStoreError.headerParseFailed("noncanonical product-student metadata, tensors, or payload")
        }
    }
}
