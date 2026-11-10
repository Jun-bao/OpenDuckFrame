import Foundation
import Darwin

/// Beta log I/O is serialized off the main thread so termination can stay bounded.
final class SPAirBetaLiveLogWriter: @unchecked Sendable {
    struct Receipt: Sendable {
        let acceptedLines: Int
        let writtenLines: Int
        let droppedLines: Int
        let pendingBytes: Int
        let maximumPendingBytes: Int
        let firstError: String?
        let firstErrorHostTicks: UInt64?
        let firstErrorUnixSeconds: Double?

        var complete: Bool { firstError == nil && droppedLines == 0 && pendingBytes == 0 && acceptedLines == writtenLines }
        var jsonObject: [String: Any] {
            ["complete": complete, "acceptedLines": acceptedLines, "writtenLines": writtenLines,
             "droppedLines": droppedLines, "pendingBytes": pendingBytes, "maximumPendingBytes": maximumPendingBytes,
             "firstError": firstError ?? NSNull(), "firstErrorHostTicks": firstErrorHostTicks.map { $0 as Any } ?? NSNull(),
             "firstErrorUnixSeconds": firstErrorUnixSeconds.map { $0 as Any } ?? NSNull()]
        }
    }

    private let url: URL
    private let maximumPendingBytes: Int
    private let queue = DispatchQueue(label: "app.openduckframe.air-beta.live-log", qos: .utility)
    private let lock = NSLock()
    private var handle: FileHandle? // queue only
    private var acceptedLines = 0
    private var writtenLines = 0
    private var droppedLines = 0
    private var pendingBytes = 0
    private var firstError: String?
    private var firstErrorHostTicks: UInt64?
    private var firstErrorUnixSeconds: Double?

    init(url: URL, maximumPendingBytes: Int = 8 * 1024 * 1024) {
        self.url = url
        self.maximumPendingBytes = maximumPendingBytes
    }

    @discardableResult func append(_ data: Data) -> Bool {
        lock.lock()
        guard firstError == nil, data.count <= maximumPendingBytes - pendingBytes else {
            droppedLines += 1
            noteErrorLocked("Live log pending-byte limit reached or an earlier write failed")
            lock.unlock()
            return false
        }
        pendingBytes += data.count
        acceptedLines += 1
        lock.unlock()
        queue.async { [self] in
            do {
                if handle == nil {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    }
                    handle = try FileHandle(forWritingTo: url)
                    try handle?.seekToEnd()
                }
                try handle?.write(contentsOf: data)
                lock.lock(); writtenLines += 1; lock.unlock()
            } catch {
                lock.lock(); noteErrorLocked(error.localizedDescription); lock.unlock()
            }
            lock.lock(); pendingBytes -= data.count; lock.unlock()
        }
        return true
    }

    func flush(_ completion: @escaping @Sendable (Receipt) -> Void) {
        queue.async { [self] in
            do { try handle?.synchronize() }
            catch { lock.lock(); noteErrorLocked(error.localizedDescription); lock.unlock() }
            completion(snapshot())
        }
    }

    func snapshot() -> Receipt {
        lock.lock(); defer { lock.unlock() }
        return Receipt(acceptedLines: acceptedLines, writtenLines: writtenLines, droppedLines: droppedLines,
                       pendingBytes: pendingBytes, maximumPendingBytes: maximumPendingBytes, firstError: firstError,
                       firstErrorHostTicks: firstErrorHostTicks, firstErrorUnixSeconds: firstErrorUnixSeconds)
    }

    private func noteErrorLocked(_ message: String) {
        guard firstError == nil else { return }
        firstError = message
        firstErrorHostTicks = mach_absolute_time()
        firstErrorUnixSeconds = Date().timeIntervalSince1970
    }
}
