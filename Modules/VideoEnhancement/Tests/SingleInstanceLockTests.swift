import Foundation
import Darwin

// Small command-line peer for the real cross-process fcntl lock test.
@main struct SingleInstanceLockTests {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { exit(2) }
        guard let lock = SingleInstanceLock(path: args[1]) else {
            if args[2] == "reject" { exit(0) }
            fputs("Could not open lock test file\n", stderr); exit(1)
        }
        switch args[2] {
        case "hold":
            guard case .acquired = lock.tryAcquire() else { exit(1) }
            print("held \(getpid())"); fflush(stdout)
            var byte: UInt8 = 0
            guard read(STDIN_FILENO, &byte, 1) == 1 else { exit(1) }
        case "check":
            guard args.count == 4, let expected = Int32(args[3]),
                  case .busy = lock.tryAcquire(), case .process(let owner) = lock.holder(),
                  owner == expected else { exit(1) }
            print("busy; kernel lock owner \(owner)")
        case "acquire":
            guard case .acquired = lock.tryAcquire() else { exit(1) }
        default: exit(1)
        }
    }
}
