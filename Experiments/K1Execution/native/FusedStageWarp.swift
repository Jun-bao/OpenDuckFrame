import Foundation
import Metal

public enum FusedStageWarpError: Error {
    case shaderNotFound
    case pipelineCompilationFailed(String)
}

/// Fuses the non-final v4.25 stage's flow split, four warps, and four packs.
/// Inputs and outputs use the internal-resolution grid. RGB buffers are NHWC
/// fp16 [1, H, W, 3]; feature and flow buffers are NHWC fp16 [1, H, W, 4].
public final class FusedStageWarp {
    public let pipeline: MTLComputePipelineState

    public init(device: MTLDevice) throws {
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            throw FusedStageWarpError.pipelineCompilationFailed("library load failed: \(error)")
        }
        guard let function = library.makeFunction(name: "rifeFusedStageWarp") else {
            throw FusedStageWarpError.shaderNotFound
        }
        do {
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw FusedStageWarpError.pipelineCompilationFailed(String(describing: error))
        }
    }

    public func encode(into encoder: MTLComputeCommandEncoder,
                       first: MTLTexture,
                       second: MTLTexture,
                       firstFeatures: MTLTexture,
                       secondFeatures: MTLTexture,
                       flow: MTLBuffer,
                       firstOutput: MTLBuffer,
                       secondOutput: MTLBuffer,
                       firstFeatureOutput: MTLBuffer,
                       secondFeatureOutput: MTLBuffer,
                       width: Int,
                       height: Int) {
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(first, index: 0)
        encoder.setTexture(second, index: 1)
        encoder.setTexture(firstFeatures, index: 2)
        encoder.setTexture(secondFeatures, index: 3)
        encoder.setBuffer(flow, offset: 0, index: 0)
        encoder.setBuffer(firstOutput, offset: 0, index: 1)
        encoder.setBuffer(secondOutput, offset: 0, index: 2)
        encoder.setBuffer(firstFeatureOutput, offset: 0, index: 3)
        encoder.setBuffer(secondFeatureOutput, offset: 0, index: 4)
        var dim = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&dim, length: MemoryLayout<SIMD2<UInt32>>.size, index: 5)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let tg = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(
            width: (width + w - 1) / w,
            height: (height + h - 1) / h,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
    }
}
