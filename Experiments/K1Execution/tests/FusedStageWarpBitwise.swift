// Standalone test body. The runner concatenates FusedStageWarp.swift before this
// source and puts default.metallib beside the executable, matching Bundle.main.
// These are the same five cases, seed, generator and value patterns used in the
// successful 513,016-half comparison; this test does not measure performance.
extension Bundle { static let module = Bundle.main }

struct CheckFailure: Error { let message: String }

@main struct FusedStageWarpCheck {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CheckFailure(message: "Metal unavailable")
        }
        let library = try device.makeDefaultLibrary(bundle: Bundle.module)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
        let split = try pipeline("rifeFlowSplit")
        let warp = try pipeline("rifeBackwardWarp")
        let rgbPack = try pipeline("rifeRGBATexToRGBBuf")
        let featurePack = try pipeline("rifeRGBATexTo4ChBuf")
        let fused = try FusedStageWarp(device: device)

        var seed: UInt64 = 0x9e3779b97f4a7c15
        func random() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 32) & 0xffff) / Float(0xffff)
        }
        let sizes = [(1, 1), (5, 3), (47, 29), (64, 33), (257, 129)]
        var totalHalfValues = 0
        var cases: [[String: Any]] = []
        for (width, height) in sizes {
            let count = width * height
            func texture(_ format: MTLPixelFormat) -> MTLTexture {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: width, height: height, mipmapped: false)
                desc.usage = [.shaderRead, .shaderWrite]
                desc.storageMode = .shared
                return device.makeTexture(descriptor: desc)!
            }
            let sources = (0..<4).map { sourceIndex -> MTLTexture in
                let source = texture(.rgba16Float)
                var data = [UInt16](repeating: 0, count: count * 4)
                for index in data.indices {
                    switch index % 31 {
                    case 0: data[index] = Float16.leastNonzeroMagnitude.bitPattern
                    case 1: data[index] = (-Float16.leastNonzeroMagnitude).bitPattern
                    case 2: data[index] = Float16.leastNormalMagnitude.bitPattern
                    case 3: data[index] = Float16(0.0).bitPattern
                    case 4: data[index] = Float16(-0.0).bitPattern
                    case 5: data[index] = Float16(65504.0).bitPattern
                    case 6: data[index] = Float16(-65504.0).bitPattern
                    default:
                        data[index] = Float16(sourceIndex < 2 ? random() : (random() - 0.5) * 16).bitPattern
                    }
                }
                data.withUnsafeBytes { raw in
                    source.replace(region: MTLRegionMake2D(0, 0, width, height),
                                   mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * 8)
                }
                return source
            }
            var flowValues = [UInt16](repeating: 0, count: count * 4)
            for index in flowValues.indices {
                let value: Float
                switch index % 17 {
                case 0: value = 0
                case 1: value = -0.0
                case 2: value = 0.5
                case 3: value = -0.5
                case 4: value = 65504
                case 5: value = -65504
                case 6: value = Float(Float16.leastNonzeroMagnitude)
                case 7: value = -Float(Float16.leastNonzeroMagnitude)
                default: value = (random() - 0.5) * Float(max(width, height)) * 2
                }
                flowValues[index] = Float16(value).bitPattern
            }
            let flow = flowValues.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)!
            }
            let flowTextures = [texture(.rg16Float), texture(.rg16Float)]
            let warpTextures = (0..<4).map { _ in texture(.rgba16Float) }
            let channels = [3, 3, 4, 4]
            let reference = channels.map {
                device.makeBuffer(length: count * $0 * 2, options: .storageModeShared)!
            }
            let result = channels.map {
                device.makeBuffer(length: count * $0 * 2, options: .storageModeShared)!
            }
            for output in reference + result { memset(output.contents(), 0xa5, output.length) }
            let commandBuffer = queue.makeCommandBuffer()!
            let encoder = commandBuffer.makeComputeCommandEncoder()!
            func dispatch(_ pipeline: MTLComputePipelineState) {
                encoder.setComputePipelineState(pipeline)
                let w = pipeline.threadExecutionWidth
                let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / pipeline.threadExecutionWidth)
                encoder.dispatchThreadgroups(
                    MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            }
            encoder.setBuffer(flow, offset: 0, index: 0)
            encoder.setTexture(flowTextures[0], index: 0)
            encoder.setTexture(flowTextures[1], index: 1)
            dispatch(split)
            func encodeWarp(_ i: Int) {
                encoder.setTexture(sources[i], index: 0)
                encoder.setTexture(flowTextures[i % 2], index: 1)
                encoder.setTexture(warpTextures[i], index: 2)
                dispatch(warp)
            }
            func encodePack(_ i: Int) {
                encoder.setTexture(warpTextures[i], index: 0)
                encoder.setBuffer(reference[i], offset: 0, index: 0)
                dispatch(i < 2 ? rgbPack : featurePack)
            }
            encodeWarp(0)
            encodeWarp(1)
            encodePack(0)
            encodePack(1)
            encodeWarp(2)
            encodeWarp(3)
            encodePack(2)
            encodePack(3)
            fused.encode(into: encoder, first: sources[0], second: sources[1],
                         firstFeatures: sources[2], secondFeatures: sources[3], flow: flow,
                         firstOutput: result[0], secondOutput: result[1],
                         firstFeatureOutput: result[2], secondFeatureOutput: result[3],
                         width: width, height: height)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else {
                throw CheckFailure(message: "GPU failed: \(String(describing: commandBuffer.error))")
            }
            var mismatchCount = 0
            for i in 0..<4 {
                let halfCount = count * channels[i]
                let expected = reference[i].contents().bindMemory(to: UInt16.self, capacity: halfCount)
                let actual = result[i].contents().bindMemory(to: UInt16.self, capacity: halfCount)
                for j in 0..<halfCount where expected[j] != actual[j] {
                    mismatchCount += 1
                    if mismatchCount <= 3 {
                        print("mismatch width=\(width) height=\(height) output=\(i) element=\(j) expected=\(expected[j]) actual=\(actual[j])")
                    }
                }
                totalHalfValues += halfCount
            }
            cases.append(["width": width, "height": height, "halfValues": count * 14,
                          "bitwiseMismatches": mismatchCount])
            if mismatchCount != 0 {
                throw CheckFailure(message: "\(mismatchCount) half values differ for \(width)x\(height)")
            }
        }
        let report: [String: Any] = [
            "device": device.name,
            "seed": "0x9e3779b97f4a7c15",
            "generator": "state = state * 6364136223846793005 + 1442695040888963407 (wrapping UInt64); Float((state >> 32) & 0xffff) / 65535",
            "sourcePatternPeriod": 31,
            "sourceSpecialValues": ["+minSubnormal", "-minSubnormal", "+minNormal", "+0", "-0", "+65504", "-65504"],
            "flowPatternPeriod": 17,
            "flowSpecialValues": ["+0", "-0", "+0.5", "-0.5", "+65504", "-65504", "+minSubnormal", "-minSubnormal"],
            "cases": cases,
            "comparedHalfValues": totalHalfValues,
            "bitwiseMismatches": 0,
            "baselineDispatchesPerCase": 9,
            "fusedDispatchesPerCase": 1,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report,
                                                         options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
