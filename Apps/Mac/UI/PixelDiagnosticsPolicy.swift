import Foundation

enum PixelDiagnosticsPolicy {
    static let flag = "--khua-pixel-diagnostics"
    static func enabled(_ args: [String]) -> Bool {
        func absoluteValue(after flag: String) -> Bool {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return false }
            return args[i + 1].hasPrefix("/")
        }
        return args.contains(flag) && absoluteValue(after: "--khua-isolated-profile") && absoluteValue(after: "--khua-live-log")
    }
}
