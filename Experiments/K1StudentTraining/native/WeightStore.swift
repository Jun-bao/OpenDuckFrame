import Foundation
import Metal
import MetalPerformanceShadersGraph

public enum WeightStoreError: Error, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt32)
    case headerParseFailed(String)
    case tensorNotFound(String)
    case fileTooSmall
}

/// Experimental loader for original product D0 and explicitly identified students.
/// Tensor access and MPS data wrapping retain the pinned product implementation.
public final class WeightStore {
    public let header: RifeWeightHeader
    public let containerVersion: UInt32
    public var graphID: String { header.model }
    public var maskUpdate: String { "accumulate" }
    private let mappedData: Data
    private let blobOffset: Int

    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count >= 12 else { throw WeightStoreError.fileTooSmall }
        guard data.subdata(in: 0..<4) == Data([0x52, 0x4D, 0x57, 0x31]) else {
            throw WeightStoreError.invalidMagic
        }
        let version = data.readUInt32LE(at: 4)
        guard version == 1 || version == 2 else { throw WeightStoreError.unsupportedVersion(version) }
        let headerLen = Int(data.readUInt32LE(at: 8))
        guard data.count >= 12 + headerLen else { throw WeightStoreError.fileTooSmall }
        let headerData = data.subdata(in: 12..<(12 + headerLen))
        let unpadded = 12 + headerLen
        let padding = (16 - (unpadded % 16)) % 16
        let payloadStart = unpadded + padding
        guard payloadStart <= data.count else { throw WeightStoreError.fileTooSmall }
        let raw: [String: Any]
        let decoded: RifeWeightHeader
        do {
            guard let object = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
                throw WeightStoreError.headerParseFailed("header must be an object")
            }
            raw = object
            decoded = try JSONDecoder().decode(RifeWeightHeader.self, from: headerData)
        } catch {
            throw WeightStoreError.headerParseFailed(String(describing: error))
        }
        try StudentGraphContract.validate(version: version, raw: raw,
            alignment: data.subdata(in: unpadded..<payloadStart), payloadBytes: data.count - payloadStart)
        self.header = decoded
        self.containerVersion = version
        self.blobOffset = payloadStart
        self.mappedData = data
    }

    /// Returns the raw fp16 bytes for the named tensor.
    public func tensorBytes(named name: String) throws -> Data {
        guard let entry = header.tensors.first(where: { $0.name == name }) else {
            throw WeightStoreError.tensorNotFound(name)
        }
        guard entry.offset >= 0, entry.size >= 0 else { throw WeightStoreError.fileTooSmall }
        let start = blobOffset + entry.offset
        let end = start + entry.size
        guard end <= mappedData.count else { throw WeightStoreError.fileTooSmall }
        return mappedData.subdata(in: start..<end)
    }

    /// Wraps the named tensor's bytes as MPSGraphTensorData (fp16, NHWC).
    public func tensorData(named name: String,
                           on device: MTLDevice) throws -> MPSGraphTensorData {
        guard let entry = header.tensors.first(where: { $0.name == name }) else {
            throw WeightStoreError.tensorNotFound(name)
        }
        guard entry.offset >= 0, entry.size >= 0 else { throw WeightStoreError.fileTooSmall }
        let start = blobOffset + entry.offset
        let end = start + entry.size
        guard end <= mappedData.count else { throw WeightStoreError.fileTooSmall }
        let bytes = mappedData.subdata(in: start..<end)
        return MPSGraphTensorData(device: MPSGraphDevice(mtlDevice: device), data: bytes,
                                  shape: entry.shape.map(NSNumber.init), dataType: .float16)
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }
}
