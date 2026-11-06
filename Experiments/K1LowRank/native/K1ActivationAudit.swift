import Foundation
import Metal
import MetalPerformanceShaders
import MetalPerformanceShadersGraph

/// Exhaustive point-operation probe on this backend; not a whole-network proof.
public enum K1ActivationAudit {
    public static func run(outputDir: URL) throws -> [String: Any] {
        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let graph = MPSGraph(), shape: [NSNumber] = [1, 256, 256, 1]
        let input = graph.placeholder(shape: shape, dataType: .float16, name: "all_half_patterns")
        let zero = graph.constant(0, dataType: .float16), slope = graph.constant(0.2, dataType: .float16)
        let expanded = graph.addition(graph.maximum(input, zero, name: nil),
            graph.multiplication(slope, graph.minimum(input, zero, name: nil), name: nil), name: "expanded")
        let native = graph.leakyReLU(with: input, alphaTensor: slope, name: "native")
        let executable = graph.compile(with: MPSGraphDevice(mtlDevice: device),
            feeds: [input: MPSGraphShapedType(shape: shape, dataType: .float16)],
            targetTensors: [expanded, native], targetOperations: nil, compilationDescriptor: nil)
        let source = device.makeBuffer(length: 65536 * 2, options: .storageModeShared)!
        let a = device.makeBuffer(length: 65536 * 2, options: .storageModeShared)!
        let b = device.makeBuffer(length: 65536 * 2, options: .storageModeShared)!
        let values = source.contents().bindMemory(to: UInt16.self, capacity: 65536)
        for i in 0..<65536 { values[i] = UInt16(i) }
        let command = MPSCommandBuffer(commandBuffer: queue.makeCommandBuffer()!)
        _ = executable.encode(to: command,
            inputs: [MPSGraphTensorData(source, shape: shape, dataType: .float16)],
            results: [MPSGraphTensorData(a, shape: shape, dataType: .float16), MPSGraphTensorData(b, shape: shape, dataType: .float16)],
            executionDescriptor: nil)
        command.commit()
        command.waitUntilCompleted()
        guard command.rootCommandBuffer.status == .completed else { throw IFNetError.commandBufferFailed("activation probe") }
        let left = a.contents().bindMemory(to: UInt16.self, capacity: 65536)
        let right = b.contents().bindMemory(to: UInt16.self, capacity: 65536)
        var finite = 0, finiteMismatch = 0, signedZeroOnly = 0, nonfiniteMismatch = 0
        var maximumError: Float = 0
        var examples: [[String: Any]] = []
        for i in 0..<65536 {
            let isFinite = UInt16(i) & 0x7c00 != 0x7c00
            if isFinite { finite += 1 }
            if left[i] != right[i] {
                if isFinite {
                    finiteMismatch += 1
                    if left[i] & 0x7fff == 0 && right[i] & 0x7fff == 0 { signedZeroOnly += 1 }
                    maximumError = max(maximumError, abs(Float(Float16(bitPattern: left[i])) - Float(Float16(bitPattern: right[i]))))
                    if examples.count < 12 { examples.append(["input_bits": i, "expanded_bits": left[i], "native_bits": right[i]]) }
                } else { nonfiniteMismatch += 1 }
            }
        }
        try Data(bytes: a.contents(), count: 65536 * 2).write(to: outputDir.appendingPathComponent("expanded.f16"))
        try Data(bytes: b.contents(), count: 65536 * 2).write(to: outputDir.appendingPathComponent("native.f16"))
        return ["all_patterns": 65536, "finite_patterns": finite, "finite_bit_mismatches": finiteMismatch,
                "finite_signed_zero_only_mismatches": signedZeroOnly, "finite_max_abs_error": maximumError,
                "nonfinite_bit_mismatches": nonfiniteMismatch, "examples": examples,
                "scope": "one shape/backend, FP16 slope tensor 0.2; graph fusion and whole-network outputs still need separate checks"]
    }
}
