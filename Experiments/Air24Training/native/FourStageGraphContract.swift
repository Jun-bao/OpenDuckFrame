import Foundation

/// Private four-stage accumulated-mask graph; original RMW1 models are unchanged.
enum FourStageGraphContract {
    static func validate(raw: [String: Any], alignment: Data, payloadBytes: Int) throws {
        let graph = "odf-ifnet425-fourstage-acc-v1"
        let keys: Set<String> = ["model", "graph_id", "mask_update", "ifblock_channels", "scale_list", "input_layout", "tensors"]
        guard Set(raw.keys) == keys, raw["graph_id"] as? String == graph,
              raw["model"] as? String == graph, raw["mask_update"] as? String == "accumulate",
              raw["ifblock_channels"] as? [Int] == [192, 128, 96, 64],
              raw["scale_list"] as? [Int] == [16, 8, 4, 2],
              raw["input_layout"] as? String == "NHWC" else {
            throw WeightStoreError.headerParseFailed("unknown four-stage graph contract")
        }
        var tensors: [[String: Any]] = []
        var offset = 0
        func append(_ name: String, _ shape: [Int]) {
            let size = shape.reduce(2, *)
            tensors.append(["name": name, "dtype": "f16", "shape": shape, "offset": offset, "size": size])
            offset += size
        }
        for (i, shape) in [[3, 3, 3, 16], [3, 3, 16, 16], [3, 3, 16, 16], [4, 4, 4, 16]].enumerated() {
            append("encode.cnn\(i).weight", shape)
            append("encode.cnn\(i).bias", [i == 3 ? 4 : 16])
        }
        for (i, c) in [192, 128, 96, 64].enumerated() {
            let p = "block\(i)."
            append(p + "conv0.0.0.weight", [3, 3, i == 0 ? 15 : 28, c / 2])
            append(p + "conv0.0.0.bias", [c / 2])
            append(p + "conv0.1.0.weight", [3, 3, c / 2, c])
            append(p + "conv0.1.0.bias", [c])
            for j in 0..<8 {
                let r = p + "convblock.\(j)."
                append(r + "conv.weight", [3, 3, c, c])
                append(r + "conv.bias", [c])
                append(r + "beta", [1, 1, 1, c])
            }
            append(p + "lastconv.0.weight", [4, 4, 52, c])
            append(p + "lastconv.0.bias", [52])
        }
        guard let entries = raw["tensors"] as? [[String: Any]], entries.count == tensors.count,
              zip(entries, tensors).allSatisfy({ NSDictionary(dictionary: $0.0).isEqual(to: $0.1) }),
              alignment.allSatisfy({ $0 == 0 }), payloadBytes == offset else {
            throw WeightStoreError.headerParseFailed("noncanonical four-stage tensors or payload")
        }
    }
}
