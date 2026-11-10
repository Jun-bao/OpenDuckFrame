// The runner concatenates PaddedFrameConvert.swift before this standalone test.
// Baseline: CPU BGRA edge replication followed by original rifeBGRAToRGB.
extension Bundle { static let module = Bundle.main }

struct PadCheckFailure: Error { let message: String }

@main struct PaddedFrameConvertCheck {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PadCheckFailure(message: "Metal unavailable")
        }
        let library = try device.makeDefaultLibrary(bundle: Bundle.module)
        let original = try device.makeComputePipelineState(function: library.makeFunction(name: "rifeBGRAToRGB")!)
        let padded = try PaddedFrameConvert(device: device)
        var seed: UInt64 = 0x8d381fb24c971a65
        func randomByte() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 32)
        }
        let sizes = [(1, 1), (3, 5), (255, 257), (256, 256), (259, 131)]
        var totalHalfValues = 0
        var cases: [[String: Any]] = []
        for (width, height) in sizes {
            let paddedWidth = (width + 255) / 256 * 256
            let paddedHeight = (height + 255) / 256 * 256
            var inputBytes = (0..<(width * height * 4)).map { _ in randomByte() }
            // Distinct B/G/R values and alternating extrema on right/bottom edges.
            for y in 0..<height {
                for x in 0..<width where x == width - 1 || y == height - 1 {
                    let i = (y * width + x) * 4
                    inputBytes[i] = (x + y) % 2 == 0 ? 0 : 255
                    inputBytes[i + 1] = UInt8(truncatingIfNeeded: x * 17 + y * 31 + 127)
                    inputBytes[i + 2] = (x + y) % 2 == 0 ? 255 : 0
                }
            }
            var cpuPadded = [UInt8](repeating: 0, count: paddedWidth * paddedHeight * 4)
            for y in 0..<paddedHeight {
                for x in 0..<paddedWidth {
                    let source = (min(y, height - 1) * width + min(x, width - 1)) * 4
                    let destination = (y * paddedWidth + x) * 4
                    for channel in 0..<4 { cpuPadded[destination + channel] = inputBytes[source + channel] }
                }
            }
            func texture(_ width: Int, _ height: Int, _ bytes: [UInt8]) -> MTLTexture {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                desc.storageMode = .shared
                desc.usage = .shaderRead
                let result = device.makeTexture(descriptor: desc)!
                bytes.withUnsafeBytes { raw in
                    result.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                   withBytes: raw.baseAddress!, bytesPerRow: width * 4)
                }
                return result
            }
            let input = texture(width, height, inputBytes)
            let baselineInput = texture(paddedWidth, paddedHeight, cpuPadded)
            let halfCount = paddedWidth * paddedHeight * 3
            let expected = device.makeBuffer(length: halfCount * 2, options: .storageModeShared)!
            let actual = device.makeBuffer(length: halfCount * 2, options: .storageModeShared)!
            memset(expected.contents(), 0xa5, expected.length)
            memset(actual.contents(), 0xa5, actual.length)
            let commandBuffer = queue.makeCommandBuffer()!
            let encoder = commandBuffer.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(original)
            encoder.setTexture(baselineInput, index: 0)
            encoder.setBuffer(expected, offset: 0, index: 0)
            let w = original.threadExecutionWidth
            let h = max(1, original.maxTotalThreadsPerThreadgroup / w)
            encoder.dispatchThreadgroups(
                MTLSize(width: (paddedWidth + w - 1) / w, height: (paddedHeight + h - 1) / h, depth: 1),
                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            padded.encode(into: encoder, input: input, output: actual, width: paddedWidth, height: paddedHeight)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else {
                throw PadCheckFailure(message: "GPU failed: \(String(describing: commandBuffer.error))")
            }
            let expectedValues = expected.contents().bindMemory(to: UInt16.self, capacity: halfCount)
            let actualValues = actual.contents().bindMemory(to: UInt16.self, capacity: halfCount)
            var mismatchCount = 0
            for index in 0..<halfCount where expectedValues[index] != actualValues[index] {
                mismatchCount += 1
                if mismatchCount <= 3 {
                    print("mismatch input=\(width)x\(height) padded=\(paddedWidth)x\(paddedHeight) element=\(index) expected=\(expectedValues[index]) actual=\(actualValues[index])")
                }
            }
            totalHalfValues += halfCount
            cases.append(["inputWidth": width, "inputHeight": height, "paddedWidth": paddedWidth,
                          "paddedHeight": paddedHeight, "halfValues": halfCount, "bitwiseMismatches": mismatchCount])
            if mismatchCount != 0 { throw PadCheckFailure(message: "\(mismatchCount) half values differ") }
        }
        let report: [String: Any] = [
            "device": device.name,
            "seed": "0x8d381fb24c971a65",
            "generator": "state = state * 6364136223846793005 + 1442695040888963407 (wrapping UInt64); UInt8(truncatingIfNeeded: state >> 32)",
            "coverage": ["random BGRA8", "distinct B/G/R", "right/bottom edges", "0/255 byte extrema", "1x1", "odd dimensions", "already padded dimensions"],
            "cases": cases,
            "comparedHalfValues": totalHalfValues,
            "bitwiseMismatches": 0,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report,
                                                         options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
