import Foundation
import Metal

public enum PaddedFrameConvertError: Error {
    case shaderNotFound
    case pipelineCompilationFailed(String)
}

/// Converts the actual BGRA frame to a padded NHWC fp16 RGB buffer, copying
/// the rightmost column and bottom row across the extra logical pixels.
public final class PaddedFrameConvert {
    public let pipeline: MTLComputePipelineState

    public init(device: MTLDevice) throws {
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            throw PaddedFrameConvertError.pipelineCompilationFailed("library load failed: \(error)")
        }
        guard let function = library.makeFunction(name: "rifeBGRAToRGBPadded") else {
            throw PaddedFrameConvertError.shaderNotFound
        }
        do {
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw PaddedFrameConvertError.pipelineCompilationFailed(String(describing: error))
        }
    }

    /// Width and height describe the padded output; input keeps its actual size.
    public func encode(into encoder: MTLComputeCommandEncoder,
                       input: MTLTexture,
                       output: MTLBuffer,
                       width: Int,
                       height: Int) {
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setBuffer(output, offset: 0, index: 0)
        var dim = SIMD2<UInt32>(UInt32(width), UInt32(height))
        encoder.setBytes(&dim, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)

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
