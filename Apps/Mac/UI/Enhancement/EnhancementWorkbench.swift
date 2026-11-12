import AppKit
@preconcurrency import ApplicationServices
import CoreVideo
import Darwin
import Metal
import MetalFX
@preconcurrency import ScreenCaptureKit

extension Notification.Name {
    static let odfMotionPlusChanged = Notification.Name("openduckframe.motionPlusChanged")
}

/// One place for the workbench type scale, spacing and surfaces.
private enum WorkbenchStyle {
    static let edge: CGFloat = 16
    static let gap: CGFloat = 12
    static let inspectorWidth: CGFloat = 300
    static let panelRadius: CGFloat = 12
    static let groupRadius: CGFloat = 10
    static var titleFont: NSFont { .systemFont(ofSize: 20, weight: .semibold) }
    static var brandFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
    static var captionFont: NSFont { .systemFont(ofSize: 11) }
    @MainActor static var labelWidth: CGFloat { EnhancementText.chinese ? 84 : 104 }
}

@MainActor enum EnhancementText {
    static let languageKey = "OpenDuckFrameWorkbenchLanguage"
    static var pairs: [String: (en: String, zh: String)] = [:]
    static var chinese: Bool {
        language(in: .standard)
    }
    static func language(in defaults: UserDefaults) -> Bool {
        if let preferred = defaults.string(forKey: languageKey) { return preferred == "zh" }
        return (AppLanguage.effectiveLanguage(for: AppLanguage.current) ?? "en").hasPrefix("zh")
    }
    static func setLanguage(_ language: String, in defaults: UserDefaults) {
        defaults.set(language == "zh" ? "zh" : "en", forKey: languageKey)
    }

    static func t(_ en: String, _ zh: String) -> String {
        pairs[en] = (en, zh); pairs[zh] = (en, zh)
        return chinese ? zh : en
    }
    static func translated(_ text: String, chinese: Bool) -> String {
        guard let pair = pairs[text] else { return text }
        return chinese ? pair.zh : pair.en
    }
    static let budgetWarningText = (zh: "电脑跟不上目标帧率，部分画面会保持原画。可降低倍率或缩小采集窗口。",
                                    en: "This Mac can't keep up with the target rate, so some frames stay original. Try a lower multiplier or a smaller capture window.")
    static func runtime(_ value: String) -> String {
        if value == LiveRuntimeStatus.interactiveBudgetWarning || value == budgetWarningText.zh || value == budgetWarningText.en {
            return chinese ? budgetWarningText.zh : budgetWarningText.en
        }
        let messages: [(String, String)] = [
            ("正在捕获", "Capturing"), ("正在捕获（BGRA，将转换）", "Capturing (BGRA)"),
            ("增强运行", "Enhancement running"), ("缩放运行", "Scaling"),
            ("预览原画面", "Original preview"), ("来源已接入", "Source connected"),
            ("正在准备引擎", "Preparing engine"), ("准备引擎", "Preparing engine"),
            ("计划已记下，等到来源画面后准备引擎", "Waiting for source frames to prepare the engine"),
            ("计划已接受，等到来源画面后准备引擎", "Waiting for source frames to prepare the engine"),
            ("已停止", "Stopped"), ("来源中断", "Source interrupted"),
            ("请重新选择窗口或显示器", "Choose a window or display again"),
            ("已取消选择", "Selection cancelled"), ("帧率请求无效", "Invalid frame rate"),
            ("不能选择本应用的窗口或输出画面", "Choose a window outside this app"),
            ("Apple 视频超分暂不支持同时插帧，请先关闭帧生成。", "Apple video super-resolution currently requires frame generation to be off."),
            ("DistilDRBA 当前支持 720p 来源和 X2。", "DistilDRBA currently supports 720p sources at X2."),
            ("倍率只接受 X2、X3、X4", "Choose X2, X3, or X4."),
            ("自定义帧率的分子和分母都要大于 0", "The custom frame rate numerator and denominator must be positive."),
            ("RIFE 只处理 8 位 SDR，HDR 已停用", "RIFE supports 8-bit SDR; HDR is not enhanced."),
            ("HDR 捕获未增强", "HDR capture is not enhanced."),
            ("低延迟不能表达固定帧率里的任意相位。请改用 Apple 帧率转换，或改成 X2 / X4。", "For a fixed frame rate, use Apple frame-rate conversion, or choose X2 / X4."),
            ("低延迟只提供 1/2，或 1/4、1/2、3/4。X3 的 1/3 和 2/3 不会被改写，可改用 Apple 帧率转换。", "Low-latency interpolation supports X2 or X4; use Apple frame-rate conversion for X3."),
            ("该动画超分当前使用 2× 来源尺寸。", "This animation scaler currently uses 2× the source size."),
            ("准备失败，仍使用上一份可用计划", "Preparation failed; the previous plan remains active."),
            ("引擎还没有准备好", "The engine is not ready yet."),
            ("输出尺寸无效", "Invalid output size."),
            ("这台 Mac 不支持 Apple 帧率转换", "This Mac does not support Apple frame-rate conversion."),
            ("这台系统没有 Apple 低延迟插帧", "Apple low-latency interpolation is unavailable on this system."),
            ("这一段原帧间隔需要超过 3 张插帧，已暂时保持原画面；可降低目标帧率。", "This source interval needs more than 3 interpolated frames, so the original is held; lower the target rate."),
            ("文件缩放当前需要已打开的 SDR 视频。", "File scaling requires an open SDR video."),
            ("文件缩放需要已呈现的 SDR 8 位 NV12 视频帧。", "File scaling requires a presented SDR 8-bit NV12 frame."),
            ("文件缩放当前仅支持 SDR 的 8 位 NV12 视频。", "File scaling supports SDR 8-bit NV12 video only."),
            ("文件缩放准备失败。", "File scaling preparation failed."),
            ("文件缩放准备任务繁忙。", "File scaling preparation is busy."),
            ("文件缩放处理失败。", "File scaling failed."),
            ("文件超分需要有效的偶数输出尺寸，最高 3840×2160。", "File super resolution needs even output dimensions up to 3840×2160."),
            ("文件 Apple 超分需要完整的 SDR 8 位 NV12 视频帧及有效时间戳。", "Apple file super resolution needs a full SDR 8-bit NV12 frame with a valid timestamp."),
            ("文件 Apple 超分失败。", "Apple file super resolution failed."),
            ("文件 Apple 超分输出格式转换失败。", "Apple file super resolution output conversion failed."),
            ("文件插帧运行中。", "File frame generation is active."),
            ("文件插帧需要已打开的 SDR 视频帧。", "Open an SDR video frame before applying frame generation."),
            ("文件插帧准备失败。", "File frame generation could not be prepared."),
            ("文件 RIFE 需要完整 SDR 8 位 NV12 帧、已知色彩信息和最高 1920×1080 的偶数尺寸。", "File RIFE needs uncropped SDR 8-bit NV12, known color information, and even dimensions up to 1920×1080."),
            ("所选 RIFE 模型不可用。", "The selected RIFE model is unavailable."),
            ("所选 RIFE 质量档位不可用。", "The selected RIFE quality is unavailable."),
            ("RIFE 模型准备失败。", "RIFE model preparation failed."),
            ("RIFE 色彩转换准备失败。", "RIFE color conversion preparation failed."),
            ("RIFE 预检任务繁忙。", "RIFE preflight is busy."),
            ("RIFE 帧对的格式或色彩信息不兼容。", "The RIFE source frames have incompatible formats or color information."),
            ("RIFE 输入画面分配失败。", "RIFE input allocation failed."),
            ("RIFE 输入格式转换失败。", "RIFE input conversion failed."),
            ("RIFE 输出画面分配失败。", "RIFE output allocation failed."),
            ("RIFE 输出格式转换失败。", "RIFE output conversion failed."),
            ("RIFE 暂时无法接收任务。", "RIFE cannot accept another task right now."),
            ("文件插帧没有返回结果。", "The file frame generator returned no output."),
            ("无法确定或设置文件的色彩矩阵。", "The file color matrix is missing or unavailable."),
            ("无法确定或设置文件的色彩信息。", "The file color information is missing or unavailable."),
            ("动画超分使用来源尺寸的 2× 输出。", "Animation super resolution outputs twice the source dimensions."),
            ("动画超分需要完整的 SDR 8 位 NV12 帧和有效时间戳。", "Animation super resolution needs full SDR 8-bit NV12 frames and valid timestamps."),
            ("动画超分需要偶数输入尺寸，2× 输出最高 3840×2160。", "Animation super resolution requires even input dimensions and outputs up to 3840×2160."),
            ("当前安装包的 Real-CUGAN 运行库需要 macOS 27，或模型、运行库缺失。", "This Real-CUGAN runtime requires macOS 27, or its model or runtime is missing."),
            ("文件 Lanczos 当前需要已打开的 SDR 视频。", "File Lanczos requires an open SDR video."),
            ("文件 Lanczos 需要已呈现的 SDR 8 位 NV12 视频帧。", "File Lanczos requires a presented SDR 8-bit NV12 video frame."),
            ("文件 Lanczos 当前仅支持 SDR 的 8 位 NV12 视频。", "File Lanczos currently supports SDR 8-bit NV12 video only."),
            ("文件 Lanczos 暂不支持带裁切区域的视频。", "File Lanczos does not yet support cropped video frames."),
            ("上一次文件缩放准备仍在结束，请稍后重试。", "The previous scaling preparation is still finishing; try again shortly."),
            ("设备不支持或输出尺寸无效（须为偶数，最高 3840×2160）。", "Device unsupported or invalid output size (even dimensions up to 3840×2160)."),
            ("Lanczos 图像处理器准备失败。", "Lanczos image processor could not be prepared."),
            ("无法分配缩放输出。", "Could not allocate the scaled output."),
            ("无法创建缩放纹理或 GPU 命令。", "Could not create scaling textures or GPU commands."),
            ("Lanczos GPU 处理失败。", "Lanczos GPU processing failed."),
            ("准备已取消，原设置保持不变。", "Preparation was cancelled; the previous settings remain."),
            ("文件 Lanczos 准备失败。", "File Lanczos preparation failed."),
            ("文件 Lanczos 准备任务繁忙。", "File Lanczos preparation is busy."),
        ]
        for (zh, en) in messages {
            if value == zh || value == en { return chinese ? zh : en }
        }
        let prefixes: [(String, String)] = [("捕获没有开始：", "Capture could not start: "), ("选择器没有打开：", "Picker could not open: "), ("来源中断：", "Source interrupted: ")]
        for (zh, en) in prefixes {
            if value.hasPrefix(zh) { return chinese ? value : en + value.dropFirst(zh.count) }
            if value.hasPrefix(en) { return chinese ? zh + value.dropFirst(en.count) : value }
        }
        return value
    }
}

enum RateRequest: Codable, Equatable {
    case fixedFPS(numerator: Int64, denominator: Int64)
    case multiplier(Int)

    private enum CodingKeys: String, CodingKey { case kind, numerator, denominator, multiplier }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .fixedFPS(numerator, denominator):
            try container.encode("fixedFPS", forKey: .kind)
            try container.encode(numerator, forKey: .numerator)
            try container.encode(denominator, forKey: .denominator)
        case let .multiplier(value):
            try container.encode("multiplier", forKey: .kind)
            try container.encode(value, forKey: .multiplier)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "fixedFPS":
            self = .fixedFPS(numerator: try container.decode(Int64.self, forKey: .numerator),
                             denominator: try container.decode(Int64.self, forKey: .denominator))
        case "multiplier":
            let value = try container.decode(Int.self, forKey: .multiplier)
            guard value == 2 || value == 3 || value == 4 else { throw DecodingError.dataCorruptedError(forKey: .multiplier, in: container, debugDescription: "multiplier") }
            self = .multiplier(value)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "kind")
        }
    }
}

struct EnhancementCountdown {
    private(set) var token: UInt64 = 0
    private(set) var remaining = 0
    var active: Bool { remaining > 0 }
    mutating func begin(seconds: Int = 3) -> UInt64? {
        guard !active else { return nil }
        token &+= 1; remaining = seconds; return token
    }
    mutating func cancel() { token &+= 1; remaining = 0 }
    mutating func tick(_ candidate: UInt64) -> Int? {
        guard active, candidate == token else { return nil }
        remaining -= 1
        return remaining
    }
}

enum FPSPreference {
    private static let key = "OpenDuckFrameShowFPS"
    static func enabled(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }
    static func set(_ value: Bool, in defaults: UserDefaults) { defaults.set(value, forKey: key) }
}

enum EnhancementDelayPreference {
    private static let key = "OpenDuckFrameEnhancementDelaySeconds"
    static let presets = [3, 5, 10]
    static func seconds(in defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: key) != nil else { return 3 }
        return min(20, max(1, defaults.integer(forKey: key)))
    }
    static func set(_ seconds: Int, in defaults: UserDefaults) {
        defaults.set(min(20, max(1, seconds)), forKey: key)
    }
}

enum FPSPresentation {
    static func rate(_ value: Double?, observing: Bool, now: TimeInterval, receipt: TimeInterval) -> Double? {
        guard observing, receipt > 0, now >= receipt, now - receipt < 1.5,
              let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

enum R7ContentChangeEvidence {
    static func isFresh(now: UInt64, host: UInt64, numer: UInt32, denom: UInt32,
                        generation: UInt64, config: UInt64, epoch: UInt64,
                        evidenceGeneration: UInt64, evidenceConfig: UInt64, evidenceEpoch: UInt64,
                        snapshotStale: Bool) -> Bool {
        guard !snapshotStale, host > 0, now >= host, denom > 0, epoch > 0,
              generation == evidenceGeneration, config == evidenceConfig, epoch == evidenceEpoch else { return false }
        let ageSeconds = Double(now - host) * Double(numer) / Double(denom) / 1_000_000_000
        return ageSeconds <= 1.5
    }
}

enum FooterMetrics {
    static func lines(target: String, output: String, generation: String, budget: String,
                      stalled: String, overdue: String, supplemental: [String]) -> (primary: String, secondary: String) {
        let primary = [target, output, generation].filter { !$0.isEmpty }.joined(separator: " · ")
        let secondary = ([budget, stalled, overdue] + supplemental).filter { !$0.isEmpty }.joined(separator: " · ")
        return (primary, secondary)
    }
}

struct R7PresentationHealth {
    private(set) var stallSeconds = 0
    private(set) var recoveryAttempted = false
    private var generation: UInt64?
    private var config: UInt64?
    private var lastAccepted: UInt64?
    private var lastPresented: UInt64?

    mutating func reset() { self = R7PresentationHealth() }

    mutating func observe(generation: UInt64, config: UInt64, running: Bool, visible: Bool,
                          accepted: UInt64, presented: UInt64, changingContent: Bool) -> (firstStall: Bool, rearm: Bool) {
        guard running else { reset(); return (false, false) }
        if self.generation != generation || self.config != config ||
            (lastAccepted != nil && accepted < lastAccepted!) || (lastPresented != nil && presented < lastPresented!) {
            reset()
            self.generation = generation
            self.config = config
        }
        guard let previousAccepted = lastAccepted, let previousPresented = lastPresented else {
            lastAccepted = accepted; lastPresented = presented
            return (false, false)
        }
        if presented > previousPresented { recoveryAttempted = false }
        if visible && accepted > previousAccepted && presented == previousPresented {
            stallSeconds += 1
        } else { stallSeconds = 0 }
        let firstStall = stallSeconds == 3
        let rearm = stallSeconds >= 3 && changingContent && !recoveryAttempted
        if rearm { recoveryAttempted = true }
        lastAccepted = accepted; lastPresented = presented
        return (firstStall, rearm)
    }
}

// Explicit diagnostic only. AX is queried on a worker, never in the tap callback.
enum P1AXInvestigation {
    static func rectMatches(_ a: CGRect, _ b: CGRect) -> Bool {
        [a.minX-b.minX, a.minY-b.minY, a.width-b.width, a.height-b.height].allSatisfy { $0.isFinite && abs($0) <= 2 }
    }
    static func uniqueGeometry(total: Int, readable: Int, matches: Int, listSucceeded: Bool) -> Bool {
        listSucceeded && total <= 8 && total == readable && matches == 1
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?; let code = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (code, value)
    }
    private static func rect(_ element: AXUIElement) -> CGRect? {
        let (_, pv) = attribute(element, kAXPositionAttribute as String)
        let (_, sv) = attribute(element, kAXSizeAttribute as String)
        guard let pv, let sv, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero; var s = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(pv, to: AXValue.self), .cgPoint, &p), AXValueGetValue(unsafeDowncast(sv, to: AXValue.self), .cgSize, &s),
              p.x.isFinite, p.y.isFinite, s.width.isFinite, s.height.isFinite, s.width > 0, s.height > 0 else { return nil }
        return CGRect(origin: p, size: s)
    }
    static func inspect(pid: pid_t, targetBounds: CGRect, source: CGRect) -> Data {
        let app = AXUIElementCreateApplication(pid), system = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(app, 0.2) // system-wide timeout would alter this process globally
        let (listCode, listValue) = attribute(app, kAXWindowsAttribute as String)
        let windows = listValue as? [AXUIElement]
        let bounded = windows != nil && windows!.count <= 8
        var matches: [AXUIElement] = []; var readable = 0
        if bounded, let windows {
            for window in windows {
                _ = AXUIElementSetMessagingTimeout(window, 0.2)
                if let bounds = rect(window) { readable += 1; if rectMatches(bounds, targetBounds) { matches.append(window) } }
            }
        }
        let unique = uniqueGeometry(total: windows?.count ?? 0, readable: readable, matches: matches.count, listSucceeded: listCode == .success && bounded)
        let selected = unique ? matches.first : nil
        let positions: [(String, CGFloat, CGFloat)] = [("upperLeft",0.02,0.02),("center",0.5,0.5),("right",0.75,0.5)]
        var points: [[String: Any]] = []
        for (name, x, y) in positions {
            let pt = CGPoint(x: source.minX + source.width*x, y: source.minY + source.height*y)
            var hit: AXUIElement?
            let code = AXUIElementCopyElementAtPosition(system, Float(pt.x), Float(pt.y), &hit)
            var row: [String: Any] = ["point": name, "position": [pt.x,pt.y], "status": code.rawValue, "association": "unknown"]
            if let hit, code == .success {
                _ = AXUIElementSetMessagingTimeout(hit, 0.2)
                var hitPID: pid_t = 0; let pidStatus = AXUIElementGetPid(hit, &hitPID)
                row["pidStatus"] = pidStatus.rawValue
                if pidStatus == .success { row["pid"] = hitPID }
                let (roleStatus, role) = attribute(hit, kAXRoleAttribute as String)
                row["roleStatus"] = roleStatus.rawValue
                if let role = role as? String { row["role"] = role }
                let (windowStatus, value) = attribute(hit, kAXWindowAttribute as String)
                row["windowStatus"] = windowStatus.rawValue
                let window: AXUIElement? = (role as? String) == (kAXWindowRole as String) ? hit :
                    value.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeDowncast($0, to: AXUIElement.self) : nil }
                if let window {
                    _ = AXUIElementSetMessagingTimeout(window, 0.2)
                    let (roleStatus, windowRole) = attribute(window, kAXRoleAttribute as String)
                    row["windowRoleStatus"] = roleStatus.rawValue
                    if let role = windowRole as? String { row["windowRole"] = role }
                    if let frame = rect(window) { row["windowBounds"] = [frame.minX,frame.minY,frame.width,frame.height] }
                    if let selected, pidStatus == .success {
                        row["association"] = hitPID == pid && CFEqual(window, selected) ? "unique_geometry_matched_ax_window" : "other_or_different_window"
                    }
                }
            }
            points.append(row)
        }
        let result: [String: Any] = ["scope":"AX z-order observation only; not a mouse-delivery receipt", "windowListStatus":listCode.rawValue,
            "windowCount":windows?.count ?? 0, "windowListBounded":bounded, "windowBoundsReadable":readable, "matchingWindowCount":matches.count,
            "uniqueGeometryAssociation":selected != nil, "associationScope":"geometry and AX identity only; CGWindowID linkage is not independently verified", "points":points]
        return (try? JSONSerialization.data(withJSONObject: result)) ?? Data()
    }
}

enum P1FocusPolicy {
    enum Decision { case ready, wait, cancel }
    static func decide(targetReady: Bool, acquired: Bool, ownFront: Bool, now: TimeInterval, deadline: TimeInterval) -> Decision {
        if targetReady { return .ready }
        if !acquired && ownFront && now.isFinite && now < deadline { return .wait }
        return .cancel
    }
}

// A single applied request may wait briefly for a transient obstruction.
struct P1ObstructionWait {
    private var started: TimeInterval?
    private var generation: UInt64 = 0
    private var config: UInt64 = 0
    mutating func reset() { started = nil; generation = 0; config = 0 }
    mutating func observe(blocked: Bool, now: TimeInterval, generation: UInt64, config: UInt64) -> Bool {
        guard now.isFinite, generation > 0, config > 0 else { reset(); return false }
        if let began = started {
            guard self.generation == generation, self.config == config, now >= began, now - began < 5 else { reset(); return false }
        }
        if !blocked { reset(); return true }
        if started == nil { started = now; self.generation = generation; self.config = config }
        return true
    }
}

