import Foundation
import Metal
import MetalPerformanceShaders
import MetalPerformanceShadersGraph

public enum K1Microbench {
    private final class Plan {
        let weights: WeightStore
        let queue: MTLCommandQueue
        let executable: MPSGraphExecutable
        let input: MPSGraphTensorData
        let output: MPSGraphTensorData
        let outputBuffer: MTLBuffer
        let shape: [Int]
        let depth: Int
        let compileMS: Double

        init(device: MTLDevice, url: URL, stage: Int, depth: Int) throws {
            let started = DispatchTime.now().uptimeNanoseconds
            let store = try WeightStore(url: url)
            self.weights = store
            self.queue = device.makeCommandQueue()!
            self.depth = depth
            let c = stage == 3 ? 64 : 32
            shape = stage == 3 ? [1, 40, 64, c] : [1, 80, 128, c]
            let g = MPSGraph()
            let dims = shape.map(NSNumber.init)
            let placeholder = g.placeholder(shape: dims, dataType: .float16, name: "input")
            var x = placeholder
            func weight(_ name: String) throws -> MPSGraphTensor {
                let entry = store.header.tensors.first { $0.name == name }!
                return g.constant(try store.tensorBytes(named: name), shape: entry.shape.map(NSNumber.init), dataType: .float16)
            }
            for j in 0..<depth {
                let p = "block\(stage).convblock.\(j)."
                let branch: MPSGraphTensor
                if let ranks = LowRankGraphContract.ranks[store.graphID] {
                    let zero = g.constant(0, shape: [NSNumber(value: ranks[stage - 3])], dataType: .float16)
                    let down = g.rifeConv2D(input: x, weight: try weight(p + "conv_a.weight"), bias: zero, stride: 1, padding: 1)
                    branch = g.rifeConv2D(input: down, weight: try weight(p + "conv_b.weight"), bias: try weight(p + "conv_b.bias"), stride: 1, padding: 0)
                } else {
                    let dense = g.rifeConv2D(input: x, weight: try weight(p + "conv.weight"), bias: try weight(p + "conv.bias"), stride: 1, padding: 1)
                    branch = g.multiplication(dense, try weight(p + "beta"), name: nil)
                }
                x = g.rifeLeakyReLU(input: g.addition(x, branch, name: nil), negativeSlope: 0.2)
            }
            executable = g.compile(with: MPSGraphDevice(mtlDevice: device),
                feeds: [placeholder: MPSGraphShapedType(shape: dims, dataType: .float16)],
                targetTensors: [x], targetOperations: nil, compilationDescriptor: nil)
            let count = shape.reduce(1, *)
            let inputBuffer = device.makeBuffer(length: count * 2, options: .storageModeShared)!
            outputBuffer = device.makeBuffer(length: count * 2, options: .storageModeShared)!
            let ptr = inputBuffer.contents().bindMemory(to: UInt16.self, capacity: count)
            for i in 0..<count { ptr[i] = Float16(sin(Float(i % 997) * 0.017) * 0.25).bitPattern }
            input = MPSGraphTensorData(inputBuffer, shape: dims, dataType: .float16)
            output = MPSGraphTensorData(outputBuffer, shape: dims, dataType: .float16)
            compileMS = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        }

        func run() throws -> [String: Double] {
            let started = DispatchTime.now().uptimeNanoseconds
            let command = K1CommandBuffers.make(queue.makeCommandBuffer()!)
            _ = executable.encode(to: command, inputs: [input], results: [output], executionDescriptor: nil)
            let last = command.commandBuffer
            command.commit()
            command.waitUntilCompleted()
            guard last.status == .completed else { throw IFNetError.commandBufferFailed(String(describing: last.error)) }
            return ["host_ms": Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6,
                    "last_command_buffer_gpu_ms": (last.gpuEndTime - last.gpuStartTime) * 1000]
        }

        func writeOutput(_ path: URL) throws {
            try Data(bytes: outputBuffer.contents(), count: shape.reduce(2, *)).write(to: path)
        }
    }

    public static func run(urls: [URL], outputDir: URL, warmup: Int, rounds: Int) throws -> [[String: Any]] {
        let device = MTLCreateSystemDefaultDevice()!
        var rows: [[String: Any]] = []
        for stage in [3, 4] {
            for depth in [1, 8] {
                let plans = try urls.map { try Plan(device: device, url: $0, stage: stage, depth: depth) }
                var samples = Array(repeating: [[String: Double]](), count: plans.count)
                for _ in 0..<warmup { for p in plans { _ = try p.run() } }
                for i in 0..<rounds {
                    let order = i.isMultiple(of: 2) ? Array(plans.indices) : Array(plans.indices.reversed())
                    for index in order { samples[index].append(try plans[index].run()) }
                }
                for (i, p) in plans.enumerated() {
                    let output = outputDir.appendingPathComponent("micro-b\(stage)-d\(depth)-m\(i).f16")
                    try p.writeOutput(output)
                    rows.append(["graph_id": p.weights.graphID, "model_path": urls[i].path,
                                 "stage": stage, "depth": depth, "shape_nhwc": p.shape,
                                 "compile_ms": p.compileMS, "samples": samples[i], "output_f16": output.path,
                                 "device_current_allocated_bytes": device.currentAllocatedSize])
                }
                FileHandle.standardError.write(Data("micro stage=\(stage) depth=\(depth) complete\n".utf8))
            }
        }
        return rows
    }
}
