import Foundation

/// Two fixed topologies: the candidate and a full-rank numerical diagnostic.
/// No arbitrary graph, model alias, rank, beta or mask-policy inference.
enum LowRankGraphContract {
    static let ranks = [
        "odf-ifnet425-b3r32-b4r16-betafold-v1": [32, 16],
        "odf-ifnet425-b3r64-b4r32-betafold-diag-v1": [64, 32],
    ]

    static func schema(graph: String) -> [RifeWeightHeader.TensorEntry] {
        let rank = ranks[graph]!
        var entries: [RifeWeightHeader.TensorEntry] = []
        var offset = 0
        func append(_ name: String, _ shape: [Int]) {
            let size = shape.reduce(2, *)
            entries.append(.init(name: name, dtype: "f16", shape: shape, offset: offset, size: size))
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
                if i >= 3 {
                    append(r + "conv_a.weight", [3, 3, c, rank[i - 3]])
                    append(r + "conv_b.weight", [1, 1, rank[i - 3], c])
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

    static func validate(header: RifeWeightHeader, raw: [String: Any], alignment: Data, payloadBytes: Int) throws {
        let keys: Set<String> = ["model", "graph_id", "mask_update", "ifblock_channels", "scale_list", "input_layout", "tensors"]
        guard Set(raw.keys) == keys,
              let graph = header.graphID, ranks[graph] != nil,
              header.model == graph, header.maskUpdate == "replace",
              header.ifblockChannels == [192, 128, 96, 64, 32],
              header.scaleList == [16, 8, 4, 2, 1], header.inputLayout == "NHWC" else {
            throw WeightStoreError.invalidGraphContract("unknown low-rank topology or mask contract")
        }
        let expected = schema(graph: graph)
        guard header.tensors == expected,
              let entries = raw["tensors"] as? [[String: Any]],
              entries.allSatisfy({ Set($0.keys) == ["name", "dtype", "shape", "offset", "size"] }),
              alignment.allSatisfy({ $0 == 0 }),
              payloadBytes == expected.reduce(0, { $0 + $1.size }) else {
            throw WeightStoreError.invalidGraphContract("noncanonical low-rank tensors or payload")
        }
    }
}
