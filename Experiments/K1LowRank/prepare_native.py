"""Create a small, isolated native source variant from the pinned lab snapshot.

Only edits the new destination. Fails if the known patch anchors have changed.
The complete copied-source hashes and actual edits remain in source-origin.json.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def replace_once(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise ValueError(f"expected one patch anchor in {path.name}, found {text.count(old)}")
    path.write_text(text.replace(old, new))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    for directory in ("Sources/RifeMetal", "Sources/RifeMetalCore", "Plugins"):
        shutil.copytree(args.source / directory, args.output / directory)
    source_files = {str(p.relative_to(args.source)): digest(p) for root in ("Sources/RifeMetal", "Sources/RifeMetalCore", "Plugins")
                    for p in (args.source / root).rglob("*") if p.is_file()}
    here = Path(__file__).resolve().parent
    for name in ("LowRankGraphContract.swift", "K1Microbench.swift"):
        shutil.copyfile(here / "native" / name, args.output / "Sources/RifeMetalCore" / name)
    (args.output / "Sources/k1-bench").mkdir()
    shutil.copyfile(here / "native/main.swift", args.output / "Sources/k1-bench/main.swift")
    package = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "K1NativeLab", platforms: [.macOS(.v13)], products: [
    .executable(name: "k1-bench", targets: ["k1-bench"]),
], targets: [
    .target(name: "RifeMetal", dependencies: ["RifeMetalCore"], resources: [.copy("Resources/rife-v4.25.rmw")]),
    .target(name: "RifeMetalCore", exclude: ["Shaders"], plugins: [.plugin(name: "CompileMetalShaders")]),
    .plugin(name: "CompileMetalShaders", capability: .buildTool()),
    .executableTarget(name: "k1-bench", dependencies: ["RifeMetal", "RifeMetalCore"]),
])
'''
    (args.output / "Package.swift").write_text(package)
    store = args.output / "Sources/RifeMetalCore/WeightStore.swift"
    replace_once(store, '            try WideGraphContract.validate(header: decodedHeader, raw: raw,', '''            let lowRank = decodedHeader.graphID.flatMap { LowRankGraphContract.ranks[$0] } != nil
            if lowRank {
                try LowRankGraphContract.validate(header: decodedHeader, raw: raw,
                    alignment: data.subdata(in: unpadded..<payloadStart), payloadBytes: data.count - payloadStart)
            } else {
            try WideGraphContract.validate(header: decodedHeader, raw: raw,''')
    replace_once(store, '                                           payloadBytes: data.count - payloadStart)\n        }',
                       '                                           payloadBytes: data.count - payloadStart)\n            }\n        }')
    builder = args.output / "Sources/RifeMetalCore/IFBlockBuilder.swift"
    start = '            let w = try loadConst(name: "convblock.\\(j).conv.weight")'
    end = '            let residual = g.addition(scaled, x, name: "\\(prefix)convblock.\\(j).add")'
    text = builder.read_text()
    a, b = text.index(start), text.index(end)
    text = text[:a] + '''            let scaled: MPSGraphTensor
            if let ranks = LowRankGraphContract.ranks[weights.graphID], prefix == "block3." || prefix == "block4." {
                let r = ranks[prefix == "block3." ? 0 : 1]
                let down = try loadConst(name: "convblock.\\(j).conv_a.weight")
                let up = try loadConst(name: "convblock.\\(j).conv_b.weight")
                let bias = try loadConst(name: "convblock.\\(j).conv_b.bias")
                let zero = g.constant(0, shape: [NSNumber(value: r)], dataType: .float16)
                let reduced = g.rifeConv2D(input: x, weight: down, bias: zero, stride: 1, padding: 1)
                scaled = g.rifeConv2D(input: reduced, weight: up, bias: bias, stride: 1, padding: 0)
            } else {
                let w = try loadConst(name: "convblock.\\(j).conv.weight")
                let b = try loadConst(name: "convblock.\\(j).conv.bias")
                let conv = g.rifeConv2D(input: x, weight: w, bias: b, stride: 1, padding: 1)
                let beta = try loadConst(name: "convblock.\\(j).beta")
                scaled = g.multiplication(conv, beta, name: nil)
            }
''' + text[b:]
    builder.write_text(text)
    graph = args.output / "Sources/RifeMetalCore/IFNetGraph.swift"
    replace_once(graph, 'public final class IFNetGraph {', '''public final class IFNetGraph {
    public private(set) var k1LastBufferTiming: [String: Double] = [:]''')
    replace_once(graph, '''            mpsCB.commit()
            mpsCB.waitUntilCompleted()
        }  // end per-timestep loop''', '''            let timedBuffer = mpsCB.commandBuffer
            mpsCB.commit()
            mpsCB.waitUntilCompleted()
            guard timedBuffer.status == .completed else {
                throw IFNetError.commandBufferFailed(String(describing: timedBuffer.error))
            }
            k1LastBufferTiming = ["last_command_buffer_gpu_ms": (timedBuffer.gpuEndTime - timedBuffer.gpuStartTime) * 1000]
        }  // end per-timestep loop''')
    stream = args.output / "Sources/RifeMetal/RifeStream.swift"
    replace_once(stream, 'public final class RifeStream: @unchecked Sendable {', '''public final class RifeStream: @unchecked Sendable {
    public var k1LastBufferTiming: [String: Double] { graph.k1LastBufferTiming }''')
    manifest = dict(source=str(args.source.resolve()), input_files_sha256=source_files,
                    generated_by_sha256=digest(Path(__file__)),
                    changed_files_sha256={str(p.relative_to(args.output)): digest(p)
                                          for p in (store, builder, graph, stream, args.output / "Package.swift")},
                    note="Isolated experiment; full host call time is primary. Last command buffer GPU interval is not labeled full pipeline GPU time.")
    (args.output / "source-origin.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(dict(native_source=str(args.output), copied_files=len(source_files))))


if __name__ == "__main__":
    main()
