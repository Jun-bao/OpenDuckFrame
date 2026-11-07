"""Prepare a pinned product-native execution variant; never modify the source."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"expected one source anchor: {old[:70]!r}")
    return text.replace(old, new)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    args = ap.parse_args()
    here = Path(__file__).resolve().parent
    prior = here.parent / "K1LowRank"
    canonical = here.parents[1] / "ThirdParty/rife-metal"
    args.output.mkdir(parents=True, exist_ok=False)
    for folder in ("Sources/RifeMetal", "Sources/RifeMetalCore", "Plugins"):
        shutil.copytree(args.source / folder, args.output / folder)
    shutil.copyfile(args.source / "LICENSE", args.output / "LICENSE")
    # SwiftPM source checkouts mark files read-only; only the generated copy is edited.
    for relative in ("Sources/RifeMetalCore/IFNetGraph.swift", "Sources/RifeMetal/RifeStream.swift", "Sources/RifeMetalCore/WeightStore.swift", "Sources/RifeMetalCore/IFBlockBuilder.swift"):
        path = args.output / relative
        path.chmod(path.stat().st_mode | 0o200)
    original = {str(p.relative_to(args.source)): sha(p) for folder in ("Sources/RifeMetal", "Sources/RifeMetalCore", "Plugins")
                for p in (args.source / folder).rglob("*") if p.is_file()}
    for name in ("FusedStageWarp.swift", "PaddedFrameConvert.swift", "K1RuntimeOptions.swift", "NarrowGraphContract.swift"):
        owner = canonical if name == "PaddedFrameConvert.swift" else here / "native"
        shutil.copyfile(owner / name, args.output / "Sources/RifeMetalCore" / name)
    shutil.copyfile(here / "native/FusedStageWarp.metal", args.output / "Sources/RifeMetalCore/Shaders/FusedStageWarp.metal")
    shutil.copyfile(canonical / "PaddedFrameConvert.metal", args.output / "Sources/RifeMetalCore/Shaders/PaddedFrameConvert.metal")
    shutil.copyfile(prior / "native/K1ProfileBuffer.swift", args.output / "Sources/RifeMetalCore/K1ProfileBuffer.swift")
    (args.output / "Sources/k1-runtime").mkdir()
    helpers = (prior / "native/main.swift").read_text().split("\ndo {\n    guard CommandLine", 1)[0]
    (args.output / "Sources/k1-runtime/main.swift").write_text(helpers + "\n" + (here / "native/main.swift").read_text())
    controlled = (prior / "native/K1ControlledBench.swift").read_text()
    controlled = controlled.replace("private func pixelHash", "func pixelHash")
    controlled = once(controlled, 'let modelKey = path + "|native_leaky=\\(nativeLeaky)"',
        'let fused = variant["fused_warp"] as? Bool ?? false\n        let trimmed = variant["trim_final_features"] as? Bool ?? false\n        let directCrop = variant["direct_crop"] as? Bool ?? false\n        let gpuPad = variant["gpu_input_padding"] as? Bool ?? false\n        let modelKey = path + "|fused=\\(fused)|trim=\\(trimmed)|crop=\\(directCrop)|pad=\\(gpuPad)"')
    controlled = once(controlled, "K1BenchmarkGraph.nativeLeakyReLU = nativeLeaky", "K1BenchmarkGraph.nativeLeakyReLU = nativeLeaky\n        K1RuntimeOptions.fusedStageWarp = fused\n        K1RuntimeOptions.trimFinalFeatures = trimmed\n        K1RuntimeOptions.directCrop = directCrop\n        K1RuntimeOptions.gpuInputPadding = gpuPad")
    controlled = once(controlled, '"variant": id, "defer_commits":', '"variant": id, "fused_warp": variant["fused_warp"] as? Bool ?? false, "defer_commits":')
    controlled = once(controlled, 'let variant = variantMap[id]!, stream = streams[id]!', '''let variant = variantMap[id]!, stream = streams[id]!
            let appMidpoint = (config["app_entrypoints"] as? Bool ?? false) && alpha == 0.5
            let providedOutput = appMidpoint ? try PixelBufferConvert.makeOutputPixelBuffer(width: width, height: height) : nil
            func pushFrame(_ frame: CVPixelBuffer) throws -> [CVPixelBuffer] {
                if appMidpoint {
                    return try stream.push(frame, into: providedOutput!) ? [providedOutput!] : []
                }
                return try stream.push(frame, timesteps: [alpha])
            }''')
    controlled = once(controlled, '_ = try stream.push(i.isMultiple(of: 2) ? second : first, timesteps: [alpha])', '_ = try pushFrame(i.isMultiple(of: 2) ? second : first)')
    controlled = once(controlled, 'let result = try stream.push(frame.isMultiple(of: 2) ? second : first, timesteps: [alpha])', 'let result = try pushFrame(frame.isMultiple(of: 2) ? second : first)')
    controlled = once(controlled, '"variant": id, "fused_warp":', '"variant": id, "entrypoint": appMidpoint ? "into" : "returning", "fused_warp":')
    (args.output / "Sources/k1-runtime/K1ControlledBench.swift").write_text(controlled)
    (args.output / "Package.swift").write_text('''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "K1ProductRuntime", platforms: [.macOS(.v13)], products: [
 .library(name: "RifeMetal", targets: ["RifeMetal", "RifeMetalCore"]),
 .executable(name: "k1-runtime", targets: ["k1-runtime"])
], targets: [
 .target(name: "RifeMetal", dependencies: ["RifeMetalCore"], resources: [.copy("Resources/rife-v4.25.rmw")]),
 .target(name: "RifeMetalCore", exclude: ["Shaders"], plugins: [.plugin(name: "CompileMetalShaders")]),
 .plugin(name: "CompileMetalShaders", capability: .buildTool()),
 .executableTarget(name: "k1-runtime", dependencies: ["RifeMetal", "RifeMetalCore"])
])
''')
    path = args.output / "Sources/RifeMetalCore/WeightStore.swift"
    text = once(path.read_text(), "guard version == 1 else", "guard version == 1 || version == 2 else")
    text = once(text, "self.blobOffset = unpadded + padding", """self.blobOffset = unpadded + padding
        if version == 2 {
            guard self.blobOffset <= data.count,
                  let raw = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
                throw WeightStoreError.fileTooSmall
            }
            try NarrowGraphContract.validate(raw: raw,
                alignment: data.subdata(in: unpadded..<self.blobOffset),
                payloadBytes: data.count - self.blobOffset)
        }""")
    path.write_text(text)
    path = args.output / "Sources/RifeMetalCore/IFBlockBuilder.swift"
    text = once(path.read_text(), "scale: Int) throws ->", "scale: Int, flowMaskOnly: Bool = false) throws ->")
    text = once(text, 'let dW = try loadConst(name: "lastconv.0.weight")', 'var dW = try loadConst(name: "lastconv.0.weight")')
    text = once(text, 'let dB = try loadConst(name: "lastconv.0.bias")', '''var dB = try loadConst(name: "lastconv.0.bias")
        if flowMaskOnly {
            dW = g.sliceTensor(dW, dimension: 2, start: 0, length: 20, name: "lastconv.used_weight")
            dB = g.sliceTensor(dB, dimension: 0, start: 0, length: 20, name: "lastconv.used_bias")
        }''')
    text = once(text, 'let feat    = g.sliceTensor(tmp, dimension: 3, start: 5, length: 8,', 'let feat    = flowMaskOnly ? mask : g.sliceTensor(tmp, dimension: 3, start: 5, length: 8,')
    path.write_text(text)
    path = args.output / "Sources/RifeMetalCore/IFNetGraph.swift"
    text = path.read_text()
    text = once(text, "public final class IFNetGraph {", """public final class IFNetGraph {
    private let k1FusedWarp: FusedStageWarp?
    private let k1GPUPad: PaddedFrameConvert?
    private let k1DirectCrop: Bool
    package var supportsGPUInputPadding: Bool { k1GPUPad != nil }
    package var usesDirectCroppedReturn: Bool { k1DirectCrop && supportsCroppedOutput }
    public private(set) var k1LastProfile: [String: Any] = [:]
    public private(set) var k1LastBufferTiming: [String: Double] = [:]""")
    text = once(text, "self.scaleList = weights.header.scaleList", "self.scaleList = weights.header.scaleList\n        self.k1FusedWarp = K1RuntimeOptions.fusedStageWarp ? try FusedStageWarp(device: context.device) : nil\n        self.k1GPUPad = K1RuntimeOptions.gpuInputPadding ? try PaddedFrameConvert(device: context.device) : nil\n        self.k1DirectCrop = K1RuntimeOptions.directCrop")
    text = once(text, "internalScale == 0.5 && !scaleList.isEmpty", "(internalScale == 0.5 || (k1DirectCrop && internalScale == 0.25)) && !scaleList.isEmpty")
    for texture, buffer in (("frameTex", "imgFullBufOut"), ("currTex", "currImgFullBuf")):
        old = f'''            enc.setComputePipelineState(conv.bgraToRGB)
            enc.setTexture({texture}, index: 0)
            enc.setBuffer({buffer}, offset: 0, index: 0)
            dispatch2D(enc, conv.bgraToRGB, gridW: width, gridH: height)'''
        new = f'''            if let padding = k1GPUPad {{
                padding.encode(into: enc, input: {texture}, output: {buffer}, width: width, height: height)
            }} else {{
''' + "\n".join("    " + line for line in old.splitlines()) + "\n            }"
        text = once(text, old, new)
    text = once(text, "let inputTensors: [MPSGraphTensor]", "let inputTensors: [MPSGraphTensor]\n        let outputsFeatures: Bool")
    text = once(text, "height: intH\n            )\n            execs.append(stage)", "height: intH, trimFinalFeatures: K1RuntimeOptions.trimFinalFeatures\n            )\n            execs.append(stage)")
    text = once(text, "height: Int) throws -> CompiledStage {", "height: Int, trimFinalFeatures: Bool) throws -> CompiledStage {")
    text = once(text, 'let blockBuilder = IFBlockBuilder(graph: g, weights: weights,', 'let trimsTail = trimFinalFeatures && stageIndex == weights.header.scaleList.count - 1\n        let blockBuilder = IFBlockBuilder(graph: g, weights: weights,')
    text = once(text, "scale: scale)\n\n        let feeds", "scale: scale, flowMaskOnly: trimsTail)\n\n        let feeds")
    text = once(text, "targetTensors: [flow, mask, feat]", "targetTensors: trimsTail ? [flow, mask] : [flow, mask, feat]")
    text = once(text, "CompiledStage(executable: exec, inputTensors: orderedInputs)", "CompiledStage(executable: exec, inputTensors: orderedInputs, outputsFeatures: !trimsTail)")
    for value in ("flowAccTD_A, maskAccTD_A", "flowRawTD, maskRawTD"):
        old = "results: [" + value + ", outFeatTD]"
        if text.count(old) != 2:
            raise ValueError("expected stateless and streaming stage outputs")
        text = text.replace(old, "results: stage.outputsFeatures ? [" + value + ", outFeatTD] : [" + value + "]")
    # Both stateless and streaming calls preserve the same post-stage outputs.
    marker = "enc.setComputePipelineState(conv.flowSplit)"
    position, count = 0, 0
    while True:
        start = text.find(marker, position)
        if start < 0:
            break
        line = text.rfind("\n", 0, start) + 1
        indent = text[line:start]
        end = text.index(indent + "enc.endEncoding()", start)
        old = text[line:end]
        if "p.stageWarped0Buf" not in old or "p.stageWf1Buf" not in old:
            raise ValueError("unexpected stage warp block")
        call = '''if let fused = k1FusedWarp {
    fused.encode(into: enc, first: p.srcTex0Int, second: p.srcTex1Int,
        firstFeatures: p.f0Tex, secondFeatures: p.f1Tex, flow: accFlowBuf!,
        firstOutput: p.stageWarped0Buf, secondOutput: p.stageWarped1Buf,
        firstFeatureOutput: p.stageWf0Buf, secondFeatureOutput: p.stageWf1Buf,
        width: intW, height: intH)
} else {
'''
        wrapped = "".join(indent + x + "\n" for x in call.splitlines())
        wrapped += "".join("    " + x + "\n" for x in old.rstrip().splitlines()) + indent + "}\n\n"
        text = text[:line] + wrapped + text[end:]
        position = line + len(wrapped) + len("enc.endEncoding()")
        count += 1
    if count != 2:
        raise ValueError(f"expected two post-stage warp paths, got {count}")
    text = text.replace("MPSCommandBuffer(commandBuffer: ", "K1CommandBuffers.make(")
    anchor = "            mpsCB.commit()\n            mpsCB.waitUntilCompleted()\n        }  // end per-timestep loop"
    text = once(text, anchor, """            let timedBuffer = mpsCB.commandBuffer
            mpsCB.commit()
            mpsCB.waitUntilCompleted()
            guard timedBuffer.status == .completed else {
                throw IFNetError.commandBufferFailed(String(describing: timedBuffer.error))
            }
            k1LastBufferTiming = ["last_command_buffer_gpu_ms": (timedBuffer.gpuEndTime - timedBuffer.gpuStartTime) * 1000]
            k1LastProfile = mpsCB.k1ProfileSnapshot()
        }  // end per-timestep loop""")
    path.write_text(text)
    path = args.output / "Sources/RifeMetal/RifeStream.swift"
    text = once(path.read_text(), "public final class RifeStream: @unchecked Sendable {", """public final class RifeStream: @unchecked Sendable {
    public var k1LastProfile: [String: Any] { graph.k1LastProfile }
    public var k1LastBufferTiming: [String: Double] { graph.k1LastBufferTiming }""")
    old = "if needsPad {\n                paddedFrame = try paddedInput(frame)"
    if text.count(old) != 2:
        raise ValueError("expected both stream input-padding entrypoints")
    text = text.replace(old, "if needsPad && !(graph.supportsGPUInputPadding && fmt == kCVPixelFormatType_32BGRA && CVPixelBufferGetIOSurface(frame) != nil) {\n                paddedFrame = try paddedInput(frame)")
    text = once(text, "// Allocate padded output buffers.", "let directCrop = needsPad && graph.usesDirectCroppedReturn\n            // Allocate only caller-visible output when the final GPU writer supports it.")
    text = once(text, "width: paddedW, height: paddedH)\n                outBuffers.append(outBuf)", "width: directCrop ? width : paddedW, height: directCrop ? height : paddedH)\n                outBuffers.append(outBuf)")
    text = once(text, "if needsPad {\n                var cropped:", "if needsPad && !directCrop {\n                var cropped:")
    path.write_text(text)
    changed = {str(p.relative_to(args.output)): sha(p) for p in (args.output / "Sources").rglob("*") if p.is_file()}
    (args.output / "source-origin.json").write_text(json.dumps(dict(original=original, generated=changed,
        preparer_sha256=sha(Path(__file__)), mask_update="accumulate", weights_unchanged=True), indent=2) + "\n")
    print(args.output)
