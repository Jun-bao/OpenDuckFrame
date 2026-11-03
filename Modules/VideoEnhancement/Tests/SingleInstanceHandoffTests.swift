import Foundation

@MainActor final class HandoffTestState {
    var expectedPeer: Int32 = 0
    var requests: [[URL]] = []
}

@main struct SingleInstanceHandoffTests {
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        let documents = [URL(fileURLWithPath: "/private/tmp/openduckframe handoff 测试.mp4"),
                         URL(fileURLWithPath: "/private/tmp/odf-second.mov")]
        if args.count == 3 && args[1] == "sender", let target = Int32(args[2]) {
            SingleInstanceIPC.request(targetPID: target, urls: [], timeout: 3) { ok, error in
                guard ok else { fputs("Reopen failed: \(error)\n", stderr); exit(1) }
                SingleInstanceIPC.request(targetPID: target, urls: documents, timeout: 3) { accepted, failure in
                    if !accepted { fputs("Document request failed: \(failure)\n", stderr) }
                    exit(accepted ? 0 : 1)
                }
            }
            dispatchMain()
        }
        let state = HandoffTestState()
        guard let server = SingleInstanceIPC.Server.start(handler: { pid, urls in
            guard pid == state.expectedPeer else { return false }
            state.requests.append(urls)
            return true
        }) else { fputs("Cannot create test handoff socket (errno \(errno)).\n", stderr); exit(1) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: args[0]).standardizedFileURL
        child.arguments = ["sender", String(ProcessInfo.processInfo.processIdentifier)]
        try child.run()
        state.expectedPeer = child.processIdentifier
        let deadline = Date().addingTimeInterval(7)
        while child.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        guard child.terminationStatus == 0, state.requests == [[], documents] else {
            fputs("Two-process PID-targeted handoff failed: requests=\(state.requests.count), child=\(child.terminationStatus).\n", stderr)
            exit(1)
        }
        withExtendedLifetime(server) {}
        print("Two headless processes exchanged PID-verified reopen and two exact file URLs")
    }
}