enum TargetOverlayPolicy {
    struct WindowMetadata {
        let id: CGWindowID
        let owner: pid_t
        let layer: Int
        let onscreen: Bool
        let alpha: Double?
        let bounds: CGRect
        let name: String?
    }
    struct WindowDecision {
        let target: WindowMetadata?
        let competing: WindowMetadata?
        let reason: String
        var ignored: [WindowMetadata] = []
        var matches: Bool { reason == "matched" }
    }
    static func normalizeWindow(_ item: [String: Any]) -> WindowMetadata? {
        guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let owner = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let dict = item[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary),
              bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 1, bounds.height > 1 else { return nil }
        let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
        guard alpha?.isFinite ?? true else { return nil }
        return WindowMetadata(id: id, owner: owner, layer: layer,
                              onscreen: (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                              alpha: alpha, bounds: bounds, name: item[kCGWindowName as String] as? String)
    }
    /// Core Graphics lists windows front to back. Limit selection to the active
    /// app so a desktop or an app without a window cannot select a window behind it.
    static func focusedWindow(_ ordered: [[String: Any]], frontPID: pid_t?, ownPID: pid_t, focusedBounds: CGRect? = nil) -> WindowMetadata? {
        guard let frontPID, frontPID != ownPID else { return nil }
        let candidates = ordered.compactMap(normalizeWindow).filter {
            $0.owner == frontPID && $0.layer == 0 && $0.onscreen && ($0.alpha ?? 1) > 0
        }
        if let focusedBounds, let focused = candidates.first(where: {
            abs($0.bounds.minX-focusedBounds.minX)<2 && abs($0.bounds.minY-focusedBounds.minY)<2 &&
                abs($0.bounds.width-focusedBounds.width)<2 && abs($0.bounds.height-focusedBounds.height)<2
        }) { return focused }
        return candidates.first
    }
    // Read existing Accessibility access only; selection never requests a new
    // permission. Window-server ordering remains the fallback when unavailable.
    static func focusedWindowBounds(pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.15)
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(p, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func evaluateWindow(_ allWindows: [[String: Any]], orderedOnscreen: [[String: Any]]?, id: CGWindowID, owner: pid_t, frontPID: pid_t?) -> WindowDecision {
        guard let rawTarget = allWindows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) else {
            return WindowDecision(target: nil, competing: nil, reason: "target_missing")
        }
        guard let target = normalizeWindow(rawTarget) else {
            return WindowDecision(target: nil, competing: nil, reason: "target_metadata_incomplete")
        }
        guard target.owner == owner else { return WindowDecision(target: target, competing: nil, reason: "target_owner_changed") }
        // Only the on-screen CG list has a documented front-to-back order.
        // The chosen window remains eligible at its actual level; competing
        // windows must be visible, nontransparent ordinary windows.
        // Only the target in this same ordered snapshot can justify a bar exemption.
        let snapshotTarget = orderedOnscreen?.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }).flatMap(normalizeWindow)
        let barTarget = snapshotTarget.flatMap { value in
            value.owner == owner && value.onscreen && (value.alpha.map { $0 > 0.01 } ?? true) ? value : nil
        }
        var top: WindowMetadata?
        var ignored: [WindowMetadata] = []
        for window in orderedOnscreen?.compactMap(normalizeWindow) ?? [] {
            guard window.owner == owner, window.onscreen, window.alpha.map({ $0 > 0.01 }) ?? true else { continue }
            if window.id == id { top = window; break }
            guard window.layer == 0, window.bounds.width >= 80, window.bounds.height >= 80 else { continue }
            if let target = barTarget, window.bounds.height <= 160,
               abs(window.bounds.minX - target.bounds.minX) <= 2,
               window.bounds.width >= target.bounds.width - 4,
               window.bounds.minY <= target.bounds.minY + 2 {
                ignored.append(window); continue
            }
            top = window; break
        }
        let competing = top.flatMap { $0.id == id ? nil : $0 }
        guard target.onscreen else { return WindowDecision(target: target, competing: competing, reason: "target_offscreen", ignored: ignored) }
        guard target.alpha.map({ $0 > 0.01 }) ?? true else { return WindowDecision(target: target, competing: competing, reason: "target_transparent", ignored: ignored) }
        guard let orderedOnscreen else { return WindowDecision(target: target, competing: nil, reason: "onscreen_window_list_unavailable", ignored: ignored) }
        guard let rawOnscreen = orderedOnscreen.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }) else {
            return WindowDecision(target: target, competing: competing, reason: "target_not_in_ordered_list", ignored: ignored)
        }
        guard let currentTarget = normalizeWindow(rawOnscreen), currentTarget.owner == owner, currentTarget.onscreen else {
            return WindowDecision(target: target, competing: competing, reason: "target_identity_changed_in_ordered_list", ignored: ignored)
        }
        guard currentTarget.alpha.map({ $0 > 0.01 }) ?? true else { return WindowDecision(target: currentTarget, competing: competing, reason: "target_transparent", ignored: ignored) }
        guard let frontPID else { return WindowDecision(target: currentTarget, competing: competing, reason: "front_process_unknown", ignored: ignored) }
        guard frontPID == owner else { return WindowDecision(target: currentTarget, competing: competing, reason: "other_app_frontmost", ignored: ignored) }
        guard let top else { return WindowDecision(target: currentTarget, competing: nil, reason: "no_visible_candidate", ignored: ignored) }
        if top.id != id { return WindowDecision(target: currentTarget, competing: top, reason: "other_window_frontmost", ignored: ignored) }
        return WindowDecision(target: currentTarget, competing: nil, reason: "matched", ignored: ignored)
    }
    // The ordered list is only a sampled observation, never a delivery receipt.
    // Treat an incomplete preceding window as unknown rather than assuming clear.
    // Until the matching surface and tap exist, the visible preparation
    // panel absorbs pointer input and keeps its stop button available.
    static func interactionCanPassThrough(available: Bool, routerActive: Bool) -> Bool {
        available && routerActive
    }
    static func interactionOwnedPassThrough(output: CGWindowID?, controls: CGWindowID?, huds: [CGWindowID]) -> Set<CGWindowID> {
        Set(([output, controls].compactMap { $0 } + huds).filter { $0 != 0 })
    }
    struct InteractionGuardResult {
        let clear: Bool
        let reason: String
        let missing: [String]
        let blocker: [String: Any]
        let targetFound: String
        var diagnostic: [String: Any] {
            ["clear": clear, "reason": reason, "missing": missing, "blocker": blocker, "targetFound": targetFound]
        }
    }
    static func interactionGuard(_ windows: [[String: Any]]?, id: CGWindowID, owner: pid_t,
                                 source: CGRect, passthrough: Set<CGWindowID>) -> InteractionGuardResult {
        func result(_ clear: Bool, _ reason: String, _ missing: [String] = [], _ blocker: [String: Any] = [:], _ found: String = "unknown") -> InteractionGuardResult {
            InteractionGuardResult(clear: clear, reason: reason, missing: missing, blocker: blocker, targetFound: found)
        }
        guard let windows else { return result(false, "window_list_unavailable") }
        guard source.minX.isFinite, source.minY.isFinite, source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0 else { return result(false, "source_bounds_invalid") }
        let found = windows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
            ? "yes" : (windows.contains { ($0[kCGWindowNumber as String] as? NSNumber) == nil } ? "unknown" : "no")
        for item in windows {
            let windowID = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            if let windowID, passthrough.contains(windowID), windowID != id { continue }
            let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue
            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue
            let on = (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue
            let bounds = (item[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            let validBounds = bounds.map { $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 } ?? false
            let validAlpha = alpha?.isFinite ?? false
            var missing: [String] = []
            if windowID == nil { missing.append("windowID") }; if pid == nil { missing.append("pid") }
            if layer == nil { missing.append("layer") }; if !validAlpha { missing.append("alpha") }
            if on == nil { missing.append("onscreen") }; if !validBounds { missing.append("bounds") }
            let blocker: [String: Any] = ["windowID": windowID.map { $0 as Any } ?? NSNull(),
                "pid": pid.map { $0 as Any } ?? NSNull(), "layer": layer.map { $0 as Any } ?? NSNull(),
                "alpha": validAlpha ? alpha! : NSNull(),
                "bounds": validBounds ? [bounds!.minX, bounds!.minY, bounds!.width, bounds!.height] : NSNull()]
            if windowID == id {
                guard missing.isEmpty, let target = normalizeWindow(item), target.owner == owner, target.onscreen, target.alpha.map({ $0 > 0.01 }) == true else {
                    return result(false, "target_invalid", missing, blocker, found)
                }
                return result(true, "clear", [], [:], found)
            }
            // A finite positive bounding rectangle proves disjointness; unrelated
            // identity or opacity fields cannot change that geometric fact.
            if validBounds, let bounds, !bounds.intersects(source) { continue }
            guard missing.isEmpty else { return result(false, "preceding_metadata_incomplete", missing, blocker, found) }
            // Opacity alone does not prove that an overlapping window is
            // unable to receive events; require it to be offscreen or disjoint.
            if on == true { return result(false, "overlapping_window", [], blocker, found) }
        }
        return result(false, "target_not_found", [], [:], found)
    }
    static func interactionUnobstructed(_ windows: [[String: Any]]?, id: CGWindowID, owner: pid_t,
                                        source: CGRect, passthrough: Set<CGWindowID>) -> Bool {
        interactionGuard(windows, id: id, owner: owner, source: source, passthrough: passthrough).clear
    }
    static func shouldCancel(exists: Bool, onscreen: Bool, wasOnscreen: Bool) -> Bool {
        !exists || (wasOnscreen && !onscreen)
    }
    static func nativeFrame(_ rect: CGRect, cgDisplay: CGRect, screen: NSRect) -> NSRect {
        guard cgDisplay.width > 0, cgDisplay.height > 0 else { return .zero }
        let sx = screen.width / cgDisplay.width, sy = screen.height / cgDisplay.height
        return NSRect(x: screen.minX + (rect.minX - cgDisplay.minX) * sx,
                      y: screen.maxY - (rect.maxY - cgDisplay.minY) * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }
    static func canReveal(token: UInt64, currentToken: UInt64, generation: UInt64, currentGeneration: UInt64,
                          config: UInt64, currentConfig: UInt64, targetReady: Bool) -> Bool {
        token != 0 && token == currentToken && generation == currentGeneration && config == currentConfig && targetReady
    }
    static func windowInputAligned(viewMode: String) -> Bool { viewMode != "compare" }
    static func outputFrame(target: NSRect, fullscreen: Bool, display: NSRect?) -> NSRect? {
        fullscreen ? display : target
    }
    static func followsTarget(fullscreen: Bool, viewerFollowOverride: Bool) -> Bool {
        !fullscreen || viewerFollowOverride
    }
    static func activeWindowViewer(windowTarget: Bool, viewerSelected: Bool, viewerFollowOverride: Bool) -> Bool {
        windowTarget && viewerSelected && !viewerFollowOverride
    }
    static func usesFullscreen(windowTarget: Bool, explicitViewer: Bool, interactiveAvailable: Bool,
                               diagnosticFullscreen: Bool, legacyFullscreen: Bool, viewerFollowOverride: Bool) -> Bool {
        diagnosticFullscreen || (windowTarget && ((explicitViewer && !viewerFollowOverride) || interactiveAvailable)) ||
            (!windowTarget && !followsTarget(fullscreen: legacyFullscreen, viewerFollowOverride: viewerFollowOverride))
    }
    static func screenIndex(target: NSRect, screens: [NSRect]) -> Int? {
        guard !target.isEmpty else { return nil }
        let candidates = screens.enumerated().map { index, frame -> (Int, CGFloat) in
            let overlap = frame.intersection(target)
            return (index, overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }
}

struct RecentEnhancementSource: Codable, Equatable {
    var kind: String
    var title: String
    var bundleIdentifier: String
}

enum LiveEngineSelection {
    static func fromPopup(_ index: Int, quality: String) -> (engine: String, model: String) {
        ("rife.metal", "rife-v4.25")
    }

    static func validQuality(_ quality: String) -> String {
        ["fast", "balanced", "hq"].contains(quality) ? quality : "fast"
    }

    static func normalize(_ profile: inout EnhancementProfile) {
        profile.interpolationEngineID = "rife.metal"
        profile.modelID = "rife-v4.25"
        profile.interpolationQuality = validQuality(profile.interpolationQuality)
        profile.rifeStreamEnabled = true
    }
}

enum ArtCNNSRSelection {
    static let ids = ["artcnn.c4f32", "artcnn.c4f16"]
    static func contains(_ id: String) -> Bool { ids.contains(id) }
    static func fromPopup(_ index: Int) -> String { ids.indices.contains(index) ? ids[index] : ids[0] }
    static func popupIndex(_ id: String) -> Int { ids.firstIndex(of: id) ?? 0 }
    static func title(_ id: String) -> String { id == ids[1] ? "ArtCNN C4F16" : "ArtCNN C4F32" }

    static func normalize(_ profile: inout EnhancementProfile) {
        if !contains(profile.scaleEngineID) {
            profile.scaleEngineID = ids[0]
            profile.outputWidth = 0
            profile.outputHeight = 0
            if profile.srInputPreset == 0 { profile.srInputPreset = 1080 }
        }
        if ![0, 480, 720, 1080].contains(profile.srInputPreset) { profile.srInputPreset = 1080 }
        profile.scaleQualityID = "none"
    }
}

enum LiveCoverage {
    static func modelScheduled(total: Int, held: Int) -> Int { max(0, total - held) }
}

struct LiveApplyTracker {
    private(set) var serial: UInt64 = 0
    private(set) var pending: UInt64?
    mutating func begin() -> UInt64 { serial &+= 1; pending = serial; return serial }
    mutating func resolve(_ id: UInt64, state: Int) -> Bool {
        guard pending == id else { return false }
        if state == 0 || state == 2 { pending = nil }
        return true
    }
    mutating func cancel() { serial &+= 1; pending = nil }
}

struct EnhancementProfile: Codable, Equatable {
    var schemaVersion = 1
    var sourceKind = "window"
    var sourceTitle = ""
    var sourceBundleIdentifier = ""
    var interpolationEnabled = true
    var interpolationEngineID = "rife.metal"
    var interpolationQuality = "fast"
    var rifeStreamEnabled = true
    var rate = RateRequest.multiplier(2)
    var scaleEnabled = false
    var scaleEngineID = "artcnn.c4f32"
    var scaleQualityID = "none"
    var srInputPreset = 1080
    var sourceWindowPreset = 0
    var outputWidth = 0
    var outputHeight = 0
    var outputDisplayID: UInt32 = 0
    var outputFullscreen = false
    // Legacy window output stays source-aligned; saved interaction is never
    // armed until the user explicitly applies it in the current session.
    var windowOutputMode = "follow"
    var soundMode = "sourceApplication"
    var viewMode = "enhanced"
    var appearance = "system"
    var captureLimit = "auto"
    var configName = "默认"
    var configID: String? = nil
    var modelID = "rife-v4.25"
    var recents: [RecentEnhancementSource] = []

    var sourceWindowResizeActive: Bool {
        sourceKind == "window" && scaleEnabled && sourceWindowPreset != 0
    }
}

private func applyDefaultPreset(_ profile: inout EnhancementProfile) {
    let defaults = EnhancementProfile()
    profile.interpolationEnabled = defaults.interpolationEnabled
    profile.interpolationEngineID = defaults.interpolationEngineID
    profile.interpolationQuality = defaults.interpolationQuality
    profile.rifeStreamEnabled = defaults.rifeStreamEnabled
    profile.modelID = defaults.modelID
    profile.rate = defaults.rate
    profile.scaleEnabled = defaults.scaleEnabled
    profile.windowOutputMode = defaults.windowOutputMode
}

private func applyAirBetaPreset(_ profile: inout EnhancementProfile) {
    guard Bundle.main.object(forInfoDictionaryKey: "ODFAirBeta") as? Bool == true else { return }
    profile.configID = "preset:air-beta"
    profile.configName = "Air 实验档 · 2× 插帧"
    profile.sourceKind = "window"
    profile.interpolationEnabled = true
    profile.interpolationEngineID = "rife.metal"
    profile.interpolationQuality = "fast"
    profile.rifeStreamEnabled = true
    profile.modelID = "rife-v4.25"
    profile.rate = .multiplier(2)
    profile.scaleEnabled = false
    profile.scaleEngineID = "artcnn.c4f32"
    profile.srInputPreset = 1080
    profile.sourceWindowPreset = 0
    profile.outputWidth = 0
    profile.outputHeight = 0
    profile.outputFullscreen = false
    profile.windowOutputMode = "follow"
    profile.captureLimit = "auto"
    profile.viewMode = "enhanced"
}

enum EnhancementProfileStore {
    // Set only by the isolated, single-threaded store contract executable.
    nonisolated(unsafe) static var testDirectory: URL?
    static func fileURL() -> URL {
        if let testDirectory { return testDirectory.appendingPathComponent("EnhancementProfile.json") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let defaultDirectory = Bundle.main.object(forInfoDictionaryKey: "ODFExperimentTrial") as? Bool == true
            ? "OpenDuckFrame/ExperimentComparison" : "OpenDuckFrame"
        // Bundle overrides are relative to the current user's Application Support.
        let directory = Bundle.main.object(forInfoDictionaryKey: "ODFEnhancementProfileDirectory") as? String
            ?? defaultDirectory
        return base.appendingPathComponent(directory, isDirectory: true).appendingPathComponent("EnhancementProfile.json")
    }

    static func decode(_ data: Data, fallbackName: String) -> EnhancementProfile? {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["rifeStreamEnabled"] = true
        if object["srInputPreset"] == nil { object["srInputPreset"] = 1080 }
        if object["scaleEngineID"] == nil { object["scaleEngineID"] = "artcnn.c4f32" }
        if object["sourceWindowPreset"] == nil { object["sourceWindowPreset"] = 0 }
        if object["captureLimit"] == nil { object["captureLimit"] = "auto" }
        object["windowOutputMode"] = "follow"
        if object["configName"] == nil { object["configName"] = fallbackName }
        if object["scaleQualityID"] == nil { object["scaleQualityID"] = "none" }
        object["interpolationEngineID"] = "rife.metal"
        object["modelID"] = "rife-v4.25"
        object["interpolationQuality"] = LiveEngineSelection.validQuality(object["interpolationQuality"] as? String ?? "fast")
        guard let normalized = try? JSONSerialization.data(withJSONObject: object),
              var profile = try? JSONDecoder().decode(EnhancementProfile.self, from: normalized),
              profile.schemaVersion == 1 else { return nil }
        ArtCNNSRSelection.normalize(&profile)
        return profile
    }

    static func load() -> EnhancementProfile {
        guard let data = try? Data(contentsOf: fileURL()), var profile = decode(data, fallbackName: "默认"),
              profile.soundMode == "sourceApplication" else { return EnhancementProfile() }
        // Reopen the default preset source-aligned, including old auto-viewer state.
        if resolvedID(profile) == "preset:default" { profile.windowOutputMode = "follow" }
        return profile
    }

    static func save(_ profile: EnhancementProfile) throws {
        var profile = profile
        ArtCNNSRSelection.normalize(&profile)
        let url = fileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profile)
        try data.write(to: url, options: .atomic)
    }

    static func safeName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: " ").replacingOccurrences(of: ":", with: " ")
        return cleaned.isEmpty ? "默认" : String(cleaned.prefix(80))
    }

    static func namedDirectory() -> URL {
        fileURL().deletingLastPathComponent().appendingPathComponent("EnhancementConfigs", isDirectory: true)
    }

    static var presets: [(id: String, name: String, english: String, symbol: String)] {
        if Bundle.main.object(forInfoDictionaryKey: "ODFAirBeta") as? Bool == true {
            return [("preset:air-beta", "Air 实验档 · 2× 插帧", "Air Beta · 2× Interpolation", "play.rectangle")]
        }
        return [
            ("preset:default", "默认", "Default", "doc.text"),
            ("preset:native", "原生画质 X2", "Native quality X2", "viewfinder"),
            ("preset:game", "游戏", "Game", "gamecontroller"),
            ("preset:film", "电影", "Film", "film"),
            ("preset:anime", "动画", "Animation", "photo"),
        ]
    }

    static func resolvedID(_ profile: EnhancementProfile) -> String {
        if let id = profile.configID, !id.isEmpty { return id }
        // Legacy named files take precedence, including names matching presets.
        if namedNames().contains(profile.configName) { return "custom:" + profile.configName }
        return presets.first(where: { $0.name == profile.configName })?.id ?? "custom:" + profile.configName
    }

    static func presetDirectory() -> URL {
        fileURL().deletingLastPathComponent().appendingPathComponent("EnhancementPresets", isDirectory: true)
    }

    static func savePreset(_ profile: EnhancementProfile, id: String) throws {
        var profile = profile
        ArtCNNSRSelection.normalize(&profile)
        guard presets.contains(where: { $0.id == id }) else { throw CocoaError(.fileWriteInvalidFileName) }
        let dir = presetDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(profile).write(to: dir.appendingPathComponent(String(id.dropFirst(7)) + ".json"), options: .atomic)
    }

    static func loadPreset(_ id: String) -> EnhancementProfile? {
        guard let preset = presets.first(where: { $0.id == id }),
              let data = try? Data(contentsOf: presetDirectory().appendingPathComponent(String(id.dropFirst(7)) + ".json")) else { return nil }
        guard var profile = decode(data, fallbackName: preset.name) else { return nil }
        if id == "preset:default" { profile.windowOutputMode = "follow" }
        return profile
    }

    static func namedNames() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: namedDirectory(), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    struct ConfigMetadata: Codable {
        var titles: [String: String] = [:]
        var hiddenPresets: [String] = []
    }
    static func metadataURL() -> URL {
        fileURL().deletingLastPathComponent().appendingPathComponent("EnhancementConfigMetadata.json")
    }
    static func metadata() -> ConfigMetadata {
        guard let data = try? Data(contentsOf: metadataURL()), let value = try? JSONDecoder().decode(ConfigMetadata.self, from: data) else { return ConfigMetadata() }
        return value
    }
    static func saveMetadata(_ value: ConfigMetadata) throws {
        let url = metadataURL()
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            guard (try? JSONDecoder().decode(ConfigMetadata.self, from: existing)) != nil else { throw CocoaError(.fileReadCorruptFile) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    enum NameCheck { case valid, invalid, duplicate }
    static func checkNewName(_ name: String) -> NameCheck {
        guard !name.isEmpty, name.count <= 80, safeName(name) == name else { return .invalid }
        let meta = metadata()
        let existing = namedNames() + presets.map(\.name) + presets.map(\.english) + Array(meta.titles.values)
        return existing.contains(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) ? .duplicate : .valid
    }
    static func checkRename(_ name: String, excluding id: String) -> NameCheck {
        guard !name.isEmpty, name.count <= 80, !id.hasPrefix("custom:") || safeName(name) == name else { return .invalid }
        let meta = metadata()
        var others: [String] = []
        for preset in presets where preset.id != id {
            others.append(meta.titles[preset.id] ?? preset.name)
            others.append(preset.english)
        }
        others += namedNames().filter { "custom:" + $0 != id }
        return others.contains(where: { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) ? .duplicate : .valid
    }

    static func saveNamed(_ profile: EnhancementProfile) throws {
        var copy = profile
        ArtCNNSRSelection.normalize(&copy)
        copy.configName = safeName(profile.configName)
        let url = namedDirectory().appendingPathComponent(copy.configName + ".json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(copy)
        try data.write(to: url, options: .atomic)
    }

    static func saveCurrent(_ profile: EnhancementProfile) throws {
        let id = resolvedID(profile)
        if id.hasPrefix("custom:") {
            var copy = profile
            copy.configName = String(id.dropFirst(7))
            try saveNamed(copy)
        } else { try savePreset(profile, id: id) }
        try save(profile)
    }

    static func loadNamed(_ name: String) -> EnhancementProfile? {
        let url = namedDirectory().appendingPathComponent(safeName(name) + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data, fallbackName: safeName(name))
    }

    static func moveNamedFile(_ oldURL: URL, to newURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: newURL.path) {
            let oldID = try fm.attributesOfItem(atPath: oldURL.path)[.systemFileNumber] as? NSNumber
            let newID = try fm.attributesOfItem(atPath: newURL.path)[.systemFileNumber] as? NSNumber
            guard oldID != nil && oldID == newID else { throw CocoaError(.fileWriteFileExists) }
            let temporary = oldURL.deletingLastPathComponent().appendingPathComponent(".rename-" + UUID().uuidString)
            try fm.moveItem(at: oldURL, to: temporary)
            do { try fm.moveItem(at: temporary, to: newURL) }
            catch { try? fm.moveItem(at: temporary, to: oldURL); throw error }
        } else { try fm.moveItem(at: oldURL, to: newURL) }
    }

    static func renameNamed(_ oldName: String, to name: String) throws {
        let directory = namedDirectory()
        let oldURL = directory.appendingPathComponent(oldName + ".json")
        let newURL = directory.appendingPathComponent(name + ".json")
        let original = try Data(contentsOf: oldURL)
        guard var saved = decode(original, fallbackName: oldName) else { throw CocoaError(.fileReadCorruptFile) }
        try moveNamedFile(oldURL, to: newURL)
        saved.configName = name; saved.configID = "custom:" + name
        do { try saveNamed(saved) }
        catch {
            do {
                try original.write(to: newURL, options: .atomic)
                try moveNamedFile(newURL, to: oldURL)
            } catch let rollback {
                throw NSError(domain: "OpenDuckFrame.ConfigRename", code: 1, userInfo: [NSLocalizedDescriptionKey: "重命名未完成，回退也失败；请检查 \(newURL.path)：\(rollback.localizedDescription)"])
            }
            throw error
        }
    }

    static func roundTripForTest() -> Bool {
        let url = fileURL()
        let backup = try? Data(contentsOf: url)
        var profile = EnhancementProfile()
        profile.interpolationEnabled = true
        profile.interpolationQuality = "quality"
        profile.rate = .fixedFPS(numerator: 60000, denominator: 1001)
        profile.scaleEnabled = true
        profile.scaleEngineID = "artcnn.c4f16"
        profile.outputWidth = 1920
        profile.outputHeight = 1080
        profile.viewMode = "compare"
        profile.appearance = "light"
        profile.captureLimit = "30"
        profile.recents = [RecentEnhancementSource(kind: "window", title: "Preview", bundleIdentifier: "com.example.preview")]
        do {
            try save(profile)
            let loaded = load()
            if let backup {
                try backup.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            return loaded == profile
        } catch {
            if let backup { try? backup.write(to: url, options: .atomic) }
            return false
        }
    }
}

enum VideoSRAvailability {
    static func readyFactors(isFile: Bool, inputReady: Bool, factors: [Int]) -> [Int] {
        guard inputReady else { return [] }
        let available = factors.filter { $0 > 1 }.sorted()
        return isFile ? available : available.filter { $0 == 4 }
    }
}

@MainActor private enum LiveSizeChain {
    static func text(_ stats: [String: Any], generation: UInt64, config: UInt64) -> String {
        guard let chain = stats["sizeChain"] as? [String: Any],
              let gen = chain["sourceGeneration"] as? UInt64, gen == generation,
              let version = chain["configVersion"] as? UInt64, version == config,
              let endpoint = chain["endpoint"] as? String, ["output", "preview"].contains(endpoint),
              let sw = chain["sourceWidth"] as? Int, let sh = chain["sourceHeight"] as? Int,
              let pw = chain["processingWidth"] as? Int, let ph = chain["processingHeight"] as? Int,
              let bw = chain["bufferWidth"] as? Int, let bh = chain["bufferHeight"] as? Int,
              let dw = chain["drawableWidth"] as? Int, let dh = chain["drawableHeight"] as? Int,
              [sw, sh, pw, ph, bw, bh, dw, dh].allSatisfy({ $0 > 0 }) else { return "" }
        let endpointText = endpoint == "output" ? EnhancementText.t("Output", "输出") : EnhancementText.t("Preview", "预览")
        let down = (chain["downsampled"] as? Bool) == true ? " · " + EnhancementText.t("Downsampled", "已降采样") : ""
        return endpointText + ": " + EnhancementText.t("Input", "输入") + " \(sw)×\(sh) → " +
            EnhancementText.t("Processing", "处理") + " \(pw)×\(ph) → " +
            EnhancementText.t("Buffer", "缓冲") + " \(bw)×\(bh) → " +
            EnhancementText.t("Drawable", "显示面") + " \(dw)×\(dh)" + down
    }
}

// Only used after the user selects the native preset; does not touch saved settings.
private func applyNativeQualityPreset(_ profile: inout EnhancementProfile) {
    profile.interpolationEnabled = true
    profile.interpolationEngineID = "rife.metal"
    profile.interpolationQuality = "fast"
    profile.modelID = "rife-v4.25"
    profile.rate = .multiplier(2)
    profile.scaleEnabled = false
    profile.outputWidth = 0
    profile.outputHeight = 0
}

private enum WorkbenchDimensionPolicy {
    static func value(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(trimmed), number >= 2 else { return nil }
        return number & ~1
    }
    static func text(_ value: Int) -> String { value > 0 ? String(value) : "—" }
    static func editable(sizeIndex: Int, scaleEnabled: Bool) -> Bool { scaleEnabled && sizeIndex == 4 }
}

enum P0DiagnosticPolicy {
    static func controlsEnabled(args: [String], isolated: Bool) -> Bool {
        isolated && args.contains("--odf-p0-controls")
    }
    static func flag(_ name: String, args: [String], isolated: Bool, overrideValue: Bool?) -> Bool {
        guard isolated else { return false }
        if controlsEnabled(args: args, isolated: isolated), let overrideValue { return overrideValue }
        return args.contains(name)
    }
}

enum WorkbenchTitle {
    static func text(_ base: String, version: String?) -> String {
        let value = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return base + (value.isEmpty ? "" : " · v" + value)
    }
}

// Keep selection menus anchored below the control rather than centered on
// the selected item, while retaining NSPopUpButton's selection and actions.
@MainActor private final class AnchoredPopUpButton: NSPopUpButton {
    private func showAnchoredMenu() {
        guard isEnabled else { return }
        let choices = NSMenu()
        choices.autoenablesItems = false
        choices.minimumWidth = bounds.width
        for (index, original) in itemArray.enumerated() {
            guard let item = original.copy() as? NSMenuItem else { continue }
            item.target = self
            item.action = #selector(selectAnchoredItem(_:))
            item.representedObject = index
            item.state = index == indexOfSelectedItem ? .on : .off
            choices.addItem(item)
        }
        let bottom = isFlipped ? bounds.maxY : bounds.minY
        choices.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bottom), in: self)
    }

    @objc private func selectAnchoredItem(_ item: NSMenuItem) {
        guard let index = item.representedObject as? Int else { return }
        selectItem(at: index)
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func mouseDown(with event: NSEvent) { showAnchoredMenu() }
    override func performClick(_ sender: Any?) { showAnchoredMenu() }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76, 125].contains(event.keyCode) { showAnchoredMenu() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        DispatchQueue.main.async { [weak self] in self?.showAnchoredMenu() }
        return true
    }
}

private final class CollapsingLabel: NSTextField {
    override var stringValue: String {
        didSet { isHidden = stringValue.isEmpty }
    }
}

final class EnhancementWorkbenchController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSToolbarDelegate {
    /// Capture callbacks call only the processor's queueing entry points.
    private final class CaptureProcessorSink: @unchecked Sendable {
        let processor: SPLiveProcessor
        init(_ processor: SPLiveProcessor) { self.processor = processor }
    }
    static let shared = EnhancementWorkbenchController()
#if ODF_AIR_BETA_DIAGNOSTIC
    private(set) static weak var betaInstance: EnhancementWorkbenchController?
    static var betaSessionRecordingEnabled: Bool {
        SPAirBetaSessionRecorder.isEnabled
    }
    private var betaRecorder: SPAirBetaSessionRecorder?
    private var betaLiveLogWriter: SPAirBetaLiveLogWriter?
    private var betaLogWritesPaused = false
    private var betaFinishInProgress = false
    private var betaSessionFinished = false
    private var betaFinishCompletions: [() -> Void] = []
    private var betaFinishToken: UUID?
    private var betaFinishPhase = "export"
    private var betaFinishDeadline: DispatchWorkItem?
#endif

    private final class WorkbenchWindow: NSWindow {
        var beforeMouseDown: ((NSEvent) -> Void)?
        var openSettings: (() -> Void)?
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "," {
                openSettings?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown { beforeMouseDown?(event) }
            super.sendEvent(event)
        }
    }

    private let processor = SPLiveProcessor()
    private let capture = WindowCaptureSource()
    private let outputPreview = SPLivePreviewView(frame: .zero)
    private var outputWindow: NSWindow?
    private var outputFollowsWindow = false
    private var viewerActive = false
    private var viewerFollowOverride = false
    private var viewerReturnPID: pid_t?
    private var viewerControls: NSStackView?
    private var viewerControlsPanel: NSPanel?
    private weak var viewerStopButton: NSButton?
    private var targetHUD: NSPanel?
    private var targetCountdownHUD: NSPanel?
    private let targetFPS = NSTextField(labelWithString: "")
    private let targetCountdown = NSTextField(labelWithString: "")
    private var targetWasOnscreen = false
    private var targetOnscreen = false
    private var targetFrontmost = false
    private var targetFrame = NSRect.zero
    private var targetContentRectVerified = false
    private var targetGeometryWarned = false
    private var targetDecision: [String: Any] = [:]
    private var targetDecisionReason = "no_target"
    private var outputHiddenReason = "no_target"
    private var hudHiddenReason = "no_target"
    private var outputWarmupToken: UInt64 = 0
    private var outputMinimumCaptureHost: Int64 = 0
    private var outputWarmupStartedAt: TimeInterval = 0
    private var outputWarmupWarningShown = false
    private var profile = EnhancementProfileStore.load()
    private var applied = EnhancementProfile()
    private var cadenceRefreshHz: Double = -1
    private var cadenceCaptureLimit: Int = -1
    private var cadenceDisplayID: UInt32 = 0
    private var fileURL: URL?
    private var shareableWindows: [SCWindowBox] = []
    private var shareableDisplays: [SCDisplayBox] = []
    private var ownCaptureApplications: [SCRunningApplication] = []

    private let statusLabel = NSTextField(labelWithString: "")
    private var lastWindowOptimizationStatus = ""
    private let statsLabel = CollapsingLabel(labelWithString: "")
    private let budgetLabel = CollapsingLabel(labelWithString: "")
    private let planLabel = NSTextField(wrappingLabelWithString: "")
    private let sizeChainLabel = NSTextField(wrappingLabelWithString: "")
    private let airBetaStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let airBetaReasonLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let fileLimitLabel = NSTextField(wrappingLabelWithString: "")
    private let interpolationSwitch = NSSwitch()
    private let scaleSwitch = NSSwitch()
    private let qualityPopup = NSPopUpButton()
    private let rateMode = NSSegmentedControl(labels: ["FPS", "X"], trackingMode: .selectOne, target: nil, action: nil)
    private let fpsPopup = NSPopUpButton()
    private let fpsNum = NSTextField()
    private let fpsDen = NSTextField()
    private let multiplierControl = NSSegmentedControl(labels: ["X2", "X3", "X4"], trackingMode: .selectOne, target: nil, action: nil)
    private let scalePopup = NSPopUpButton()
    private let scaleQualityPopup = NSPopUpButton()
    private var scaleQualityRow: NSView?
    private var artCNNLibraryButtons: [String: NSButton] = [:]
    private let sizePopup = AnchoredPopUpButton()
    private let srInputPopup = NSPopUpButton()
    private let srInputHelp = NSButton(title: "", target: nil, action: nil)
    private let sourceWindowPopup = NSPopUpButton()
    private let sourceWindowHelp = NSButton(title: "", target: nil, action: nil)
    private var srInputRow: NSView?
    private var sourceWindowRow: NSView?
    private let sourceWindowHint = NSTextField(wrappingLabelWithString: "")
    private var sourceWindowPreparing = false
    private var sourceWindowConfirmedAfter: UInt64 = 0
    private var sourceWindowConfirmedStarted: TimeInterval = 0
    private var sourceWindowConfirmedTarget: CaptureTarget?
    private var sourceWindowConfirmedSelection: SourceWindowResize.Selected?
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private var dimensionEditOriginal: [ObjectIdentifier: String] = [:]
    private let displayPopup = NSPopUpButton()
    private let fullscreenCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var interactionArmed = false
    private var interactionFailure = ""
    private var interactionSourceUnobstructed = false
    private var interactionObstructionWait = P1ObstructionWait()
    private var interactionRequestGeneration: UInt64 = 0
    private var interactionRequestConfig: UInt64 = 0
    private var interactionFocusAcquired = false
    private var interactionFocusDeadline: TimeInterval = 0
    private var interactionGuardFirst: [String: Any]?
    private var interactionGuardLast: [String: Any]?
    private var interactionAXBusy = false
    private var interactionAXLastRequest: TimeInterval = 0
    private var interactionGeometryWaitAt: TimeInterval = 0
    private var inputRouter: LiveInputRouter?
    private let fpsSwitch = NSSwitch()
    private let outputFPS = NSTextField(labelWithString: "")
    private var lastStatsReceipt: TimeInterval = 0
    private var fpsCanObserve = false
    private var fpsOutputObservable = false
    private let viewMode = NSSegmentedControl(labels: ["E", "O", "C"], trackingMode: .selectOne, target: nil, action: nil)
    private let appearanceControl = NSSegmentedControl(labels: ["S", "L", "D"], trackingMode: .selectOne, target: nil, action: nil)
    private let languageControl = NSSegmentedControl(labels: ["中文", "English", "More"], trackingMode: .selectOne, target: nil, action: nil)
    private let languageDetail = NSTextField(wrappingLabelWithString: "")
    private var settingsWindow: NSWindow?
    private var settingsStack: NSStackView?
    private var experimentComparisonPanel: ExperimentComparisonPanel?
    private var experimentPanelAutoOpened = false
    private let enhancementDelayControl = NSSegmentedControl(labels: ["3 s", "5 s", "10 s", "Custom"], trackingMode: .selectOne, target: nil, action: nil)
    private let enhancementDelayField = NSTextField(string: "3")
    private let enhancementDelayStepper = NSStepper()
    private let enhancementDelayCustomRow = NSStackView()
    private var enhancementDelayCustomSelected = false
    private let pageControl = NSSegmentedControl()
    private let configPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let configActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private var scaleBody: NSView?
    private var framesBody: NSView?
    private var formLabels: [(NSTextField, NSView, NSLayoutConstraint)] = []
    private var hasPendingFormChanges = false
    private let captureCapPopup = NSPopUpButton()
    private let recentStack = NSStackView()
    private var liveLogTimer: Timer?
    private var visibilityTimer: Timer?
    static var liveLogPath: String?
    private var r7Health = R7PresentationHealth()
    private var r7Visibility = ""
    private var r7LastHealthAt: TimeInterval = 0
    private var r7Diagnostics: Bool { PixelDiagnosticsPolicy.enabled(CommandLine.arguments) }
    private var p0ControlsEnabled: Bool { P0DiagnosticPolicy.controlsEnabled(args: CommandLine.arguments, isolated: r7Diagnostics) }
    private var p0OpaqueOverride: Bool?
    private var p0ActivateOverride: Bool?
    private var p0OpaqueButton: NSButton?
    private var p0ActivateButton: NSButton?
    private var p0CaptureButton: NSButton?
    private var p0MainOpaqueButton: NSButton?
    private var p0MainActivateButton: NSButton?
    private var p0MainCaptureButton: NSButton?
    private var p0MainActionInProgress = false
    private var geometryObservedWindow: CGWindowID = 0
    private var geometryObservedGeneration: UInt64 = 0
    private var geometryObservedBounds: CGRect = .null
    private var geometryBoundsChangedHost: UInt64 = 0
    private func r7Flag(_ flag: String) -> Bool {
        let overrideValue = flag == "--odf-r7-opaque" ? p0OpaqueOverride : (flag == "--odf-r7-activate" ? p0ActivateOverride : nil)
        return P0DiagnosticPolicy.flag(flag, args: CommandLine.arguments, isolated: r7Diagnostics, overrideValue: overrideValue)
    }
    private let shareStack = NSStackView()
    private let diagnosticLabel = NSTextField(labelWithString: "")
    private let sourceStripLabel = NSTextField(labelWithString: "")
    private let sourceMetaLabel = NSTextField(labelWithString: "")
    private var startButton: NSButton?
    private var stopButton: NSButton?
    private var sourceActionButton: NSButton?
    private var emptySourceButton: NSButton?
    private var activeSourceTitle = ""
    private var activeSourceKind = ""
    private var activeSourceBundle = ""
    private let stageHost = NSView()
    private let sourceHost = NSView()
    private let libraryHost = NSView()
    private let enginePopup = AnchoredPopUpButton()
    private let sourceKindControl = NSSegmentedControl(labels: ["窗口", "显示器", "视频文件"], trackingMode: .selectOne, target: nil, action: nil)
    private let phaseLabel = NSTextField(wrappingLabelWithString: "")
    private let compatibilityButton = NSButton(title: "改用 ODF-VFI", target: nil, action: nil)
    private var page = 0
    private var pendingApply: EnhancementProfile?
    private var liveApply = LiveApplyTracker()
    private var pendingSourceGeneration: UInt64?
    private var liveApplyFailure = ""
    private var fileApplied: EnhancementProfile?
    private var fileOutputToken: UInt64 = 0
    private weak var fileOutputPlayer: PlayerViewController?
    private var filePreparing = false
    private var filePrepareToken: UInt64 = 0
    private weak var filePreparingPlayer: PlayerViewController?
    private var lastStats: [String: Any] = [:]
    private var customRateRow: NSView?
    private var interpolationQualityRow: NSView?
    private var applyingFileSettings = false
    private var fileApplyError = ""
    private var lastFileStatsUpdate: TimeInterval = 0
    private var generation: UInt64 = 1
    private var renameEditor: ConfigRenameField?
    private var renameID: String?
    private var countdown = EnhancementCountdown()
    private var countdownTimer: Timer?
    private var countdownSourceGeneration: UInt64?
    private var delayedWindowSelection = false
    private var startImmediatelyAfterPreparation = false
    private var screenCountdownPanels: [NSPanel] = []
    private var screenCountdownLabels: [NSTextField] = []
    private let previewCountdown = NSTextField(labelWithString: "")
    private let outputCountdown = NSTextField(labelWithString: "")

    private struct SCWindowBox { var title: String; var bundle: String; var window: Any }
    private struct SCDisplayBox { var title: String; var display: Any }

    private init() {
        let window = WorkbenchWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "OpenDuckFrame"
        super.init(window: window)
#if ODF_AIR_BETA_DIAGNOSTIC
        Self.betaInstance = self
#endif
        profile.configID = EnhancementProfileStore.resolvedID(profile)
        if SPRifeExperiments.available { useRifeComparisonProfile() }
        applyAirBetaPreset(&profile)
        window.delegate = self
        let contentHost = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        contentHost.autoresizingMask = [.width, .height]
        window.contentView = contentHost
        let content = build()
        content.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentHost.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        installToolbar(on: window)
        window.openSettings = { [weak self] in self?.showSettings() }
        let minimumFrameSize = NSSize(width: 540, height: 620)
        let minimumContentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: minimumFrameSize)).size
        // Auto Layout derives the window minimum from its content constraints.
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumContentSize.width),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumContentSize.height),
        ])
        window.setFrameAutosaveName("OpenDuckFrame.Workbench")
        let restored = window.setFrameUsingName("OpenDuckFrame.Workbench")
        var frame = window.frame
        let previousHeight = frame.height
        frame.size = NSSize(width: 560, height: max(restored ? frame.height : 700, minimumFrameSize.height))
        frame.origin.y += previousHeight - frame.height
        window.setFrame(frame, display: false)
        if !restored { window.center() }
        window.initialFirstResponder = sourceKindControl
        window.beforeMouseDown = { [weak self] event in self?.endDimensionEditingBeforeClick(event) }
        installCountdownLabels()
        installFPSLabels()
        wire()
        loadControls()
        applyAppearance()
        refreshPlanLabel()
        updateFPSOverlay()
    }

    required init?(coder: NSCoder) { nil }

    private func installCountdownLabels() {
        for (host, label) in [(outputPreview, outputCountdown)] {
            label.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
            label.textColor = .white
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            label.layer?.cornerRadius = 48
            label.isHidden = true
            label.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                label.widthAnchor.constraint(equalToConstant: 96),
                label.heightAnchor.constraint(equalToConstant: 96),
            ])
        }
    }

    private func installFPSLabels() {
        for (host, label) in [(outputPreview, outputFPS)] {
            let plate = NSView()
            plate.wantsLayer = true
            plate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
            plate.layer?.cornerRadius = 6
            plate.translatesAutoresizingMaskIntoConstraints = false
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(label)
            host.addSubview(plate)
            NSLayoutConstraint.activate([
                plate.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
                plate.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -12),
                plate.topAnchor.constraint(equalTo: host.topAnchor, constant: 12),
                label.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: plate.topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -4),
            ])
            plate.isHidden = true
        }
    }

    private func updateFPSOverlay() {
        let enabled = fpsSwitch.state == .on
        let isFile = profile.sourceKind == "file"
        let now = ProcessInfo.processInfo.systemUptime
        let endpointVisible = outputPreview.drawableVisibleSnapshot && outputPreview.exposedSnapshot
        let canObserve = !isFile && capture.running && !capture.paused && (endpointVisible || targetFrontmost)
        fpsOutputObservable = !isFile && capture.running && !capture.paused && endpointVisible
        if canObserve != fpsCanObserve {
            fpsCanObserve = canObserve
            lastStatsReceipt = 0
            processor.resetFPSObservations()
        }
        let players = NSApp.windows.compactMap { $0.contentViewController as? PlayerViewController }
        let selectedPlayer = selectedFilePlayer()
        for player in players {
            player.setWorkbenchFPSObservation(player.workbenchFPSVisible)
        }
        let fileInput = selectedPlayer?.workbenchInputEstimateFPS ?? -1
        let fileOutput = selectedPlayer?.workbenchPresentedFPS ?? -1
        let fileInputText = fileInput > 0 ? String(format: "%.1f", fileInput) : "—"
        let fileOutputText = fileOutput > 0 ? String(format: "%.1f", fileOutput) : "—"
        let hasPlan = isFile ? ((selectedPlayer?.workbenchMotionPlusRequested ?? false) || (selectedPlayer?.workbenchFileLanczosActive ?? false)) :
            (capture.running && processor.resolvedPlan.committed && (processor.resolvedPlan.interpolationActive || processor.resolvedPlan.scaleActive))
        let text: String
        if isFile {
            text = EnhancementText.t("Input≈", "输入≈") + " \(fileInputText)" +
                (hasPlan ? " → " + EnhancementText.t("Output", "输出") + " \(fileOutputText)" : "") + " FPS"
        } else {
            text = LiveFPSOverlay.text(stats: lastStats, now: now, receipt: lastStatsReceipt,
                generation: capture.currentGeneration, config: processor.resolvedPlan.configVersion,
                running: capture.running, paused: capture.paused, committed: processor.resolvedPlan.committed,
                interpolation: processor.resolvedPlan.interpolationActive, canObserve: canObserve,
                outputObservable: fpsOutputObservable, chinese: EnhancementText.chinese)
        }
        for label in [targetFPS] {
            label.stringValue = text
        }
        if !isFile && outputWarmupWarningShown && outputWindow?.isVisible == true && (outputWindow?.alphaValue ?? 1) < 1 {
            targetFPS.stringValue += EnhancementText.t(" · Not ready", " · 未就绪")
        }
        outputFPS.superview?.isHidden = true
        targetFPS.superview?.isHidden = !enabled
        for player in players {
            player.setWorkbenchFPSOverlay(text: text, enabled: enabled && isFile && player === selectedPlayer)
        }
        if !isFile && !lastStats.isEmpty { updateStatsText(lastStats) }
    }

    @objc private func fpsVisibilityChanged() {
        FPSPreference.set(fpsSwitch.state == .on, in: .standard)
        updateFPSOverlay()
    }

    private func updateCountdownDisplay() {
        let showing = countdown.active && !sourceWindowPreparing && !delayedWindowSelection && !startImmediatelyAfterPreparation
        let text = showing ? "\(countdown.remaining)" : ""
        for label in screenCountdownLabels { label.stringValue = "\(countdown.remaining)" }
        for label in [previewCountdown, outputCountdown] {
            label.stringValue = text
            label.isHidden = !showing
        }
        outputCountdown.isHidden = true
        targetCountdown.stringValue = text
        targetCountdown.isHidden = !showing
        let selected = profile.sourceKind == "file" ? selectedFilePlayer() : nil
        for player in NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }) {
            player.setWorkbenchCountdown(text, enabled: showing && player === selected)
        }
        if delayedWindowSelection || startImmediatelyAfterPreparation { refreshActions() }
        else if countdown.active { startButton?.title = sourceWindowPreparing ? EnhancementText.t("Preparing…", "准备中…") : text }
        else { refreshActions() }
    }

    private func cancelCountdown() {
        let wasActive = countdown.active || delayedWindowSelection || startImmediatelyAfterPreparation
        delayedWindowSelection = false
        startImmediatelyAfterPreparation = false
        hideScreenCountdown()
        if let player = fileOutputPlayer {
            fileOutputToken &+= 1
            fileOutputPlayer = nil
            player.workbenchCancelFileOutput()
        }
        if filePreparing {
            filePrepareToken &+= 1
            filePreparing = false
            filePreparingPlayer?.workbenchCancelFileLanczosPreparation()
            filePreparingPlayer?.workbenchCancelFileRifePreparation()
            filePreparingPlayer = nil
            refreshActions()
        }
        sourceWindowPreparing = false
        sourceWindowConfirmedAfter = 0; sourceWindowConfirmedTarget = nil; sourceWindowConfirmedSelection = nil
        guard wasActive else { return }
        recordPlanEvent("countdown_cancelled")
        countdown.cancel()
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownSourceGeneration = nil
        updateCountdownDisplay()
    }

    func showWorkbench() {
        applyAppearance()
        showWindow(nil)
        installWorkbenchMenuEntries()
        NSApp.activate(ignoringOtherApps: true)
        startLiveLogIfNeeded()
        if SPRifeExperiments.available, !SPRifeExperiments.airBeta, !experimentPanelAutoOpened,
           CommandLine.arguments.contains("--odf-experiment-comparison") {
            experimentPanelAutoOpened = true
            showExperimentComparison()
        }
    }

    func showFileEnhancement(for player: PlayerViewController) {
        guard player.hasOpenMedia, let path = player.openMediaPath else { return }
        cancelCountdown()
        inputRouter?.stop(reason: "source_changed")
        interactionArmed = false
        capture.stop()
        let url = URL(fileURLWithPath: path)
        if fileURL?.standardizedFileURL != url.standardizedFileURL { fileApplied = nil }
        fileURL = url
        profile.sourceKind = "file"
        profile.sourceTitle = url.lastPathComponent
        profile.sourceBundleIdentifier = ""
        profile.interpolationEnabled = true
        LiveEngineSelection.normalize(&profile)
        activeSourceKind = "file"
        activeSourceBundle = ""
        showSourceTitle(url.lastPathComponent)
        loadControls()
        persist()
        showWorkbench()
        showNotice(EnhancementText.t("ODF-VFI is selected. Click Start Enhancement to apply it to this video.",
                                    "已选择 ODF-VFI。请点击开始增强后应用到此视频。"))
    }

    func showPlaybackFailure(_ message: String) {
        showWorkbench()
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
    }

    func showNotice(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .labelColor
    }

    @objc private func showExperimentComparison() {
        guard SPRifeExperiments.available, !SPRifeExperiments.airBeta else { return }
        if experimentComparisonPanel == nil {
            experimentComparisonPanel = ExperimentComparisonPanel(selectionChanged: { [weak self] selection in
                self?.selectExperimentComparison(selection)
            }, switchBuild: { [weak self] in
                guard let self else { throw CancellationError() }
                self.readControls()
                self.stop()
                guard self.saveCurrentProfile() else {
                    throw NSError(domain: "OpenDuckFrame.ExperimentComparison", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: self.statusLabel.stringValue])
                }
                try await SPRifeExperiments.switchBuild()
            })
        }
        experimentComparisonPanel?.window?.appearance = window?.appearance
        experimentComparisonPanel?.present()
    }

    private func selectExperimentComparison(_ selection: SPRifeExperimentSelection) {
        guard SPRifeExperiments.available, !SPRifeExperiments.airBeta else { return }
        readControls()
        stop()
        SPRifeExperiments.selection = selection
        useRifeComparisonProfile()
        loadControls()
        guard saveCurrentProfile() else {
            experimentComparisonPanel?.showStatus(statusLabel.stringValue, error: true)
            return
        }
        let message = EnhancementText.t(
            "Options saved for ODF-VFI. Enhancement stopped; click Start Enhancement to apply them.",
            "方案已保存为 ODF-VFI。增强已停止，请点击开始增强后应用。")
        showNotice(message)
        experimentComparisonPanel?.showStatus(message)
    }

    private func useRifeComparisonProfile() {
        profile.interpolationEnabled = true
        profile.interpolationEngineID = "rife.metal"
        profile.modelID = "rife-v4.25"
        profile.rifeStreamEnabled = true
        if !["fast", "balanced", "hq"].contains(profile.interpolationQuality) {
            profile.interpolationQuality = "fast"
        }
    }

    private func build() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        let inspector = glass()
        for view in [inspector, stageHost, sourceHost, libraryHost] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        for view in [stageHost, sourceHost, libraryHost] { root.addSubview(view) }
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged)
        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        languageControl.selectedSegment = EnhancementText.chinese ? 0 : 1

        viewMode.translatesAutoresizingMaskIntoConstraints = false
        viewMode.segmentDistribution = .fillEqually
        viewMode.isEnabled = !SPRifeExperiments.airBeta
        let source = column([sourceBlock(), viewMode])
        let sourceDivider = divider()
        let inspectorScroll = scrolled(inspectorColumn(), inset: 16)
        let runDivider = divider()
        let run = runPanel()
        let content = inspector.content
        for view in [source, sourceDivider, inspectorScroll, runDivider, run] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        stageHost.addSubview(inspector)
        let sourceScroll = scrolled(readableColumn(sourceColumn(), maxWidth: 900))
        let libraryScroll = scrolled(readableColumn(libraryColumn(), maxWidth: 760))
        sourceHost.addSubview(sourceScroll)
        libraryHost.addSubview(libraryScroll)
        NSLayoutConstraint.activate([
            stageHost.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            stageHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: WorkbenchStyle.edge),
            stageHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -WorkbenchStyle.edge),
            stageHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -WorkbenchStyle.edge),
            sourceHost.leadingAnchor.constraint(equalTo: stageHost.leadingAnchor),
            sourceHost.trailingAnchor.constraint(equalTo: stageHost.trailingAnchor),
            sourceHost.topAnchor.constraint(equalTo: stageHost.topAnchor),
            sourceHost.bottomAnchor.constraint(equalTo: stageHost.bottomAnchor),
            libraryHost.leadingAnchor.constraint(equalTo: stageHost.leadingAnchor),
            libraryHost.trailingAnchor.constraint(equalTo: stageHost.trailingAnchor),
            libraryHost.topAnchor.constraint(equalTo: stageHost.topAnchor),
            libraryHost.bottomAnchor.constraint(equalTo: stageHost.bottomAnchor),
            sourceScroll.leadingAnchor.constraint(equalTo: sourceHost.leadingAnchor),
            sourceScroll.trailingAnchor.constraint(equalTo: sourceHost.trailingAnchor),
            sourceScroll.topAnchor.constraint(equalTo: sourceHost.topAnchor),
            sourceScroll.bottomAnchor.constraint(equalTo: sourceHost.bottomAnchor),
            libraryScroll.leadingAnchor.constraint(equalTo: libraryHost.leadingAnchor),
            libraryScroll.trailingAnchor.constraint(equalTo: libraryHost.trailingAnchor),
            libraryScroll.topAnchor.constraint(equalTo: libraryHost.topAnchor),
            libraryScroll.bottomAnchor.constraint(equalTo: libraryHost.bottomAnchor),
            inspector.topAnchor.constraint(equalTo: stageHost.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: stageHost.bottomAnchor),
            inspector.trailingAnchor.constraint(equalTo: stageHost.trailingAnchor),
            inspector.leadingAnchor.constraint(equalTo: stageHost.leadingAnchor),
            source.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            source.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            source.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            sourceDivider.topAnchor.constraint(equalTo: source.bottomAnchor, constant: 12),
            sourceDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sourceDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inspectorScroll.topAnchor.constraint(equalTo: sourceDivider.bottomAnchor),
            inspectorScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            inspectorScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inspectorScroll.bottomAnchor.constraint(equalTo: runDivider.topAnchor),
            runDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            runDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            run.topAnchor.constraint(equalTo: runDivider.bottomAnchor, constant: 12),
            run.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            run.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            run.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        showPage(0)
        rebuildConfigRows()
        return root
    }

    private var hasSelectedSource: Bool {
        if profile.sourceKind == "file" { return selectedFilePlayer() != nil }
        return activeSourceKind == profile.sourceKind && capture.target != nil
    }

    private func updateSourceChrome(hasSource: Bool) {
        sourceActionButton?.isHidden = false
        sourceMetaLabel.isHidden = !hasSource || sourceMetaLabel.stringValue.isEmpty
        viewMode.isHidden = !hasSource || SPRifeExperiments.airBeta
        refreshActions()
    }


    private func refreshFormLabels() {
        for (label, view, width) in formLabels {
            width.constant = WorkbenchStyle.labelWidth
            let control = (view as? NSControl) ?? view.subviews.compactMap { $0 as? NSControl }.first
            label.textColor = control?.isEnabled == false ? .tertiaryLabelColor : .labelColor
        }
    }

    private enum ToolbarID {
        static let brand = NSToolbarItem.Identifier("odf.brand")
        static let pages = NSToolbarItem.Identifier("odf.pages")
        static let compare = NSToolbarItem.Identifier("odf.compare")
        static let settings = NSToolbarItem.Identifier("odf.settings")
    }

    private func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "odf.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [ToolbarID.pages]
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.title = "OpenDuckFrame"
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let compare: [NSToolbarItem.Identifier] = SPRifeExperiments.available && !SPRifeExperiments.airBeta ? [ToolbarID.compare] : []
        return [ToolbarID.brand, .flexibleSpace, ToolbarID.pages, .flexibleSpace] + compare + [ToolbarID.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case ToolbarID.brand:
            let icon = NSImageView(image: NSApp.applicationIconImage)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 22).isActive = true
            let name = NSTextField(labelWithString: "OpenDuckFrame")
            name.font = WorkbenchStyle.brandFont
            let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let version = NSTextField(labelWithString: "v" + shortVersion)
            version.font = WorkbenchStyle.captionFont
            version.textColor = .secondaryLabelColor
            let brand = NSStackView(views: [icon, name, version])
            brand.alignment = .centerY
            brand.spacing = 6
            item.view = brand
            item.label = "OpenDuckFrame"
            item.visibilityPriority = .high
        case ToolbarID.pages:
            var titles = [EnhancementText.t("Workbench", "工作台"), EnhancementText.t("Input", "输入源")]
            if !SPRifeExperiments.airBeta { titles.append(EnhancementText.t("Library", "技术库")) }
            pageControl.segmentCount = titles.count
            for (index, title) in titles.enumerated() { pageControl.setLabel(title, forSegment: index) }
            pageControl.selectedSegment = page
            pageControl.trackingMode = .selectOne
            pageControl.segmentDistribution = .fillEqually
            pageControl.target = self
            pageControl.action = #selector(pageControlChanged(_:))
            item.view = pageControl
            item.label = EnhancementText.t("Page", "页面")
            item.visibilityPriority = .high
        case ToolbarID.compare:
            let compare = NSButton(image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(showExperimentComparison))
            compare.identifier = NSUserInterfaceItemIdentifier("experiments.comparison.open")
            compare.bezelStyle = .texturedRounded
            item.view = compare
            item.label = EnhancementText.t("Compare Options", "方案对比")
            item.toolTip = item.label
            compare.setAccessibilityLabel(item.label)
            item.visibilityPriority = .low
        case ToolbarID.settings:
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            item.label = EnhancementText.t("Settings", "设置")
            item.toolTip = item.label
            item.isBordered = true
            item.target = self
            item.action = #selector(showSettings)
            item.visibilityPriority = .high
        default:
            return nil
        }
        return item
    }

    @objc private func pageControlChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1: showSourcePage()
        case 2: showLibrary()
        default: showStage()
        }
    }

    private func installWorkbenchMenuEntries() {
        guard let help = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: {
            $0.identifier?.rawValue == "sp.helpMenu"
        }) else { return }
        for (title, key) in [(EnhancementText.t("Website", "官网"), "ODFWebsiteURL"),
                             ("GitHub", "ODFRepositoryURL"),
                             (EnhancementText.t("Feedback", "反馈"), "ODFFeedbackURL")] {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else { continue }
            let item = help.items.first { $0.identifier?.rawValue == key || ($0.representedObject as? String) == value }
                ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if item.menu == nil { help.addItem(item) }
            item.title = title
            item.identifier = NSUserInterfaceItemIdentifier(key)
            item.target = self
            item.action = #selector(openProjectLink(_:))
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        installWorkbenchMenuEntries()
    }

    private func sourceBlock() -> NSView {
        sourceKindControl.target = self
        sourceKindControl.action = #selector(sourceKindChanged)
        sourceKindControl.setLabel(EnhancementText.t("Window", "窗口"), forSegment: 0)
        sourceKindControl.setLabel(EnhancementText.t("Display", "显示器"), forSegment: 1)
        sourceKindControl.setLabel(EnhancementText.t("Video File", "视频文件"), forSegment: 2)
        sourceKindControl.isHidden = SPRifeExperiments.airBeta
        sourceKindControl.segmentDistribution = .fillEqually
        sourceStripLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        sourceMetaLabel.font = WorkbenchStyle.captionFont
        sourceMetaLabel.textColor = .secondaryLabelColor
        for label in [sourceStripLabel, sourceMetaLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.allowsExpansionToolTips = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let sourceText = NSStackView(views: [sourceStripLabel, sourceMetaLabel])
        sourceText.orientation = .vertical
        sourceText.alignment = .leading
        sourceText.spacing = 1
        sourceText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let changeSource = button(EnhancementText.t("Change Window", "更换窗口"), #selector(changeWindow))
        changeSource.setContentCompressionResistancePriority(.required, for: .horizontal)
        sourceActionButton = changeSource
        let current = NSStackView(views: [sourceText, changeSource])
        current.orientation = .horizontal
        current.alignment = .centerY
        current.spacing = 8
        return column([sourceKindControl, current])
    }

    private func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func divider() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func sectionHeader(_ title: String, _ toggle: NSView) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [heading(title), spacer, toggle])
        header.orientation = .horizontal
        header.alignment = .centerY
        return header
    }

    private func readableColumn(_ content: NSView, maxWidth: CGFloat) -> NSView {
        let host = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        let fill = content.widthAnchor.constraint(equalTo: host.widthAnchor, constant: -32)
        // Preferred fill must yield to window resizing, whose priority is 500.
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([
            fill,
            content.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            content.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    private final class Plate: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = WorkbenchStyle.groupRadius
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refresh()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refresh()
        }
        override func layout() {
            super.layout()
            refresh()
        }
        func refresh() {
            let appearance = window?.effectiveAppearance ?? effectiveAppearance
            appearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045).cgColor
            }
        }
    }

    private final class GlassBox: NSView {
        let content = NSView()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = WorkbenchStyle.panelRadius
            content.translatesAutoresizingMaskIntoConstraints = false
            content.wantsLayer = true
            content.layer?.cornerRadius = WorkbenchStyle.panelRadius
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.translatesAutoresizingMaskIntoConstraints = false
                glass.cornerRadius = WorkbenchStyle.panelRadius
                glass.contentView = content
                addSubview(glass)
                pin(glass, to: self)
            } else {
                let visual = NSVisualEffectView()
                visual.material = .underWindowBackground
                visual.blendingMode = .withinWindow
                visual.state = .followsWindowActiveState
                visual.translatesAutoresizingMaskIntoConstraints = false
                addSubview(visual)
                pin(visual, to: self)
                visual.addSubview(content)
            }
            pin(content, to: self)
            refreshPlate()
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            refreshPlate()
        }
        override func layout() {
            super.layout()
            refreshPlate()
        }
        func refreshPlate() {
            let appearance = window?.effectiveAppearance ?? effectiveAppearance
            var glassAvailable = false
            if #available(macOS 26.0, *) { glassAvailable = true }
            appearance.performAsCurrentDrawingAppearance {
                // Liquid Glass draws its own fill and depth; older systems get a
                // translucent plate over the window material instead of opaque white.
                content.layer?.backgroundColor = glassAvailable ? NSColor.clear.cgColor
                    : NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
                content.layer?.borderWidth = 0.5
                content.layer?.borderColor = NSColor.separatorColor.cgColor
                layer?.shadowColor = NSColor.black.cgColor
            }
            layer?.shadowOpacity = glassAvailable ? 0 : 0.06
            layer?.shadowRadius = 4
            layer?.shadowOffset = CGSize(width: 0, height: 1)
            layer?.masksToBounds = false
        }
        private func pin(_ child: NSView, to parent: NSView) {
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                child.topAnchor.constraint(equalTo: parent.topAnchor),
                child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            ])
        }
    }

    private func glass() -> GlassBox { GlassBox() }

    private func fill(_ box: NSView, with stack: NSView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -12),
        ])
    }

    private func sourceCard(_ title: String, _ detail: String, _ action: Selector) -> NSView {
        let plate = Plate()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: detail)
        body.preferredMaxLayoutWidth = 180
        body.textColor = .secondaryLabelColor
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(button(EnhancementText.t("Choose", "选择"), action, primary: true))
        stack.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: plate.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -14),
            plate.widthAnchor.constraint(equalToConstant: 220),
            plate.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        return plate
    }

    private func sourceColumn() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        sourceLabel.maximumNumberOfLines = 2
        fileLimitLabel.maximumNumberOfLines = 3
        fileLimitLabel.textColor = .secondaryLabelColor
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        shareStack.orientation = .vertical
        shareStack.alignment = .leading
        let title = NSTextField(labelWithString: EnhancementText.t("Choose Input", "选择输入源"))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: EnhancementText.t(
            SPRifeExperiments.airBeta ? "Choose the window playing your video." : "Window, display, or a video file. A capture card is just that app's preview window.",
            SPRifeExperiments.airBeta ? "选择正在播放视频的窗口。" : "窗口、显示器或视频文件。采集卡就是那个软件自己的预览窗口。"))
        subtitle.preferredMaxLayoutWidth = 640
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.spacing = 12
        cards.addArrangedSubview(sourceCard(EnhancementText.t("Window", "窗口"), EnhancementText.t("Choose an app window to enhance.", "选择想要增强的应用窗口。"), #selector(chooseWindow)))
        if !SPRifeExperiments.airBeta {
            cards.addArrangedSubview(sourceCard(EnhancementText.t("Display", "显示器"), EnhancementText.t("Capture one display, excluding this app.", "捕获一块显示器，排除本应用。"), #selector(chooseDisplay)))
            cards.addArrangedSubview(sourceCard(EnhancementText.t("Video File", "视频文件"), EnhancementText.t("Open a video in the player to use supported file enhancement.", "在播放器中打开视频，使用支持的文件增强。"), #selector(chooseFile)))
        }
        stack.addArrangedSubview(cards)
        stack.addArrangedSubview(heading(EnhancementText.t("Current source", "当前来源")))
        captureCapPopup.removeAllItems()
        captureCapPopup.addItems(withTitles: [EnhancementText.t("Auto", "自动"), "30", "60"])
        captureCapPopup.target = self
        captureCapPopup.action = #selector(captureCapChanged)
        if !SPRifeExperiments.airBeta {
            stack.addArrangedSubview(heading(EnhancementText.t("Input capture cap (FPS)", "输入采集上限（FPS）")))
            stack.addArrangedSubview(captureCapPopup)
        }
        stack.addArrangedSubview(sourceLabel)
        stack.addArrangedSubview(fileLimitLabel)
        stack.addArrangedSubview(heading(EnhancementText.t("Recent", "最近")))
        stack.addArrangedSubview(recentStack)
        stack.addArrangedSubview(heading(EnhancementText.t("Authorized now", "当前可共享")))
        stack.addArrangedSubview(button(EnhancementText.t("Refresh List", "刷新列表"), #selector(refreshShareable)))
        stack.addArrangedSubview(shareStack)
        return stack
    }

    private func inspectorColumn() -> NSView {
        configurePopups()
        var items: [NSView] = []
        if SPRifeExperiments.airBeta {
            items.append(airBetaInspector())
        } else {
            configPopup.target = self
            configPopup.action = #selector(configPopupChanged(_:))
            configPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
            (configActions.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
            configActions.setAccessibilityLabel(EnhancementText.t("Manage configs", "管理配置"))
            let configControls = NSStackView(views: [configPopup, configActions])
            configControls.spacing = 4
            items.append(row(EnhancementText.t("Config", "配置"), configControls))

            let frameQuality = row(EnhancementText.t("Quality", "质量"), qualityPopup)
            interpolationQualityRow = frameQuality
            let customRate = row("n/d", pair(fpsNum, fpsDen))
            customRateRow = customRate
            phaseLabel.maximumNumberOfLines = 0
            phaseLabel.textColor = .secondaryLabelColor
            phaseLabel.preferredMaxLayoutWidth = WorkbenchStyle.inspectorWidth - 32
            compatibilityButton.target = self
            compatibilityButton.action = #selector(useFrameRateConversion)
            let frames = column([row(EnhancementText.t("Engine", "引擎"), enginePopup), frameQuality,
                                 phaseLabel, compatibilityButton, rateMode, fpsPopup, customRate, multiplierControl])
            framesBody = frames
            let qualityRow = row(EnhancementText.t("Denoising", "降噪"), scaleQualityPopup)
            scaleQualityRow = qualityRow
            srInputHelp.bezelStyle = .helpButton
            srInputHelp.setAccessibilityLabel(EnhancementText.t("SR input size help", "超分输入尺寸帮助"))
            let srInputControls = NSStackView(views: [srInputPopup, srInputHelp])
            srInputControls.orientation = .horizontal
            srInputControls.alignment = .centerY
            srInputControls.spacing = 4
            srInputControls.distribution = .fill
            srInputHelp.setContentHuggingPriority(.required, for: .horizontal)
            let srRow = row(EnhancementText.t("SR input size", "超分输入尺寸"), srInputControls)
            srInputRow = srRow
            sourceWindowHelp.bezelStyle = .helpButton
            sourceWindowHelp.setAccessibilityLabel(EnhancementText.t("Source window size help", "来源窗口尺寸帮助"))
            sourceWindowHelp.toolTip = EnhancementText.t("The selected window is resized before capture. The video must fill that window for the video itself to be 720p; browser toolbars and borders are not video. Requires Accessibility permission and a resizable window. Try 720p first; final clarity depends on the source and engine.", "开始时会调整所选来源窗口，再采集画面。视频须铺满该窗口，视频本身才可能是720p；浏览器工具栏和边框不是视频。需要辅助功能权限且窗口可调整大小。建议先从720p试起，最终清晰度取决于片源与引擎。")
            let sourceControls = NSStackView(views: [sourceWindowPopup, sourceWindowHelp])
            sourceControls.orientation = .horizontal
            sourceControls.alignment = .centerY
            sourceControls.spacing = 4
            sourceControls.distribution = .fill
            sourceWindowHelp.setContentHuggingPriority(.required, for: .horizontal)
            let windowRow = row(EnhancementText.t("Source window", "来源窗口尺寸"), sourceControls)
            sourceWindowRow = windowRow
            sourceWindowHint.stringValue = EnhancementText.t("Use a dedicated or picture-in-picture video window; the video must fill the captured window.", "请使用独立或画中画视频窗口；视频须铺满采集画面。")
            sourceWindowHint.textColor = .secondaryLabelColor
            sourceWindowHint.maximumNumberOfLines = 0
            sourceWindowHint.preferredMaxLayoutWidth = WorkbenchStyle.inspectorWidth - 32
            let scale = column([row(EnhancementText.t("Technology", "技术"), scalePopup), qualityRow,
                                srRow, windowRow, sourceWindowHint,
                                row(EnhancementText.t("Output size", "输出尺寸"), sizePopup),
                                row("W×H", pair(widthField, heightField))])
            scaleBody = scale
            items += [divider(), sectionHeader(EnhancementText.t("Frame generation", "帧生成"), interpolationSwitch), frames,
                      divider(), sectionHeader(EnhancementText.t("Scale", "缩放 / 超分"), scaleSwitch), scale]
        }
        if p0ControlsEnabled { items += [divider(), p0Controls()] }
        return column(items, spacing: 12)
    }

    private func p0Controls() -> NSView {
        let opaque = NSButton(title: "", target: self, action: #selector(toggleP0OpaqueFromMain))
        let focus = NSButton(title: "", target: self, action: #selector(toggleP0ActivationFromMain))
        let cap = NSButton(title: "", target: self, action: #selector(toggleP0CaptureCapFromMain))
        opaque.identifier = NSUserInterfaceItemIdentifier("p0.main.opaque")
        focus.identifier = NSUserInterfaceItemIdentifier("p0.main.focus")
        cap.identifier = NSUserInterfaceItemIdentifier("p0.main.capture")
        for item in [opaque, focus, cap] { item.bezelStyle = .rounded }
        p0MainOpaqueButton = opaque
        p0MainActivateButton = focus
        p0MainCaptureButton = cap
        refreshP0ControlTitles()
        return column([opaque, focus, cap])
    }

    private func airBetaInspector() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.addArrangedSubview(heading(EnhancementText.t("Runtime status", "运行状态")))
        airBetaStatusLabel.font = .systemFont(ofSize: 12)
        airBetaStatusLabel.maximumNumberOfLines = 10
        airBetaStatusLabel.stringValue = EnhancementText.t("Choose a window to see runtime details.", "选择窗口后显示运行状态。")
        airBetaReasonLabel.font = .systemFont(ofSize: 12)
        airBetaReasonLabel.maximumNumberOfLines = 6
        airBetaReasonLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(airBetaStatusLabel)
        stack.addArrangedSubview(airBetaReasonLabel)
        for label in [airBetaStatusLabel, airBetaReasonLabel] {
            label.preferredMaxLayoutWidth = 220
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func runPanel() -> NSView {
        let start = button(EnhancementText.t("Delayed Enhancement", "延迟增强"), #selector(start), primary: true)
        let stop = button(EnhancementText.t("Stop", "停止"), #selector(stop), primary: true)
        startButton = start
        stopButton = stop
        stop.isHidden = true
        fpsSwitch.state = FPSPreference.enabled(in: .standard) ? .on : .off
        fpsSwitch.target = self
        fpsSwitch.action = #selector(fpsVisibilityChanged)
        let fpsRow = sectionHeader(EnhancementText.t("Show FPS", "显示帧率"), fpsSwitch)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.cell?.truncatesLastVisibleLine = true
        statusLabel.preferredMaxLayoutWidth = WorkbenchStyle.inspectorWidth - 32
        for label in [statsLabel, budgetLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.allowsExpansionToolTips = true
            label.isHidden = label.stringValue.isEmpty
        }
        let statusColumn = column([statusLabel, statsLabel, budgetLabel], spacing: 2)
        var views: [NSView] = []
        if !SPRifeExperiments.airBeta {
            views += [row(EnhancementText.t("Output to", "输出到"), displayPopup), fullscreenCheck]
        }
        views += [fpsRow, statusColumn, start, stop]
        let stack = column(views)
        stack.setCustomSpacing(12, after: fpsRow)
        stack.setCustomSpacing(10, after: statusColumn)
        return stack
    }

    private final class TopDownDocument: NSView {
        nonisolated override var isFlipped: Bool { true }
    }

    private func scrolled(_ view: NSView, inset: CGFloat = 4) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = TopDownDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(view)
        scroll.documentView = document
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            view.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: document.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -inset),
        ])
        return scroll
    }

    private func libraryColumn() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.addArrangedSubview(heading(EnhancementText.t("Technology Library", "技术库")))
        let intro = NSTextField(wrappingLabelWithString: EnhancementText.t(
            "Choose the technology that fits your content and device.",
            "根据内容和设备选择合适的画质技术。"))
        intro.preferredMaxLayoutWidth = 640
        intro.textColor = .secondaryLabelColor
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(heading(EnhancementText.t("Frame generation", "帧生成")))
        stack.addArrangedSubview(libraryRow(
            "ODF-VFI",
            EnhancementText.t("Available for ordinary 8-bit video. fast is the checked tier. balanced and hq stay experimental.", "可用于普通 8 位画面。fast 是已核对的档位，balanced 和 hq 仍是实验。"),
            "rife.metal|rife-v4.25", enabled: true))
        stack.addArrangedSubview(heading(EnhancementText.t("Scale and super-resolution", "缩放与超分")))
        stack.addArrangedSubview(libraryRow("ArtCNN C4F32", EnhancementText.t("2× enhancement with more detail.", "2× 增强，画质优先。"), "scale|artcnn.c4f32", enabled: true))
        stack.addArrangedSubview(libraryRow("ArtCNN C4F16", EnhancementText.t("Lightweight 2× enhancement.", "2× 增强，速度优先。"), "scale|artcnn.c4f16", enabled: true))
        return stack
    }

    private func libraryRow(_ title: String, _ detail: String, _ identifier: String, enabled: Bool, unavailableStatus: String? = nil) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: detail)
        body.preferredMaxLayoutWidth = 430
        body.maximumNumberOfLines = 3
        body.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, body])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let symbol = identifier.hasPrefix("scale") ? "square.resize" : "play.rectangle"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = enabled ? .controlAccentColor : .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let line = NSStackView()
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 16
        line.translatesAutoresizingMaskIntoConstraints = false
        line.addArrangedSubview(icon)
        line.addArrangedSubview(labels)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        line.addArrangedSubview(spacer)
        if enabled {
            let use = button(EnhancementText.t("Use", "使用"), #selector(useLibrary(_:)), primary: true)
            use.identifier = NSUserInterfaceItemIdentifier(identifier)
            if identifier.hasPrefix("scale|artcnn.") {
                let id = String(identifier.dropFirst(6))
                artCNNLibraryButtons[id] = use
                use.isEnabled = SPArtCNNSR.isPackagedForThisSystem()
            }
            line.addArrangedSubview(use)
        } else {
            let unavailable = NSTextField(labelWithString: unavailableStatus ?? EnhancementText.t("Unavailable", "暂不可用"))
            unavailable.textColor = .secondaryLabelColor
            line.addArrangedSubview(unavailable)
        }
        let box = Plate()
        box.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            line.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            line.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
            box.widthAnchor.constraint(equalToConstant: 680),
        ])
        return box
    }

    @objc private func showStage() { showPage(0) }
    @objc private func showSourcePage() { showPage(1) }

    private func showPage(_ next: Int) {
        page = next
        stageHost.isHidden = next != 0
        sourceHost.isHidden = next != 1
        libraryHost.isHidden = next != 2
        pageControl.selectedSegment = next
        if next == 0 { redrawPreview() }
    }

    private func redrawPreview() {
        if profile.sourceKind == "file" { selectedFilePlayer()?.workbenchSetFileViewMode(profile.viewMode); return }
        applyAirBetaPreset(&profile)
        let mode: SPLiveViewMode
        switch profile.viewMode {
        case "original": mode = .original
        case "compare": mode = .compare
        default: mode = .enhanced
        }
        processor.setViewMode(mode)
    }

    @objc private func changeWindow() {
        chooseCurrentKind()
    }

    @objc private func chooseCurrentKind() {
        switch sourceKindControl.selectedSegment {
        case 1: chooseDisplay()
        case 2: chooseFile()
        default: chooseWindow()
        }
    }

    @objc private func sourceKindChanged() {
        cancelCountdown()
        inputRouter?.stop(reason:"source_changed"); interactionArmed = false
        readControls()
        updateSRCapability()
        refreshSourceBar()
        refreshActions()
        persist()
        refreshPlanLabel()
    }

    private func applyPresetDefaults(_ id: String) {
        switch id {
        case "preset:native":
            applyNativeQualityPreset(&profile)
        case "preset:game":
            profile.interpolationEnabled = true
            profile.interpolationEngineID = "rife.metal"
            profile.modelID = "rife-v4.25"
            profile.rate = .multiplier(2)
            profile.scaleEnabled = true
            profile.scaleEngineID = "artcnn.c4f32"
            profile.outputWidth = 0
            profile.outputHeight = 0
        case "preset:film":
            profile.interpolationEnabled = true
            profile.interpolationEngineID = "rife.metal"
            profile.interpolationQuality = "fast"
            profile.modelID = "rife-v4.25"
            profile.rate = .multiplier(2)
            profile.scaleEnabled = true
            profile.scaleEngineID = "artcnn.c4f32"
            profile.outputWidth = 0
            profile.outputHeight = 0
        case "preset:anime":
            profile.interpolationEnabled = true
            profile.interpolationEngineID = "rife.metal"
            profile.modelID = "rife-v4.25"
            profile.interpolationQuality = "fast"
            profile.rate = .multiplier(2)
            profile.scaleEnabled = true
            profile.scaleEngineID = "artcnn.c4f32"
            profile.outputWidth = 0
            profile.outputHeight = 0
        default:
            applyDefaultPreset(&profile)
        }
        LiveEngineSelection.normalize(&profile)
    }

    private final class ConfigRenameField: NSTextField {
        var cancelRename: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { cancelRename?() }
    }

    private func rebuildConfigRows() {
        cancelRename()
        configPopup.removeAllItems()
        configPopup.menu = NSMenu()
        configActions.removeAllItems()
        guard !SPRifeExperiments.airBeta else { return }
        let active = EnhancementProfileStore.resolvedID(profile)
        let metadata = EnhancementProfileStore.metadata()
        func add(_ id: String, _ title: String, _ symbol: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = id
            item.identifier = NSUserInterfaceItemIdentifier(id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            configPopup.menu?.addItem(item)
            if id == active { configPopup.select(item) }
        }
        for preset in EnhancementProfileStore.presets where !metadata.hiddenPresets.contains(preset.id) {
            add(preset.id, metadata.titles[preset.id] ?? EnhancementText.t(preset.english, preset.name), preset.symbol)
        }
        for name in EnhancementProfileStore.namedNames() {
            let matchesPreset = EnhancementProfileStore.presets.contains { $0.name == name }
            let title = matchesPreset ? name + " · " + EnhancementText.t("Custom", "自定义") : name
            add("custom:" + name, title, "doc.text")
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        menu.addItem(title)
        let add = NSMenuItem(title: EnhancementText.t("New Config…", "新增配置…"), action: #selector(addConfig), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let rename = NSMenuItem(title: EnhancementText.t("Rename…", "重命名…"), action: #selector(renameConfig(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = active
        menu.addItem(rename)
        let delete = NSMenuItem(title: EnhancementText.t("Delete", "删除"), action: #selector(deleteConfig(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = active
        delete.isEnabled = configPopup.numberOfItems > 1
        menu.addItem(delete)
        if !metadata.hiddenPresets.isEmpty {
            let restore = NSMenuItem(title: EnhancementText.t("Restore presets", "恢复预设"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for preset in EnhancementProfileStore.presets where metadata.hiddenPresets.contains(preset.id) {
                let item = NSMenuItem(title: metadata.titles[preset.id] ?? EnhancementText.t(preset.english, preset.name), action: #selector(restorePreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.id
                submenu.addItem(item)
            }
            restore.submenu = submenu
            menu.addItem(restore)
        }
        configActions.menu = menu
        configActions.setAccessibilityLabel(EnhancementText.t("Manage configs", "管理配置"))
    }

    @objc private func configPopupChanged(_ sender: NSPopUpButton) {
        cancelCountdown()
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        readControls()
        guard saveCurrentProfile() else { rebuildConfigRows(); return }
        if !activateConfig(id) { rebuildConfigRows() }
    }

    @discardableResult private func activateConfig(_ id: String) -> Bool {
        let previous = profile
        if id.hasPrefix("custom:") {
            guard let loaded = EnhancementProfileStore.loadNamed(String(id.dropFirst(7))) else { return false }
            profile = loaded
        } else {
            guard EnhancementProfileStore.presets.contains(where: { $0.id == id }) else { return false }
            if let saved = EnhancementProfileStore.loadPreset(id) { profile = saved }
            else { applyPresetDefaults(id) }
        }
        profile.configID = id
        if let preset = EnhancementProfileStore.presets.first(where: { $0.id == id }) { profile.configName = preset.name }
        else { profile.configName = String(id.dropFirst(7)) }
        profile.appearance = previous.appearance
        profile.recents = previous.recents
        if capture.running {
            profile.sourceKind = activeSourceKind
            profile.sourceTitle = activeSourceTitle
            profile.sourceBundleIdentifier = activeSourceBundle
        } else if previous.sourceKind == "file" && selectedFilePlayer() != nil {
            profile.sourceKind = previous.sourceKind
            profile.sourceTitle = previous.sourceTitle
            profile.sourceBundleIdentifier = previous.sourceBundleIdentifier
        }
        loadControls()
        guard saveCurrentProfile() else { profile = previous; loadControls(); return false }
        statusLabel.stringValue = EnhancementText.t("Config selected. The current source stays. Press Start to apply.", "已选择配置。当前来源不变。按开始后生效。")
        statusLabel.textColor = .labelColor
        return true
    }

    private func displayName(_ id: String) -> String {
        if let preset = EnhancementProfileStore.presets.first(where: { $0.id == id }) {
            return EnhancementProfileStore.metadata().titles[id] ?? EnhancementText.t(preset.english, preset.name)
        }
        return id.hasPrefix("custom:") ? String(id.dropFirst(7)) : id
    }

    @objc private func renameConfig(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        beginRename(id)
    }

    private func beginRename(_ id: String) {
        cancelCountdown()
        cancelRename()
        let alert = NSAlert()
        alert.messageText = EnhancementText.t("Rename config", "重命名配置")
        let editor = ConfigRenameField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        editor.stringValue = displayName(id)
        alert.accessoryView = editor
        alert.addButton(withTitle: EnhancementText.t("Rename", "重命名"))
        alert.addButton(withTitle: EnhancementText.t("Cancel", "取消"))
        alert.window.initialFirstResponder = editor
        renameID = id
        renameEditor = editor
        if alert.runModal() == .alertFirstButtonReturn { commitRename(editor) }
        else { cancelRename() }
    }

    private func cancelRename() {
        renameEditor?.delegate = nil
        renameEditor = nil
        renameID = nil
    }

    private func endDimensionEditingBeforeClick(_ event: NSEvent) {
        guard let window, let content = window.contentView,
              let field = [widthField, heightField].first(where: { $0.currentEditor() === window.firstResponder }),
              let editor = field.currentEditor() else { return }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        let target = content.hitTest(point)
        if let target, target === field || target.isDescendant(of: field) || target === editor || target.isDescendant(of: editor) { return }
        // The original event is still delivered by NSWindow.sendEvent.
        window.makeFirstResponder(nil)
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === widthField || field === heightField else { return }
        dimensionEditOriginal[ObjectIdentifier(field)] = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? NSTextField, field === widthField || field === heightField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textView.string = dimensionEditOriginal[ObjectIdentifier(field)] ?? field.stringValue
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)), field === widthField, heightField.isEditable {
            return window?.makeFirstResponder(heightField) ?? false
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)), field === heightField, widthField.isEditable {
            return window?.makeFirstResponder(widthField) ?? false
        }
        return false // Other key-view navigation remains with AppKit.
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === enhancementDelayField,
           let seconds = Int(field.stringValue), (1...20).contains(seconds) {
            enhancementDelayStepper.integerValue = seconds
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === enhancementDelayField {
            let seconds = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? EnhancementDelayPreference.seconds(in: .standard)
            saveEnhancementDelay(seconds)
            return
        }
        if let field = notification.object as? NSTextField, field === widthField || field === heightField {
            let previous = dimensionEditOriginal.removeValue(forKey: ObjectIdentifier(field))
            let fallback = field === widthField ? profile.outputWidth : profile.outputHeight
            let value = WorkbenchDimensionPolicy.value(field.stringValue) ??
                previous.flatMap(WorkbenchDimensionPolicy.value) ?? (fallback >= 2 ? fallback : (field === widthField ? 1920 : 1080))
            field.stringValue = String(value)
            controlChanged()
            return
        }
        guard let editor = notification.object as? ConfigRenameField, editor === renameEditor else { return }
        let movement = (notification.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
        if movement == NSReturnTextMovement { commitRename(editor) }
        else { cancelRename() }
    }

    @objc private func commitRename(_ sender: NSTextField) {
        guard sender === renameEditor, let id = renameID else { return }
        let name = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == displayName(id) { cancelRename(); return }
        let check = EnhancementProfileStore.checkRename(name, excluding: id)
        guard check == .valid else {
            cancelRename()
            let alert = NSAlert()
            alert.messageText = check == .duplicate ? EnhancementText.t("A config with this name already exists.", "配置名称已存在。") : EnhancementText.t("Invalid config name", "配置名称无效")
            alert.informativeText = EnhancementText.t("Use a nonempty name of at most 80 characters; custom names cannot contain / or :.", "名称不能为空且最多 80 个字；自定义名称不能包含 / 或 :。")
            alert.runModal()
            return
        }
        readControls()
        guard saveCurrentProfile() else { return }
        do {
            if id.hasPrefix("preset:") {
                var meta = EnhancementProfileStore.metadata()
                meta.titles[id] = name
                try EnhancementProfileStore.saveMetadata(meta)
            } else if id.hasPrefix("custom:") {
                let oldName = String(id.dropFirst(7))
                let directory = EnhancementProfileStore.namedDirectory()
                let oldURL = directory.appendingPathComponent(oldName + ".json")
                let newURL = directory.appendingPathComponent(name + ".json")
                let original = try Data(contentsOf: oldURL)
                let previous = profile
                let newID = "custom:" + name
                try EnhancementProfileStore.renameNamed(oldName, to: name)
                do {
                    if EnhancementProfileStore.resolvedID(profile) == id {
                        profile.configName = name; profile.configID = newID
                        try EnhancementProfileStore.save(profile)
                    }
                } catch {
                    profile = previous
                    do {
                        try original.write(to: newURL, options: .atomic)
                        try EnhancementProfileStore.moveNamedFile(newURL, to: oldURL)
                    } catch let rollback {
                        throw NSError(domain: "OpenDuckFrame.ConfigRename", code: 2, userInfo: [NSLocalizedDescriptionKey: "重命名未完成，回退也失败；请检查 \(newURL.path)：\(rollback.localizedDescription)"])
                    }
                    throw error
                }
            }
            cancelRename()
            rebuildConfigRows()
            statusLabel.stringValue = EnhancementText.t("Config renamed.", "配置已重命名。")
            statusLabel.textColor = .labelColor
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func deleteConfig(_ sender: NSMenuItem) {
        cancelCountdown()
        cancelRename()
        guard let id = sender.representedObject as? String else { return }
        let meta = EnhancementProfileStore.metadata()
        let visible = EnhancementProfileStore.presets.filter { !meta.hiddenPresets.contains($0.id) }.map(\.id) + EnhancementProfileStore.namedNames().map { "custom:" + $0 }
        guard visible.contains(id), visible.count > 1 else {
            let alert = NSAlert(); alert.messageText = EnhancementText.t("Keep at least one config.", "请至少保留一个配置。"); alert.runModal(); return
        }
        readControls()
        guard saveCurrentProfile() else { return }
        // Persist a valid replacement before removing the active entry. Later edits,
        // switches and restart can no longer save the removed identity again.
        if EnhancementProfileStore.resolvedID(profile) == id {
            guard let fallback = visible.first(where: { $0 != id }), activateConfig(fallback) else { return }
        }
        do {
            if id.hasPrefix("preset:") {
                var changed = meta
                if !changed.hiddenPresets.contains(id) { changed.hiddenPresets.append(id) }
                try EnhancementProfileStore.saveMetadata(changed)
            } else if id.hasPrefix("custom:") {
                let name = String(id.dropFirst(7))
                let url = EnhancementProfileStore.namedDirectory().appendingPathComponent(name + ".json")
                _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            rebuildConfigRows()
            statusLabel.stringValue = id.hasPrefix("preset:")
                ? EnhancementText.t("Preset hidden. Use Restore presets to bring it back.", "预设已隐藏，可通过“恢复预设”找回。")
                : EnhancementText.t("Config moved to Trash.", "配置已移到废纸篓。")
            statusLabel.textColor = .labelColor
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func restorePreset(_ sender: NSMenuItem) {
        cancelCountdown()
        guard let id = sender.representedObject as? String else { return }
        var meta = EnhancementProfileStore.metadata()
        meta.hiddenPresets.removeAll { $0 == id }
        do { try EnhancementProfileStore.saveMetadata(meta); rebuildConfigRows() }
        catch { statusLabel.stringValue = error.localizedDescription; statusLabel.textColor = .systemRed }
    }

    @objc private func addConfig() {
        cancelCountdown()
        let alert = NSAlert()
        alert.messageText = EnhancementText.t("Add config", "新增配置")
        alert.informativeText = EnhancementText.t("Enter a name for the current settings.", "为当前设置输入名称。")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: EnhancementText.t("Create", "创建"))
        alert.addButton(withTitle: EnhancementText.t("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = EnhancementProfileStore.checkNewName(name)
        guard result != .invalid else {
            let error = NSAlert()
            error.messageText = EnhancementText.t("Invalid config name", "配置名称无效")
            error.informativeText = EnhancementText.t("Enter a nonempty name without / or : (up to 80 characters).", "名称不能为空、不能包含 / 或 :，最多 80 个字。")
            error.runModal()
            return
        }
        guard result != .duplicate else {
            let error = NSAlert()
            error.messageText = EnhancementText.t("A config with this name already exists.", "配置名称已存在。")
            error.runModal()
            return
        }
        readControls()
        guard saveCurrentProfile() else { return }
        var created = profile
        created.configName = name
        created.configID = "custom:" + name
        do {
            try EnhancementProfileStore.saveNamed(created)
            profile = created
            guard saveCurrentProfile() else { return }
            rebuildConfigRows()
            statusLabel.stringValue = EnhancementText.t("Config created and selected.", "已创建并选择配置。")
            statusLabel.textColor = .labelColor
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func useLibrary(_ sender: NSButton) {
        cancelCountdown()
        let parts = (sender.identifier?.rawValue ?? "").split(separator: "|").map(String.init)
        guard let id = parts.first, !id.isEmpty else { return }
        if id == "scale", parts.count > 1 {
            guard ArtCNNSRSelection.contains(parts[1]), SPArtCNNSR.isPackagedForThisSystem() else { return }
            profile.outputWidth = 0; profile.outputHeight = 0
            profile.scaleEnabled = true
            profile.scaleEngineID = parts[1]
            loadControls()
            persist()
            refreshPlanLabel()
            showPage(0)
            statusLabel.stringValue = EnhancementText.t("Scale selected. Apply changes to use it.", "已选择缩放技术，应用更改后生效。")
            return
        }
        profile.interpolationEnabled = true
        LiveEngineSelection.normalize(&profile)
        loadControls()
        persist()
        showPage(0)
        statusLabel.stringValue = EnhancementText.t("Engine selected. Press Start to apply it.", "已选择引擎。按开始后生效。")
        statusLabel.textColor = .labelColor
    }

    @objc private func useFrameRateConversion() {
        cancelCountdown()
        LiveEngineSelection.normalize(&profile)
        profile.interpolationEnabled = true
        loadControls()
        persist()
        statusLabel.stringValue = EnhancementText.t("ODF-VFI selected. Press Start to apply it.", "已选择 ODF-VFI。按开始后生效。")
        statusLabel.textColor = .labelColor
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func button(_ title: String, _ action: Selector, primary: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = primary ? .push : .rounded
        button.controlSize = primary ? .large : .regular
        if primary { button.bezelColor = .controlAccentColor; button.contentTintColor = .white }
        if action == #selector(start) { button.keyEquivalent = "\r" }
        return button
    }

    private func showSourceTitle(_ title: String) {
        activeSourceTitle = title
        refreshSourceBar()
    }

    private func refreshSourceBar() {
        let text = hasSelectedSource ? activeSourceTitle : EnhancementText.t("No source", "未选择来源")
        sourceLabel.stringValue = text
        sourceStripLabel.stringValue = text
        sourceLabel.textColor = .labelColor
        sourceStripLabel.textColor = .labelColor
        let choose: String
        switch sourceKindControl.selectedSegment {
        case 1: choose = EnhancementText.t("Choose Display", "选择显示器")
        case 2: choose = EnhancementText.t("Choose File", "选择文件")
        default: choose = EnhancementText.t("Choose Window", "选择窗口")
        }
        sourceActionButton?.title = hasSelectedSource ? [EnhancementText.t("Change Window", "更换窗口"),
                                      EnhancementText.t("Change Display", "更换显示器"),
                                      EnhancementText.t("Change File", "更换文件")][max(0, sourceKindControl.selectedSegment)] : choose
        emptySourceButton?.title = choose
        updateSourceChrome(hasSource: hasSelectedSource)
    }

    private func refreshActions() {
        let player = selectedFilePlayer()
        let enhancing = profile.sourceKind == "file" ? ((player?.workbenchMotionPlusRequested ?? false) || (player?.workbenchFileLanczosActive ?? false)) :
            (capture.running && (processor.resolvedPlan.interpolationActive || processor.resolvedPlan.scaleActive || (applied.sourceKind == "window" && applied.windowOutputMode != "follow")))
        startButton?.isHidden = enhancing && !hasPendingFormChanges && !countdown.active
            && !delayedWindowSelection && !startImmediatelyAfterPreparation
        let canCancel = countdown.active || delayedWindowSelection || startImmediatelyAfterPreparation
        let canStart = (profile.sourceKind == "window" || hasSelectedSource) && !filePreparing
        startButton?.isEnabled = canCancel || canStart
        startButton?.toolTip = canCancel || canStart ? nil : EnhancementText.t("Choose a source first", "请先选择来源")
        if delayedWindowSelection || startImmediatelyAfterPreparation {
            startButton?.title = EnhancementText.t("Cancel", "取消")
        } else if profile.sourceKind == "window" {
            startButton?.title = EnhancementText.t("Delayed Enhancement", "延迟增强")
        } else {
            startButton?.title = filePreparing ? EnhancementText.t("Preparing…", "准备中…") : (countdown.active ? "\(countdown.remaining)" : (enhancing ? EnhancementText.t("Apply Changes", "应用更改") : EnhancementText.t("Start Enhancement", "开始增强")))
        }
        stopButton?.isHidden = !enhancing && !filePreparing
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        let label = NSTextField(labelWithString: title)
        let width = label.widthAnchor.constraint(equalToConstant: WorkbenchStyle.labelWidth)
        width.isActive = true
        formLabels.append((label, control, width))
        stack.addArrangedSubview(label)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(control)
        return stack
    }

    private func pair(_ a: NSTextField, _ b: NSTextField) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.distribution = .fillEqually
        stack.addArrangedSubview(a)
        stack.addArrangedSubview(b)
        return stack
    }

    private func configurePopups() {
        enginePopup.addItems(withTitles: ["ODF-VFI"])
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        qualityPopup.addItems(withTitles: ["fast", "balanced", "hq"])
        fpsPopup.addItems(withTitles: ["24", "25", "30", "50", "60", "90", "120", EnhancementText.t("Custom", "自定义")])
        scalePopup.addItems(withTitles: ArtCNNSRSelection.ids.map(ArtCNNSRSelection.title))
        scaleQualityPopup.addItems(withTitles: [EnhancementText.t("Off", "不降噪"), EnhancementText.t("Low", "轻度"), EnhancementText.t("Medium", "中等"), EnhancementText.t("Strong", "强")])
        srInputPopup.addItems(withTitles: [EnhancementText.t("Source size", "保持采集尺寸"), "480p (≤854×480)", "720p (≤1280×720)", "1080p (≤1920×1080)"])
        sourceWindowPopup.addItems(withTitles: [EnhancementText.t("Keep current size", "保持当前尺寸"), "480p (854×480)", "720p (1280×720)", "1080p (1920×1080)"])
        sizePopup.addItems(withTitles: [
            EnhancementText.t("Source size", "与来源相同"),
            "1280×720", "1920×1080", "2560×1440", EnhancementText.t("Custom", "自定义"), EnhancementText.t("2× source size", "来源的 2×"),
        ])
        sizePopup.item(at: 5)?.isEnabled = false
        rateMode.target = self
        rateMode.action = #selector(controlChanged)
        multiplierControl.target = self
        multiplierControl.action = #selector(controlChanged)
        viewMode.target = self
        viewMode.action = #selector(viewModeChanged)
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged)
        for control in [qualityPopup, fpsPopup, scalePopup, scaleQualityPopup, srInputPopup, sourceWindowPopup, sizePopup, displayPopup] {
            control.target = self
            control.action = #selector(controlChanged)
        }
        fpsNum.stringValue = "60"
        fpsDen.stringValue = "1"
        widthField.stringValue = "1920"
        heightField.stringValue = "1080"
        for field in [fpsNum, fpsDen, widthField, heightField] {
            if field === widthField || field === heightField { field.delegate = self }
            else { field.formatter = NumberFormatter() }
            field.target = self
            field.action = #selector(controlChanged)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        interpolationSwitch.target = self
        interpolationSwitch.action = #selector(controlChanged)
        scaleSwitch.target = self
        scaleSwitch.action = #selector(controlChanged)
        fullscreenCheck.target = self
        fullscreenCheck.action = #selector(controlChanged)
        fullscreenCheck.title = EnhancementText.t("Fullscreen on output display", "在输出显示器全屏")
        rateMode.setLabel(EnhancementText.t("Target FPS", "目标帧率"), forSegment: 0)
        rateMode.setLabel(EnhancementText.t("Multiplier", "倍率"), forSegment: 1)
        viewMode.setLabel(EnhancementText.t("Enhanced", "增强"), forSegment: 0)
        viewMode.setLabel(EnhancementText.t("Original", "原始"), forSegment: 1)
        viewMode.setLabel(EnhancementText.t("Compare", "对比"), forSegment: 2)
        appearanceControl.setLabel(EnhancementText.t("System", "系统"), forSegment: 0)
        appearanceControl.setLabel(EnhancementText.t("Light", "浅色"), forSegment: 1)
        appearanceControl.setLabel(EnhancementText.t("Dark", "深色"), forSegment: 2)
    }

    private func wire() {
        processor.preview = nil
        processor.outputPreview = outputPreview
        processor.installPresentationHooks()
        if PixelDiagnosticsPolicy.enabled(CommandLine.arguments) { processor.enablePixelDiagnostics() }
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.outputPreview.refreshVisibilitySnapshot()
                self?.updateTargetPanels()
                self?.updateFPSOverlay()
                guard let self, self.profile.sourceKind == "file" else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastFileStatsUpdate >= 1 else { return }
                self.lastFileStatsUpdate = now
                self.updateSRCapability()
                if let player = self.selectedFilePlayer() {
                    player.workbenchSetFileViewMode(self.profile.viewMode)
                    let fps = player.workbenchPresentedFPS
                    let rate = fps > 0 ? String(format: EnhancementText.t("Output %.1f fps", "输出约 %.1f fps"), fps) : ""
                    let coverage = player.workbenchMotionPlusRequested ? String(format: EnhancementText.t("Generated-pair coverage %.0f%%", "生成帧对覆盖率 %.0f%%"), player.workbenchInterpolationCoverage * 100) : ""
                    let lag = player.workbenchFileLanczosActive && player.workbenchVideoDelayMs >= 0
                        ? String(format: EnhancementText.t("Video delay ≈ %.0f ms", "视频延后约 %.0f 毫秒"), player.workbenchVideoDelayMs) : ""
                    self.statsLabel.stringValue = [rate, coverage, lag].filter { !$0.isEmpty }.joined(separator: " · ")
                    self.budgetLabel.stringValue = ""
                    let warning = player.workbenchMotionPlusStatus
                    if !self.fileApplyError.isEmpty {
                        self.statusLabel.stringValue = self.fileApplyError
                        self.statusLabel.textColor = .systemOrange
                    } else if self.fileOutputPlayer != nil {
                        self.statusLabel.stringValue = EnhancementText.t("Applying display output…", "正在切换输出…")
                        self.statusLabel.textColor = .labelColor
                    } else if player.workbenchMotionPlusRequested && player.workbenchMotionPlusAwaitingScan {
                        self.statusLabel.stringValue = EnhancementText.t("Waiting to verify the video. Seek backward or restart playback to reach a keyframe.", "正在确认视频，等待关键帧；可将进度拖回较早位置或重新播放。")
                        self.statusLabel.textColor = .systemOrange
                    } else if player.workbenchMotionPlusRequested && !warning.isEmpty {
                        self.statusLabel.stringValue = EnhancementText.runtime(warning)
                        self.statusLabel.textColor = player.workbenchMotionPlusActive ? .labelColor : .systemOrange
                    }
                    if self.fileApplyError.isEmpty && self.fileOutputPlayer == nil && !player.workbenchFileLanczosStatus.isEmpty {
                        self.statusLabel.stringValue = EnhancementText.runtime(player.workbenchFileLanczosStatus)
                        self.statusLabel.textColor = .systemRed
                    }
                    self.refreshActions()
                }
            }
        }
        processor.statsHandler = { [weak self] stats in self?.render(stats: stats) }
        processor.statusHandler = { [weak self] text, failed, requestID in
            guard let self else { return }
            guard requestID == 0 ? self.liveApply.pending == nil : requestID == self.liveApply.serial else { return }
            if text == LiveRuntimeStatus.interactiveBudgetWarning && self.nativePassthroughIsCurrent() {
                self.clearObsoleteBudgetWarningIfNeeded()
                return
            }
            self.statusLabel.stringValue = EnhancementText.runtime(text)
            self.statusLabel.textColor = text == LiveRuntimeStatus.interactiveBudgetWarning ? .systemOrange
                : (failed ? .systemRed : .labelColor)
            self.refreshActions()
        }
        processor.planHandler = { [weak self] state, engine, model, reason, requestID in
            guard let self else { return }
            let matched = self.liveApply.resolve(requestID, state: state)
            let event: [String: Any] = ["requestID": requestID, "ackState": state,
                "ackEngine": engine, "ackModel": model, "ackReason": reason, "ackMatched": matched]
            guard matched else { self.recordPlanEvent("ack", extra: event); return }
            if state == 2, let pending = self.pendingApply {
                self.inputRouter?.stop(reason:"configuration_changed")
                if self.isInteractiveMode(pending.windowOutputMode) && self.viewerActive {
                    self.viewerActive = false; self.viewerReturnPID = nil
                    (self.outputWindow as? TargetPanel)?.viewerKeyboard = false
                    self.outputWindow?.orderOut(nil); self.viewerControlsPanel?.orderOut(nil)
                }
                self.applied = pending
                self.interactionArmed = self.isInteractiveMode(pending.windowOutputMode) && pending.sourceKind == "window"
                self.interactionObstructionWait.reset()
                self.interactionRequestGeneration = self.capture.currentGeneration
                self.interactionRequestConfig = self.processor.resolvedPlan.configVersion
                self.interactionFocusAcquired = false
                self.interactionFocusDeadline = ProcessInfo.processInfo.systemUptime + 5
                self.interactionFailure = ""
                self.interactionGeometryWaitAt = 0
                self.cadenceRefreshHz = -1
                self.syncRawCadenceEnvironment()
                self.viewerFollowOverride = false
                self.pendingApply = nil
                self.pendingSourceGeneration = nil
                self.liveApplyFailure = ""
            } else if state == 0 {
                let requested = Self.engineDisplayName(engine, model: model)
                let active = Self.engineDisplayName(self.processor.resolvedPlan.engineID ?? "", model: self.processor.resolvedPlan.modelID ?? "")
                let w = self.lastStats["sourceWidth"] as? Int ?? 0, h = self.lastStats["sourceHeight"] as? Int ?? 0
                let size = w > 0 && h > 0 ? " \(w)×\(h)" : ""
                let retained = self.processor.resolvedPlan.committed ? " · " + EnhancementText.t("Still active", "继续生效") + " \(active)" : ""
                let detail: String
                if engine == "apple.lowlatency", reason.hasPrefix("画面边长超过低延迟上限"), let limit = reason.split(separator: " ").last {
                    detail = EnhancementText.t("Source exceeds this device's \(limit) px limit; choose a smaller source.", "来源边长超过本机 \(limit) 限制，请选择更小的来源。")
                } else { detail = EnhancementText.runtime(reason) }
                self.liveApplyFailure = EnhancementText.t("Requested", "请求") + " \(requested)" + size + "：" + detail + retained
                self.statusLabel.stringValue = self.liveApplyFailure
                self.statusLabel.textColor = .systemRed
                self.pendingApply = nil
                self.pendingSourceGeneration = nil
            }
            self.recordPlanEvent("ack", extra: event)
            self.refreshPlanLabel()
        }
        processor.outputSurfaceHandler = { [weak self] generation, config, token in
            guard let self, let panel = self.outputWindow else { return }
            let targetReady = self.capture.running && !self.capture.paused && self.capture.target != nil && self.targetFrontmost && panel.isVisible
            if token == self.outputWarmupToken && targetReady && generation == self.capture.currentGeneration &&
                config != self.processor.resolvedPlan.configVersion {
                self.outputWarmupToken &+= 1
                self.processor.awaitOutputSurface(withToken: self.outputWarmupToken, minimumCaptureHost: self.outputMinimumCaptureHost)
                return
            }
            guard TargetOverlayPolicy.canReveal(token: token, currentToken: self.outputWarmupToken,
                    generation: generation, currentGeneration: self.capture.currentGeneration,
                    config: config, currentConfig: self.processor.resolvedPlan.configVersion, targetReady: targetReady) else { return }
            self.recordPlanEvent("output_surface_ready", extra: ["generation": generation, "config": config, "token": token])
            panel.alphaValue = 1
            self.recordPlanEvent("reveal_alpha_1")
            self.outputPreview.refreshVisibilitySnapshot()
            self.outputWarmupStartedAt = 0
            self.lastStatsReceipt = 0
            self.processor.resetFPSObservations()
        }
        capture.excludedWindowIDs = { [weak self] in self?.excludedIDs() ?? [] }
        capture.onGeneration = { [weak self] generation in
            DispatchQueue.main.async {
                guard let self else { return }
                guard generation == self.capture.currentGeneration else { return }
                self.inputRouter?.stop(reason:"source_changed")
                self.interactionArmed = false
                if self.countdown.active && !self.delayedWindowSelection && generation != self.countdownSourceGeneration { self.cancelCountdown() }
                if let pending = self.pendingSourceGeneration, generation != pending {
                    self.recordPlanEvent("source_supersedes_request")
                    self.liveApply.cancel(); self.pendingApply = nil; self.pendingSourceGeneration = nil
                }
                self.r7Health.reset()
                self.r7LastHealthAt = 0
                self.r7Visibility = ""
                self.targetWasOnscreen = false
                self.viewerActive = false
                self.viewerFollowOverride = false
                self.viewerReturnPID = nil
                self.viewerControlsPanel?.orderOut(nil)
                (self.outputWindow as? TargetPanel)?.viewerKeyboard = false
                self.outputWarmupToken &+= 1
                self.outputMinimumCaptureHost = 0
                self.outputWindow?.orderOut(nil)
                self.targetHUD?.orderOut(nil)
                self.targetCountdownHUD?.orderOut(nil)
                self.outputPreview.refreshVisibilitySnapshot()
                self.lastStats = [:]
                self.lastStatsReceipt = 0
                self.updateFPSOverlay()
                self.generation = generation
                self.syncRawCadenceEnvironment()
                self.processor.adoptSourceGeneration(generation)
                self.outputPreview.setGeneration(generation)
                let active = self.processor.resolvedPlan.interpolationActive || self.processor.resolvedPlan.scaleActive
                self.statusLabel.stringValue = active
                    ? EnhancementText.t("Source changed; waiting for the new frame.", "已换源，等待新画面。")
                    : EnhancementText.t("Waiting for the new source frame.", "等待新来源画面。")
                self.statusLabel.textColor = .labelColor
                self.updateSourceChrome(hasSource: true)
            }
        }
        capture.onDiagnostic = { [weak self] text in
            DispatchQueue.main.async { self?.diagnosticLabel.stringValue = text }
        }
        capture.onSource = { [weak self] kind, title, bundle in
            DispatchQueue.main.async {
                guard let self else { return }
                self.activeSourceKind = kind
                self.activeSourceBundle = bundle
                self.profile.sourceKind = kind
                self.profile.sourceTitle = title
                self.profile.sourceBundleIdentifier = bundle
                self.sourceKindControl.selectedSegment = ["window": 0, "display": 1, "file": 2][kind] ?? 0
                self.showSourceTitle(title)
                self.applyModeVisibility()
                self.showPage(0)
                self.refreshActions()
                self.persist()
            }
        }
        capture.onStatus = { [weak self] text, failed in
            DispatchQueue.main.async {
                if failed { self?.cancelCountdown() }
                self?.statusLabel.stringValue = EnhancementText.runtime(text)
                self?.statusLabel.textColor = failed ? .systemRed : .labelColor
                if !failed, let self, self.capture.running { self.rememberRunningSource() }
            }
        }
        let sink = CaptureProcessorSink(processor)
        capture.onNote = { code in sink.processor.noteCaptureStatus(code) }
        capture.onGeometry = { geometry, generation in sink.processor.observeCaptureGeometry(geometry, generation: generation) }
        capture.onRawFrame = { ptsNum, ptsDen, host, width, height, generation in
            sink.processor.noteRawCapture(ptsNum: ptsNum, ptsDen: ptsDen, host: host,
                                          width: width, height: height, generation: generation)
        }
        capture.onPoolPressure = { generation in sink.processor.noteCapturePoolPressure(forGeneration: generation) }
        capture.onFrame = { buffer, ptsNum, ptsDen, captureHost, readyHost, generation in
            sink.processor.push(buffer, ptsNum: ptsNum, ptsDen: ptsDen, host: captureHost, readyHost: readyHost, generation: generation)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged), name: .odfMotionPlusChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(foregroundApplicationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pendingTextChanged(_:)), name: NSControl.textDidChangeNotification, object: nil)
        DistributedNotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged), name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        reloadDisplays()
        reloadRecents()
    }

    @objc private func foregroundApplicationChanged() {
        updateTargetPanels()
        updateFPSOverlay()
    }

    private func updateSRCapability() {
        if SPRifeExperiments.airBeta { applyModeVisibility(); return }
        let packaged = SPArtCNNSR.isPackagedForThisSystem()
        for (index, id) in ArtCNNSRSelection.ids.enumerated() {
            scalePopup.item(at: index)?.isEnabled = packaged
            artCNNLibraryButtons[id]?.isEnabled = packaged
        }
        applyModeVisibility()
    }

    private func selectOutputSize(_ w: Int, _ h: Int) {
        switch (w,h) {
        case (1280,720): sizePopup.selectItem(at: 1)
        case (1920,1080): sizePopup.selectItem(at: 2)
        case (2560,1440): sizePopup.selectItem(at: 3)
        default: sizePopup.selectItem(at: 4); widthField.stringValue = "\(w)"; heightField.stringValue = "\(h)"
        }
    }

    private func nativePassthroughIsCurrent() -> Bool {
        LiveRuntimeStatus.nativePassthroughIsCurrent(stats: lastStats, now: ProcessInfo.processInfo.systemUptime,
            receipt: lastStatsReceipt, generation: capture.currentGeneration, config: processor.resolvedPlan.configVersion,
            running: capture.running, paused: capture.paused, committed: processor.resolvedPlan.committed,
            interpolation: processor.resolvedPlan.interpolationActive, pending: liveApply.pending != nil)
    }

    private func clearObsoleteBudgetWarningIfNeeded() {
        let warning = EnhancementText.runtime(LiveRuntimeStatus.interactiveBudgetWarning)
        if LiveRuntimeStatus.shouldClearDisplayedWarning(statusLabel.stringValue, localizedWarning: warning,
                                                         nativeCurrent: nativePassthroughIsCurrent()) {
            statusLabel.stringValue = EnhancementText.t("Enhancement running", "增强运行")
            statusLabel.textColor = .labelColor
        }
    }

    private func render(stats: [String: Any]) {
        if capture.running, let incoming = stats["sourceGeneration"] as? UInt64, incoming != capture.currentGeneration { return }
        lastStats = stats
        lastStatsReceipt = ProcessInfo.processInfo.systemUptime
#if ODF_AIR_BETA_DIAGNOSTIC
        betaRecorder?.observeReadyStats(stats)
#endif
        clearObsoleteBudgetWarningIfNeeded()
        if profile.interpolationEngineID == "apple.lowlatency" { phaseLabel.stringValue = lowLatencyPhaseText() }
        updateSRCapability()
        refreshActions()
        updateFPSOverlay()
        refreshPlanLabel()
    }

    private func updateStatsText(_ stats: [String: Any]) {
        updateAirBetaStatus(stats)
        let healthNow = ProcessInfo.processInfo.systemUptime
        if healthNow - r7LastHealthAt >= 1 {
            r7LastHealthAt = healthNow
            observeR7Health()
        }
        if let width = stats["sourceWidth"] as? Int, let height = stats["sourceHeight"] as? Int, width > 0 {
            let fps = stats["callbackFPS"] as? Double ?? 0
            let label = EnhancementText.t("Capture", "采集回调")
            sourceMetaLabel.stringValue = fps > 1 && (r7Diagnostics || p0ControlsEnabled) ? "\(width)×\(height) · \(label) \(String(format: "%.0f", fps)) fps" : "\(width)×\(height)"
            sourceMetaLabel.isHidden = !hasSelectedSource
        }
        if SPRifeExperiments.airBeta { return }
        let presented = (stats["epochPhysicalSynthetic"] as? Int) ?? 0
        let scheduled = LiveCoverage.modelScheduled(total: (stats["epochScheduled"] as? Int) ?? 0,
                                                     held: (stats["epochStaticHoldPhases"] as? Int) ?? 0)
        let limited = processor.resolvedPlan.presentationLimited
        let budgetSkipped = (stats["nativeBudgetSkippedPhases"] as? Int) ?? 0
        let attempted = max(0, scheduled - budgetSkipped)
        let short = attempted > 120 && presented * 20 < attempted * 19
        let hint = limited
            ? EnhancementText.t(" Requested rate exceeds the display refresh rate.", " 请求帧率超过显示器刷新率。")
            : (short ? EnhancementText.t(" Output is below the requested rate. Reduce the multiplier or capture window size.", " 实际输出低于请求。可降低倍率或缩小采集窗口。") : "")
        let output = FPSPresentation.rate(stats["overlayPresentedFPS"] as? Double, observing: fpsOutputObservable,
                                          now: ProcessInfo.processInfo.systemUptime, receipt: lastStatsReceipt)
        let rate = output.map { String(format: EnhancementText.t("Output %.1f FPS", "输出 %.1f FPS"), $0) }
            ?? EnhancementText.t("Output — FPS", "输出 — FPS")
        let targetFPS = (stats["estimatedRequestedFPS"] as? Double) ?? -1
        let targetText = targetFPS > 0 ? String(format: (stats["requestedFPSIsEstimated"] as? Bool) == true
            ? EnhancementText.t("Target ≈%.0f", "目标 ≈%.0f") : EnhancementText.t("Target %.0f", "目标 %.0f"), targetFPS) : ""
        let coverage = attempted > 0 ? "\(EnhancementText.t("Synthesized", "合成")) \(presented)/\(attempted)" : ""
        let budget = budgetSkipped > 0 ? "\(EnhancementText.t("Display budget skipped", "显示上限跳过")) \(budgetSkipped)" : ""
        let generatedFPS = stats["r9GeneratedFPS"] as? Double ?? -1
        let onTimeFPS = stats["r9OnTimeSyntheticFPS"] as? Double ?? -1
        let generationRates = processor.resolvedPlan.interpolationActive && generatedFPS >= 0 && onTimeFPS >= 0
            ? String(format: EnhancementText.t("Generated %.1f/s · on-time %.1f/s", "生成 %.1f/秒 · 按期合成 %.1f/秒"), generatedFPS, onTimeFPS) : ""
        let requiredBudget = stats["r9RequiredBudgetMs"] as? Double ?? 0
        let allowedBudget = stats["r9AllowedBudgetMs"] as? Double ?? 0
        let budgetLimited = (stats["r9BudgetLimited"] as? Bool) == true
            ? String(format: EnhancementText.t("FRC budget limited (needs %.0f ms, allows %.0f ms)", "插帧预算不足（需要 %.0f ms，可用 %.0f ms）"), requiredBudget, allowedBudget) : ""
        let outputStalled = r7Health.stallSeconds >= 3
            ? EnhancementText.t("Capture continues; output has not presented", "采集持续，输出尚未呈现") : ""
        let modelOverdue = (stats["r7OldestJobAgeMs"] as? Double ?? -1) > 1000
            ? EnhancementText.t("Enhancement job delayed", "增强任务超时") : ""
        let holds = ((stats["epochStaticHoldPhases"] as? Int) ?? 0) > 0
            ? EnhancementText.t("Identical frames held", "静止画面保持原图") : ""
        // Coverage counts, scheduler rates and the size chain are for diagnosis;
        // everyday use sees the output rate, the target and actionable warnings.
        let diagnostics = r7Diagnostics || p0ControlsEnabled
        let lines = FooterMetrics.lines(target: targetText, output: rate, generation: diagnostics ? generationRates : "",
            budget: budgetLimited, stalled: outputStalled, overdue: modelOverdue,
            supplemental: diagnostics ? [coverage, budget, holds, sizeChainLabel.stringValue, hint.trimmingCharacters(in: .whitespaces)]
                : [hint.trimmingCharacters(in: .whitespaces)])
        statsLabel.stringValue = capture.running ? lines.primary : ""
        budgetLabel.stringValue = capture.running ? lines.secondary : ""
        budgetLabel.textColor = budgetLimited.isEmpty ? .secondaryLabelColor : .systemOrange
    }

    private func updateAirBetaStatus(_ stats: [String: Any]) {
        guard SPRifeExperiments.airBeta else { return }
        guard capture.running else {
            airBetaStatusLabel.stringValue = EnhancementText.t("Choose a window to see runtime details.", "选择窗口后显示运行状态。")
            airBetaReasonLabel.stringValue = ""
            statsLabel.stringValue = ""
            budgetLabel.stringValue = ""
            return
        }
        guard LiveFPSOverlay.fresh(stats: stats, now: ProcessInfo.processInfo.systemUptime, receipt: lastStatsReceipt,
                generation: capture.currentGeneration, config: processor.resolvedPlan.configVersion,
                running: capture.running, paused: capture.paused),
              let runtime = stats["airBeta"] as? [String: Any] else {
            airBetaStatusLabel.stringValue = EnhancementText.t("Waiting for runtime details…", "正在等待运行数据…")
            airBetaReasonLabel.stringValue = ""
            statsLabel.stringValue = EnhancementText.t("Output — FPS", "输出 — FPS")
            budgetLabel.stringValue = ""
            return
        }
        func pixels(_ key: String) -> String {
            guard let value = runtime[key] as? [Int], value.count == 2, value[0] > 0, value[1] > 0 else { return "—" }
            return "\(value[0])×\(value[1])"
        }
        let keeper = runtime["keeper"] as? String ?? ""
        let keeperText: String
        switch keeper {
        case "active": keeperText = EnhancementText.t("Active", "运行中")
        case "stopping": keeperText = EnhancementText.t("Stopping", "停止中")
        case "inactive": keeperText = EnhancementText.t("Inactive", "未运行")
        case "failed": keeperText = EnhancementText.t("Failed", "失败")
        case "preparing": keeperText = EnhancementText.t("Preparing", "准备中")
        default: keeperText = "—"
        }
        let factor = runtime["effectiveFactor"] as? Int
        let factorText = factor.map { "\($0)×" } ?? "—"
        let fps = FPSPresentation.rate(runtime["fps"] as? Double ?? stats["overlayPresentedFPS"] as? Double,
            observing: fpsOutputObservable, now: ProcessInfo.processInfo.systemUptime, receipt: lastStatsReceipt)
        let fpsText = fps.map { String(format: "%.1f FPS", $0) } ?? "— FPS"
        statsLabel.stringValue = EnhancementText.t("Output", "输出") + " " + fpsText
        budgetLabel.stringValue = ""
        airBetaStatusLabel.stringValue = [
            EnhancementText.t("Capture", "采集") + "  " + pixels("capturePixels"),
            EnhancementText.t("Processing", "处理") + "  " + pixels("processingPixels"),
            EnhancementText.t("Format", "格式") + "  " + (runtime["format"] as? String ?? "—"),
            EnhancementText.t("GPU keep-alive", "算力维持") + "  " + keeperText,
            EnhancementText.t("Active factor", "当前倍率") + "  " + factorText,
            EnhancementText.t("Output", "输出") + "  " + fpsText,
        ].joined(separator: "\n")
        airBetaReasonLabel.stringValue = runtime["reason"] as? String ?? ""
        airBetaReasonLabel.textColor = factor == 1 ? .systemOrange : .secondaryLabelColor
    }

    @objc private func captureCapChanged() {
        cancelCountdown()
        let previous = profile.captureLimit
        readControls()
        capture.captureCapFPS = Int(profile.captureLimit) ?? 0
        syncRawCadenceEnvironment()
        persist()
        if capture.running && previous != profile.captureLimit {
            capture.restart()
        }
        refreshPlanLabel()
    }

    private func startLiveLogIfNeeded() {
        guard liveLogTimer == nil, let path = Self.liveLogPath else { return }
        let url = URL(fileURLWithPath: path)
#if ODF_AIR_BETA_DIAGNOSTIC
        if Self.betaSessionRecordingEnabled {
            if betaLiveLogWriter == nil { betaLiveLogWriter = SPAirBetaLiveLogWriter(url: url) }
            if betaRecorder == nil {
                let directory = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-sessions", isDirectory: true)
                betaRecorder = SPAirBetaSessionRecorder(processor: processor, source: capture, preview: outputPreview, directory: directory)
            }
        } else {
            prepareLiveLogFile(url)
        }
#else
        prepareLiveLogFile(url)
#endif
        liveLogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeLiveLog(to: path) }
        }
    }

    private func prepareLiveLogFile(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    }

#if ODF_AIR_BETA_DIAGNOSTIC
    private func betaAllowsSessionChange() -> Bool {
        if Self.betaSessionRecordingEnabled {
            if betaFinishInProgress || betaRecorder?.isFinishing == true {
                statusLabel.stringValue = EnhancementText.t("Saving session logs…", "正在保存会话日志…")
                return false
            }
            if let recorder = betaRecorder, !recorder.canArm && !recorder.isActive {
                statusLabel.stringValue = EnhancementText.t("Log export is incomplete. Reopen AirBeta to continue.", "日志导出未完成，请重新打开 AirBeta 后继续。")
                return false
            }
        }
        return true
    }

    private func armBetaSessionIfNeeded() {
        guard Self.betaSessionRecordingEnabled, !betaFinishInProgress,
              case let .window(id, owner) = capture.target else { return }
        startLiveLogIfNeeded()
        guard let recorder = betaRecorder, recorder.canArm || recorder.isActive else { return }
        betaSessionFinished = false
        betaLogWritesPaused = false
        recorder.arm(windowID: id, ownerPID: owner, generation: capture.currentGeneration)
        recorder.observeReadyStats(lastStats)
    }

    func finishBetaSession(reason: String, completion: @escaping () -> Void) {
        guard Self.betaSessionRecordingEnabled else { completion(); return }
        cancelCountdown()
        if betaSessionFinished {
            if capture.running { stopImmediately() }
            completion()
            return
        }
        betaFinishCompletions.append(completion)
        guard !betaFinishInProgress else { return }
        betaFinishInProgress = true
        let token = UUID()
        betaFinishToken = token
        betaFinishPhase = "export"
        let deadline = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.completeBetaFinish(token: token, incompleteReason: "session_finish_38s_timeout_\(self.betaFinishPhase)")
        }
        betaFinishDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 38, execute: deadline)
        betaLogWritesPaused = true
        liveLogTimer?.invalidate(); liveLogTimer = nil
        guard let recorder = betaRecorder else {
            stopImmediately()
            completeBetaFinish(token: token)
            return
        }
        recorder.finish(reason: reason) { [weak self] report in
            guard let self, self.betaFinishToken == token else { return }
            self.stopImmediately(stopPipeline: false)
            if let path = Self.liveLogPath {
                self.writeLiveLog(to: path, event: "beta_session_export_finished", extra: ["betaSessionExport": report], force: true)
            }
            guard let writer = self.betaLiveLogWriter else {
                self.betaFinishPhase = "final_marker"
                recorder.recordFinalLiveLogReceipt(["complete": false, "firstError": "live_log_writer_missing"]) { [weak self] in self?.completeBetaFinish(token: token) }
                return
            }
            self.betaFinishPhase = "live_log_flush"
            writer.flush { [weak self] receipt in
                DispatchQueue.main.async {
                    guard let self, self.betaFinishToken == token else { return }
                    self.betaFinishPhase = "final_marker"
                    recorder.recordFinalLiveLogReceipt(receipt.jsonObject) { [weak self] in self?.completeBetaFinish(token: token) }
                }
            }
        }
        outputWindow?.orderOut(nil)
        targetHUD?.orderOut(nil)
        targetCountdownHUD?.orderOut(nil)
        statusLabel.stringValue = EnhancementText.t("Saving session logs…", "正在保存会话日志…")
    }

    func forceBetaTerminationIncomplete() {
        betaLogWritesPaused = true
        liveLogTimer?.invalidate(); liveLogTimer = nil
        if let token = betaFinishToken {
            completeBetaFinish(token: token, incompleteReason: "application_termination_60s_timeout")
        } else {
            betaRecorder?.forceIncomplete(reason: "application_termination_60s_timeout")
        }
    }

    private func completeBetaFinish(token: UUID, incompleteReason: String? = nil) {
        guard betaFinishInProgress, betaFinishToken == token else { return }
        betaFinishToken = nil
        betaFinishDeadline?.cancel(); betaFinishDeadline = nil
        betaFinishInProgress = false
        betaSessionFinished = true
        let completions = betaFinishCompletions
        betaFinishCompletions.removeAll()
        if let incompleteReason {
            betaRecorder?.forceIncomplete(reason: incompleteReason)
            stopImmediately(stopPipeline: false)
            statusLabel.stringValue = EnhancementText.t("Log export is incomplete. Reopen AirBeta to continue.", "日志导出未完成，请重新打开 AirBeta 后继续。")
        }
        for completion in completions { completion() }
    }
#endif

    private func observeR7Health() {
        let captureStats = capture.diagnostics()
        let stats = processor.stats
        let accepted = (captureStats["accepted"] as? NSNumber)?.uint64Value ?? 0
        let presented = (stats["outputPresentedValidTime"] as? NSNumber)?.uint64Value ?? 0
        let visible = outputWindow?.isVisible == true && outputWindow?.alphaValue == 1 && targetFrontmost
        let state = "\(visible):\(targetDecisionReason):\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)"
        if state != r7Visibility {
            r7Visibility = state
            recordPlanEvent("visibility_changed")
        }
        let generation = capture.currentGeneration
        let config = processor.resolvedPlan.configVersion
        // Cached stats can briefly belong to a retired source or plan.
        guard (stats["sourceGeneration"] as? NSNumber)?.uint64Value == generation,
              (stats["configVersion"] as? NSNumber)?.uint64Value == config else {
            r7Health.reset()
            return
        }
        let evidence = stats["r7ContentChange"] as? [String: Any] ?? [:]
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let contentFresh = R7ContentChangeEvidence.isFresh(now: mach_absolute_time(),
            host: (evidence["host"] as? NSNumber)?.uint64Value ?? 0, numer: timebase.numer, denom: timebase.denom,
            generation: generation, config: config, epoch: (stats["measurementEpoch"] as? NSNumber)?.uint64Value ?? 0,
            evidenceGeneration: (evidence["generation"] as? NSNumber)?.uint64Value ?? 0,
            evidenceConfig: (evidence["configVersion"] as? NSNumber)?.uint64Value ?? 0,
            evidenceEpoch: (evidence["measurementEpoch"] as? NSNumber)?.uint64Value ?? 0,
            snapshotStale: (stats["snapshotStale"] as? Bool) == true)
        let result = r7Health.observe(generation: generation, config: config,
            running: capture.running && !capture.paused, visible: visible,
            accepted: accepted, presented: presented, changingContent: contentFresh)
        if result.firstStall {
            recordPlanEvent("capture_advancing_present_stalled", extra: ["observationSeconds": r7Health.stallSeconds])
        }
        if result.rearm {
            // Re-arm only this presenter; preserve capture and in-flight work.
            outputWarmupToken &+= 1
            outputMinimumCaptureHost = Int64(mach_absolute_time())
            outputWindow?.orderOut(nil)
            outputPreview.refreshVisibilitySnapshot()
            recordPlanEvent("presenter_rearm")
            updateTargetPanels()
        }
    }

    private func recordPlanEvent(_ event: String, extra: [String: Any] = [:]) {
        guard let path = Self.liveLogPath else { return }
        writeLiveLog(to: path, event: event, extra: extra)
    }

    private func writeLiveLog(to path: String, event: String? = nil, extra: [String: Any] = [:], force: Bool = false) {
#if ODF_AIR_BETA_DIAGNOSTIC
        if Self.betaSessionRecordingEnabled && betaLogWritesPaused && !force { return }
#endif
        var line: [String: Any] = [
            "t": Date().timeIntervalSince1970,
            "monotonicSeconds": ProcessInfo.processInfo.systemUptime,
            "machAbsolute": mach_absolute_time(),
            "r8ProcessID": ProcessInfo.processInfo.processIdentifier,
            "r7Passthrough": r7Flag("--odf-r7-passthrough"),
            "r7Opaque": r7Flag("--odf-r7-opaque"),
            "r7Activate": r7Flag("--odf-r7-activate"),
            "r7FullscreenGeometry": r7Flag("--odf-r7-fullscreen-geometry"),
            "p0ControlsEnabled": p0ControlsEnabled,
            "p0RequestedCaptureCap": capture.captureCapFPS,
            "realWindowCapture": capture.running,
            "capturePaused": capture.paused,
            "sourceKind": activeSourceKind.isEmpty ? profile.sourceKind : activeSourceKind,
            "sourceTitle": activeSourceTitle,
            "profileSourceTitle": profile.sourceTitle,
            "sourceBundle": activeSourceBundle,
            "capture": capture.diagnostics(),
            "processor": processor.stats,
            "sharedGeometry": outputPreview.sharedGeometrySnapshot(),
            "presentationLimited": processor.resolvedPlan.presentationLimited,
            "countdownActive": countdown.active,
            "countdownRemaining": countdown.remaining,
            "countdownToken": countdown.token,
            "delayedWindowSelection": delayedWindowSelection,
            "screenCountdownPanelCount": screenCountdownPanels.count,
            "screenCountdownClickThrough": screenCountdownPanels.allSatisfy(\.ignoresMouseEvents),
            "screenCountdownCanBecomeKey": screenCountdownPanels.contains(where: { $0.canBecomeKey }),
            "selectedConfigID": EnhancementProfileStore.resolvedID(profile),
            "showFPS": fpsSwitch.state == .on,
            "selectedEngine": profile.interpolationEngineID,
            "selectedModel": profile.modelID,
            "pendingEngine": pendingApply?.interpolationEngineID ?? "",
            "pendingModel": pendingApply?.modelID ?? "",
            "pendingRequestID": liveApply.pending ?? 0,
            "appliedEngine": applied.interpolationEngineID,
            "appliedModel": applied.modelID,
            "targetIgnoredWindows": targetDecision["targetIgnoredWindows"] ?? [],
            "targetOnscreen": targetOnscreen,
            "targetFrontmostMatch": targetDecisionReason == "matched",
            "outputTargetReady": targetFrontmost,
            "diagnosticOwnActivated": viewerActive && r7Flag("--odf-r7-activate"),
            "targetOverlayFrame": [targetFrame.origin.x, targetFrame.origin.y, targetFrame.width, targetFrame.height],
            "targetContentRectVerified": targetContentRectVerified,
            "outputPanelVisible": outputWindow?.isVisible ?? false,
            "outputPanelOnActiveSpace": outputWindow?.isOnActiveSpace ?? false,
            "hudPanelOnActiveSpace": targetHUD?.isOnActiveSpace ?? false,
            "outputPanelAlpha": outputWindow?.alphaValue ?? 0,
            "outputMinimumCaptureHost": outputMinimumCaptureHost,
            "outputPanelIsOpaque": outputWindow?.isOpaque ?? false,
            "outputLayerIsOpaque": outputPreview.layer?.isOpaque ?? false,
            "outputFollowsWindow": outputFollowsWindow,
            "outputFullscreenApplied": applied.outputFullscreen,
            "requestedWindowOutputMode": profile.windowOutputMode,
            "appliedWindowOutputMode": applied.windowOutputMode,
            "inputRoute": inputRouter?.diagnostics() ?? ["active": false, "reason": "not_started"],
            "inputListenPermission": isInteractiveMode(profile.windowOutputMode) ? LiveInputRouter.Permission.preflight().listen : false,
            "inputPostPermission": isInteractiveMode(profile.windowOutputMode) ? LiveInputRouter.Permission.preflight().post : false,
            "inputAccessibilityTrusted": isInteractiveMode(profile.windowOutputMode) ? LiveInputRouter.Permission.preflight().accessibility : false,
            "effectiveMode": (outputWindow?.isVisible != true) ? "hidden" :
                (r7Flag("--odf-r7-fullscreen-geometry") && activeSourceKind == "window" ? "diagnostic_fullscreen_input_blocked" :
                 (outputFollowsWindow ? "source_aligned_interactive" : (isInteractiveMode(applied.windowOutputMode) ?
                    (inputRouter?.ready == true ? "fullscreen_interaction_\(applied.windowOutputMode)" : "fullscreen_interaction_preparing") : "fullscreen_viewer_input_blocked"))),
            "effectiveViewMode": profile.viewMode,
            "outputPanelIsKey": outputWindow?.isKeyWindow ?? false,
            "frontProcessActualPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "hudPanelVisible": targetHUD?.isVisible ?? false,
            "countdownPanelVisible": targetCountdownHUD?.isVisible ?? false,
            "outputPanelClickThrough": outputWindow?.ignoresMouseEvents ?? true,
            "hudPanelClickThrough": targetHUD?.ignoresMouseEvents ?? true,
            "countdownPanelClickThrough": targetCountdownHUD?.ignoresMouseEvents ?? true,
            "outputPanelCanBecomeKey": outputWindow?.canBecomeKey ?? false,
            "hudPanelCanBecomeKey": targetHUD?.canBecomeKey ?? false,
            "countdownPanelCanBecomeKey": targetCountdownHUD?.canBecomeKey ?? false,
            "outputPanelCanBecomeMain": outputWindow?.canBecomeMain ?? false,
            "hudPanelCanBecomeMain": targetHUD?.canBecomeMain ?? false,
            "countdownPanelCanBecomeMain": targetCountdownHUD?.canBecomeMain ?? false,
        ]
        if let event { line["event"] = event }
        line.merge(extra) { _, new in new }
        if profile.sourceKind == "file", let player = selectedFilePlayer() { line["fileScaler"] = player.workbenchFileScalerDiagnostics }
        if let rect = outputWindow?.frame { line["outputPanelFrame"] = [rect.minX, rect.minY, rect.width, rect.height] }
        if let rect = targetHUD?.frame { line["hudPanelFrame"] = [rect.minX, rect.minY, rect.width, rect.height] }
        if let rect = targetCountdownHUD?.frame { line["countdownPanelFrame"] = [rect.minX, rect.minY, rect.width, rect.height] }
        if let rect = capture.latestScreenRect() { line["captureScreenRect"] = [rect.origin.x, rect.origin.y, rect.width, rect.height] }
        switch capture.target {
        case let .window(id, owner): line["targetWindowID"] = id; line["targetOwnerPID"] = owner
        case let .display(id): line["targetDisplayID"] = id
        case nil: break
        }
        if r7Diagnostics {
            line["interactionGuardFirst"] = interactionGuardFirst ?? NSNull()
            line["interactionGuardLast"] = interactionGuardLast ?? NSNull()
        }
        line.merge(targetDecision) { _, new in new }
        line["targetMatchReason"] = targetDecisionReason
        line["outputHiddenReason"] = outputHiddenReason
        line["hudHiddenReason"] = hudHiddenReason
        line["note"] = "counts are capture callbacks and drawable presents; complete is not the output rate"
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line) else { return }
        data.append(0x0A)
#if ODF_AIR_BETA_DIAGNOSTIC
        if Self.betaSessionRecordingEnabled { betaLiveLogWriter?.append(data); return }
#endif
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
    }

    @objc private func chooseWindow() {
#if ODF_AIR_BETA_DIAGNOSTIC
        guard betaAllowsSessionChange() else { return }
#endif
        cancelCountdown(); inputRouter?.stop(reason:"source_changed"); interactionArmed = false
        profile.sourceKind = "window"; capture.presentPicker(windows: true); persist()
    }
    @objc private func chooseDisplay() {
#if ODF_AIR_BETA_DIAGNOSTIC
        guard betaAllowsSessionChange() else { return }
#endif
        cancelCountdown(); inputRouter?.stop(reason:"source_changed"); interactionArmed = false
        profile.sourceKind = "display"; capture.presentPicker(windows: false); persist()
    }

    @objc func chooseFile() {
#if ODF_AIR_BETA_DIAGNOSTIC
        guard betaAllowsSessionChange() else { return }
#endif
        cancelCountdown()
        inputRouter?.stop(reason:"source_changed"); interactionArmed = false
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
#if ODF_AIR_BETA_DIAGNOSTIC
            guard self.betaAllowsSessionChange() else { return }
#endif
            self.fileURL = url
            self.fileApplied = nil
            self.profile.sourceKind = "file"
            self.sourceKindControl.selectedSegment = 2
            self.profile.sourceTitle = url.lastPathComponent
            self.activeSourceKind = "file"
            self.activeSourceBundle = ""
            self.capture.stop()
            (NSApp.delegate as? AppDelegate)?.openPlayerFileFromWorkbench(url)
            self.showSourceTitle(url.lastPathComponent)
            self.applyModeVisibility()
            self.showPage(0)
            self.refreshActions()
            self.persist()
            self.refreshPlanLabel()
        }
    }

    @objc private func refreshShareable() {
        capture.refreshShareable { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(content):
                    let bundle = Bundle.main.bundleIdentifier
                    self.ownCaptureApplications = content.applications.filter { $0.bundleIdentifier == bundle }
                    self.shareableWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier != bundle }.map {
                        SCWindowBox(title: $0.title ?? $0.owningApplication?.applicationName ?? EnhancementText.t("Window", "窗口"),
                                    bundle: $0.owningApplication?.bundleIdentifier ?? "",
                                    window: $0)
                    }
                    self.shareableDisplays = content.displays.map {
                        SCDisplayBox(title: EnhancementText.t("Display \($0.displayID)", "显示器 \($0.displayID)"), display: $0)
                    }
                    self.rebuildShareList()
                case let .failure(error):
                    self.statusLabel.stringValue = error.localizedDescription
                    self.statusLabel.textColor = .systemRed
                }
        }
    }

    private func rebuildShareList() {
        shareStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in shareableWindows {
            let button = NSButton(title: item.title, target: self, action: #selector(pickShareable(_:)))
            button.bezelStyle = .recessed
            button.identifier = NSUserInterfaceItemIdentifier("window")
            button.toolTip = item.bundle
            shareStack.addArrangedSubview(button)
        }
        for item in shareableDisplays {
            let button = NSButton(title: item.title, target: self, action: #selector(pickShareable(_:)))
            button.bezelStyle = .recessed
            button.identifier = NSUserInterfaceItemIdentifier("display")
            shareStack.addArrangedSubview(button)
        }
    }

    @objc private func pickShareable(_ sender: NSButton) {
#if ODF_AIR_BETA_DIAGNOSTIC
        guard betaAllowsSessionChange() else { return }
#endif
        cancelCountdown()
        if sender.identifier?.rawValue == "display",
           let box = shareableDisplays.first(where: { $0.title == sender.title }),
           let display = box.display as? SCDisplay {
            capture.start(filter: SCContentFilter(display: display, excludingApplications: ownCaptureApplications, exceptingWindows: []))
            profile.sourceKind = "display"
            profile.sourceTitle = box.title
        } else if let box = shareableWindows.first(where: { $0.title == sender.title }),
                  let window = box.window as? SCWindow {
            capture.start(filter: SCContentFilter(desktopIndependentWindow: window))
            profile.sourceKind = "window"
            profile.sourceTitle = box.title
            profile.sourceBundleIdentifier = box.bundle
        }
        showSourceTitle(profile.sourceTitle)
        showPage(0)
        persist()
    }

    private func rememberRunningSource() {
        guard !activeSourceTitle.isEmpty else { return }
        let recent = RecentEnhancementSource(kind: activeSourceKind, title: activeSourceTitle, bundleIdentifier: activeSourceBundle)
        profile.recents.removeAll { $0 == recent }
        profile.recents.insert(recent, at: 0)
        profile.recents = Array(profile.recents.prefix(8))
        refreshSourceBar()
        reloadRecents()
        persist()
    }

    private func reloadRecents() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for recent in profile.recents {
            let label = NSTextField(labelWithString: recent.title)
            label.textColor = .secondaryLabelColor
            label.toolTip = EnhancementText.t("Choose this source again to resume.", "重新选择此来源即可继续。")
            recentStack.addArrangedSubview(label)
        }
    }

    @objc private func start() {
#if ODF_AIR_BETA_DIAGNOSTIC
        guard betaAllowsSessionChange() else { return }
#endif
        if delayedWindowSelection || startImmediatelyAfterPreparation {
            cancelCountdown()
            statusLabel.stringValue = EnhancementText.t("Cancelled", "已取消")
            statusLabel.textColor = .labelColor
            return
        }
        if profile.sourceKind == "window" {
            beginDelayedWindowSelection()
        } else {
            startSelectedSource()
        }
    }

    private func hideScreenCountdown() {
        for panel in screenCountdownPanels { panel.close() }
        screenCountdownPanels.removeAll()
        screenCountdownLabels.removeAll()
    }

    private func showScreenCountdown() {
        hideScreenCountdown()
        for screen in NSScreen.screens {
            let panel = overlayPanel()
            panel.level = .screenSaver
            panel.backgroundColor = NSColor.black.withAlphaComponent(0.12)
            panel.isOpaque = false
            panel.sharingType = .none
            panel.setFrame(screen.frame, display: false)
            let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let digit = NSTextField(labelWithString: "\(countdown.remaining)")
            digit.font = .monospacedDigitSystemFont(ofSize: 96, weight: .semibold)
            digit.textColor = .white
            digit.alignment = .center
            digit.wantsLayer = true
            digit.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
            digit.layer?.cornerRadius = 16
            digit.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(digit)
            NSLayoutConstraint.activate([
                digit.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                digit.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                digit.widthAnchor.constraint(equalToConstant: 160),
                digit.heightAnchor.constraint(equalToConstant: 132),
            ])
            panel.contentView = host
            screenCountdownPanels.append(panel)
            screenCountdownLabels.append(digit)
            panel.orderFrontRegardless()
        }
    }

    private func beginDelayedWindowSelection() {
        guard !countdown.active && !filePreparing else { return }
        stop()
        readControls()
        let seconds = EnhancementDelayPreference.seconds(in: .standard)
        guard let ticket = countdown.begin(seconds: seconds) else { return }
        delayedWindowSelection = true
        statusLabel.stringValue = String(format: EnhancementText.t("Switch to the window to enhance. It will be selected in %d seconds.", "请切到要增强的窗口，%d 秒后自动选定并增强。"), seconds)
        statusLabel.textColor = .secondaryLabelColor
        showScreenCountdown()
        updateCountdownDisplay()
        recordPlanEvent("focused_window_countdown_started", extra: ["delaySeconds": seconds])
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.delayedWindowSelection,
                      let remaining = self.countdown.tick(ticket) else { return }
                self.updateCountdownDisplay()
                if remaining == 0 {
                    self.countdownTimer?.invalidate(); self.countdownTimer = nil
                    // Freeze identity at zero, before the asynchronous shareable-content lookup.
                    let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                    let focusedBounds = frontPID.flatMap { TargetOverlayPolicy.focusedWindowBounds(pid: $0) }
                    let target = TargetOverlayPolicy.focusedWindow(windows, frontPID: frontPID, ownPID: ProcessInfo.processInfo.processIdentifier, focusedBounds: focusedBounds)
                    self.hideScreenCountdown()
                    self.selectFocusedWindow(target, ticket: ticket)
                }
            }
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func failDelayedSelection(_ message: String) {
        cancelCountdown()
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
    }

    private func selectFocusedWindow(_ target: TargetOverlayPolicy.WindowMetadata?, ticket: UInt64) {
        guard let target else {
            failDelayedSelection(EnhancementText.t("No active app window. Try again and switch to the window to enhance.", "未找到聚焦的应用窗口，请重试并切到要增强的窗口。"))
            return
        }
        statusLabel.stringValue = EnhancementText.t("Preparing the active window…", "正在准备聚焦窗口…")
        capture.refreshShareable { [weak self] result in
            guard let self, self.delayedWindowSelection, self.countdown.token == ticket else { return }
            switch result {
            case .failure(let error):
                self.failDelayedSelection(EnhancementText.t("Cannot capture the active window. Check Screen Recording permission: ", "无法采集聚焦窗口，请检查屏幕录制权限：") + error.localizedDescription)
            case .success(let content):
                guard let window = content.windows.first(where: { $0.windowID == target.id && $0.owningApplication?.processID == target.owner }) else {
                    self.failDelayedSelection(EnhancementText.t("The active window is no longer available. Try again.", "聚焦窗口已不可用，请重试。"))
                    return
                }
                self.recordPlanEvent("focused_window_selected", extra: ["windowID": target.id, "ownerPID": target.owner])
                self.capture.start(filter: SCContentFilter(desktopIndependentWindow: window))
                let generation = self.capture.currentGeneration
                let started = ProcessInfo.processInfo.systemUptime
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.delayedWindowSelection, self.countdown.token == ticket else { return }
                        guard self.capture.currentGeneration == generation else { self.cancelCountdown(); return }
                        if ProcessInfo.processInfo.systemUptime - started > 10 {
                            self.failDelayedSelection(EnhancementText.t("The active window did not provide a frame. Try again.", "聚焦窗口未提供有效画面，请重试。"))
                            return
                        }
                        guard self.capture.running, self.capture.latestFrameGeometrySnapshot() != nil else { return }
                        self.countdownTimer?.invalidate(); self.countdownTimer = nil
                        self.delayedWindowSelection = false
                        self.startSelectedSource(immediate: true)
                    }
                }
                self.countdownTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func startSelectedSource(immediate: Bool = false) {
        guard !countdown.active && !filePreparing else { return }
        refreshActions()
        readControls()
        let selectedFile = selectedFilePlayer()?.openMediaPath
        if profile.sourceKind == "file" {
            guard selectedFile != nil else { chooseFile(); return }
        } else {
            guard !activeSourceTitle.isEmpty, activeSourceKind == profile.sourceKind else { chooseCurrentKind(); return }
            guard let target = capture.target else {
                statusLabel.stringValue = EnhancementText.t("This source does not provide a window or display identity; choose it again.", "无法确定目标窗口或显示器，请重新选择来源。")
                statusLabel.textColor = .systemRed
                return
            }
            let targetState = targetWindowState(target)
            guard targetState.exists else {
                statusLabel.stringValue = EnhancementText.t("The target has closed; choose it again.", "目标已关闭，请重新选择来源。")
                statusLabel.textColor = .systemRed
                return
            }
            targetOnscreen = targetState.onscreen
            targetWasOnscreen = targetState.onscreen
            if capture.paused {
                statusLabel.stringValue = EnhancementText.t("Resume the source before applying.", "请先继续来源再应用。")
                statusLabel.textColor = .systemRed
                return
            }
            if !capture.running && !capture.restart() { chooseCurrentKind(); return }
        }
        let snapshot = profile
        if snapshot.sourceWindowResizeActive {
            guard [480,720,1080].contains(snapshot.sourceWindowPreset) else {
                statusLabel.stringValue = EnhancementText.t("The source window size is invalid.", "来源窗口尺寸无效。")
                statusLabel.textColor = .systemRed; return
            }
            guard ArtCNNSRSelection.contains(snapshot.scaleEngineID) else {
                statusLabel.stringValue = EnhancementText.t("Choose a supported 2× scaling engine.", "请选择支持 2× 的缩放引擎。")
                statusLabel.textColor = .systemRed; return
            }
            if !SPArtCNNSR.isPackagedForThisSystem() {
                statusLabel.stringValue = EnhancementText.t("The selected 2× engine is unavailable in this build.", "当前安装包没有所选 2× 引擎。")
                statusLabel.textColor = .systemRed; return
            }
            let width = snapshot.sourceWindowPreset == 480 ? 854 : (snapshot.sourceWindowPreset == 720 ? 1280 : 1920)
            if (snapshot.outputWidth != width*2 || snapshot.outputHeight != snapshot.sourceWindowPreset*2) && !(snapshot.outputWidth == 0 && snapshot.outputHeight == 0) {
                statusLabel.stringValue = EnhancementText.t("Choose the matching 2× output size.", "请选择与来源窗口匹配的 2× 输出尺寸。")
                statusLabel.textColor = .systemRed; return
            }
        }
        guard let ticket = countdown.begin() else { return }
        startImmediatelyAfterPreparation = immediate
        let selectedKind = profile.sourceKind
        let selectedGeneration = capture.currentGeneration
        countdownSourceGeneration = selectedKind == "file" ? nil : selectedGeneration
        if snapshot.sourceWindowResizeActive {
            guard let target = capture.target else { cancelCountdown(); return }
            prepareSourceWindow(snapshot: snapshot, target: target, generation: selectedGeneration, ticket: ticket, selectedFile: selectedFile)
            return
        }
        beginStartCountdown(snapshot: snapshot, selectedKind: selectedKind, selectedGeneration: selectedGeneration, selectedFile: selectedFile, ticket: ticket)
    }

    private func prepareSourceWindow(snapshot: EnhancementProfile, target: CaptureTarget, generation: UInt64, ticket: UInt64, selectedFile: String?) {
        guard case let .window(id, owner) = target else { cancelCountdown(); return }
        guard capture.running, let frame = capture.latestFrameGeometrySnapshot(),
              let rect = frame.geometry["screenRect"] as? [CGFloat], rect.count == 4,
              let scale = frame.geometry["scaleFactor"] as? Double else {
            sourceWindowPreparing = true; updateCountdownDisplay()
            statusLabel.stringValue = EnhancementText.t("Waiting for the source window…", "正在等待来源窗口画面…")
            statusLabel.textColor = .secondaryLabelColor
            let started = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.countdown.active, self.countdown.token == ticket else { return }
                    guard self.capture.currentGeneration == generation, self.capture.target == target else { self.cancelCountdown(); return }
                    if ProcessInfo.processInfo.systemUptime-started > 10 {
                        self.recordPlanEvent("source_window_resize_failed", extra: ["ticket":ticket, "generation":generation, "windowID":id, "reason":"source_frame_timeout"])
                        self.cancelCountdown(); self.statusLabel.stringValue = EnhancementText.t("Source window did not provide a valid frame.", "来源窗口未提供有效画面。")
                        self.statusLabel.textColor = .systemRed; return
                    }
                    guard self.capture.running, let frame = self.capture.latestFrameGeometrySnapshot(),
                          let rect = frame.geometry["screenRect"] as? [CGFloat], rect.count == 4,
                          frame.geometry["scaleFactor"] is Double else { return }
                    self.countdownTimer?.invalidate(); self.countdownTimer = nil
                    self.prepareSourceWindow(snapshot: snapshot, target: target, generation: generation, ticket: ticket, selectedFile: selectedFile)
                }
            }
            countdownTimer = timer; RunLoop.main.add(timer, forMode: .common); return
        }
        let bounds = targetWindowState(target).observedWindowBounds
        let displays = NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return CGDisplayBounds(id)
        }
        let displayBounds = displays.max { a,b in
            let x=a.intersection(bounds), y=b.intersection(bounds)
            return (x.isNull ? 0 : x.width*x.height) < (y.isNull ? 0 : y.width*y.height)
        } ?? .null
        guard !displayBounds.isNull, displayBounds.intersects(bounds) else {
            cancelCountdown(); statusLabel.stringValue = EnhancementText.t("The selected window is not on an identifiable display.", "无法确定所选窗口所在的显示器。")
            statusLabel.textColor = .systemRed; return
        }
        let screenRect = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
        let width = snapshot.sourceWindowPreset == 480 ? 854 : (snapshot.sourceWindowPreset == 720 ? 1280 : 1920)
        let desired = CGSize(width: width, height: snapshot.sourceWindowPreset)
        sourceWindowPreparing = true; updateCountdownDisplay()
        recordPlanEvent("source_window_resize_requested", extra: ["ticket":ticket, "generation":generation, "windowID":id, "pid":owner, "sourceWidth":width, "sourceHeight":snapshot.sourceWindowPreset, "beforeCaptureHost":frame.host, "scaleFactor":scale])
        statusLabel.stringValue = EnhancementText.t("Preparing the selected source window…", "正在准备所选来源窗口…")
        statusLabel.textColor = .secondaryLabelColor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let selected = SourceWindowResize.find(pid: owner, windowID: id)
            DispatchQueue.main.async {
                guard let self, self.countdown.active, self.countdown.token == ticket,
                      self.capture.currentGeneration == generation, self.capture.target == target else { return }
                let result: Result<Void, SourceWindowResize.Failure>
                switch selected {
                case .success(let selected):
                    result = SourceWindowResize.setSize(selected, target: desired, screenRect: screenRect, scale: scale, expectedBounds: bounds, displayBounds: displayBounds)
                    if case .success = result { self.sourceWindowConfirmedSelection = selected }
                case .failure(let failure): result = .failure(failure)
                }
                if case .failure(let failure) = result {
                    self.recordPlanEvent("source_window_resize_failed", extra: ["ticket":ticket, "generation":generation, "windowID":id, "reason":String(describing:failure)])
                    self.cancelCountdown()
                    switch failure {
                    case .denied: self.statusLabel.stringValue = EnhancementText.t("Accessibility permission is required to resize the selected window.", "调整来源窗口需要辅助功能权限。")
                    case .unavailable: self.statusLabel.stringValue = EnhancementText.t("Exact window identification is unavailable on this system or build.", "当前系统或版本无法精确识别来源窗口。")
                    case .windowMissing, .ambiguous: self.statusLabel.stringValue = EnhancementText.t("The selected window could not be identified exactly; choose it again.", "无法精确匹配所选窗口，请重新选择。")
                    case .notResizable: self.statusLabel.stringValue = EnhancementText.t("The selected window does not allow resizing.", "所选窗口不允许调整大小。")
                    case .geometry: self.statusLabel.stringValue = EnhancementText.t("The selected window's capture geometry is not ready for resizing.", "所选窗口的采集几何信息不满足调整条件。")
                    case .failed: self.statusLabel.stringValue = EnhancementText.t("The size or position change did not complete; the source window may already have moved or resized.", "尺寸或位置调整未完成；来源窗口可能已经移动或改变大小。")
                    }
                    self.statusLabel.textColor = .systemRed; return
                }
                let after = mach_absolute_time(), started = ProcessInfo.processInfo.systemUptime
                self.recordPlanEvent("source_window_resize_set", extra: ["ticket":ticket, "generation":generation, "windowID":id, "afterHost":after])
                self.sourceWindowConfirmedAfter = after; self.sourceWindowConfirmedStarted = started; self.sourceWindowConfirmedTarget = target
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.countdown.active, self.countdown.token == ticket else { return }
                        guard self.capture.currentGeneration == generation, self.capture.target == target else { self.cancelCountdown(); return }
                        if ProcessInfo.processInfo.systemUptime - started > 10 {
                            self.recordPlanEvent("source_window_resize_failed", extra: ["ticket":ticket, "generation":generation, "windowID":id, "reason":"capture_size_timeout"])
                            self.cancelCountdown(); self.statusLabel.stringValue = EnhancementText.t("The window did not produce the requested capture size; enhancement was not started.", "窗口未产生指定的采集尺寸，增强未启动。")
                            self.statusLabel.textColor = .systemRed; return
                        }
                        guard self.sourceWindowFrameMatches(snapshot: snapshot, target: target, generation: generation, after: after, started: started),
                              let newFrame = self.capture.latestFrameGeometrySnapshot() else { return }
                        self.countdownTimer?.invalidate(); self.countdownTimer = nil
                        self.recordPlanEvent("source_window_size_confirmed", extra: ["ticket":ticket, "generation":generation, "sourceWidth": width, "sourceHeight": snapshot.sourceWindowPreset, "captureHost": newFrame.host, "windowID": id, "geometry":newFrame.geometry])
                        self.beginStartCountdown(snapshot: snapshot, selectedKind: "window", selectedGeneration: generation, selectedFile: selectedFile, ticket: ticket)
                    }
                }
                self.countdownTimer = timer; RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    private func sourceWindowFrameMatches(snapshot: EnhancementProfile, target: CaptureTarget, generation: UInt64, after: UInt64, started: TimeInterval) -> Bool {
        guard case let .window(id, owner) = target, capture.currentGeneration == generation, capture.target == target,
              let selected = sourceWindowConfirmedSelection,
              let frame = capture.latestFrameGeometrySnapshot() else { return false }
        let g = frame.geometry
        let width = snapshot.sourceWindowPreset == 480 ? 854 : (snapshot.sourceWindowPreset == 720 ? 1280 : 1920)
        guard let frameGeneration = g["generation"] as? UInt64, let frameWindow = g["windowID"] as? UInt32,
              SourceWindowSizePolicy.freshFrame(host: frame.host, after: after, frameGeneration: frameGeneration,
                  currentGeneration: generation, frameWindow: frameWindow, targetWindow: id),
              (g["pid"] as? Int32) == owner, (g["bufferWidth"] as? Int) == width,
              (g["bufferHeight"] as? Int) == snapshot.sourceWindowPreset,
              let content = g["contentRect"] as? [CGFloat], content.count == 4,
              let screen = g["screenRect"] as? [CGFloat], screen.count == 4,
              let factor = g["scaleFactor"] as? Double, let contentScale = g["contentScale"] as? Double,
              factor.isFinite, contentScale.isFinite, abs(contentScale - 1) <= 0.002,
              abs(content[0]) <= 0.01, abs(content[1]) <= 0.01,
              abs(content[2]*factor-Double(width)) <= 1, abs(content[3]*factor-Double(snapshot.sourceWindowPreset)) <= 1,
              (lastStats["sourceWidth"] as? Int) == width, (lastStats["sourceHeight"] as? Int) == snapshot.sourceWindowPreset,
              (lastStats["sourceGeneration"] as? UInt64) == generation, lastStatsReceipt >= started else { return false }
        let cgBounds = targetWindowState(target).observedWindowBounds
        let captured = CGRect(x:screen[0],y:screen[1],width:screen[2],height:screen[3])
        return SourceWindowResize.verify(selected, captureRect: captured, scale: factor,
            target: CGSize(width: width, height: snapshot.sourceWindowPreset), cgBounds: cgBounds)
    }

    private func beginStartCountdown(snapshot: EnhancementProfile, selectedKind: String, selectedGeneration: UInt64, selectedFile: String?, ticket: UInt64) {
        sourceWindowPreparing = false
        if startImmediatelyAfterPreparation {
            startImmediatelyAfterPreparation = false
            countdown.cancel()
            countdownSourceGeneration = nil
            updateCountdownDisplay()
            sourceWindowConfirmedTarget = nil; sourceWindowConfirmedSelection = nil
            applyAfterCountdown(snapshot: snapshot)
            return
        }
        recordPlanEvent("countdown_started", extra: ["selectedEngine": snapshot.interpolationEngineID, "selectedModel": snapshot.modelID])
        statusLabel.stringValue = selectedKind == "file"
            ? EnhancementText.t("Starting in 3 seconds.", "3 秒后开始。")
            : EnhancementText.t("Starting in 3 seconds. Switch to the source window now.", "3 秒后开始，请切到来源窗口。")
        statusLabel.textColor = .secondaryLabelColor
        updateCountdownDisplay()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.countdown.active, self.countdown.token == ticket else { return }
                guard self.profile.sourceKind == selectedKind,
                      selectedKind == "file" || self.capture.currentGeneration == selectedGeneration else { self.cancelCountdown(); return }
                if selectedKind == "file" {
                    let currentFile = self.selectedFilePlayer()?.openMediaPath
                    guard currentFile == selectedFile else { self.cancelCountdown(); return }
                }
                guard let remaining = self.countdown.tick(ticket) else { return }
                self.updateCountdownDisplay()
                if remaining == 0 {
                    self.countdownTimer?.invalidate(); self.countdownTimer = nil; self.countdownSourceGeneration = nil
                    if selectedKind != "file" && !self.capture.running {
                        self.statusLabel.stringValue = EnhancementText.t("Source is not ready; choose it again.", "来源尚未就绪，请重新选择。")
                        self.statusLabel.textColor = .systemRed
                        return
                    }
                    if snapshot.sourceWindowResizeActive {
                        guard let target = self.sourceWindowConfirmedTarget,
                              self.sourceWindowFrameMatches(snapshot: snapshot, target: target, generation: selectedGeneration,
                                  after: self.sourceWindowConfirmedAfter, started: self.sourceWindowConfirmedStarted) else {
                            self.recordPlanEvent("source_window_resize_failed", extra: ["ticket":ticket, "generation":selectedGeneration, "reason":"size_changed_before_apply"])
                            self.sourceWindowConfirmedTarget = nil; self.sourceWindowConfirmedSelection = nil
                            self.statusLabel.stringValue = EnhancementText.t("The source window size changed before enhancement started.", "增强开始前来源窗口尺寸已改变，请重试。")
                            self.statusLabel.textColor = .systemRed; return
                        }
                    }
                    self.sourceWindowConfirmedTarget = nil; self.sourceWindowConfirmedSelection = nil
                    self.applyAfterCountdown(snapshot: snapshot)
                }
            }
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }


    private func applyAfterCountdown(snapshot: EnhancementProfile) {
        if snapshot.sourceKind == "file" {
            applyFileRequest()
            return
        }
        // Queue the selected generation before the explicit plan request. The
        // picker/source callback may arrive on main after this action returns.
        processor.adoptSourceGeneration(capture.currentGeneration)
        placeOutput()
        pendingApply = snapshot
        liveApplyFailure = ""
        pendingSourceGeneration = capture.currentGeneration
        let request = planRequest(snapshot)
        let requestID = liveApply.begin()
        request.requestID = requestID
#if ODF_AIR_BETA_DIAGNOSTIC
        armBetaSessionIfNeeded()
#endif
        recordPlanEvent("submit", extra: ["requestID": requestID, "submittedEngine": request.engineID,
            "submittedModel": request.modelID, "submittedRateKind": request.rateKind == .multiplier ? "multiplier" : "fixedFPS",
            "submittedMultiplier": request.multiplier, "submittedScaleEnabled": request.scaleEnabled,
            "submittedInterpolationEnabled": request.interpolationEnabled,
            "requiredSourceWidth": request.requiredSourceWidth, "requiredSourceHeight": request.requiredSourceHeight,
            "requiredSourceWindowID": request.requiredSourceWindowID, "requiredSourcePID": request.requiredSourcePID,
            "requiredSourceAfterHost": request.requiredSourceAfterHost])
        processor.update(request)
        persist()
        refreshPlanLabel()
    }

    @objc private func apply() { start() }

    @objc private func stop() {
#if ODF_AIR_BETA_DIAGNOSTIC
        if Self.betaSessionRecordingEnabled { finishBetaSession(reason: "stop") {}; return }
#endif
        stopImmediately()
    }

    private func stopImmediately(stopPipeline: Bool = true) {
        recordPlanEvent("stop")
        inputRouter?.stop(reason:"stopped")
        interactionArmed = false
        r7Health.reset()
        r7LastHealthAt = 0
        r7Visibility = ""
        cancelCountdown()
        if profile.sourceKind == "file" {
            applyingFileSettings = true
            fileOutputToken &+= 1
            selectedFilePlayer()?.workbenchCancelFileOutput()
            _ = selectedFilePlayer()?.workbenchCommitFilePlan(interpolation: false, rife: false, cadence: 2, numerator: 0, denominator: 1, scaler: false)
            applyingFileSettings = false
            fileApplied = nil
            statsLabel.stringValue = ""
            budgetLabel.stringValue = ""
            statusLabel.stringValue = EnhancementText.t("Stopped", "已停止")
            statusLabel.textColor = .labelColor
            refreshActions()
            refreshPlanLabel()
            return
        }
        if stopPipeline { capture.stop() }
        viewerActive = false; viewerFollowOverride = false; viewerReturnPID = nil
        viewerControlsPanel?.orderOut(nil)
        (outputWindow as? TargetPanel)?.viewerKeyboard = false
        liveApply.cancel(); pendingApply = nil; pendingSourceGeneration = nil
        capture.paused = false
        outputWarmupToken &+= 1
        outputMinimumCaptureHost = 0
        outputWindow?.orderOut(nil)
        targetHUD?.orderOut(nil)
        targetCountdownHUD?.orderOut(nil)
        outputPreview.refreshVisibilitySnapshot()
        if stopPipeline { processor.stop() }
        lastStats = [:]
        lastStatsReceipt = 0
        updateFPSOverlay()
        statusLabel.stringValue = EnhancementText.t("Stopped", "已停止")
        statusLabel.textColor = .labelColor
        statsLabel.stringValue = ""
        budgetLabel.stringValue = ""
        refreshActions()
        refreshPlanLabel()
    }

    @objc private func showLibrary() { showPage(2) }

    @objc private func viewModeChanged() {
        cancelCountdown()
        inputRouter?.stop(reason:"view_changed")
        interactionArmed = false
        fileApplyError = ""
        readControls()
        if profile.sourceKind == "file" {
            selectedFilePlayer()?.workbenchSetFileViewMode(profile.viewMode)
            persist(); refreshPlanLabel()
            statusLabel.stringValue = EnhancementText.t("Preview mode changed", "预览模式已切换")
            statusLabel.textColor = .labelColor
            return
        }
        let mode: SPLiveViewMode
        switch profile.viewMode {
        case "original": mode = .original
        case "compare": mode = .compare
        default: mode = .enhanced
        }
        processor.setViewMode(mode)
        persist()
        refreshPlanLabel()
        statusLabel.stringValue = EnhancementText.t("Preview mode changed", "预览模式已切换")
        statusLabel.textColor = .labelColor
    }

    @objc private func engineChanged() {
        readEngineSelection()
        reloadQualityItems()
        controlChanged()
        recordPlanEvent("engine_selected")
    }

    @objc private func controlChanged() {
        cancelCountdown()
        inputRouter?.stop(reason:"configuration_changed"); interactionArmed = false
        fileApplyError = ""
        if rateMode.selectedSegment == 1 && multiplierControl.selectedSegment < 0 {
            multiplierControl.selectedSegment = 0
        }
        let selectedEngine = scalePopup.indexOfSelectedItem
        let chosenWindowPreset = [0,480,720,1080][max(0,min(3,sourceWindowPopup.indexOfSelectedItem))]
        let windowPresetChanged = sourceKindControl.selectedSegment == 0 && chosenWindowPreset != profile.sourceWindowPreset
        let windowResizeSelected = sourceKindControl.selectedSegment == 0 && scaleSwitch.state == .on && chosenWindowPreset > 0
        if windowResizeSelected && windowPresetChanged && ArtCNNSRSelection.ids.indices.contains(selectedEngine) {
            let w = chosenWindowPreset == 480 ? 854 : (chosenWindowPreset == 720 ? 1280 : 1920)
            selectOutputSize(w*2, chosenWindowPreset*2)
        }
        let wasLanczos = !ArtCNNSRSelection.contains(profile.scaleEngineID)
        if wasLanczos { srInputPopup.selectItem(at: [0,480,720,1080].firstIndex(of: profile.srInputPreset == 0 ? 1080 : profile.srInputPreset) ?? 3) }
        let engineID = ArtCNNSRSelection.fromPopup(selectedEngine)
        let scaleJustEnabled = scaleSwitch.state == .on && !profile.scaleEnabled
        sizePopup.item(at: 5)?.isEnabled = true
        sizePopup.item(at: 0)?.isEnabled = false
        if engineID != profile.scaleEngineID || scaleJustEnabled { sizePopup.selectItem(at: 5) }
        readControls()
        updateSRCapability()
        applyModeVisibility()
        let mode: SPLiveViewMode
        switch profile.viewMode {
        case "original": mode = .original
        case "compare": mode = .compare
        default: mode = .enhanced
        }
        processor.setViewMode(mode)
        persist()
        refreshPlanLabel()
        if capture.running { statusLabel.stringValue = EnhancementText.t("Pending", "待应用") }
    }

    private func applyModeVisibility() {
        srInputRow?.isHidden = profile.sourceKind == "window"
        sourceWindowRow?.isHidden = profile.sourceKind != "window"
        sourceWindowPopup.isEnabled = profile.sourceKind == "window" && profile.scaleEnabled
        sourceWindowHint.isHidden = profile.sourceKind != "window" || (profile.scaleEnabled && profile.sourceWindowPreset == 0)
        sourceWindowHint.stringValue = profile.scaleEnabled
            ? EnhancementText.t("Use a dedicated or picture-in-picture video window; the video must fill the captured window.", "请使用独立或画中画视频窗口；视频须铺满采集画面。")
            : EnhancementText.t("Scaling is off; the saved window size is not applied.", "缩放已关闭；已保存的窗口尺寸不会应用。")
        srInputPopup.isEnabled = profile.sourceKind != "file"
        let help = profile.sourceKind == "file"
            ? EnhancementText.t("Video files use decoded pixels; this control applies to live capture.", "视频文件使用解码后的原始像素；此选项适用于实时采集。")
            : EnhancementText.t("This reduces the captured image before scaling; it does not identify the source video resolution. Lower input may trade quality for speed and does not guarantee a sharper image.", "此选项会先缩小采集画面，再进行缩放；它不代表自动识别到了片源分辨率。较低输入尺寸可能以画质换速度，不保证画面更清晰。")
        srInputHelp.toolTip = help
        srInputPopup.toolTip = help
        fullscreenCheck.title = profile.sourceKind == "file"
            ? EnhancementText.t("Fullscreen on output display", "在输出显示器全屏")
            : EnhancementText.t("Fullscreen (Esc to return)", "全屏预览（Esc 返回交互）")
        fullscreenCheck.toolTip = profile.sourceKind == "file" ? nil
            : EnhancementText.t("Fullscreen viewer (Esc to return to interaction)", "全屏预览（Esc 返回交互）")
        fullscreenCheck.isHidden = profile.sourceKind == "window"
        fullscreenCheck.isEnabled = profile.sourceKind != "window"
        fullscreenCheck.state = profile.outputFullscreen ? .on : .off
        let editable = WorkbenchDimensionPolicy.editable(sizeIndex: sizePopup.indexOfSelectedItem, scaleEnabled: scaleSwitch.state == .on)
        for (field, value) in [(widthField, profile.outputWidth), (heightField, profile.outputHeight)] {
            if field.isEditable != editable { field.isEditable = editable }
            if field.isSelectable != editable { field.isSelectable = editable }
            if field.currentEditor() == nil { field.stringValue = WorkbenchDimensionPolicy.text(value) }
        }
        sizePopup.item(at: 0)?.title = EnhancementText.t("2× source (model native)", "2×来源（模型原生）")
        sizePopup.item(at: 5)?.title = EnhancementText.t("2× source (model native)", "2×来源（模型原生）")
        scaleQualityRow?.isHidden = true
        let targetRate = rateMode.selectedSegment == 0
        fpsPopup.isHidden = !targetRate
        customRateRow?.isHidden = !targetRate || fpsPopup.indexOfSelectedItem != 7
        multiplierControl.isHidden = targetRate
        if profile.interpolationEngineID == "apple.lowlatency" {
            phaseLabel.stringValue = lowLatencyPhaseText()
        }
        scaleBody?.isHidden = scaleSwitch.state != .on
        framesBody?.isHidden = interpolationSwitch.state != .on
        refreshFormLabels()
    }

    @objc private func pendingTextChanged(_ notification: Notification) {
        guard (countdown.active || delayedWindowSelection || filePreparing), let field = notification.object as? NSTextField,
              [widthField, heightField, fpsNum, fpsDen].contains(where: { $0 === field }) else { return }
        cancelCountdown()
    }

    @objc private func openProjectLink(_ sender: Any) {
        guard let key = (sender as? NSUserInterfaceItemIdentification)?.identifier?.rawValue,
              let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              var components = URLComponents(string: value), components.scheme == "https" else { return }
        if key == "ODFFeedbackURL" {
            var context = URLComponents()
            context.queryItems = [
                URLQueryItem(name: "version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String),
                URLQueryItem(name: "system", value: ProcessInfo.processInfo.operatingSystemVersionString),
                URLQueryItem(name: "lang", value: EnhancementText.chinese ? "zh" : "en"),
            ]
            components.percentEncodedFragment = context.percentEncodedQuery
        }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                                 styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let content = NSView()
            for control in [enhancementDelayControl, languageControl, appearanceControl] {
                control.segmentDistribution = .fillEqually
                control.segmentStyle = .rounded
                control.selectedSegmentBezelColor = .controlAccentColor
                control.heightAnchor.constraint(equalToConstant: 28).isActive = true
            }
            enhancementDelayControl.target = self
            enhancementDelayControl.action = #selector(enhancementDelayChanged)
            enhancementDelayControl.setAccessibilityLabel(EnhancementText.t("Countdown", "倒计时时间"))
            enhancementDelayField.alignment = .right
            enhancementDelayField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            enhancementDelayField.widthAnchor.constraint(equalToConstant: 48).isActive = true
            enhancementDelayField.delegate = self
            enhancementDelayStepper.minValue = 1
            enhancementDelayStepper.maxValue = 20
            enhancementDelayStepper.increment = 1
            enhancementDelayStepper.target = self
            enhancementDelayStepper.action = #selector(enhancementDelayStepped)
            let customLabel = NSTextField(labelWithString: EnhancementText.t("Seconds (1–20)", "秒数（1–20）"))
            customLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            enhancementDelayCustomRow.orientation = .horizontal
            enhancementDelayCustomRow.alignment = .centerY
            enhancementDelayCustomRow.spacing = 8
            for view in [customLabel, enhancementDelayField, enhancementDelayStepper] {
                enhancementDelayCustomRow.addArrangedSubview(view)
            }
            let delayBody = column([enhancementDelayControl, enhancementDelayCustomRow])
            languageDetail.font = WorkbenchStyle.captionFont
            languageDetail.textColor = .secondaryLabelColor
            let languageBody = column([languageControl, languageDetail])
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let about = NSTextField(labelWithString: "OpenDuckFrame " + version)
            let links = NSStackView()
            links.orientation = .horizontal
            links.spacing = 8
            for (title, key) in [(EnhancementText.t("Website", "官网"), "ODFWebsiteURL"),
                                 ("GitHub", "ODFRepositoryURL"),
                                 (EnhancementText.t("Feedback", "反馈"), "ODFFeedbackURL")] {
                let link = button(title, #selector(openProjectLink(_:)))
                link.identifier = NSUserInterfaceItemIdentifier(key)
                links.addArrangedSubview(link)
            }
            let grid = NSGridView(views: [
                [NSTextField(labelWithString: EnhancementText.t("Appearance", "外观")), appearanceControl],
                [NSTextField(labelWithString: EnhancementText.t("Language", "语言")), languageBody],
                [NSTextField(labelWithString: EnhancementText.t("Countdown", "倒计时时间")), delayBody],
                [NSTextField(labelWithString: EnhancementText.t("About", "关于")), about],
                [NSGridCell.emptyContentView, links],
            ])
            grid.rowSpacing = 12
            grid.columnSpacing = 12
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .fill
            grid.yPlacement = .top
            let stack = column([grid])
            stack.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            ])
            panel.contentView = content
            settingsStack = stack
            settingsWindow = panel
        }
        settingsWindow?.title = EnhancementText.t("Settings", "设置")
        settingsWindow?.appearance = window?.appearance
        refreshSettingsLanguage()
        let seconds = EnhancementDelayPreference.seconds(in: .standard)
        enhancementDelayCustomSelected = !EnhancementDelayPreference.presets.contains(seconds)
        refreshEnhancementDelayControls()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func fitSettingsWindow() {
        guard let panel = settingsWindow, let stack = settingsStack else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height) + 44
        var frame = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 440, height: height))
        frame.origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    private func refreshEnhancementDelayControls() {
        let seconds = EnhancementDelayPreference.seconds(in: .standard)
        enhancementDelayControl.selectedSegment = enhancementDelayCustomSelected ? 3 : (EnhancementDelayPreference.presets.firstIndex(of: seconds) ?? 3)
        enhancementDelayField.stringValue = String(seconds)
        enhancementDelayStepper.integerValue = seconds
        enhancementDelayCustomRow.isHidden = !enhancementDelayCustomSelected
        fitSettingsWindow()
    }

    private func saveEnhancementDelay(_ seconds: Int) {
        cancelCountdown()
        EnhancementDelayPreference.set(seconds, in: .standard)
        refreshEnhancementDelayControls()
    }

    @objc private func enhancementDelayChanged() {
        let index = enhancementDelayControl.selectedSegment
        settingsWindow?.makeFirstResponder(nil)
        enhancementDelayCustomSelected = index == 3
        if enhancementDelayCustomSelected {
            refreshEnhancementDelayControls()
            settingsWindow?.makeFirstResponder(enhancementDelayField)
            enhancementDelayField.selectText(nil)
        } else if EnhancementDelayPreference.presets.indices.contains(index) {
            saveEnhancementDelay(EnhancementDelayPreference.presets[index])
        }
    }

    @objc private func enhancementDelayStepped() {
        saveEnhancementDelay(enhancementDelayStepper.integerValue)
    }

    private func refreshSettingsLanguage() {
        let code = AppLanguage.current
        for (index, seconds) in EnhancementDelayPreference.presets.enumerated() {
            enhancementDelayControl.setLabel(EnhancementText.t("\(seconds) s", "\(seconds) 秒"), forSegment: index)
        }
        enhancementDelayControl.setLabel(EnhancementText.t("Custom", "自定义"), forSegment: 3)
        enhancementDelayControl.setAccessibilityLabel(EnhancementText.t("Countdown", "倒计时时间"))
        enhancementDelayField.setAccessibilityLabel(EnhancementText.t("Custom countdown in seconds, 1 to 20", "自定义倒计时秒数，1 到 20"))
        enhancementDelayStepper.setAccessibilityLabel(EnhancementText.t("Adjust countdown", "调整倒计时秒数"))
        languageDetail.isHidden = code == nil || code == "en" || code == "zh-Hans"
        languageControl.setLabel(EnhancementText.t("More…", "更多…"), forSegment: 2)
        languageControl.selectedSegment = code != nil && code != "en" && code != "zh-Hans" ? 2 : (EnhancementText.chinese ? 0 : 1)
        let effective = AppLanguage.effectiveLanguage(for: code) ?? "en"
        let name = AppLanguage.displayName(for: effective)
        languageDetail.stringValue = EnhancementText.chinese
            ? "播放器语言：\(name)。画质工作台支持中文和英文。"
            : "Player language: \(name). The workbench supports Chinese and English."
        fitSettingsWindow()
    }

    @objc private func selectMoreLanguage(_ sender: NSMenuItem) {
        let code = sender.representedObject as? String
        let effective = AppLanguage.effectiveLanguage(for: code) ?? "en"
        EnhancementText.setLanguage(effective.hasPrefix("zh") ? "zh" : "en", in: .standard)
        applyPlayerLanguage(code)
        translateWorkbench()
        refreshSettingsLanguage()
    }

    private func applyPlayerLanguage(_ code: String?) {
        let item = NSMenuItem()
        item.representedObject = code
        (NSApp.delegate as? AppDelegate)?.languageAction(item)
    }

    @objc private func appearanceChanged() {
        cancelCountdown()
        readControls()
        applyAppearance()
        persist()
    }

    @objc private func languageChanged() {
        if languageControl.selectedSegment == 2 {
            let menu = NSMenu()
            let system = NSMenuItem(title: L("settings.language.system"), action: #selector(selectMoreLanguage(_:)), keyEquivalent: "")
            system.target = self
            system.state = AppLanguage.current == nil ? .on : .off
            menu.addItem(system)
            menu.addItem(.separator())
            for code in AppLanguage.supported where code != "en" && code != "zh-Hans" {
                let item = NSMenuItem(title: AppLanguage.displayName(for: code), action: #selector(selectMoreLanguage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = code
                item.state = AppLanguage.current == code ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: languageControl)
            refreshSettingsLanguage()
            return
        }
        let chinese = languageControl.selectedSegment == 0
        EnhancementText.setLanguage(chinese ? "zh" : "en", in: .standard)
        applyPlayerLanguage(chinese ? "zh-Hans" : "en")
        translateWorkbench()
        refreshSettingsLanguage()
    }

    private func translateWorkbench() {
        func translate(_ text: String) -> String {
            EnhancementText.translated(text, chinese: EnhancementText.chinese)
        }
        func visit(_ view: NSView) {
            if view === configPopup || view === configActions || view === recentStack || view === shareStack || view === languageControl { return }
            if let popup = view as? NSPopUpButton {
                if popup !== displayPopup {
                    for item in popup.itemArray { item.title = translate(item.title) }
                }
            } else if let segments = view as? NSSegmentedControl {
                for index in 0..<segments.segmentCount {
                    if let label = segments.label(forSegment: index) { segments.setLabel(translate(label), forSegment: index) }
                }
            } else if let button = view as? NSButton {
                button.title = translate(button.title)
            } else if let field = view as? NSTextField, !field.isEditable,
                      field !== sourceLabel, field !== sourceStripLabel, field !== sourceMetaLabel,
                      field !== diagnosticLabel, field !== planLabel, field !== statsLabel, field !== budgetLabel,
                      field !== fileLimitLabel, field !== statusLabel {
                field.stringValue = field.identifier?.rawValue == "brand-quality"
                    ? (EnhancementText.chinese ? "画质" : "Quality") : translate(field.stringValue)
            }
            for child in view.subviews { visit(child) }
        }
        if let root = window?.contentView { visit(root) }
        if let root = settingsWindow?.contentView { visit(root) }
        settingsWindow?.title = EnhancementText.t("Settings", "设置")
        window?.title = "OpenDuckFrame"
        if let window { installToolbar(on: window) }
        installWorkbenchMenuEntries()
        outputWindow?.title = EnhancementText.t("Enhanced output", "增强输出")
        if let first = displayPopup.item(at: 0) { first.title = EnhancementText.t("Main display", "主显示器") }
        statusLabel.stringValue = EnhancementText.runtime(translate(statusLabel.stringValue))
        rebuildConfigRows()
        reloadQualityItems()
        applyModeVisibility()
        refreshSourceBar()
        refreshActions()
        if !lastStats.isEmpty { updateStatsText(lastStats) }
        refreshPlanLabel()
        experimentComparisonPanel?.refresh()
    }

    @objc private func motionChanged() {
        guard profile.sourceKind == "file" else { return }
        guard !applyingFileSettings else { return }
        guard let player = selectedFilePlayer() else { return }
        if player.workbenchMotionPlusRequested {
            profile.interpolationEnabled = true
            profile.rate = .multiplier(2)
        } else {
            profile.interpolationEnabled = false
        }
        if var active = fileApplied {
            active.interpolationEnabled = player.workbenchMotionPlusRequested
            if active.interpolationEnabled {
                active.rate = .multiplier(2)
            }
            LiveEngineSelection.normalize(&active)
            fileApplied = active
        }
        LiveEngineSelection.normalize(&profile)
        loadControls()
        refreshPlanLabel()
    }

    private func applyFileRequest() {
        LiveEngineSelection.normalize(&profile)
        guard let player = selectedFilePlayer() else {
            fileApplyError = EnhancementText.t("Open a video before applying file settings.", "请先打开视频，再应用文件设置。")
            statusLabel.stringValue = fileApplyError; statusLabel.textColor = .systemRed; return
        }
        guard outputScreen(for: profile.outputDisplayID) != nil else {
            fileApplyError = EnhancementText.t("The selected display is unavailable.", "所选显示器不可用。")
            statusLabel.stringValue = fileApplyError; statusLabel.textColor = .systemRed; return
        }
        guard !profile.scaleEnabled || ArtCNNSRSelection.contains(profile.scaleEngineID) else {
            fileApplyError = EnhancementText.t("This scaler is not connected to file playback yet.", "这个缩放引擎尚未接入文件播放。")
            statusLabel.stringValue = fileApplyError; statusLabel.textColor = .systemRed; return
        }
        guard !profile.interpolationEnabled || ["apple.frc", "rife.metal", "apple.lowlatency", "distildrba.coreml"].contains(profile.interpolationEngineID) else {
            fileApplyError = EnhancementText.t("This interpolation engine is not connected to file playback yet.", "这个插帧引擎尚未接入文件播放。")
            statusLabel.stringValue = fileApplyError; statusLabel.textColor = .systemRed; return
        }
        if profile.interpolationEnabled && profile.interpolationEngineID == "apple.frc" && profile.interpolationQuality != "normal" {
            fileApplyError = EnhancementText.t("File playback currently supports the normal FRC setting.", "文件播放目前支持 Apple 帧率转换的标准档。")
            statusLabel.stringValue = fileApplyError; statusLabel.textColor = .systemRed; return
        }
        let mode: Int, numerator: Int64, denominator: Int64
        if !profile.interpolationEnabled {
            mode = 2; numerator = 0; denominator = 1
        } else {
            switch profile.rate {
            case .multiplier(let value): mode = value; numerator = 0; denominator = 1
            case .fixedFPS(let n, let d):
                guard d > 0, n > 0, player.workbenchSourceFPS > 0, Double(n) / Double(d) <= player.workbenchSourceFPS * 3 + 0.01 else {
                    fileApplyError = EnhancementText.t("For file playback choose a fixed rate up to 3× the source rate.", "文件固定帧率目前最多为来源帧率的 3 倍。")
                    statusLabel.stringValue = fileApplyError; statusLabel.textColor = .systemRed; return
                }
                mode = 1; numerator = n; denominator = d
            }
        }
        if profile.interpolationEnabled && ["apple.lowlatency", "distildrba.coreml"].contains(profile.interpolationEngineID) {
            guard case .multiplier(2) = profile.rate else {
                fileApplyError = EnhancementText.t("This file interpolation engine currently supports X2 midpoint only.", "此文件插帧引擎当前仅支持 X2 中点。")
                statusLabel.stringValue = fileApplyError; statusLabel.textColor = .systemRed; return
            }
        }
        let request = profile, sourcePath = player.openMediaPath
        let useRife = request.interpolationEnabled && request.interpolationEngineID == "rife.metal"
        let useLowLatency = request.interpolationEnabled && request.interpolationEngineID == "apple.lowlatency"
        let useDistil = request.interpolationEnabled && request.interpolationEngineID == "distildrba.coreml"
        fileApplyError = ""
        filePrepareToken &+= 1
        let token = filePrepareToken
        filePreparing = true; filePreparingPlayer = player; refreshActions()
        statusLabel.stringValue = EnhancementText.t("Preparing file enhancement…", "正在准备文件增强…")
        statusLabel.textColor = .labelColor

        func finish(_ ready: Bool, _ message: String) {
            guard self.filePreparing, self.filePrepareToken == token else { return }
            self.filePreparing = false; self.filePreparingPlayer = nil; self.refreshActions()
            guard ready, self.profile == request, self.selectedFilePlayer() === player, player.openMediaPath == sourcePath else {
                player.workbenchCancelFileLanczosPreparation(); player.workbenchCancelFileRifePreparation()
                self.fileApplyError = message.isEmpty ? EnhancementText.t("File settings changed; the previous plan remains.", "文件设置已改变，保留原方案。") : EnhancementText.runtime(message)
                self.statusLabel.stringValue = self.fileApplyError; self.statusLabel.textColor = .systemRed; return
            }
            guard self.outputScreen(for: request.outputDisplayID) != nil else {
                player.workbenchCancelFileLanczosPreparation(); player.workbenchCancelFileRifePreparation()
                self.fileApplyError = EnhancementText.t("The selected display is unavailable; the previous plan remains.", "所选显示器不可用，保留原方案。")
                self.statusLabel.stringValue = self.fileApplyError; self.statusLabel.textColor = .systemRed; return
            }
            self.applyingFileSettings = true
            let committed = player.workbenchCommitFilePlan(interpolation: request.interpolationEnabled, rife: useRife || useLowLatency || useDistil, cadence: mode, numerator: numerator, denominator: denominator, scaler: request.scaleEnabled)
            self.applyingFileSettings = false
            guard committed else {
                player.workbenchCancelFileLanczosPreparation(); player.workbenchCancelFileRifePreparation()
                self.fileApplyError = EnhancementText.t("File enhancement could not be applied; the previous plan remains.", "文件增强未能应用，保留原方案。")
                self.statusLabel.stringValue = self.fileApplyError; self.statusLabel.textColor = .systemRed; return
            }
            var active = request
            active.outputDisplayID = self.fileApplied?.outputDisplayID ?? 0
            active.outputFullscreen = self.fileApplied?.outputFullscreen ?? false
            self.fileApplied = active; self.persist(); self.refreshActions(); self.refreshPlanLabel()
            self.fileOutputToken &+= 1
            let outputToken = self.fileOutputToken
            self.fileOutputPlayer = player
            self.statusLabel.stringValue = EnhancementText.t("Applying display output…", "正在切换输出…")
            self.statusLabel.textColor = .labelColor
            player.workbenchApplyFileOutput(displayID: request.outputDisplayID, fullscreen: request.outputFullscreen) { [weak self, weak player] ok, message in
                guard let self, let player, self.fileOutputToken == outputToken, self.selectedFilePlayer() === player else { return }
                self.fileOutputPlayer = nil
                if ok {
                    self.fileApplied?.outputDisplayID = request.outputDisplayID
                    self.fileApplied?.outputFullscreen = request.outputFullscreen
                    self.fileApplyError = ""; self.statusLabel.stringValue = self.fileStatus(); self.statusLabel.textColor = .labelColor
                } else {
                    self.fileApplyError = EnhancementText.t("Enhancement applied; display output could not be changed: ", "增强已应用，输出切换失败：") + EnhancementText.runtime(message)
                    self.statusLabel.stringValue = self.fileApplyError; self.statusLabel.textColor = .systemOrange
                }
                self.refreshPlanLabel()
            }
        }
        func prepareScaler() {
            guard self.filePreparing, self.filePrepareToken == token else { return }
            guard request.scaleEnabled else { finish(true, ""); return }
            player.workbenchPrepareFileScaler(engine: request.scaleEngineID, variant: request.scaleQualityID, width: request.outputWidth, height: request.outputHeight, completion: finish)
        }
        if useRife {
            player.workbenchPrepareFileRife(modelID: request.modelID, quality: request.interpolationQuality) { ready, message in
                guard self.filePreparing, self.filePrepareToken == token else { return }
                if ready { prepareScaler() } else { finish(false, message) }
            }
        } else if useLowLatency {
            player.workbenchPrepareFileLowLatency { ready, message in
                guard self.filePreparing, self.filePrepareToken == token else { return }
                if ready { prepareScaler() } else { finish(false, message) }
            }
        } else if useDistil {
            player.workbenchPrepareFileDistil { ready, message in
                guard self.filePreparing, self.filePrepareToken == token else { return }
                if ready { prepareScaler() } else { finish(false, message) }
            }
        } else { prepareScaler() }
    }

    private func fileStatus() -> String {
        if !fileApplyError.isEmpty { return fileApplyError }
        if profile.scaleEnabled && !ArtCNNSRSelection.contains(profile.scaleEngineID) { return EnhancementText.t("This scaler is not connected to file playback yet.", "这个缩放引擎尚未接入文件播放。") }
        if profile.interpolationEnabled && !["apple.frc", "rife.metal", "apple.lowlatency", "distildrba.coreml"].contains(profile.interpolationEngineID) {
            return EnhancementText.t("This interpolation engine is not connected to file playback yet; current playback is unchanged.", "这个插帧引擎尚未接入文件播放，当前播放保持不变。")
        }
        let player = selectedFilePlayer()
        if let warning = player?.workbenchFileLanczosStatus, !warning.isEmpty { return EnhancementText.runtime(warning) }
        let active = fileApplied ?? profile
        let interpolationActive = player?.workbenchMotionPlusRequested ?? false
        let mode: String
        let interpolationName = active.interpolationEngineID == "rife.metal" ? "ODF-VFI · \(active.interpolationQuality)" : (active.interpolationEngineID == "apple.lowlatency" ? EnhancementText.t("Apple Low Latency", "Apple 低延迟") : (active.interpolationEngineID == "distildrba.coreml" ? "DistilDRBA" : "Apple FRC"))
        switch active.rate {
        case .multiplier(let value): mode = interpolationActive ? "\(interpolationName) X\(value) · " + EnhancementText.t("Experimental", "实验") : EnhancementText.t("Motion+ off", "Motion+ 关闭")
        case let .fixedFPS(n, d): mode = interpolationActive ? "\(interpolationName) \(n)/\(d) FPS · " + EnhancementText.t("Experimental", "实验") : EnhancementText.t("Motion+ off", "Motion+ 关闭")
        }
        let fps = player?.workbenchPresentedFPS ?? 0
        let size = player?.workbenchFileLanczosSize ?? (0, 0)
        let scalerName = ArtCNNSRSelection.title(active.scaleEngineID)
        let scaler = (player?.workbenchFileLanczosActive ?? false) ? "\(scalerName) \(size.0)×\(size.1) · " : ""
        return scaler + mode + (fps > 0 ? String(format: " · %.1f FPS", fps) : "")
    }

    private func selectedFilePlayer() -> PlayerViewController? {
        let players = NSApp.windows.compactMap { $0.contentViewController as? PlayerViewController }.filter { $0.hasOpenMedia }
        if let selected = fileURL?.standardizedFileURL.path {
            return players.first { $0.openMediaPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path == selected } ?? false }
        }
        return players.first { $0.view.window?.isKeyWindow == true } ?? players.first
    }

    private func planRequest(_ snapshot: EnhancementProfile? = nil) -> SPLivePlanRequest {
        var profile = snapshot ?? self.profile
        applyAirBetaPreset(&profile)
        LiveEngineSelection.normalize(&profile)
        ArtCNNSRSelection.normalize(&profile)
        let request = SPLivePlanRequest()
        if profile.sourceKind == "file" {
            request.captureSourceKind = .file
        } else {
            switch capture.target {
            case .window?: request.captureSourceKind = .window
            case .display?: request.captureSourceKind = .display
            case nil: request.captureSourceKind = .unknown
            }
        }
        let engine = profile.interpolationEngineID
        request.engineID = engine
        request.modelID = profile.modelID
        request.qualityID = profile.interpolationQuality
        request.rifeStreamEnabled = profile.rifeStreamEnabled
        request.interpolationEnabled = profile.interpolationEnabled && (engine == "apple.frc" || engine == "apple.lowlatency" || engine == "rife.metal" || engine == "distildrba.coreml")
        if engine == "apple.lowlatency" {
            let frames2: Bool
            if case .multiplier(4) = profile.rate { frames2 = true }
            else if case .fixedFPS = profile.rate { frames2 = true }
            else { frames2 = false }
            request.modelID = frames2 ? "vt.llfi.temporal.2" : "vt.llfi.temporal.1"
        }
        request.quality = profile.interpolationQuality == "quality" ? 2 : 1
        switch profile.rate {
        case let .fixedFPS(numerator, denominator):
            request.rateKind = .fixedFPS
            request.fpsNumerator = numerator
            request.fpsDenominator = denominator
        case let .multiplier(value):
            request.rateKind = .multiplier
            request.multiplier = value
        }
        request.scaleEnabled = profile.scaleEnabled
        request.scaleQualityID = profile.scaleQualityID
        request.scaleEngine = profile.scaleEngineID == "artcnn.c4f16" ? .artCNN16 : .artCNN32
        request.srInputPreset = Int32(profile.sourceKind == "window" || profile.sourceKind == "file" ? 0 : profile.srInputPreset)
        if profile.sourceWindowResizeActive, case let .window(id, owner) = capture.target {
            request.requiredSourceWidth = Int32(profile.sourceWindowPreset == 480 ? 854 : (profile.sourceWindowPreset == 720 ? 1280 : 1920))
            request.requiredSourceHeight = Int32(profile.sourceWindowPreset)
            request.requiredSourceWindowID = id; request.requiredSourcePID = owner
            request.requiredSourceAfterHost = sourceWindowConfirmedAfter
        }
        request.outputWidth = Int32(profile.outputWidth)
        request.outputHeight = Int32(profile.outputHeight)
        switch profile.viewMode {
        case "original": request.viewMode = .original
        case "compare": request.viewMode = .compare
        default: request.viewMode = .enhanced
        }
        request.displayRefreshHz = Double(cadenceScreen(for: profile)?.maximumFramesPerSecond ?? 60)
        request.captureCapFPS = Int32(Int(profile.captureLimit) ?? 0)
        return request
    }

    private func cadenceScreen(for output: EnhancementProfile) -> NSScreen? {
        let windowTarget: Bool
        if case .window = capture.target { windowTarget = true } else { windowTarget = false }
        if (windowTarget || TargetOverlayPolicy.followsTarget(fullscreen: output.outputFullscreen, viewerFollowOverride: viewerFollowOverride)) && capture.target != nil && !targetFrame.isEmpty {
            let screens = NSScreen.screens
            if let index = TargetOverlayPolicy.screenIndex(target: targetFrame, screens: screens.map(\.frame)) { return screens[index] }
        }
        return outputScreen(for: output.outputDisplayID) ?? NSScreen.screens.first
    }

    private func syncRawCadenceEnvironment() {
        let output = processor.resolvedPlan.committed ? applied : profile
        let screen = cadenceScreen(for: output)
        let hz = Double(screen?.maximumFramesPerSecond ?? 60)
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let limit = capture.captureCapFPS
        guard cadenceRefreshHz != hz || cadenceCaptureLimit != limit || cadenceDisplayID != displayID else { return }
        cadenceRefreshHz = hz; cadenceCaptureLimit = limit; cadenceDisplayID = displayID
        processor.setRawCadence(refreshHz: hz, captureLimit: Int32(limit), displayID: UInt64(displayID))
        processor.updateDisplayRefreshHz(hz)
        processor.updateCaptureLimitFPS(Int32(limit))
    }

    @objc private func displayParametersChanged() {
        inputRouter?.stop(reason:"display_changed"); interactionArmed = false
        outputPreview.invalidateSharedGeometry()
        cadenceRefreshHz = -1
        syncRawCadenceEnvironment()
    }

    private func refreshPlanLabel() {
        updateAirBetaStatus(lastStats)
        let rate: String
        switch profile.rate {
        case let .fixedFPS(numerator, denominator): rate = "\(numerator)/\(denominator) fps"
        case let .multiplier(value): rate = "X\(value)"
        }
        let screenHz = selectedScreen()?.maximumFramesPerSecond ?? 0
        let target: Double
        if case let .fixedFPS(numerator, denominator) = profile.rate, denominator > 0 {
            target = Double(numerator) / Double(denominator)
        } else { target = 0 }
        let observedInput = (lastStats["overlayInputEstimateFPS"] as? Double) ?? -1
        let multiplied: Double
        if case let .multiplier(value) = profile.rate, observedInput > 0 {
            multiplied = observedInput * Double(value)
        } else {
            multiplied = 0
        }
        let limited = (target > 1 && Double(screenHz) + 1 < target) || (multiplied > 1 && Double(screenHz) + 1 < multiplied)
        let reason = EnhancementText.runtime(processor.resolvedPlan.unavailableReason ?? "")
        let liveEngine = processor.resolvedPlan.engineID ?? ""
        let liveModel = processor.resolvedPlan.modelID ?? ""
        let scaleEngine = processor.resolvedPlan.scaleEngineID ?? ""
        let scaleName = ArtCNNSRSelection.contains(scaleEngine) ? ArtCNNSRSelection.title(scaleEngine) : scaleEngine
        let parts = [processor.resolvedPlan.interpolationActive ? "\(liveEngine) \(liveModel)" : "", processor.resolvedPlan.scaleActive ? scaleName : ""].filter { !$0.isEmpty }.joined(separator: " + ")
        let live: String
        if profile.sourceKind == "file" {
            let player = selectedFilePlayer()
            if player?.workbenchMotionPlusActive == true {
                let selected = fileApplied ?? profile
                let name = selected.interpolationEngineID == "rife.metal" ? "ODF-VFI · \(selected.interpolationQuality)" : "Apple FRC"
                live = EnhancementText.t("Active", "生效") + " " + name
            } else if player?.workbenchMotionPlusRequested == true {
                live = EnhancementText.t("Preparing or waiting for compatible frames", "正在准备或等待兼容画面")
            } else if player?.workbenchFileLanczosActive == true {
                live = EnhancementText.t("Active", "生效")
            } else {
                live = EnhancementText.t("Not running", "未运行")
            }
        } else if !liveApplyFailure.isEmpty {
            live = liveApplyFailure
        } else if !reason.isEmpty {
            let retained = capture.running && processor.resolvedPlan.committed
                ? " · " + EnhancementText.t("Still active", "继续生效") + " \(parts)" : ""
            live = EnhancementText.t("Failed", "失败") + " " + reason + retained
        } else if capture.running && processor.resolvedPlan.committed && (processor.resolvedPlan.interpolationActive || processor.resolvedPlan.scaleActive) {
            let output = processor.resolvedPlan.scaleActive && processor.resolvedPlan.outputWidth > 0 && processor.resolvedPlan.outputHeight > 0
                ? " · " + EnhancementText.t("Active output", "实际输出") + " \(processor.resolvedPlan.outputWidth)×\(processor.resolvedPlan.outputHeight)" : ""
            live = EnhancementText.t("Active", "生效") + " \(parts)" + output
        } else if capture.running {
            live = EnhancementText.t("Previewing the original", "正在预览原画面")
        } else {
            live = EnhancementText.t("Not running", "未运行")
        }
        let baseline = profile.sourceKind == "file" ? (fileApplied ?? EnhancementProfile()) : applied
        let formDiffers = profile.interpolationEngineID != baseline.interpolationEngineID
            || profile.interpolationEnabled != baseline.interpolationEnabled
            || profile.modelID != baseline.modelID
            || profile.rate != baseline.rate
            || profile.interpolationQuality != baseline.interpolationQuality
            || (profile.interpolationEngineID == "rife.metal" && profile.rifeStreamEnabled != baseline.rifeStreamEnabled)
            || profile.scaleEnabled != baseline.scaleEnabled
            || profile.scaleEngineID != baseline.scaleEngineID
            || profile.scaleQualityID != baseline.scaleQualityID
            || profile.srInputPreset != baseline.srInputPreset
            || profile.sourceWindowPreset != baseline.sourceWindowPreset
            || profile.outputWidth != baseline.outputWidth
            || profile.outputHeight != baseline.outputHeight
            || (profile.sourceKind != "window" && (profile.outputDisplayID != baseline.outputDisplayID || profile.outputFullscreen != baseline.outputFullscreen))
        hasPendingFormChanges = formDiffers
        refreshActions()
        let pending = formDiffers ? EnhancementText.t("Pending", "待应用") + " \(Self.engineDisplayName(profile.interpolationEngineID, model: profile.modelID)) \(rate)" : ""
        let sizeChain = profile.sourceKind != "file" && capture.running && processor.resolvedPlan.committed
            ? LiveSizeChain.text(lastStats, generation: capture.currentGeneration, config: processor.resolvedPlan.configVersion) : ""
        if !sizeChain.isEmpty, let chain = lastStats["sizeChain"] as? [String: Any], let w = chain["srInputWidth"] as? Int, let h = chain["srInputHeight"] as? Int, w > 0, h > 0 {
            sizeChainLabel.stringValue = sizeChain + " · " + EnhancementText.t("SR input", "超分输入") + " \(w)×\(h)"
        } else { sizeChainLabel.stringValue = sizeChain }
        planLabel.stringValue = [live, pending, limited ? EnhancementText.t("Display is \(screenHz) Hz", "显示器 \(screenHz) Hz，不能完整呈现该帧率") : "", profile.sourceKind == "file" ? fileStatus() : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        statusLabel.toolTip = [planLabel.stringValue, sizeChainLabel.stringValue].filter { !$0.isEmpty }.joined(separator: " · ")
        if statusLabel.stringValue.isEmpty { statusLabel.stringValue = live }
        updateWindowOptimizationStatus(lastStats)
        fileLimitLabel.stringValue = profile.sourceKind == "file" ? fileStatus() : ""
    }

    private func updateWindowOptimizationStatus(_ stats: [String: Any]) {
        guard !SPRifeExperiments.airBeta, profile.sourceKind != "file",
              pendingApply == nil, liveApplyFailure.isEmpty,
              LiveFPSOverlay.fresh(stats: stats, now: ProcessInfo.processInfo.systemUptime, receipt: lastStatsReceipt,
                  generation: capture.currentGeneration, config: processor.resolvedPlan.configVersion,
                  running: capture.running, paused: capture.paused),
              let runtime = stats["airWindowOptimization"] as? [String: Any],
              runtime["requestEligible"] as? Bool == true else {
            if !lastWindowOptimizationStatus.isEmpty, statusLabel.stringValue == lastWindowOptimizationStatus {
                statusLabel.stringValue = ""
            }
            lastWindowOptimizationStatus = ""
            return
        }
        guard processor.resolvedPlan.unavailableReason.isEmpty,
              statusLabel.textColor != .systemRed, statusLabel.textColor != .systemOrange else { return }
        let active = runtime["active"] as? Bool == true
        let reason = EnhancementText.runtime((runtime["reason"] as? String) ?? "")
        let message = reason.isEmpty
            ? EnhancementText.t(active ? "RIFE window optimization is active" : "Preparing RIFE window optimization…",
                                active ? "RIFE窗口优化已生效" : "正在准备RIFE窗口优化…")
            : reason
        lastWindowOptimizationStatus = message
        statusLabel.stringValue = message
        statusLabel.textColor = active ? .labelColor : .secondaryLabelColor
    }

    private static func engineDisplayName(_ engine: String, model: String) -> String {
        switch engine {
        case "apple.lowlatency": return EnhancementText.t("Apple low latency", "Apple 低延迟")
        case "apple.frc": return "Apple FRC"
        case "rife.metal": return model == "rife-v4.26" ? "RIFE 4.26" : "ODF-VFI"
        case "distildrba.coreml": return "DistilDRBA"
        default: return engine
        }
    }

    private func loadControls() {
        applyAirBetaPreset(&profile)
        LiveEngineSelection.normalize(&profile)
        ArtCNNSRSelection.normalize(&profile)
        interpolationSwitch.state = profile.interpolationEnabled ? .on : .off
        enginePopup.selectItem(at: 0)
        reloadQualityItems()
        sourceKindControl.selectedSegment = ["window": 0, "display": 1, "file": 2][profile.sourceKind] ?? 0
        switch profile.rate {
        case .multiplier(let value):
            rateMode.selectedSegment = 1
            multiplierControl.selectedSegment = [2, 3, 4].firstIndex(of: value) ?? 0
        case let .fixedFPS(numerator, denominator):
            rateMode.selectedSegment = 0
            fpsNum.stringValue = "\(numerator)"
            fpsDen.stringValue = "\(denominator)"
            let label = denominator == 1 ? "\(numerator)" : EnhancementText.t("Custom", "自定义")
            fpsPopup.selectItem(withTitle: label)
        }
        scaleSwitch.state = profile.scaleEnabled ? .on : .off
        sourceWindowPopup.selectItem(at: [0,480,720,1080].firstIndex(of: profile.sourceWindowPreset) ?? 0)
        srInputPopup.selectItem(at: [0, 480, 720, 1080].firstIndex(of: profile.srInputPreset) ?? 3)
        scaleQualityPopup.selectItem(at: ["none", "light", "medium", "strong"].firstIndex(of: profile.scaleQualityID) ?? 0)
        updateSRCapability()
        scalePopup.selectItem(at: ArtCNNSRSelection.popupIndex(profile.scaleEngineID))
        sizePopup.item(at: 5)?.isEnabled = true
        sizePopup.item(at: 0)?.isEnabled = false
        switch (profile.outputWidth, profile.outputHeight) {
        case (0, 0): sizePopup.selectItem(at: 5)
        case (1280, 720): sizePopup.selectItem(at: 1)
        case (1920, 1080): sizePopup.selectItem(at: 2)
        case (2560, 1440): sizePopup.selectItem(at: 3)
        default: sizePopup.selectItem(at: 4)
        }
        widthField.stringValue = "\(profile.outputWidth)"
        heightField.stringValue = "\(profile.outputHeight)"
        fullscreenCheck.state = profile.sourceKind == "window" ? .on : (profile.outputFullscreen ? .on : .off)
        profile.windowOutputMode = "follow"
        viewMode.selectedSegment = ["enhanced": 0, "original": 1, "compare": 2][profile.viewMode] ?? 0
        appearanceControl.selectedSegment = ["system": 0, "light": 1, "dark": 2][profile.appearance] ?? 0
        captureCapPopup.selectItem(at: ["auto": 0, "30": 1, "60": 2][profile.captureLimit] ?? 0)
        capture.captureCapFPS = Int(profile.captureLimit) ?? 0
        refreshP0ControlTitles()
        if case .multiplier = profile.rate, multiplierControl.selectedSegment < 0 {
            multiplierControl.selectedSegment = 0
        }
        refreshSourceBar()
        reloadDisplays()
        if !capture.running { syncRawCadenceEnvironment() }
        rebuildConfigRows()
        applyModeVisibility()
        refreshPlanLabel()
    }

    private func reloadQualityItems() {
        qualityPopup.removeAllItems()
        qualityPopup.addItems(withTitles: ["fast", "balanced", "hq"])
        qualityPopup.selectItem(at: ["fast": 0, "balanced": 1, "hq": 2][profile.interpolationQuality] ?? 0)
        qualityPopup.isHidden = false
        phaseLabel.isHidden = true
        compatibilityButton.isHidden = true
        interpolationQualityRow?.isHidden = false
    }

    private func lowLatencyPhaseText() -> String {
        func sizeText(_ multiplier: Int) -> String {
            let fileSize = selectedFilePlayer()?.workbenchSourceSize
            let width = profile.sourceKind == "file" ? (fileSize?.0 ?? 0) : ((lastStats["sourceWidth"] as? Int) ?? 0)
            let height = profile.sourceKind == "file" ? (fileSize?.1 ?? 0) : ((lastStats["sourceHeight"] as? Int) ?? 0)
            guard width > 0 && height > 0 else { return "X\(multiplier)" }
            let w=profile.outputWidth, h=profile.outputHeight
            let before = profile.sourceKind != "file" && profile.scaleEnabled && profile.scaleEngineID == "lanczos" &&
                profile.srInputPreset == 0 && w > 0 && h > 0 && w < width && h < height && w * height == h * width
            let size = before ? "\(width)×\(height) → \(w)×\(h)" : "\(width)×\(height)"
            return "X\(multiplier) · " + EnhancementText.t("Processing", "处理") + " \(size)"
        }
        switch profile.rate {
        case .multiplier(2):
            return sizeText(2)
        case .multiplier(3):
            return EnhancementText.t("X3 needs 1/3 and 2/3. Low-latency will not rewrite them. Use Apple frame-rate conversion.", "X3 需要 1/3 和 2/3。低延迟不会改写它们。请改用 Apple 帧率转换。")
        case .multiplier(4):
            return sizeText(4)
        case .fixedFPS:
            return EnhancementText.t("Fixed frame rates are unavailable with this engine. Choose X2 or X4, or use Apple frame-rate conversion.", "此引擎不支持固定帧率。请选择 X2、X4 或 Apple 帧率转换。")
        case .multiplier:
            return EnhancementText.t("This multiplier is not one of the low-latency phase sets.", "这个倍率不在低延迟的相位集合里。")
        }
    }

    private func readEngineSelection() {
        let selection = LiveEngineSelection.fromPopup(enginePopup.indexOfSelectedItem, quality: profile.interpolationQuality)
        profile.interpolationEngineID = selection.engine
        profile.modelID = selection.model
        LiveEngineSelection.normalize(&profile)
    }

    private func readControls() {
        profile.interpolationEnabled = interpolationSwitch.state == .on
        readEngineSelection()
        profile.interpolationQuality = LiveEngineSelection.validQuality(qualityPopup.titleOfSelectedItem ?? "fast")
        profile.sourceKind = ["window", "display", "file"][max(0, sourceKindControl.selectedSegment)]
        if rateMode.selectedSegment == 1 {
            profile.rate = .multiplier([2, 3, 4][max(0, multiplierControl.selectedSegment)])
        } else if fpsPopup.indexOfSelectedItem == 7 {
            let n = Int64(fpsNum.stringValue) ?? 60
            let d = Int64(fpsDen.stringValue) ?? 1
            profile.rate = .fixedFPS(numerator: max(1, n), denominator: max(1, d))
        } else {
            let presets = [24, 25, 30, 50, 60, 90, 120]
            let index = min(max(0, fpsPopup.indexOfSelectedItem), presets.count - 1)
            profile.rate = .fixedFPS(numerator: Int64(presets[index]), denominator: 1)
        }
        profile.scaleEnabled = scaleSwitch.state == .on
        if profile.sourceKind == "window" { profile.sourceWindowPreset = [0,480,720,1080][max(0,min(3,sourceWindowPopup.indexOfSelectedItem))] }
        if profile.sourceKind != "window" && profile.sourceKind != "file" { profile.srInputPreset = [0, 480, 720, 1080][max(0, min(3, srInputPopup.indexOfSelectedItem))] }
        profile.scaleEngineID = ArtCNNSRSelection.fromPopup(scalePopup.indexOfSelectedItem)
        profile.scaleQualityID = "none"
        switch sizePopup.indexOfSelectedItem {
        case 0: profile.outputWidth = 0; profile.outputHeight = 0
        case 1: profile.outputWidth = 1280; profile.outputHeight = 720
        case 2: profile.outputWidth = 1920; profile.outputHeight = 1080
        case 3: profile.outputWidth = 2560; profile.outputHeight = 1440
        case 5: profile.outputWidth = 0; profile.outputHeight = 0
        default:
            profile.outputWidth = WorkbenchDimensionPolicy.value(widthField.stringValue) ?? (profile.outputWidth >= 2 ? profile.outputWidth : 1920)
            profile.outputHeight = WorkbenchDimensionPolicy.value(heightField.stringValue) ?? (profile.outputHeight >= 2 ? profile.outputHeight : 1080)
        }
        if profile.sourceKind != "window" { profile.outputFullscreen = fullscreenCheck.state == .on }
        profile.windowOutputMode = "follow"
        profile.viewMode = ["enhanced", "original", "compare"][max(0, viewMode.selectedSegment)]
        profile.appearance = ["system", "light", "dark"][max(0, appearanceControl.selectedSegment)]
        profile.captureLimit = ["auto", "30", "60"][max(0, min(2, captureCapPopup.indexOfSelectedItem))]
        profile.soundMode = "sourceApplication"
        let displayIndex = max(0, min(displayIDs.count - 1, displayPopup.indexOfSelectedItem))
        profile.outputDisplayID = displayIDs[displayIndex]
        applyAirBetaPreset(&profile)
    }

    private var displayIDs: [UInt32] = [0]

    private func reloadDisplays() {
        displayPopup.removeAllItems()
        displayIDs = [0]
        displayPopup.addItem(withTitle: EnhancementText.t("Main display", "主显示器"))
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = number?.uint32Value ?? 0
            displayIDs.append(id)
            displayPopup.addItem(withTitle: "\(screen.localizedName) · \(screen.maximumFramesPerSecond) Hz")
        }
        if let index = displayIDs.firstIndex(of: profile.outputDisplayID) {
            displayPopup.selectItem(at: index)
        } else {
            displayIDs.append(profile.outputDisplayID)
            displayPopup.addItem(withTitle: EnhancementText.t("Unavailable display", "显示器不可用"))
            displayPopup.selectItem(at: displayIDs.count - 1)
        }
    }

    private func outputScreen(for id: UInt32) -> NSScreen? {
        if id == 0 { return NSScreen.screens.first ?? NSScreen.main }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    private func isInteractiveMode(_ mode: String) -> Bool { mode == "absolute" || mode == "relative" }

    private func isVerifiedInputTarget(_ context: LiveInputRouter.Context, requireGeometry: Bool) -> Bool {
        guard capture.running, !capture.paused, capture.currentGeneration == context.generation,
              case let .window(id, owner) = capture.target, id == context.windowID, owner == context.sourcePID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == owner, targetFrontmost, targetDecisionReason == "matched", interactionSourceUnobstructed else { return false }
        if !requireGeometry { return true }
        let geometry = processor.inputGeometrySnapshot()
        return (geometry["valid"] as? Bool) == true && (geometry["version"] as? NSNumber)?.uint64Value == context.version &&
            (geometry["windowID"] as? NSNumber)?.uint32Value == id && (geometry["pid"] as? NSNumber)?.int32Value == owner &&
            (geometry["generation"] as? NSNumber)?.uint64Value == context.generation &&
            (geometry["config"] as? NSNumber)?.uint64Value == context.config &&
            (geometry["measurementEpoch"] as? NSNumber)?.uint64Value == context.epoch
    }

    private func isVerifiedBootstrapTarget(_ context: LiveInputRouter.Context) -> Bool {
        guard interactionArmed, capture.running, !capture.paused, capture.currentGeneration == context.generation,
              processor.resolvedPlan.configVersion == context.config, interactionRequestGeneration == context.generation,
              interactionRequestConfig == context.config, targetFrontmost, targetDecisionReason == "matched",
              interactionSourceUnobstructed, case let .window(id, owner) = capture.target,
              id == context.windowID, owner == context.sourcePID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == owner else { return false }
        return true
    }

    private func setInteractionControlsPassthrough(_ enabled: Bool) {
        viewerControlsPanel?.ignoresMouseEvents = enabled
        viewerStopButton?.isHidden = enabled
        p0OpaqueButton?.isHidden = enabled
        p0ActivateButton?.isHidden = enabled
        p0CaptureButton?.isHidden = enabled
    }

    private func interactionDisplayMappings() -> [P1DisplayMapping] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  CGDisplayIsActive(id) != 0 else { return nil }
            let bounds = CGDisplayBounds(id), frame = screen.frame
            guard bounds.minX.isFinite, bounds.minY.isFinite, bounds.width > 0, bounds.height > 0,
                  frame.minX.isFinite, frame.minY.isFinite, frame.width > 0, frame.height > 0 else { return nil }
            return P1DisplayMapping(quartz: bounds, appKit: frame)
        }
    }
    private func interactionDisplays() -> [CGRect] { interactionDisplayMappings().map(\.quartz) }

    private func investigateSelectedAX(id: CGWindowID, owner: pid_t, source: CGRect, targetBounds: CGRect) {
        guard r7Diagnostics, CommandLine.arguments.contains("--odf-p1-ax-diagnostics"), AXIsProcessTrusted(),
              outputWindow?.isVisible != true, !source.isEmpty, !targetBounds.isEmpty,
              !interactionAXBusy, ProcessInfo.processInfo.systemUptime - interactionAXLastRequest >= 2 else { return }
        let generation = capture.currentGeneration, config = processor.resolvedPlan.configVersion
        let requestAt = ProcessInfo.processInfo.systemUptime, visibilityToken = outputWarmupToken, requestSerial = liveApply.serial
        interactionAXBusy = true; interactionAXLastRequest = requestAt
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = P1AXInvestigation.inspect(pid: owner, targetBounds: targetBounds, source: source)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.interactionAXBusy = false
                guard self.capture.running, !self.capture.paused, self.capture.currentGeneration == generation,
                      self.processor.resolvedPlan.configVersion == config, self.liveApply.serial == requestSerial,
                      self.isInteractiveMode(self.profile.windowOutputMode), case let .window(currentID, currentOwner) = self.capture.target,
                      currentID == id, currentOwner == owner, NSWorkspace.shared.frontmostApplication?.processIdentifier == owner,
                      self.outputWindow?.isVisible != true, self.outputWarmupToken == visibilityToken,
                      self.capture.latestScreenRect() == source,
                      var result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
                result["generation"] = generation; result["config"] = config; result["targetWindowID"] = id
                result["targetPID"] = owner; result["requestMonotonic"] = requestAt
                result["resultMonotonic"] = ProcessInfo.processInfo.systemUptime
                result["requestedTargetBounds"] = [targetBounds.minX,targetBounds.minY,targetBounds.width,targetBounds.height]
                self.recordPlanEvent("interaction_ax_observation", extra: ["interactionAX": result])
            }
        }
    }

    private func ensureInputRouter() -> LiveInputRouter {
        if let inputRouter { return inputRouter }
        let router = LiveInputRouter(mapper: { [weak self] point, version, clamp in
            guard let result = self?.processor.mapQuartzOutputPoint(point, geometryVersion: version, clamp: clamp),
                  let x = result["x"]?.doubleValue, let y = result["y"]?.doubleValue else { return nil }
            return CGPoint(x:x,y:y)
        }, verifyTarget: { [weak self] in self?.isVerifiedInputTarget($0, requireGeometry: true) ?? false },
        verifyBootstrap: { [weak self] in self?.isVerifiedBootstrapTarget($0) ?? false },
        safeReleaseTarget: { [weak self] context in
            guard let self, self.isVerifiedInputTarget(context, requireGeometry: true), let target = self.capture.target else { return false }
            return self.targetWindowState(target).front
        }, stopped: { [weak self] reason in
            guard let self else { return }
            self.interactionArmed = false; self.interactionFailure = reason
            if reason == "emergency_exit" { self.stop() }
            else { self.updateTargetPanels() }
        })
        inputRouter = router
        return router
    }

    private func reconcileInputRouter(target: CaptureTarget, interactive: Bool) {
        guard interactive, interactionArmed, case let .window(id, owner) = target else {
            if inputRouter?.active == true { inputRouter?.stop(reason:"not_interactive") }
            return
        }
        let permission = LiveInputRouter.Permission.preflight()
        guard permission.permits(relative: applied.windowOutputMode == "relative") else {
            if inputRouter?.active == true { inputRouter?.stop(reason:"permission_missing") }
            interactionFailure = !permission.listen ? "input_monitoring_missing" : (!permission.accessibility ? "accessibility_missing" : "event_modification_missing")
            return
        }
        let geometry = processor.inputGeometrySnapshot()
        guard (geometry["valid"] as? Bool) == true, let version = (geometry["version"] as? NSNumber)?.uint64Value, version > 0,
              (geometry["windowID"] as? NSNumber)?.uint32Value == id, (geometry["pid"] as? NSNumber)?.int32Value == owner,
              (geometry["generation"] as? NSNumber)?.uint64Value == capture.currentGeneration,
              let config = (geometry["config"] as? NSNumber)?.uint64Value, config == processor.resolvedPlan.configVersion,
              let epoch = (geometry["measurementEpoch"] as? NSNumber)?.uint64Value, epoch > 0 else {
            if inputRouter?.ready == true {
                inputRouter?.stop(reason:"geometry_unavailable"); interactionArmed = false
            } else if interactionGeometryWaitAt == 0 { interactionGeometryWaitAt = ProcessInfo.processInfo.systemUptime }
            else if ProcessInfo.processInfo.systemUptime - interactionGeometryWaitAt > 3 { interactionArmed = false }
            if !interactionArmed { inputRouter?.stop(reason:"geometry_unavailable"); outputWindow?.orderOut(nil); viewerControlsPanel?.orderOut(nil); outputPreview.refreshVisibilitySnapshot() }
            interactionFailure = "geometry_unavailable"; return
        }
        let context = LiveInputRouter.Context(sourcePID: owner, windowID: id, generation: capture.currentGeneration,
            config: config, epoch: epoch, version: version, relative: applied.windowOutputMode == "relative", exclusions: [], sourceDisplays: interactionDisplayMappings())
        let router = ensureInputRouter()
        if router.start(context) { interactionFailure = ""; interactionGeometryWaitAt = 0 }
        else if router.reason == "bootstrap_buttons_pending" {
            if interactionGeometryWaitAt == 0 { interactionGeometryWaitAt = ProcessInfo.processInfo.systemUptime }
            interactionFailure = "release_mouse_buttons"
            if ProcessInfo.processInfo.systemUptime - interactionGeometryWaitAt >= 3 {
                router.stop(reason:"bootstrap_buttons_timeout"); interactionArmed = false
                outputWindow?.orderOut(nil); viewerControlsPanel?.orderOut(nil); outputPreview.refreshVisibilitySnapshot()
            }
        } else {
            interactionFailure = router.reason; interactionArmed = false
            router.stop(reason: router.reason)
            outputWindow?.orderOut(nil); viewerControlsPanel?.orderOut(nil); outputPreview.refreshVisibilitySnapshot()
        }
    }

    private func selectedScreen() -> NSScreen? {
        outputScreen(for: profile.outputDisplayID) ?? NSScreen.screens.first
    }

    private final class TargetPanel: NSPanel {
        var viewerKeyboard = false
        var exitViewer: (() -> Void)?
        override var canBecomeKey: Bool { viewerKeyboard }
        override var canBecomeMain: Bool { false }
        override func sendEvent(_ event: NSEvent) {
            if viewerKeyboard && (event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged) {
                if event.type == .keyDown && event.keyCode == 53 { exitViewer?() }
                return
            }
            super.sendEvent(event)
        }
    }

    private func overlayPanel() -> NSPanel {
        let panel = TargetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        return panel
    }

    private func placeOutput() {
        guard outputWindow == nil else { return }
        let panel = overlayPanel()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        outputPreview.layer?.isOpaque = false
        panel.title = EnhancementText.t("Enhanced output", "增强输出")
        panel.contentView = outputPreview
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        controls.layer?.cornerRadius = 8
        let label = NSTextField(labelWithString: EnhancementText.t("Fullscreen viewer · input paused", "全屏预览 · 输入已暂停"))
        label.textColor = .white
        let back = NSButton(title: EnhancementText.t("Stop enhancement", "停止增强"), target: self, action: #selector(stop))
        back.bezelStyle = .rounded
        viewerStopButton = back
        controls.addArrangedSubview(label)
        if p0ControlsEnabled {
            let opaque = NSButton(title: "", target: self, action: #selector(toggleP0Opaque))
            let focus = NSButton(title: "", target: self, action: #selector(toggleP0Activation))
            let cap = NSButton(title: "", target: self, action: #selector(toggleP0CaptureCap))
            for item in [opaque, focus, cap] { item.bezelStyle = .rounded; controls.addArrangedSubview(item) }
            p0OpaqueButton = opaque; p0ActivateButton = focus; p0CaptureButton = cap
            refreshP0ControlTitles()
        }
        controls.addArrangedSubview(back)
        let controlsPanel = overlayPanel()
        controlsPanel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        controlsPanel.backgroundColor = .clear
        controlsPanel.isOpaque = false
        controlsPanel.ignoresMouseEvents = false
        controlsPanel.contentView = controls
        viewerControlsPanel = controlsPanel
        viewerControls = controls
        if let targetPanel = panel as? TargetPanel { targetPanel.exitViewer = { [weak self] in self?.exitFullscreenViewer() } }
        outputWindow = panel
    }

    private func refreshP0ControlTitles() {
        guard p0ControlsEnabled else { return }
        let opaque = r7Flag("--odf-r7-opaque") ? EnhancementText.t("Overlay: opaque", "遮罩：不透明") : EnhancementText.t("Overlay: clear", "遮罩：透明")
        let focus = r7Flag("--odf-r7-activate") ? EnhancementText.t("Focus: output", "焦点：输出") : EnhancementText.t("Focus: source", "焦点：来源")
        let cap = capture.captureCapFPS == 60 ? "60" : (capture.captureCapFPS == 30 ? "30" : "Auto")
        let captureTitle = EnhancementText.t("Capture: \(cap)", "采集：\(cap)")
        for item in [p0OpaqueButton, p0MainOpaqueButton] { item?.title = opaque }
        for item in [p0ActivateButton, p0MainActivateButton] { item?.title = focus }
        for item in [p0CaptureButton, p0MainCaptureButton] { item?.title = captureTitle }
    }

    @objc private func toggleP0OpaqueFromMain() { withP0MainAction { toggleP0Opaque() } }
    @objc private func toggleP0ActivationFromMain() { withP0MainAction { toggleP0Activation() } }
    @objc private func toggleP0CaptureCapFromMain() { withP0MainAction { toggleP0CaptureCap() } }

    private func withP0MainAction(_ action: () -> Void) {
        guard p0ControlsEnabled else { return }
        p0MainActionInProgress = true
        defer { p0MainActionInProgress = false }
        action()
    }

    @objc private func toggleP0Opaque() {
        guard p0ControlsEnabled else { return }
        p0OpaqueOverride = !r7Flag("--odf-r7-opaque")
        refreshP0ControlTitles()
        updateTargetPanels()
        recordPlanEvent("p0_opaque_changed", extra: ["p0ControlSurface": p0MainActionInProgress ? "main" : "overlay"])
    }

    @objc private func toggleP0Activation() {
        guard p0ControlsEnabled else { return }
        let enable = !r7Flag("--odf-r7-activate")
        p0ActivateOverride = enable
        if !enable && viewerActive { exitFullscreenViewer() }
        refreshP0ControlTitles()
        updateTargetPanels()
        recordPlanEvent("p0_activation_changed", extra: ["p0ControlSurface": p0MainActionInProgress ? "main" : "overlay"])
    }

    @objc private func toggleP0CaptureCap() {
        guard p0ControlsEnabled else { return }
        // The stream must restart to apply minimumFrameInterval. Reuse the
        // already-authorized SCContentFilter; no new picker is presented.
        if viewerActive { exitFullscreenViewer() }
        captureCapPopup.selectItem(at: capture.captureCapFPS == 60 ? 0 : 2)
        captureCapChanged()
        refreshP0ControlTitles()
        recordPlanEvent("p0_capture_cap_changed", extra: ["p0ControlSurface": p0MainActionInProgress ? "main" : "overlay"])
    }

    @objc private func exitFullscreenViewer() {
        guard viewerActive else { return }
        viewerActive = false
        viewerFollowOverride = true // session-only; keep the saved fullscreen preference
        viewerControlsPanel?.orderOut(nil)
        if let panel = outputWindow as? TargetPanel { panel.viewerKeyboard = false; panel.ignoresMouseEvents = true }
        outputWindow?.orderOut(nil)
        if !p0MainActionInProgress, let pid = viewerReturnPID, let app = NSRunningApplication(processIdentifier: pid) { app.activate(options: []) }
        viewerReturnPID = nil
        DispatchQueue.main.async { [weak self] in self?.updateTargetPanels() }
    }

    private func ensureTargetHUD() -> (NSPanel, NSPanel) {
        if let targetHUD, let targetCountdownHUD { return (targetHUD, targetCountdownHUD) }
        let panel = overlayPanel()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let countdownPanel = overlayPanel()
        countdownPanel.level = panel.level
        countdownPanel.backgroundColor = .clear
        countdownPanel.isOpaque = false
        let countdownHost = NSView()
        countdownHost.wantsLayer = true
        countdownHost.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        countdownHost.layer?.cornerRadius = 12
        let plate = NSView()
        plate.wantsLayer = true
        plate.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        plate.layer?.cornerRadius = 6
        targetFPS.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        targetFPS.textColor = .white
        targetFPS.maximumNumberOfLines = 0
        targetFPS.lineBreakMode = .byWordWrapping
        targetCountdown.font = .systemFont(ofSize: 54, weight: .bold)
        targetCountdown.textColor = .white
        targetCountdown.alignment = .center
        targetFPS.translatesAutoresizingMaskIntoConstraints = false
        targetCountdown.translatesAutoresizingMaskIntoConstraints = false
        plate.addSubview(targetFPS)
        countdownHost.addSubview(targetCountdown)
        NSLayoutConstraint.activate([
            targetFPS.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 8),
            targetFPS.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -8),
            targetFPS.topAnchor.constraint(equalTo: plate.topAnchor, constant: 4),
            targetFPS.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -4),
            targetCountdown.centerXAnchor.constraint(equalTo: countdownHost.centerXAnchor),
            targetCountdown.centerYAnchor.constraint(equalTo: countdownHost.centerYAnchor),
        ])
        targetCountdown.stringValue = countdown.active ? "\(countdown.remaining)" : ""
        targetCountdown.isHidden = !countdown.active
        plate.isHidden = fpsSwitch.state != .on
        panel.contentView = plate
        countdownPanel.contentView = countdownHost
        targetHUD = panel
        targetCountdownHUD = countdownPanel
        return (panel, countdownPanel)
    }

    private struct TargetWindowState {
        var exists: Bool
        var onscreen: Bool
        var front: Bool
        var frame: NSRect
        var contentRectVerified: Bool
        var verifiedScreenRect: CGRect? = nil
        var screenRectHost: UInt64 = 0
        var observedWindowBounds: CGRect = .null
    }

    private func targetWindowState(_ target: CaptureTarget) -> TargetWindowState {
        targetDecision = [:]
        guard let raw = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
            targetDecisionReason = "window_list_unavailable"
            return .init(exists: false, onscreen: false, front: false, frame: .zero, contentRectVerified: false)
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let frontPID { targetDecision["frontProcessPID"] = frontPID }
        func record(_ metadata: TargetOverlayPolicy.WindowMetadata, prefix: String) {
            targetDecision[prefix + "ID"] = metadata.id
            targetDecision[prefix + "OwnerPID"] = metadata.owner
            targetDecision[prefix + "Layer"] = metadata.layer
            if let alpha = metadata.alpha { targetDecision[prefix + "Alpha"] = alpha }
            targetDecision[prefix + "Onscreen"] = metadata.onscreen
            targetDecision[prefix + "Bounds"] = [metadata.bounds.minX, metadata.bounds.minY, metadata.bounds.width, metadata.bounds.height]
        }
        func native(_ rect: CGRect) -> NSRect {
            let candidates: [(NSScreen, CGRect)] = NSScreen.screens.compactMap { screen in
                guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
                let cg = CGDisplayBounds(id)
                return cg.width > 0 && cg.height > 0 ? (screen, cg) : nil
            }
            guard let (screen, cg) = candidates.max(by: {
                let a = $0.1.intersection(rect), b = $1.1.intersection(rect)
                let aArea = a.isNull ? 0 : max(0, a.width) * max(0, a.height)
                let bArea = b.isNull ? 0 : max(0, b.width) * max(0, b.height)
                return aArea < bArea
            }) else { return .zero }
            return TargetOverlayPolicy.nativeFrame(rect, cgDisplay: cg, screen: screen.frame)
        }
        switch target {
        case let .window(id, owner):
            let ordered = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
            let decision = TargetOverlayPolicy.evaluateWindow(raw, orderedOnscreen: ordered, id: id, owner: owner, frontPID: frontPID)
            targetDecision["targetIgnoredWindows"] = decision.ignored.map { item -> [String: Any] in
                ["id": item.id, "bounds": [item.bounds.minX, item.bounds.minY, item.bounds.width, item.bounds.height],
                 "layer": item.layer, "alpha": item.alpha as Any? ?? NSNull(), "name": item.name as Any? ?? NSNull()]
            }
            targetDecisionReason = decision.reason
            if let target = decision.target { record(target, prefix: "targetCG") }
            if let competing = decision.competing { record(competing, prefix: "competingCG") }
            guard let chosen = decision.target else {
                return .init(exists: decision.reason != "target_missing", onscreen: false, front: false, frame: .zero, contentRectVerified: false)
            }
            guard chosen.owner == owner else { return .init(exists: false, onscreen: false, front: false, frame: .zero, contentRectVerified: false) }
            let rect = chosen.bounds
            let captured = capture.latestScreenRectSnapshot()
            let content = captured.flatMap { value in rect.insetBy(dx: -4, dy: -4).contains(value.rect) ? value.rect : nil }
            return .init(exists: true, onscreen: chosen.onscreen, front: decision.matches,
                         frame: native(content ?? rect), contentRectVerified: content != nil, verifiedScreenRect: content,
                         screenRectHost: captured?.host ?? 0, observedWindowBounds: rect)
        case let .display(id):
            guard CGDisplayIsActive(id) != 0 else { targetDecisionReason = "display_unavailable"; return .init(exists: false, onscreen: false, front: false, frame: .zero, contentRectVerified: false) }
            let rect = CGDisplayBounds(id)
            let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let systemUI: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.systempreferences"]
            let front = frontPID != nil && frontPID != ProcessInfo.processInfo.processIdentifier && !systemUI.contains(frontBundle)
            targetDecisionReason = front ? "matched" : (frontPID == nil ? "front_process_unknown" : "workbench_or_system_frontmost")
            return .init(exists: true, onscreen: true, front: front, frame: native(rect), contentRectVerified: true)
        }
    }

    private func updateTargetPanels() {
        guard profile.sourceKind != "file", let target = capture.target else {
            if inputRouter?.active == true || interactionArmed {
                inputRouter?.stop(reason:"source_closed"); interactionArmed = false; interactionObstructionWait.reset()
            }
            outputPreview.observeVerifiedWindowGeometry(nil)
            viewerActive = false
            viewerReturnPID = nil
            (outputWindow as? TargetPanel)?.viewerKeyboard = false
            targetOnscreen = false
            targetFrontmost = false
            targetFrame = .zero
            targetContentRectVerified = false
            targetDecision = [:]; targetDecisionReason = "no_target"
            outputHiddenReason = "no_target"; hudHiddenReason = "no_target"
            if outputWindow?.isVisible == true { outputWarmupToken &+= 1 }
            outputWindow?.orderOut(nil); targetHUD?.orderOut(nil); targetCountdownHUD?.orderOut(nil); viewerControlsPanel?.orderOut(nil)
            outputPreview.refreshVisibilitySnapshot()
            return
        }
        let state = targetWindowState(target)
        let ownViewerFront = viewerActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let targetReady = state.front || (ownViewerFront && state.exists && state.onscreen)
        targetOnscreen = state.onscreen
        targetFrontmost = targetReady
        targetFrame = state.frame
        syncRawCadenceEnvironment()
        targetContentRectVerified = state.contentRectVerified
        if state.onscreen { targetWasOnscreen = true }
        if !delayedWindowSelection && (targetDecisionReason == "target_identity_changed_in_ordered_list" || (targetDecisionReason != "target_metadata_incomplete" && targetDecisionReason != "window_list_unavailable" && TargetOverlayPolicy.shouldCancel(exists: state.exists, onscreen: state.onscreen, wasOnscreen: targetWasOnscreen))) {
            cancelCountdown()
        }
        if interactionArmed && (interactionRequestGeneration != capture.currentGeneration ||
                                interactionRequestConfig != processor.resolvedPlan.configVersion) {
            inputRouter?.stop(reason: "identity_changed"); interactionArmed = false; interactionObstructionWait.reset(); interactionFailure = "target_unavailable"
        }
        if interactionArmed && capture.running && !capture.paused && state.exists && state.onscreen && !state.frame.isEmpty {
            switch P1FocusPolicy.decide(targetReady: targetReady, acquired: interactionFocusAcquired,
                ownFront: NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                now: ProcessInfo.processInfo.systemUptime, deadline: interactionFocusDeadline) {
            case .wait:
                outputPreview.observeVerifiedWindowGeometry(nil)
                outputWindow?.orderOut(nil); viewerControlsPanel?.orderOut(nil); outputPreview.refreshVisibilitySnapshot()
                interactionFailure = "waiting_source_focus"; outputHiddenReason = "waiting_source_focus"; return
            case .ready: interactionFocusAcquired = true
            case .cancel:
                inputRouter?.stop(reason:"target_unavailable"); interactionArmed = false; interactionObstructionWait.reset(); interactionFailure = "target_unavailable"
            }
        }
        guard capture.running && !capture.paused && targetReady && !state.frame.isEmpty else {
            if inputRouter?.active == true || interactionArmed {
                inputRouter?.stop(reason:"target_unavailable"); interactionArmed = false; interactionObstructionWait.reset(); interactionFailure = "target_unavailable"
            }
            outputPreview.observeVerifiedWindowGeometry(nil)
            viewerActive = false
            viewerControlsPanel?.orderOut(nil)
            (outputWindow as? TargetPanel)?.viewerKeyboard = false
            let reason = !capture.running ? "capture_not_running" : (capture.paused ? "paused" : (!targetReady ? targetDecisionReason : "geometry_unavailable"))
            outputHiddenReason = reason; hudHiddenReason = reason
            if outputWindow?.isVisible == true { outputWarmupToken &+= 1 }
            outputWindow?.orderOut(nil); targetHUD?.orderOut(nil); targetCountdownHUD?.orderOut(nil)
            outputPreview.refreshVisibilitySnapshot()
            return
        }
        let planActive = processor.resolvedPlan.committed && (processor.resolvedPlan.interpolationActive || processor.resolvedPlan.scaleActive || r7Flag("--odf-r7-passthrough") || (profile.sourceKind == "window" && applied.windowOutputMode != "follow"))
        let windowTarget: Bool
        if case .window = target { windowTarget = true } else { windowTarget = false }
        // Fullscreen geometry for a window is a non-interactive diagnostic only.
        let diagnosticFullscreen = windowTarget && r7Flag("--odf-r7-fullscreen-geometry")
        let requestedInteractive = windowTarget && isInteractiveMode(applied.windowOutputMode)
        let permission = requestedInteractive ? LiveInputRouter.Permission.preflight() : nil
        let interactionAvailable = requestedInteractive && interactionArmed && permission?.permits(relative: applied.windowOutputMode == "relative") == true && profile.viewMode != "compare"
        if requestedInteractive && !interactionAvailable {
            if inputRouter?.active == true { inputRouter?.stop(reason:"interaction_restricted") }
            if !interactionArmed { if interactionFailure.isEmpty { interactionFailure = "apply_to_start" } }
            else if permission?.listen != true { interactionFailure = "input_monitoring_missing" }
            else if permission?.accessibility != true { interactionFailure = "accessibility_missing" }
            else if applied.windowOutputMode == "absolute" && permission?.post != true { interactionFailure = "event_modification_missing" }
            else { interactionFailure = "comparison_unsupported" }
            if interactionArmed { interactionArmed = false }
            outputWindow?.orderOut(nil); viewerControlsPanel?.orderOut(nil); outputPreview.refreshVisibilitySnapshot()
            outputHiddenReason = "interaction_restricted"; return
        }
        if interactionAvailable { setInteractionControlsPassthrough(inputRouter?.ready == true) }
        if interactionAvailable, case let .window(id, owner) = target, let source = state.verifiedScreenRect,
           outputWindow != nil {
            // Exclude only panels this controller will make pass-through after
            // the router starts. Their actual input state is untouched here.
            func windowID(_ window: NSWindow?) -> CGWindowID? {
                guard let window, window.windowNumber > 0 else { return nil }
                return CGWindowID(window.windowNumber)
            }
            let huds = [targetHUD, targetCountdownHUD].compactMap { $0 }
                .filter { $0.ignoresMouseEvents }.compactMap { windowID($0) }
            let passthrough = TargetOverlayPolicy.interactionOwnedPassThrough(
                output: windowID(outputWindow), controls: windowID(viewerControlsPanel), huds: huds)
            let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            let displays = interactionDisplays()
            let guardResult = TargetOverlayPolicy.interactionGuard(ordered, id: id, owner: owner, source: source, passthrough: passthrough)
            let pointValidatedAbsolute = applied.windowOutputMode == "absolute"
            interactionSourceUnobstructed = !displays.isEmpty && (pointValidatedAbsolute || guardResult.clear)
            if r7Diagnostics {
                var detail = guardResult.diagnostic
                detail["enforcement"] = pointValidatedAbsolute ? "per_event_exact_window" : "full_source_guard"
                if displays.isEmpty { detail["clear"] = false; detail["reason"] = "active_displays_unavailable" }
                detail["activeDisplaysQuartz"] = displays.map { [$0.minX, $0.minY, $0.width, $0.height] }
                detail["knownOwnedWindowIDs"] = excludedIDs()
                detail["passthroughWindowIDs"] = passthrough.sorted()
                detail["targetWindowID"] = id; detail["targetPID"] = owner
                detail["generation"] = capture.currentGeneration; detail["config"] = processor.resolvedPlan.configVersion
                if interactionGuardFirst == nil && !interactionSourceUnobstructed { interactionGuardFirst = detail }
                if interactionGuardLast.map({ !NSDictionary(dictionary: $0).isEqual(to: detail) }) ?? true {
                    interactionGuardLast = detail
                    recordPlanEvent("interaction_guard_changed")
                }
            }
            if pointValidatedAbsolute && !guardResult.clear && outputWindow?.isVisible != true {
                investigateSelectedAX(id: id, owner: owner, source: source, targetBounds: state.observedWindowBounds)
            }
            if !interactionSourceUnobstructed {
                inputRouter?.stop(reason: "source_obstructed")
                let mayWait = interactionObstructionWait.observe(blocked: true, now: ProcessInfo.processInfo.systemUptime,
                    generation: capture.currentGeneration, config: processor.resolvedPlan.configVersion)
                interactionArmed = mayWait; interactionFailure = mayWait ? "source_obstructed_waiting" : "source_obstructed"
                interactionGeometryWaitAt = 0
                if outputWindow?.isVisible == true { outputWarmupToken &+= 1 }
                outputPreview.invalidateSharedGeometry()
                outputWindow?.orderOut(nil); viewerControlsPanel?.orderOut(nil); outputPreview.refreshVisibilitySnapshot()
                investigateSelectedAX(id: id, owner: owner, source: source, targetBounds: state.observedWindowBounds)
                outputHiddenReason = mayWait ? "source_obstructed_waiting" : "source_obstructed"; return
            }
            guard interactionObstructionWait.observe(blocked: false, now: ProcessInfo.processInfo.systemUptime,
                generation: capture.currentGeneration, config: processor.resolvedPlan.configVersion) else {
                inputRouter?.stop(reason: "obstruction_timeout"); interactionArmed = false; interactionFailure = "source_obstructed"
                outputPreview.invalidateSharedGeometry(); outputWindow?.orderOut(nil); viewerControlsPanel?.orderOut(nil)
                outputPreview.refreshVisibilitySnapshot(); outputHiddenReason = "source_obstructed"; return
            }
            if interactionFailure == "source_obstructed_waiting" { interactionFailure = "" }
        } else {
            interactionSourceUnobstructed = false
            setInteractionControlsPassthrough(false)
        }
        if interactionAvailable && applied.windowOutputMode == "absolute", case let .window(id, owner) = target,
           inputRouter?.active != true {
            let router = ensureInputRouter()
            let outputID = outputScreen(for: applied.outputDisplayID).flatMap {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            }
            let outputBounds = outputID.map(CGDisplayBounds) ?? .null
            let preparing = LiveInputRouter.Context(sourcePID: owner, windowID: id, generation: capture.currentGeneration,
                config: processor.resolvedPlan.configVersion, epoch: 0, version: 0, relative: false,
                exclusions: [], sourceDisplays: interactionDisplayMappings())
            if !router.startBootstrap(preparing, controlWindowID: viewerControlsPanel?.windowNumber ?? 0, outputQuartz: outputBounds) {
                if router.reason == "bootstrap_buttons_down" {
                    if interactionGeometryWaitAt == 0 { interactionGeometryWaitAt = ProcessInfo.processInfo.systemUptime }
                    if ProcessInfo.processInfo.systemUptime - interactionGeometryWaitAt >= 3 { interactionArmed = false }
                    interactionFailure = "release_mouse_buttons"
                } else { interactionArmed = false; interactionFailure = router.reason }
                outputWindow?.orderOut(nil); viewerControlsPanel?.orderOut(nil); outputPreview.refreshVisibilitySnapshot()
                outputHiddenReason = "bootstrap_unavailable"; return
            }
        }
        let explicitViewer = TargetOverlayPolicy.activeWindowViewer(windowTarget: windowTarget,
            viewerSelected: applied.windowOutputMode == "viewer", viewerFollowOverride: viewerFollowOverride)
        let fullscreen = TargetOverlayPolicy.usesFullscreen(windowTarget: windowTarget, explicitViewer: explicitViewer,
            interactiveAvailable: interactionAvailable, diagnosticFullscreen: diagnosticFullscreen,
            legacyFullscreen: applied.outputFullscreen, viewerFollowOverride: viewerFollowOverride)
        let screenFrame = fullscreen ? outputScreen(for: applied.outputDisplayID)?.frame : nil
        let outputFrame = TargetOverlayPolicy.outputFrame(target: state.frame, fullscreen: fullscreen, display: screenFrame)
        let alignedInput = !windowTarget || diagnosticFullscreen || explicitViewer || TargetOverlayPolicy.windowInputAligned(viewMode: profile.viewMode)
        outputHiddenReason = !alignedInput ? "compare_not_input_aligned" : (!planActive ? "no_plan" : (!state.contentRectVerified ? "content_rect_unverified" : (outputFrame == nil ? "output_display_unavailable" : (outputWindow == nil ? "output_not_created" : "none"))))
        if !alignedInput {
            statusLabel.stringValue = EnhancementText.t("Comparison cannot align with source input; output hidden. Choose enhanced or original.", "对比画面无法与来源操作位置对齐，输出已隐藏；请选择增强或原始画面。")
            statusLabel.textColor = .systemOrange
        }
        if planActive && (!state.contentRectVerified || outputFrame == nil) && !targetGeometryWarned {
            targetGeometryWarned = true
            statusLabel.stringValue = outputFrame == nil
                ? EnhancementText.t("The selected output display is unavailable.", "所选输出显示器不可用。")
                : EnhancementText.t("Waiting for the target content position; output remains hidden.", "正在等待目标内容位置，增强画面暂时隐藏。")
            statusLabel.textColor = .systemOrange
        } else if state.contentRectVerified && outputFrame != nil { targetGeometryWarned = false }
        var hudFrame = state.frame
        if planActive && alignedInput && state.contentRectVerified, let frame = outputFrame, let panel = outputWindow {
            let followsWindow: Bool
            if case .window = target { followsWindow = !fullscreen }
            else { followsWindow = false }
            outputFollowsWindow = followsWindow
            // Fullscreen viewing already fills the output; avoid transparent-window composition.
            let opaque = interactionAvailable ? false : (explicitViewer || (windowTarget ? r7Flag("--odf-r7-opaque") : true))
            panel.isOpaque = opaque
            panel.backgroundColor = opaque ? .black : .clear
            outputPreview.layer?.isOpaque = opaque
            outputPreview.setFollowTargetContent(followsWindow)
            // A scaled fullscreen picture is not aligned with the source.
            // Absorb pointer input instead of misdirecting it underneath; the
            // aligned follow-window mode retains normal click-through.
            panel.ignoresMouseEvents = !fullscreen || (interactionAvailable && inputRouter?.ready == true)
            let diagnosticActivate = windowTarget && !interactionAvailable && r7Flag("--odf-r7-activate")
            if interactionAvailable {
                viewerActive = false; viewerReturnPID = nil
                (panel as? TargetPanel)?.viewerKeyboard = false
            }
            let enteringViewer = ((!windowTarget && fullscreen) || diagnosticActivate || explicitViewer) && !viewerActive
            if enteringViewer {
                viewerReturnPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                viewerActive = true
                (panel as? TargetPanel)?.viewerKeyboard = true
            } else if !fullscreen && !diagnosticActivate && viewerActive {
                viewerActive = false
                viewerReturnPID = nil
                (panel as? TargetPanel)?.viewerKeyboard = false
            }
            if (fullscreen || windowTarget), let controlsPanel = viewerControlsPanel, let controls = viewerControls {
                if let label = controls.arrangedSubviews.first as? NSTextField {
                    label.stringValue = interactionAvailable ? (inputRouter?.ready == true ? EnhancementText.t("Interaction · Ctrl+Option+Esc exits", "全屏交互 · Control+Option+Esc 退出") : EnhancementText.t("Preparing · Ctrl+Option+Esc exits", "正在准备交互 · Control+Option+Esc 退出")) : (diagnosticFullscreen ? EnhancementText.t("Diagnostic fullscreen · input blocked", "诊断全屏 · 输入已阻止") : (explicitViewer ? EnhancementText.t("Fullscreen viewer · input paused", "全屏观看 · 输入已暂停") : (windowTarget ? EnhancementText.t("Aligned to source · interactive", "按来源位置增强 · 可直接操作") : EnhancementText.t("Fullscreen viewer · input paused", "全屏预览 · 输入已暂停"))))
                }
                let fit = controls.fittingSize
                let width = min(frame.width - 24, max(220, fit.width))
                let height = max(40, fit.height)
                controlsPanel.setFrame(NSRect(x: frame.maxX - width - 12, y: frame.maxY - height - 12, width: width, height: height), display: true)
                if !controlsPanel.isVisible { controlsPanel.orderFrontRegardless() }
            } else { viewerControlsPanel?.orderOut(nil) }
            hudFrame = frame
            if panel.frame != frame { outputPreview.observeVerifiedWindowGeometry(nil); panel.setFrame(frame, display: true) }
            if !panel.isVisible {
                outputWarmupToken &+= 1
                panel.alphaValue = 0.001
                outputWarmupStartedAt = ProcessInfo.processInfo.systemUptime
                outputWarmupWarningShown = false
                processor.awaitOutputSurface(withToken: outputWarmupToken, minimumCaptureHost: outputMinimumCaptureHost)
                panel.orderFrontRegardless()
                recordPlanEvent("output_enter")
            }
            if enteringViewer {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
            if panel.alphaValue < 1 {
                outputHiddenReason = "warming"
                if !outputWarmupWarningShown && outputWarmupStartedAt > 0 && ProcessInfo.processInfo.systemUptime - outputWarmupStartedAt > 3 {
                    outputWarmupWarningShown = true
                    statusLabel.stringValue = EnhancementText.t("Output is not ready. Stop and try again, or choose another scaler.", "增强画面尚未准备好，请停止后重试或选择其他缩放方式。")
                    statusLabel.textColor = .systemOrange
                }
            }
        } else {
            outputPreview.observeVerifiedWindowGeometry(nil)
            if viewerActive { exitFullscreenViewer() }
            if outputWindow?.isVisible == true { outputWarmupToken &+= 1 }
            outputWindow?.orderOut(nil)
            viewerControlsPanel?.orderOut(nil)
        }
        let showTargetCountdown = countdown.active && !delayedWindowSelection && !startImmediatelyAfterPreparation && !sourceWindowPreparing
        if showTargetCountdown || fpsSwitch.state == .on {
            hudHiddenReason = "none"
            let (fpsPanel, countdownPanel) = ensureTargetHUD()
            if fpsSwitch.state == .on {
                let natural = targetFPS.fittingSize
                let width = min(max(80, hudFrame.width - 24), max(80, natural.width + 16))
                let cellHeight = targetFPS.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 16, height: 1000)).height ?? natural.height
                let height = max(30, cellHeight + 8)
                let fpsFrame = NSRect(x: hudFrame.minX + 12, y: hudFrame.maxY - height - 12, width: width, height: height)
                if fpsPanel.frame != fpsFrame { fpsPanel.setFrame(fpsFrame, display: true) }
                if !fpsPanel.isVisible { fpsPanel.orderFrontRegardless() }
            } else { fpsPanel.orderOut(nil) }
            if showTargetCountdown {
                let timerFrame = NSRect(x: hudFrame.midX - 41, y: hudFrame.midY - 41, width: 82, height: 82)
                if countdownPanel.frame != timerFrame { countdownPanel.setFrame(timerFrame, display: true) }
                if !countdownPanel.isVisible { countdownPanel.orderFrontRegardless() }
            } else { countdownPanel.orderOut(nil) }
            let requestedFPSVisible = fpsSwitch.state != .on || fpsPanel.isVisible
            let requestedCountdownVisible = !showTargetCountdown || countdownPanel.isVisible
            if !requestedFPSVisible || !requestedCountdownVisible { hudHiddenReason = "panel_not_visible" }
        } else { targetHUD?.orderOut(nil); targetCountdownHUD?.orderOut(nil); hudHiddenReason = "hud_disabled" }
        outputPreview.refreshVisibilitySnapshot()
        observeOutputGeometry(target: target, state: state, planActive: planActive, alignedInput: alignedInput)
        reconcileInputRouter(target: target, interactive: interactionAvailable)
        if interactionAvailable, let panel = outputWindow {
            let active = TargetOverlayPolicy.interactionCanPassThrough(available: interactionAvailable, routerActive: inputRouter?.ready == true)
            panel.ignoresMouseEvents = active
            setInteractionControlsPassthrough(active)
            if active, let label = viewerControls?.arrangedSubviews.first as? NSTextField {
                label.stringValue = EnhancementText.t("Interaction · Ctrl+Option+Esc exits", "全屏交互 · Control+Option+Esc 退出")
            }
        }
    }

    private func observeOutputGeometry(target: CaptureTarget, state: TargetWindowState, planActive: Bool, alignedInput: Bool) {
        if case let .window(id, _) = target, !state.observedWindowBounds.isNull,
           (geometryObservedWindow != id || geometryObservedGeneration != capture.currentGeneration || geometryObservedBounds != state.observedWindowBounds) {
            outputPreview.invalidateSharedGeometry()
            geometryObservedWindow = id; geometryObservedGeneration = capture.currentGeneration
            geometryObservedBounds = state.observedWindowBounds; geometryBoundsChangedHost = mach_absolute_time()
        }
        guard case let .window(id, owner) = target, let source = state.verifiedScreenRect,
              state.contentRectVerified, state.screenRectHost > geometryBoundsChangedHost,
              targetFrontmost, planActive, alignedInput, profile.viewMode != "compare",
              let panel = outputWindow, panel.isVisible, panel.alphaValue >= 0.99,
              outputPreview.drawableVisibleSnapshot, outputPreview.exposedSnapshot,
              let screen = panel.screen,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
              displayID != 0, lastStatsReceipt > 0, ProcessInfo.processInfo.systemUptime - lastStatsReceipt < 1.5,
              (lastStats["snapshotStale"] as? Bool) != true,
              (lastStats["sourceGeneration"] as? NSNumber)?.uint64Value == capture.currentGeneration,
              (lastStats["configVersion"] as? NSNumber)?.uint64Value == processor.resolvedPlan.configVersion,
              let epoch = (lastStats["measurementEpoch"] as? NSNumber)?.uint64Value, epoch > 0 else {
            outputPreview.observeVerifiedWindowGeometry(nil); return
        }
        func rect(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
        outputPreview.observeVerifiedWindowGeometry(["generation": capture.currentGeneration, "windowID": id, "pid": owner,
            "config": processor.resolvedPlan.configVersion, "epoch": epoch, "displayID": displayID,
            "screenRect": rect(source), "windowBounds": rect(state.observedWindowBounds),
            "panelFrame": rect(panel.frame), "displayFrame": rect(screen.frame),
            "displayBoundsQuartz": rect(CGDisplayBounds(displayID)),
            "backingScale": panel.backingScaleFactor, "verified": true])
    }

    private func excludedIDs() -> [Int] {
        [window?.windowNumber, outputWindow?.windowNumber, targetHUD?.windowNumber, targetCountdownHUD?.windowNumber, viewerControlsPanel?.windowNumber].compactMap { $0 }.filter { $0 > 0 } + screenCountdownPanels.map(\.windowNumber)
    }

    private func applyAppearance() {
        let name: NSAppearance.Name
        switch profile.appearance {
        case "light": name = .aqua
        case "dark": name = .darkAqua
        default:
            name = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .darkAqua : .aqua
        }
        window?.appearance = NSAppearance(named: name)
        settingsWindow?.appearance = NSAppearance(named: name)
        experimentComparisonPanel?.window?.appearance = NSAppearance(named: name)
    }

    @discardableResult private func saveCurrentProfile() -> Bool {
        do {
            try EnhancementProfileStore.saveCurrent(profile)
            return true
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
            return false
        }
    }

    private func persist() {
        _ = saveCurrentProfile()
    }

    func windowWillClose(_ notification: Notification) {
#if ODF_AIR_BETA_DIAGNOSTIC
        if Self.betaSessionRecordingEnabled { finishBetaSession(reason: "window_close") {}; return }
#endif
        stop()
    }
}
