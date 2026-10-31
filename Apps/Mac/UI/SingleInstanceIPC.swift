import Foundation
import Darwin

// Direct-release handoff. A private local socket is addressed by the elected
// PID, and both sides verify the kernel-reported peer PID and same-user UID.
// A sandboxed build may not be allowed to use this shared /private/tmp path.
enum SingleInstanceIPC {
    private struct Request: Codable {
        let targetPID: Int32
        let senderPID: Int32
        let urls: [String]
    }
    private static let limit = 256 * 1024

    private static func path(_ pid: Int32) -> String {
        "/private/tmp/khua-single-\(getuid())-\(pid).sock"
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)! + bytes.count)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: bytes)
        }
        return address
    }

    private static func peer(_ fd: Int32) -> (uid: uid_t, pid: Int32)? {
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == MemoryLayout<pid_t>.size else { return nil }
        return (uid, pid)
    }

    private static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let count = Darwin.recv(fd, &bytes, bytes.count, 0)
            if count <= 0 { return nil }
            data.append(contentsOf: bytes[0..<count])
            if data.last == 10 { data.removeLast(); return data.count <= limit ? data : nil }
        }
        return nil
    }

    final class Server: @unchecked Sendable {
        private let fd: Int32
        private let socketPath: String
        private let handler: @MainActor @Sendable (Int32, [URL]) -> Bool
        private let queue: DispatchQueue
        private let source: DispatchSourceRead

        private init(fd: Int32, path: String, handler: @escaping @MainActor @Sendable (Int32, [URL]) -> Bool) {
            self.fd = fd; socketPath = path; self.handler = handler
            queue = DispatchQueue(label: "app.khuaplayer.single-instance-ipc")
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptOne() }
            source.setCancelHandler { Darwin.close(fd); unlink(path) }
            source.resume()
        }

        static func start(handler: @escaping @MainActor @Sendable (Int32, [URL]) -> Bool) -> Server? {
            let path = SingleInstanceIPC.path(getpid())
            guard var addr = SingleInstanceIPC.address(path) else { return nil }
            var existing = stat()
            if lstat(path, &existing) == 0 {
                guard existing.st_uid == getuid(), (existing.st_mode & S_IFMT) == S_IFSOCK,
                      unlink(path) == 0 else { return nil }
            } else if errno != ENOENT { return nil }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            let addressLength = socklen_t(addr.sun_len)
            let result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, addressLength) }
            }
            guard result == 0 else { Darwin.close(fd); return nil }
            guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
                Darwin.close(fd); unlink(path); return nil
            }
            return Server(fd: fd, path: path, handler: handler)
        }

        private func acceptOne() {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            SingleInstanceIPC.configure(client)
            guard let peer = SingleInstanceIPC.peer(client), peer.uid == getuid(),
                  let line = SingleInstanceIPC.readLine(client),
                  let request = try? JSONDecoder().decode(Request.self, from: line),
                  request.targetPID == getpid(), request.senderPID == peer.pid,
                  request.urls.count <= 128 else { Darwin.close(client); return }
            let urls = request.urls.compactMap(URL.init(string:))
            guard urls.count == request.urls.count, urls.allSatisfy(\.isFileURL) else { Darwin.close(client); return }
            let handler = self.handler
            let queue = self.queue
            DispatchQueue.main.async {
                let accepted = handler(peer.pid, urls)
                queue.async {
                    _ = SingleInstanceIPC.writeAll(client, Data((accepted ? "OK\n" : "REJECT\n").utf8))
                    Darwin.close(client)
                }
            }
        }

        func stop() { source.cancel(); unlink(socketPath) }
        deinit { stop() }
    }

    static func request(targetPID: Int32, urls: [URL], timeout: TimeInterval,
                        completion: @escaping @Sendable (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = Request(targetPID: targetPID, senderPID: getpid(), urls: urls.map(\.absoluteString))
            guard urls.count <= 128, urls.allSatisfy(\.isFileURL),
                  var body = try? JSONEncoder().encode(request), body.count < limit,
                  var addr = address(path(targetPID)) else { completion(false, "invalid handoff request"); return }
            body.append(10)
            let end = ProcessInfo.processInfo.systemUptime + max(0, timeout)
            repeat {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { completion(false, "socket creation failed (errno \(errno))"); return }
                configure(fd)
                let addressLength = socklen_t(addr.sun_len)
                let result = withUnsafePointer(to: &addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addressLength) }
                }
                if result == 0 {
                    guard let remote = peer(fd), remote.uid == getuid(), remote.pid == targetPID else {
                        Darwin.close(fd); completion(false, "socket peer did not match elected PID and UID"); return
                    }
                    let written = writeAll(fd, body)
                    let response = written ? readLine(fd) : nil
                    Darwin.close(fd)
                    let ok = response == Data("OK".utf8)
                    completion(ok, ok ? "" : "selected primary did not acknowledge the request")
                    return
                }
                let failure = errno
                Darwin.close(fd)
                if failure != ENOENT && failure != ECONNREFUSED {
                    completion(false, "socket connection failed (errno \(failure))"); return
                }
                usleep(100_000)
            } while ProcessInfo.processInfo.systemUptime < end
            completion(false, "selected primary handoff socket did not become available")
        }
    }
}
