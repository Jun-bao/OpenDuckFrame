import AppKit
@preconcurrency import ApplicationServices
import CoreVideo
import Darwin
@preconcurrency import ScreenCaptureKit

extension Notification.Name {
    static let khuaMotionPlusChanged = Notification.Name("khua.motionPlusChanged")
}

@MainActor enum EnhancementText {
    static let languageKey = "KhuaWorkbenchLanguage"
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
    static func runtime(_ value: String) -> String {
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
    mutating func begin() -> UInt64? {
        guard !active else { return nil }
        token &+= 1; remaining = 3; return token
    }
    mutating func cancel() { token &+= 1; remaining = 0 }
    mutating func tick(_ candidate: UInt64) -> Int? {
        guard active, candidate == token else { return nil }
        remaining -= 1
        return remaining
    }
}

enum FPSPreference {
    private static let key = "KhuaShowFPS"
    static func enabled(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }
    static func set(_ value: Bool, in defaults: UserDefaults) { defaults.set(value, forKey: key) }
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
    static func usesFullscreen(windowTarget: Bool, explicitViewer: Bool, interactiveAvailable: Bool,
                               diagnosticFullscreen: Bool, legacyFullscreen: Bool, viewerFollowOverride: Bool) -> Bool {
        diagnosticFullscreen || (windowTarget && (explicitViewer || interactiveAvailable)) ||
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
        switch index {
        case 1: return ("apple.lowlatency", "vt.llfi.temporal")
        case 2: return ("rife.metal", "rife-v4.25")
        case 3: return ("rife.metal", "rife-v4.26")
        case 4: return ("distildrba.coreml", "distildrba.v1.720p")
        default: return ("apple.frc", quality == "quality" ? "vt.frc.quality" : "vt.frc.normal")
        }
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
    var interpolationEnabled = false
    var interpolationEngineID = "apple.frc"
    var interpolationQuality = "normal"
    var rifeStreamEnabled = false
    var rate = RateRequest.multiplier(2)
    var scaleEnabled = false
    var scaleEngineID = "lanczos"
    var scaleQualityID = "none"
    var outputWidth = 1920
    var outputHeight = 1080
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
    var modelID = "vt.frc.normal"
    var recents: [RecentEnhancementSource] = []
}

enum EnhancementProfileStore {
    // Set only by the isolated, single-threaded store contract executable.
    nonisolated(unsafe) static var testDirectory: URL?
    static func fileURL() -> URL {
        if let testDirectory { return testDirectory.appendingPathComponent("EnhancementProfile.json") }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Khua/EnhancementProfile.json")
    }

    static func decode(_ data: Data, fallbackName: String) -> EnhancementProfile? {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if object["rifeStreamEnabled"] == nil { object["rifeStreamEnabled"] = false }
        if object["captureLimit"] == nil { object["captureLimit"] = "auto" }
        if !["follow", "viewer", "absolute", "relative"].contains(object["windowOutputMode"] as? String ?? "") { object["windowOutputMode"] = "follow" }
        if object["configName"] == nil { object["configName"] = fallbackName }
        if object["scaleQualityID"] == nil { object["scaleQualityID"] = "none" }
        if object["modelID"] == nil {
            let engine = object["interpolationEngineID"] as? String ?? "apple.frc"
            let quality = object["interpolationQuality"] as? String ?? "normal"
            if engine == "rife.metal" { object["modelID"] = "rife-v4.25" }
            else if engine == "apple.lowlatency" { object["modelID"] = "vt.llfi.temporal" }
            else { object["modelID"] = quality == "quality" ? "vt.frc.quality" : "vt.frc.normal" }
        }
        guard let normalized = try? JSONSerialization.data(withJSONObject: object),
              let profile = try? JSONDecoder().decode(EnhancementProfile.self, from: normalized),
              profile.schemaVersion == 1 else { return nil }
        return profile
    }

    static func load() -> EnhancementProfile {
        guard let data = try? Data(contentsOf: fileURL()), let profile = decode(data, fallbackName: "默认"),
              profile.soundMode == "sourceApplication" else { return EnhancementProfile() }
        return profile
    }

    static func save(_ profile: EnhancementProfile) throws {
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

    static let presets: [(id: String, name: String, english: String, symbol: String)] = [
        ("preset:default", "默认", "Default", "doc.text"),
        ("preset:native", "原生画质 X2", "Native quality X2", "viewfinder"),
        ("preset:game", "游戏", "Game", "gamecontroller"),
        ("preset:film", "电影", "Film", "film"),
        ("preset:anime", "动画", "Animation", "photo"),
    ]

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
        guard presets.contains(where: { $0.id == id }) else { throw CocoaError(.fileWriteInvalidFileName) }
        let dir = presetDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(profile).write(to: dir.appendingPathComponent(String(id.dropFirst(7)) + ".json"), options: .atomic)
    }

    static func loadPreset(_ id: String) -> EnhancementProfile? {
        guard let preset = presets.first(where: { $0.id == id }),
              let data = try? Data(contentsOf: presetDirectory().appendingPathComponent(String(id.dropFirst(7)) + ".json")) else { return nil }
        return decode(data, fallbackName: preset.name)
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
                throw NSError(domain: "Khua.ConfigRename", code: 1, userInfo: [NSLocalizedDescriptionKey: "重命名未完成，回退也失败；请检查 \(newURL.path)：\(rollback.localizedDescription)"])
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
        profile.scaleEngineID = "metalfx.spatial"
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
    profile.interpolationEngineID = "apple.frc"
    profile.interpolationQuality = "quality"
    profile.modelID = "vt.frc.quality"
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
        isolated && args.contains("--khua-p0-controls")
    }
    static func flag(_ name: String, args: [String], isolated: Bool, overrideValue: Bool?) -> Bool {
        guard isolated else { return false }
        if controlsEnabled(args: args, isolated: isolated), let overrideValue { return overrideValue }
        return args.contains(name)
    }
}

enum WorkbenchTitle {
    static func text(_ base: String, candidate: String) -> String {
        let label = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return base + (label.isEmpty ? "" : " · " + label)
    }
}

final class EnhancementWorkbenchController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// Capture callbacks call only the processor's queueing entry points.
    private final class CaptureProcessorSink: @unchecked Sendable {
        let processor: SPLiveProcessor
        init(_ processor: SPLiveProcessor) { self.processor = processor }
    }
    static let shared = EnhancementWorkbenchController()

    private final class WorkbenchWindow: NSWindow {
        var beforeMouseDown: ((NSEvent) -> Void)?
        override func sendEvent(_ event: NSEvent) {
            if event.type == .leftMouseDown { beforeMouseDown?(event) }
            super.sendEvent(event)
        }
    }

    private let processor = SPLiveProcessor()
    private let capture = WindowCaptureSource()
    private let preview = SPLivePreviewView(frame: .zero)
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
    private let statsLabel = NSTextField(labelWithString: "")
    private let budgetLabel = NSTextField(labelWithString: "")
    private let planLabel = NSTextField(wrappingLabelWithString: "")
    private let sizeChainLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let fileLimitLabel = NSTextField(wrappingLabelWithString: "")
    private let interpolationSwitch = NSSwitch()
    private let rifeStreamCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
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
    private var appleSRLibraryButton: NSButton?
    private var appleVideoSRLibraryButton: NSButton?
    private var anime4KLibraryButton: NSButton?
    private var cuganLibraryButton: NSButton?
    private var appleSRCapabilityKey = ""
    private var appleSRCandidate = false
    private var appleVideoSRCandidate = false
    private var appleVideoSRFactor = 4
    private var anime4KCandidate = false
    private var cuganCandidate = false
    private let sizePopup = NSPopUpButton()
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private var dimensionEditOriginal: [ObjectIdentifier: String] = [:]
    private let displayPopup = NSPopUpButton()
    private let fullscreenCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let windowOutputPopup = NSPopUpButton()
    private let interactionStateLabel = NSTextField(wrappingLabelWithString: "")
    private let inputMonitoringButton = NSButton()
    private let accessibilityButton = NSButton()
    private let eventAccessButton = NSButton()
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
    private let previewFPS = NSTextField(labelWithString: "")
    private let outputFPS = NSTextField(labelWithString: "")
    private var lastStatsReceipt: TimeInterval = 0
    private var fpsCanObserve = false
    private var fpsOutputObservable = false
    private let viewMode = NSSegmentedControl(labels: ["E", "O", "C"], trackingMode: .selectOne, target: nil, action: nil)
    private let appearanceControl = NSSegmentedControl(labels: ["S", "L", "D"], trackingMode: .selectOne, target: nil, action: nil)
    private let languageControl = NSSegmentedControl(labels: ["中文", "English"], trackingMode: .selectOne, target: nil, action: nil)
    private let configRows = NSStackView()
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
        let overrideValue = flag == "--khua-r7-opaque" ? p0OpaqueOverride : (flag == "--khua-r7-activate" ? p0ActivateOverride : nil)
        return P0DiagnosticPolicy.flag(flag, args: CommandLine.arguments, isolated: r7Diagnostics, overrideValue: overrideValue)
    }
    private let shareStack = NSStackView()
    private let diagnosticLabel = NSTextField(labelWithString: "")
    private let sourceStripLabel = NSTextField(labelWithString: "")
    private let sourceMetaLabel = NSTextField(labelWithString: "")
    private var startButton: NSButton?
    private var stopButton: NSButton?
    private var pauseButton: NSButton?
    private var sourceActionButton: NSButton?
    private var emptySourceButton: NSButton?
    private var activeSourceTitle = ""
    private var activeSourceKind = ""
    private var activeSourceBundle = ""
    private let stageHost = NSView()
    private let sourceHost = NSView()
    private let libraryHost = NSView()
    private let enginePopup = NSPopUpButton()
    private let sourceKindControl = NSSegmentedControl(labels: ["窗口", "显示器", "视频文件"], trackingMode: .selectOne, target: nil, action: nil)
    private let phaseLabel = NSTextField(wrappingLabelWithString: "")
    private let compatibilityButton = NSButton(title: "改用 Apple 帧率转换", target: nil, action: nil)
    private let emptyOverlay = NSView()
    private var navButtons: [NSButton] = []
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
    private weak var renameRow: NSButton?
    private var renameOriginalTitle = ""
    private var countdown = EnhancementCountdown()
    private var countdownTimer: Timer?
    private var countdownSourceGeneration: UInt64?
    private let previewCountdown = NSTextField(labelWithString: "")
    private let outputCountdown = NSTextField(labelWithString: "")

    private struct SCWindowBox { var title: String; var bundle: String; var window: Any }
    private struct SCDisplayBox { var title: String; var display: Any }

    private init() {
        let window = WorkbenchWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        let candidate = (Bundle.main.object(forInfoDictionaryKey: "SPCandidateLabel") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        window.title = WorkbenchTitle.text(EnhancementText.t("Quality Workbench", "画质工作台"), candidate: candidate)
        window.minSize = NSSize(width: 1100, height: 760)
        super.init(window: window)
        profile.configID = EnhancementProfileStore.resolvedID(profile)
        window.delegate = self
        window.contentView = build()
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
        for (host, label) in [(preview, previewCountdown), (outputPreview, outputCountdown)] {
            label.font = .systemFont(ofSize: 42, weight: .bold)
            label.textColor = .white
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            label.layer?.cornerRadius = 14
            label.isHidden = true
            label.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                label.widthAnchor.constraint(equalToConstant: 80),
                label.heightAnchor.constraint(equalToConstant: 66),
            ])
        }
    }

    private func installFPSLabels() {
        for (host, label) in [(preview, previewFPS), (outputPreview, outputFPS)] {
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
        let endpointVisible = outputPreview.windowVisibleSnapshot
            ? (outputPreview.drawableVisibleSnapshot && outputPreview.exposedSnapshot)
            : (preview.drawableVisibleSnapshot && preview.exposedSnapshot)
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
        for label in [previewFPS, targetFPS] {
            label.stringValue = text
        }
        if !isFile && outputWarmupWarningShown && outputWindow?.isVisible == true && (outputWindow?.alphaValue ?? 1) < 1 {
            targetFPS.stringValue += EnhancementText.t(" · Not ready", " · 未就绪")
        }
        previewFPS.superview?.isHidden = !enabled || isFile
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
        let text = countdown.active ? "\(countdown.remaining)" : ""
        for label in [previewCountdown, outputCountdown] {
            label.stringValue = text
            label.isHidden = !countdown.active
        }
        outputCountdown.isHidden = true
        targetCountdown.stringValue = text
        targetCountdown.isHidden = !countdown.active
        let selected = profile.sourceKind == "file" ? selectedFilePlayer() : nil
        for player in NSApp.windows.compactMap({ $0.contentViewController as? PlayerViewController }) {
            player.setWorkbenchCountdown(text, enabled: countdown.active && player === selected)
        }
        if countdown.active { startButton?.title = text }
        else { refreshActions() }
    }

    private func cancelCountdown() {
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
        guard countdown.active else { return }
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
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        startLiveLogIfNeeded()
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

    private func build() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        let sidebar = glass()
        let inspector = glass()
        let bottom = glass()
        let strip = glass()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        inspector.translatesAutoresizingMaskIntoConstraints = false
        bottom.translatesAutoresizingMaskIntoConstraints = false
        strip.translatesAutoresizingMaskIntoConstraints = false
        stageHost.translatesAutoresizingMaskIntoConstraints = false
        sourceHost.translatesAutoresizingMaskIntoConstraints = false
        libraryHost.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        root.addSubview(stageHost)
        root.addSubview(sourceHost)
        root.addSubview(libraryHost)

        let brand = NSTextField(labelWithString: EnhancementText.t("OpenDuckFrame", "OpenDuckFrame"))
        brand.font = .systemFont(ofSize: 20, weight: .bold)
        brand.textColor = .labelColor
        let brandSub = NSTextField(labelWithString: EnhancementText.t("Quality", "画质"))
        brandSub.identifier = NSUserInterfaceItemIdentifier("brand-quality")
        brandSub.font = .systemFont(ofSize: 13, weight: .medium)
        brandSub.textColor = .secondaryLabelColor
        navButtons = [
            navButton(EnhancementText.t("Workbench", "工作台"), "rectangle.inset.filled", #selector(showStage)),
            navButton(EnhancementText.t("Input", "输入源"), "macwindow", #selector(showSourcePage)),
            navButton(EnhancementText.t("Technology Library", "技术库"), "books.vertical", #selector(showLibrary)),
        ]
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged)
        languageControl.target = self
        languageControl.action = #selector(languageChanged)
        let sideStack = NSStackView()
        sideStack.orientation = .vertical
        sideStack.alignment = .leading
        sideStack.spacing = 10
        sideStack.addArrangedSubview(brand)
        sideStack.addArrangedSubview(brandSub)
        sideStack.addArrangedSubview(navButtons[0])
        sideStack.addArrangedSubview(navButtons[1])
        sideStack.addArrangedSubview(navButtons[2])
        if p0ControlsEnabled {
            let opaque = NSButton(title: "", target: self, action: #selector(toggleP0OpaqueFromMain))
            let focus = NSButton(title: "", target: self, action: #selector(toggleP0ActivationFromMain))
            let cap = NSButton(title: "", target: self, action: #selector(toggleP0CaptureCapFromMain))
            opaque.identifier = NSUserInterfaceItemIdentifier("p0.main.opaque")
            focus.identifier = NSUserInterfaceItemIdentifier("p0.main.focus")
            cap.identifier = NSUserInterfaceItemIdentifier("p0.main.capture")
            for item in [opaque, focus, cap] { item.bezelStyle = .rounded; sideStack.addArrangedSubview(item) }
            p0MainOpaqueButton = opaque; p0MainActivateButton = focus; p0MainCaptureButton = cap
            refreshP0ControlTitles()
        }
        sideStack.addArrangedSubview(heading(EnhancementText.t("Configs", "配置")))
        configRows.orientation = .vertical
        configRows.alignment = .leading
        configRows.spacing = 4
        configRows.widthAnchor.constraint(equalToConstant: 168).isActive = true
        sideStack.addArrangedSubview(configRows)
        let upper = scrolled(sideStack, inset: 0)
        let footer = NSStackView()
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addArrangedSubview(heading(EnhancementText.t("Language", "语言")))
        footer.addArrangedSubview(languageControl)
        footer.addArrangedSubview(heading(EnhancementText.t("Appearance", "外观")))
        footer.addArrangedSubview(appearanceControl)
        languageControl.widthAnchor.constraint(equalToConstant: 168).isActive = true
        appearanceControl.widthAnchor.constraint(equalToConstant: 168).isActive = true
        languageControl.selectedSegment = EnhancementText.chinese ? 0 : 1
        sidebar.content.addSubview(upper)
        sidebar.content.addSubview(footer)
        NSLayoutConstraint.activate([
            upper.leadingAnchor.constraint(equalTo: sidebar.content.leadingAnchor, constant: 12),
            upper.trailingAnchor.constraint(equalTo: sidebar.content.trailingAnchor, constant: -12),
            upper.topAnchor.constraint(equalTo: sidebar.content.topAnchor, constant: 12),
            upper.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: sidebar.content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: sidebar.content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: sidebar.content.bottomAnchor, constant: -12),
        ])

        let title = NSTextField(labelWithString: EnhancementText.t("Quality Workbench", "画质工作台"))
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.textColor = .labelColor
        sourceKindControl.target = self
        sourceKindControl.action = #selector(sourceKindChanged)
        sourceKindControl.setLabel(EnhancementText.t("Window", "窗口"), forSegment: 0)
        sourceKindControl.setLabel(EnhancementText.t("Display", "显示器"), forSegment: 1)
        sourceKindControl.setLabel(EnhancementText.t("Video File", "视频文件"), forSegment: 2)
        sourceKindControl.segmentDistribution = .fillEqually
        sourceKindControl.translatesAutoresizingMaskIntoConstraints = false
        sourceKindControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        sourceStripLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        sourceStripLabel.textColor = .labelColor
        sourceStripLabel.lineBreakMode = .byTruncatingTail
        sourceStripLabel.stringValue = EnhancementText.t("None selected", "未选择")
        sourceMetaLabel.font = .systemFont(ofSize: 12)
        sourceMetaLabel.textColor = .secondaryLabelColor
        sourceMetaLabel.stringValue = ""
        let sourceText = NSStackView()
        sourceText.orientation = .vertical
        sourceText.alignment = .leading
        sourceText.spacing = 1
        sourceText.addArrangedSubview(sourceStripLabel)
        sourceText.addArrangedSubview(sourceMetaLabel)
        let stripColumn = NSStackView()
        stripColumn.orientation = .vertical
        stripColumn.alignment = .leading
        stripColumn.spacing = 8
        stripColumn.addArrangedSubview(sourceKindControl)
        let stripRow = NSStackView()
        stripRow.orientation = .horizontal
        stripRow.alignment = .centerY
        stripRow.spacing = 8
        sourceText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stripRow.addArrangedSubview(sourceText)
        let stripSpacer = NSView()
        stripSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stripRow.addArrangedSubview(stripSpacer)
        let chooseSource = button(EnhancementText.t("Change", "更换"), #selector(chooseCurrentKind))
        sourceActionButton = chooseSource
        stripRow.addArrangedSubview(chooseSource)
        stripColumn.addArrangedSubview(stripRow)
        sourceKindControl.widthAnchor.constraint(equalTo: stripColumn.widthAnchor).isActive = true
        stripRow.widthAnchor.constraint(equalTo: stripColumn.widthAnchor).isActive = true
        fill(strip.content, with: stripColumn)

        let well = NSView()
        well.wantsLayer = true
        well.layer?.backgroundColor = NSColor.black.cgColor
        well.layer?.cornerRadius = 16
        well.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(preview)
        emptyOverlay.translatesAutoresizingMaskIntoConstraints = false
        emptyOverlay.wantsLayer = true
        let emptyTitle = NSTextField(labelWithString: EnhancementText.t("Choose a source to preview", "选择来源后在这里预览"))
        emptyTitle.font = .systemFont(ofSize: 18, weight: .semibold)
        emptyTitle.textColor = .white
        let emptyButton = button(EnhancementText.t("Choose Window", "选择窗口"), #selector(chooseCurrentKind), primary: true)
        emptySourceButton = emptyButton
        let emptyStack = NSStackView()
        emptyStack.orientation = .vertical
        emptyStack.alignment = .centerX
        emptyStack.spacing = 12
        emptyStack.addArrangedSubview(emptyTitle)
        emptyStack.addArrangedSubview(emptyButton)
        emptyOverlay.addSubview(emptyStack)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(emptyOverlay)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            preview.topAnchor.constraint(equalTo: well.topAnchor),
            preview.bottomAnchor.constraint(equalTo: well.bottomAnchor),
            emptyStack.centerXAnchor.constraint(equalTo: emptyOverlay.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyOverlay.centerYAnchor),
            emptyOverlay.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            emptyOverlay.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            emptyOverlay.topAnchor.constraint(equalTo: well.topAnchor),
            emptyOverlay.bottomAnchor.constraint(equalTo: well.bottomAnchor),
        ])

        let inspectorScroll = scrolled(inspectorColumn())
        inspector.content.addSubview(inspectorScroll)
        NSLayoutConstraint.activate([
            inspectorScroll.leadingAnchor.constraint(equalTo: inspector.content.leadingAnchor),
            inspectorScroll.trailingAnchor.constraint(equalTo: inspector.content.trailingAnchor),
            inspectorScroll.topAnchor.constraint(equalTo: inspector.content.topAnchor),
            inspectorScroll.bottomAnchor.constraint(equalTo: inspector.content.bottomAnchor),
        ])
        let outputCard = glass()
        outputCard.translatesAutoresizingMaskIntoConstraints = false
        let outputRow = NSStackView()
        outputRow.orientation = .horizontal
        outputRow.alignment = .centerY
        outputRow.spacing = 8
        outputRow.addArrangedSubview(heading(EnhancementText.t("Output", "输出")))
        outputRow.addArrangedSubview(displayPopup)
        outputRow.addArrangedSubview(fullscreenCheck)
        let fpsRow = NSStackView()
        fpsRow.orientation = .horizontal
        fpsRow.alignment = .centerY
        fpsRow.spacing = 4
        fpsRow.addArrangedSubview(NSTextField(labelWithString: EnhancementText.t("Show FPS", "显示帧率")))
        fpsRow.addArrangedSubview(fpsSwitch)
        fpsSwitch.state = FPSPreference.enabled(in: .standard) ? .on : .off
        fpsSwitch.target = self
        fpsSwitch.action = #selector(fpsVisibilityChanged)
        outputRow.addArrangedSubview(fpsRow)
        fill(outputCard.content, with: outputRow)
        viewMode.translatesAutoresizingMaskIntoConstraints = false
        viewMode.segmentDistribution = .fillEqually
        viewMode.appearance = NSAppearance(named: .darkAqua)
        well.addSubview(viewMode)
        NSLayoutConstraint.activate([
            viewMode.widthAnchor.constraint(equalToConstant: 240),
            viewMode.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            viewMode.bottomAnchor.constraint(equalTo: well.bottomAnchor, constant: -12),
        ])
        fill(bottom.content, with: bottomBar())
        stageHost.addSubview(title)
        stageHost.addSubview(outputCard)
        stageHost.addSubview(strip)
        stageHost.addSubview(well)
        stageHost.addSubview(inspector)
        stageHost.addSubview(bottom)
        title.translatesAutoresizingMaskIntoConstraints = false

        let sourceScroll = scrolled(sourceColumn())
        sourceHost.addSubview(sourceScroll)
        let libraryScroll = scrolled(libraryColumn())
        libraryHost.addSubview(libraryScroll)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            stageHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
            stageHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stageHost.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            stageHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
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
            title.leadingAnchor.constraint(equalTo: stageHost.leadingAnchor),
            title.topAnchor.constraint(equalTo: stageHost.topAnchor),
            strip.leadingAnchor.constraint(equalTo: stageHost.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -12),
            strip.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            strip.heightAnchor.constraint(equalToConstant: 92),
            inspector.trailingAnchor.constraint(equalTo: stageHost.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            inspector.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -12),
            inspector.widthAnchor.constraint(equalToConstant: 320),
            well.leadingAnchor.constraint(equalTo: stageHost.leadingAnchor),
            well.trailingAnchor.constraint(equalTo: inspector.leadingAnchor, constant: -12),
            well.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 12),
            well.heightAnchor.constraint(equalTo: well.widthAnchor, multiplier: 9.0 / 16.0),
            outputCard.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            outputCard.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            outputCard.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 8),
            outputCard.heightAnchor.constraint(equalToConstant: 64),
            outputCard.bottomAnchor.constraint(lessThanOrEqualTo: bottom.topAnchor, constant: -8),
            bottom.leadingAnchor.constraint(equalTo: stageHost.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: stageHost.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: stageHost.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: 72),
        ])
        showPage(0)
        rebuildConfigRows()
        return root
    }

    private final class Plate: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 14
            layer?.borderWidth = 1
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
                layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
                layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }
    }

    private final class GlassBox: NSView {
        let content = NSView()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 16
            content.translatesAutoresizingMaskIntoConstraints = false
            content.wantsLayer = true
            content.layer?.cornerRadius = 12
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.translatesAutoresizingMaskIntoConstraints = false
                glass.cornerRadius = 16
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
            var plate = NSColor.textBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                plate = NSColor.textBackgroundColor
            }
            content.layer?.backgroundColor = plate.cgColor
            content.layer?.borderWidth = 1
            content.layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.shadowColor = NSColor.shadowColor.cgColor
            layer?.shadowOpacity = 0.16
            layer?.shadowRadius = 12
            layer?.shadowOffset = CGSize(width: 0, height: 4)
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
            "Window, display, or a video file. A capture card is just that app's preview window.",
            "窗口、显示器或视频文件。采集卡就是那个软件自己的预览窗口。"))
        subtitle.preferredMaxLayoutWidth = 640
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.spacing = 12
        cards.addArrangedSubview(sourceCard(EnhancementText.t("Window", "窗口"), EnhancementText.t("Choose an app window to enhance.", "选择想要增强的应用窗口。"), #selector(chooseWindow)))
        cards.addArrangedSubview(sourceCard(EnhancementText.t("Display", "显示器"), EnhancementText.t("Capture one display, excluding this app.", "捕获一块显示器，排除本应用。"), #selector(chooseDisplay)))
        cards.addArrangedSubview(sourceCard(EnhancementText.t("Video File", "视频文件"), EnhancementText.t("Open a video in the player to use supported file enhancement.", "在播放器中打开视频，使用支持的文件增强。"), #selector(chooseFile)))
        stack.addArrangedSubview(cards)
        stack.addArrangedSubview(heading(EnhancementText.t("Current source", "当前来源")))
        captureCapPopup.removeAllItems()
        captureCapPopup.addItems(withTitles: [EnhancementText.t("Auto", "自动"), "30", "60"])
        captureCapPopup.target = self
        captureCapPopup.action = #selector(captureCapChanged)
        stack.addArrangedSubview(heading(EnhancementText.t("Input capture cap (FPS)", "输入采集上限（FPS）")))
        stack.addArrangedSubview(captureCapPopup)
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
        func column() -> NSStackView {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            return stack
        }
        func card(_ content: NSStackView) -> NSView {
            let plate = Plate()
            content.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 12),
                content.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -12),
                content.topAnchor.constraint(equalTo: plate.topAnchor, constant: 12),
                content.bottomAnchor.constraint(equalTo: plate.bottomAnchor, constant: -12),
            ])
            return plate
        }
        func cardHeader(_ title: String, _ toggle: NSView) -> NSView {
            let header = NSStackView()
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 8
            header.addArrangedSubview(NSTextField(labelWithString: title))
            header.addArrangedSubview(toggle)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            header.addArrangedSubview(spacer)
            return header
        }
        let scale = column()
        scale.addArrangedSubview(cardHeader(EnhancementText.t("Scale", "缩放 / 超分"), scaleSwitch))
        scale.addArrangedSubview(row(EnhancementText.t("Technology", "技术"), scalePopup))
        let qualityRow = row(EnhancementText.t("Denoising", "降噪"), scaleQualityPopup)
        scaleQualityRow = qualityRow
        scale.addArrangedSubview(qualityRow)
        scale.addArrangedSubview(row(EnhancementText.t("Output size", "输出尺寸"), sizePopup))
        scale.addArrangedSubview(row("W×H", pair(widthField, heightField)))

        let frames = column()
        frames.addArrangedSubview(cardHeader(EnhancementText.t("Frame generation", "帧生成"), interpolationSwitch))
        frames.addArrangedSubview(row(EnhancementText.t("Engine", "引擎"), enginePopup))
        let frameQuality = row(EnhancementText.t("Quality", "质量"), qualityPopup)
        interpolationQualityRow = frameQuality
        frames.addArrangedSubview(frameQuality)
        frames.addArrangedSubview(rifeStreamCheck)
        phaseLabel.maximumNumberOfLines = 4
        phaseLabel.textColor = .secondaryLabelColor
        phaseLabel.preferredMaxLayoutWidth = 220
        frames.addArrangedSubview(phaseLabel)
        compatibilityButton.target = self
        compatibilityButton.action = #selector(useFrameRateConversion)
        frames.addArrangedSubview(compatibilityButton)
        frames.addArrangedSubview(rateMode)
        frames.addArrangedSubview(fpsPopup)
        let customRate = row("n/d", pair(fpsNum, fpsDen))
        customRateRow = customRate
        frames.addArrangedSubview(customRate)
        frames.addArrangedSubview(multiplierControl)
        let interaction = column()
        interaction.addArrangedSubview(heading(EnhancementText.t("Window output", "窗口输出")))
        windowOutputPopup.addItems(withTitles: [EnhancementText.t("Follow source", "跟随来源"),
            EnhancementText.t("Fullscreen viewer", "全屏观看"), EnhancementText.t("Fullscreen interaction · pointer", "全屏交互 · 指针"),
            EnhancementText.t("Fullscreen interaction · relative", "全屏交互 · 相对输入")])
        windowOutputPopup.target = self
        windowOutputPopup.action = #selector(interactionModeChanged)
        interaction.addArrangedSubview(windowOutputPopup)
        interactionStateLabel.maximumNumberOfLines = 4
        interactionStateLabel.textColor = .secondaryLabelColor
        interaction.addArrangedSubview(interactionStateLabel)
        for (button, title, action) in [
            (inputMonitoringButton, EnhancementText.t("Input Monitoring…", "输入监听设置…"), #selector(requestInputMonitoring)),
            (accessibilityButton, EnhancementText.t("Accessibility…", "辅助功能设置…"), #selector(requestAccessibility)),
            (eventAccessButton, EnhancementText.t("Request event access…", "请求事件访问…"), #selector(requestEventAccess))
        ] {
            button.title = title; button.target = self; button.action = action
            button.isHidden = true
            interaction.addArrangedSubview(button)
        }
        phaseLabel.stringValue = ""
        for column in [scale, frames, interaction] {
            for item in column.arrangedSubviews {
                item.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        let scaleCard = card(scale)
        let framesCard = card(frames)
        let interactionCard = card(interaction)
        stack.addArrangedSubview(scaleCard)
        stack.addArrangedSubview(framesCard)
        stack.addArrangedSubview(interactionCard)
        NSLayoutConstraint.activate([
            scaleCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            framesCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            interactionCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return stack
    }

    private func bottomBar() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let pause = button(EnhancementText.t("Pause", "暂停"), #selector(pause))
        pauseButton = pause
        let again = button(EnhancementText.t("Choose Again", "重选"), #selector(reselect))
        let start = button(EnhancementText.t("Start Enhancement", "开始增强"), #selector(start), primary: true)
        let stop = button(EnhancementText.t("Stop", "停止"), #selector(stop), primary: true)
        startButton = start
        stopButton = stop
        stop.isHidden = true
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        planLabel.maximumNumberOfLines = 2
        planLabel.textColor = .secondaryLabelColor
        planLabel.preferredMaxLayoutWidth = 520
        let statusColumn = NSStackView()
        statusColumn.orientation = .vertical
        statusColumn.alignment = .leading
        statusColumn.spacing = 1
        statusColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusColumn.addArrangedSubview(statusLabel)
        for label in [statsLabel, budgetLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            statusColumn.addArrangedSubview(label)
        }
        for label in [statusLabel, statsLabel, budgetLabel] {
            label.widthAnchor.constraint(lessThanOrEqualTo: statusColumn.widthAnchor).isActive = true
        }
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.addArrangedSubview(statusColumn)
        row.addArrangedSubview(NSView())
        buttons.addArrangedSubview(pause)
        buttons.addArrangedSubview(again)
        buttons.addArrangedSubview(start)
        buttons.addArrangedSubview(stop)
        row.addArrangedSubview(buttons)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func navButton(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let button = ConfigNavButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.bezelStyle = .rounded
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 168).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        button.cell?.lineBreakMode = .byTruncatingTail
        button.toolTip = title
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        return button
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
            EnhancementText.t("Apple frame-rate conversion", "Apple 帧率转换"),
            EnhancementText.t("General video · Normal or Quality. Quality uses more resources.", "适合通用视频 · 标准与质量两档。质量档资源开销更高。"),
            "apple.frc", enabled: true))
        stack.addArrangedSubview(libraryRow(
            EnhancementText.t("Apple low-latency interpolation", "Apple 低延迟插帧"),
            EnhancementText.t("Experimental. X2 and X4 only. Fixed frame rates use frame-rate conversion instead.", "实验。只开放 X2 和 X4。固定帧率请改用帧率转换。"),
            "apple.lowlatency", enabled: true))
        stack.addArrangedSubview(libraryRow(
            "RIFE Metal 4.25",
            EnhancementText.t("Available for ordinary 8-bit video. fast is the checked tier. balanced and hq stay experimental.", "可用于普通 8 位画面。fast 是已核对的档位，balanced 和 hq 仍是实验。"),
            "rife.metal|rife-v4.25", enabled: true))
        stack.addArrangedSubview(libraryRow(
            "RIFE 4.26",
            EnhancementText.t("Experimental separate model, packaged with the app. It is not a renamed 4.25.", "实验。随应用打包的独立模型，不是 4.25 换名。"),
            "rife.metal|rife-v4.26", enabled: true))
        stack.addArrangedSubview(libraryRow("DistilDRBA", EnhancementText.t("Experimental animation interpolation for 720p, X2. Uses three consecutive frames.", "实验性动画插帧，支持 720p、X2，需要连续三帧。"), "distildrba.coreml", enabled: SPDistilDRBA.isPackagedForThisSystem(), unavailableStatus: EnhancementText.t("Model missing", "缺少模型")))
        stack.addArrangedSubview(heading(EnhancementText.t("Scale and super-resolution", "缩放与超分")))
        stack.addArrangedSubview(libraryRow("Lanczos", EnhancementText.t("High-quality spatial scaling with low overhead.", "高质量空间缩放，资源开销较低。"), "scale|lanczos", enabled: true))
        stack.addArrangedSubview(libraryRow("MetalFX Spatial", EnhancementText.t("Spatial scaling on supported Macs.", "在支持的 Mac 上使用空间缩放。"), "scale|metalfx.spatial", enabled: true))
        stack.addArrangedSubview(libraryRow(EnhancementText.t("Apple low-latency super-resolution", "Apple 低延迟超分"), EnhancementText.t("Experimental · 720p to 1080p on supported sources.", "实验 · 支持的 720p 来源可提升至 1080p。"), "scale|apple.low-sr", enabled: true))
        stack.addArrangedSubview(libraryRow(
            EnhancementText.t("Apple video super-resolution", "Apple 视频超分"),
            EnhancementText.t("Experimental · 480×270 to 1080p, with frame generation off.", "实验 · 480×270 升至 1080p，暂需关闭帧生成。"),
            "scale|apple.video-sr", enabled: true))
        stack.addArrangedSubview(libraryRow("Real-CUGAN", EnhancementText.t("Experimental · 2× anime detail enhancement with optional denoising.", "实验 · 2× 动画细节增强，可选降噪。"), "scale|realcugan", enabled: true))
        stack.addArrangedSubview(libraryRow("Anime4K", EnhancementText.t("Experimental · Anime-oriented 2× enhancement. This build requires macOS 27.", "实验 · 面向动画的 2× 增强，此版本运行库需要 macOS 27。"), "scale|anime4k", enabled: true))
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
            if identifier == "scale|apple.low-sr" { appleSRLibraryButton = use; use.isEnabled = false }
            if identifier == "scale|apple.video-sr" { appleVideoSRLibraryButton = use; use.isEnabled = false }
            if identifier == "scale|anime4k" { anime4KLibraryButton = use; use.isEnabled = false }
            if identifier == "scale|realcugan" { cuganLibraryButton = use; use.isEnabled = false }
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
        preview.isHidden = next != 0
        preview.refreshVisibilitySnapshot()
        for (index, button) in navButtons.enumerated() {
            let selected = index == next
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            button.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        }
        if next == 0 { redrawPreview() }
    }

    private func redrawPreview() {
        let mode: SPLiveViewMode
        switch profile.viewMode {
        case "original": mode = .original
        case "compare": mode = .compare
        default: mode = .enhanced
        }
        processor.setViewMode(mode)
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
        updateAppleSRCapability()
        refreshSourceBar()
        persist()
        refreshPlanLabel()
        refreshInteractionStatus()
    }

    private func applyPresetDefaults(_ id: String) {
        switch id {
        case "preset:native":
            applyNativeQualityPreset(&profile)
        case "preset:game":
            profile.interpolationEnabled = true
            profile.interpolationEngineID = "apple.lowlatency"
            profile.modelID = "vt.llfi.temporal.1"
            profile.rate = .multiplier(2)
            profile.scaleEnabled = true
            profile.scaleEngineID = "lanczos"
            profile.outputWidth = 1920
            profile.outputHeight = 1080
        case "preset:film":
            profile.interpolationEnabled = true
            profile.interpolationEngineID = "apple.frc"
            profile.interpolationQuality = "quality"
            profile.modelID = "vt.frc.quality"
            profile.rate = .multiplier(2)
            profile.scaleEnabled = true
            profile.scaleEngineID = "lanczos"
            profile.outputWidth = 1920
            profile.outputHeight = 1080
        case "preset:anime":
            profile.interpolationEnabled = true
            profile.interpolationEngineID = "rife.metal"
            profile.modelID = "rife-v4.25"
            profile.interpolationQuality = "fast"
            profile.rate = .multiplier(2)
            profile.scaleEnabled = true
            profile.scaleEngineID = "lanczos"
            profile.outputWidth = 1920
            profile.outputHeight = 1080
        default:
            profile.interpolationEnabled = true
            profile.interpolationEngineID = "apple.frc"
            profile.interpolationQuality = "normal"
            profile.modelID = "vt.frc.normal"
            profile.rate = .multiplier(2)
            profile.scaleEnabled = false
        }
    }

    private final class DashedConfigButton: NSButton {
        private let outline = CAShapeLayer()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            wantsLayer = true
            outline.fillColor = NSColor.clear.cgColor
            outline.lineWidth = 1
            outline.lineDashPattern = [4, 3]
            layer?.addSublayer(outline)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            outline.frame = bounds
            outline.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil)
            outline.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        }
    }

    private final class ConfigNavButton: NSButton {
        var doubleClick: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2, let doubleClick { doubleClick(); return }
            super.mouseDown(with: event)
        }
    }

    private final class ConfigRenameField: NSTextField {
        var cancelRename: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { cancelRename?() }
    }

    private func rebuildConfigRows() {
        cancelRename()
        for item in configRows.arrangedSubviews { configRows.removeArrangedSubview(item); item.removeFromSuperview() }
        let active = EnhancementProfileStore.resolvedID(profile)
        let metadata = EnhancementProfileStore.metadata()
        func add(_ id: String, _ title: String, _ symbol: String) {
            let item = navButton(title, symbol, #selector(selectConfig(_:)))
            item.identifier = NSUserInterfaceItemIdentifier(id)
            if let row = item as? ConfigNavButton { row.doubleClick = { [weak self] in self?.beginRename(id) } }
            let menu = NSMenu()
            let rename = NSMenuItem(title: EnhancementText.t("Rename", "重命名"), action: #selector(renameConfig(_:)), keyEquivalent: "")
            rename.target = self; rename.representedObject = id; menu.addItem(rename)
            let delete = NSMenuItem(title: EnhancementText.t("Delete", "删除"), action: #selector(deleteConfig(_:)), keyEquivalent: "")
            delete.target = self; delete.representedObject = id; menu.addItem(delete)
            item.menu = menu
            let selected = active == id
            item.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            item.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
            item.layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
            configRows.addArrangedSubview(item)
        }
        for preset in EnhancementProfileStore.presets where !metadata.hiddenPresets.contains(preset.id) {
            add(preset.id, metadata.titles[preset.id] ?? EnhancementText.t(preset.english, preset.name), preset.symbol)
        }
        for name in EnhancementProfileStore.namedNames() {
            let matchesPreset = EnhancementProfileStore.presets.contains { $0.name == name }
            let title = matchesPreset ? name + " · " + EnhancementText.t("Custom", "自定义") : name
            add("custom:" + name, title, "doc.text")
        }
        if !metadata.hiddenPresets.isEmpty {
            let restore = navButton(EnhancementText.t("Restore presets", "恢复预设"), "arrow.uturn.backward", #selector(restorePresets(_:)))
            configRows.addArrangedSubview(restore)
        }
        let addButton = DashedConfigButton(frame: .zero)
        addButton.title = EnhancementText.t("＋ Add config", "＋ 新增配置")
        addButton.target = self
        addButton.action = #selector(addConfig)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.widthAnchor.constraint(equalToConstant: 168).isActive = true
        addButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        configRows.addArrangedSubview(addButton)
    }

    @objc private func selectConfig(_ sender: NSButton) {
        cancelCountdown()
        guard let id = sender.identifier?.rawValue else { return }
        readControls()
        guard saveCurrentProfile() else { return }
        activateConfig(id)
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
        guard let row = configRows.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == id }) else { return }
        let editor = ConfigRenameField(frame: .zero)
        editor.stringValue = displayName(id)
        editor.isBezeled = false
        editor.drawsBackground = false
        editor.focusRingType = .none
        editor.font = row.font
        editor.delegate = self
        editor.target = self
        editor.action = #selector(commitRename(_:))
        editor.cancelRename = { [weak self] in self?.cancelRename() }
        editor.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(editor)
        renameRow = row
        renameOriginalTitle = row.title
        row.title = ""
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 30),
            editor.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
            editor.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            editor.heightAnchor.constraint(lessThanOrEqualTo: row.heightAnchor, constant: -8),
        ])
        renameID = id
        renameEditor = editor
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }

    private func cancelRename() {
        let editor = renameEditor
        renameEditor = nil
        renameID = nil
        renameRow?.title = renameOriginalTitle
        renameRow = nil
        renameOriginalTitle = ""
        editor?.delegate = nil
        editor?.removeFromSuperview()
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

    func controlTextDidEndEditing(_ notification: Notification) {
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
                        throw NSError(domain: "Khua.ConfigRename", code: 2, userInfo: [NSLocalizedDescriptionKey: "重命名未完成，回退也失败；请检查 \(newURL.path)：\(rollback.localizedDescription)"])
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

    @objc private func restorePresets(_ sender: NSButton) {
        let meta = EnhancementProfileStore.metadata()
        let menu = NSMenu()
        for preset in EnhancementProfileStore.presets where meta.hiddenPresets.contains(preset.id) {
            let item = NSMenuItem(title: meta.titles[preset.id] ?? EnhancementText.t(preset.english, preset.name), action: #selector(restorePreset(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = preset.id; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
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
            if parts[1] == "apple.low-sr" {
                guard appleSRCandidate else { return }
                profile.outputWidth = 1920; profile.outputHeight = 1080
            }
            if parts[1] == "apple.video-sr" {
                guard appleVideoSRCandidate else { return }
                if profile.sourceKind == "file", let player = selectedFilePlayer() {
                    let size = player.workbenchSourceSize
                    profile.outputWidth = size.0 * appleVideoSRFactor; profile.outputHeight = size.1 * appleVideoSRFactor
                } else { profile.outputWidth = 1920; profile.outputHeight = 1080 }
            }
            if parts[1] == "anime4k" {
                guard anime4KCandidate else { return }
                profile.outputWidth = 0; profile.outputHeight = 0
            }
            if parts[1] == "realcugan" {
                guard cuganCandidate else { return }
                profile.outputWidth = 0; profile.outputHeight = 0
            }
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
        profile.interpolationEngineID = id
        if id == "rife.metal" {
            profile.modelID = parts.count > 1 ? parts[1] : "rife-v4.25"
            if !["fast", "balanced", "hq"].contains(profile.interpolationQuality) {
                profile.interpolationQuality = "fast"
            }
        } else if id == "apple.lowlatency" {
            profile.modelID = "vt.llfi.temporal"
        } else if id == "distildrba.coreml" {
            profile.modelID = "distildrba.v1.720p"
            profile.rate = .multiplier(2)
        } else {
            profile.modelID = profile.interpolationQuality == "quality" ? "vt.frc.quality" : "vt.frc.normal"
        }
        loadControls()
        persist()
        showPage(0)
        statusLabel.stringValue = EnhancementText.t("Engine selected. Press Start to apply it.", "已选择引擎。按开始后生效。")
        statusLabel.textColor = .labelColor
    }

    @objc private func useFrameRateConversion() {
        cancelCountdown()
        profile.interpolationEngineID = "apple.frc"
        profile.interpolationQuality = "normal"
        profile.modelID = "vt.frc.normal"
        profile.interpolationEnabled = true
        loadControls()
        persist()
        statusLabel.stringValue = EnhancementText.t("Switched the form to Apple frame-rate conversion. Press Start to apply it.", "表单已改为 Apple 帧率转换。按开始后生效。")
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
        let text = activeSourceTitle.isEmpty ? EnhancementText.t("None selected", "未选择") : activeSourceTitle
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
        let selectedKind = ["window", "display", "file"][max(0, min(2, sourceKindControl.selectedSegment))]
        sourceActionButton?.title = !activeSourceTitle.isEmpty && activeSourceKind == selectedKind ? EnhancementText.t("Change", "更换") : choose
        emptySourceButton?.title = choose
        emptyOverlay.isHidden = capture.running
    }

    private func refreshActions() {
        let player = selectedFilePlayer()
        let enhancing = profile.sourceKind == "file" ? ((player?.workbenchMotionPlusRequested ?? false) || (player?.workbenchFileLanczosActive ?? false)) :
            (capture.running && (processor.resolvedPlan.interpolationActive || processor.resolvedPlan.scaleActive || (applied.sourceKind == "window" && applied.windowOutputMode != "follow")))
        startButton?.isHidden = false
        startButton?.isEnabled = !filePreparing
        startButton?.title = filePreparing ? EnhancementText.t("Preparing…", "准备中…") : (countdown.active ? "\(countdown.remaining)" : (enhancing ? EnhancementText.t("Apply Changes", "应用更改") : EnhancementText.t("Start Enhancement", "开始增强")))
        stopButton?.isHidden = !enhancing && !filePreparing
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 82).isActive = true
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
        enginePopup.addItems(withTitles: [
            EnhancementText.t("Apple frame-rate conversion", "Apple 帧率转换"),
            EnhancementText.t("Apple low-latency interpolation", "Apple 低延迟插帧"),
            "RIFE 4.25",
            "RIFE 4.26",
            EnhancementText.t("DistilDRBA · 720p X2 · Experimental", "DistilDRBA · 720p X2 · 实验"),
        ])
        enginePopup.item(at: 4)?.isEnabled = SPDistilDRBA.isPackagedForThisSystem()
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        qualityPopup.addItems(withTitles: [
            EnhancementText.t("Apple FRC · Normal", "Apple 帧率转换 · 标准"),
            EnhancementText.t("Apple FRC · Quality", "Apple 帧率转换 · 质量"),
        ])
        fpsPopup.addItems(withTitles: ["24", "25", "30", "50", "60", "90", "120", EnhancementText.t("Custom", "自定义")])
        scalePopup.addItems(withTitles: [
            EnhancementText.t("Lanczos scale", "Lanczos 高质量缩放"),
            "MetalFX Spatial",
            EnhancementText.t("Apple low-latency super-resolution · Experimental", "Apple 低延迟超分 · 实验"),
            EnhancementText.t("Apple video super-resolution · Experimental", "Apple 视频超分 · 实验"),
            EnhancementText.t("Anime4K · 2× · Experimental", "Anime4K · 2× · 实验"),
            EnhancementText.t("Real-CUGAN · 2× · Experimental", "Real-CUGAN · 2× · 实验"),
        ])
        scalePopup.item(at: 2)?.isEnabled = false
        scalePopup.item(at: 3)?.isEnabled = false
        scalePopup.item(at: 4)?.isEnabled = false
        scalePopup.item(at: 5)?.isEnabled = false
        scaleQualityPopup.addItems(withTitles: [EnhancementText.t("Off", "不降噪"), EnhancementText.t("Low", "轻度"), EnhancementText.t("Medium", "中等"), EnhancementText.t("Strong", "强")])
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
        for control in [qualityPopup, fpsPopup, scalePopup, scaleQualityPopup, sizePopup, displayPopup] {
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
        rifeStreamCheck.title = EnhancementText.t("RIFE stream cache (experimental)", "RIFE 连续缓存（实验）")
        rifeStreamCheck.toolTip = EnhancementText.t("Live capture only. Uses the selected model and quality; failures fall back to normal processing.", "仅实时采集。使用当前模型和质量；失败时回退普通处理。")
        rifeStreamCheck.target = self
        rifeStreamCheck.action = #selector(controlChanged)
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
        processor.preview = preview
        processor.outputPreview = outputPreview
        processor.installPresentationHooks()
        if PixelDiagnosticsPolicy.enabled(CommandLine.arguments) { processor.enablePixelDiagnostics() }
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.preview.refreshVisibilitySnapshot()
                self?.outputPreview.refreshVisibilitySnapshot()
                self?.updateTargetPanels()
                self?.updateFPSOverlay()
                guard let self, self.profile.sourceKind == "file" else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastFileStatsUpdate >= 1 else { return }
                self.lastFileStatsUpdate = now
                self.updateAppleSRCapability()
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
                    self.pauseButton?.title = player.workbenchIsPlaying ? EnhancementText.t("Pause", "暂停") : EnhancementText.t("Resume", "继续")
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
            self.statusLabel.textColor = failed ? .systemRed : .labelColor
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
                if self.countdown.active && generation != self.countdownSourceGeneration { self.cancelCountdown() }
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
                self.preview.setGeneration(generation)
                self.outputPreview.setGeneration(generation)
                let active = self.processor.resolvedPlan.interpolationActive || self.processor.resolvedPlan.scaleActive
                self.statusLabel.stringValue = active
                    ? EnhancementText.t("Source changed; waiting for the new frame.", "已换源，等待新画面。")
                    : EnhancementText.t("Waiting for the new source frame.", "等待新来源画面。")
                self.statusLabel.textColor = .labelColor
                self.emptyOverlay.isHidden = true
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
                self.persist()
            }
        }
        capture.onStatus = { [weak self] text, failed in
            DispatchQueue.main.async {
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
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged), name: .khuaMotionPlusChanged, object: nil)
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

    private func updateAppleSRCapability() {
        let filePlayer = profile.sourceKind == "file" ? selectedFilePlayer() : nil
        let fileSize = filePlayer?.workbenchSourceSize ?? (0, 0)
        let liveSelected = profile.sourceKind != "file" && capture.running
        let width = profile.sourceKind == "file" ? fileSize.0 : (liveSelected ? (lastStats["sourceWidth"] as? Int ?? 0) : 0)
        let height = profile.sourceKind == "file" ? fileSize.1 : (liveSelected ? (lastStats["sourceHeight"] as? Int ?? 0) : 0)
        let key = "\(profile.sourceKind)-\(capture.running)-\(filePlayer?.openMediaPath ?? "")-\(width)-\(height)-\(interpolationSwitch.state.rawValue)"
        guard key != appleSRCapabilityKey else { return }
        appleSRCapabilityKey = key
        appleSRCandidate = (filePlayer != nil || liveSelected) && width == 1280 && height == 720 &&
            SPAppleLowLatencySR.supportedFactors(forWidth: Int32(width), height: Int32(height)).contains { abs($0.doubleValue - 1.5) < 0.0001 }
        scalePopup.item(at: 2)?.isEnabled = appleSRCandidate
        appleSRLibraryButton?.isEnabled = appleSRCandidate
        let videoSRInputReady = profile.sourceKind == "file" ? filePlayer != nil : (capture.running && width == 480 && height == 270 && interpolationSwitch.state == .off)
        let availableFactors = videoSRInputReady && width > 0 && height > 0
            ? SPAppleVideoSR.readyScales(forWidth: Int32(width), height: Int32(height)).map(\.intValue) : []
        let videoScales = VideoSRAvailability.readyFactors(isFile: profile.sourceKind == "file", inputReady: videoSRInputReady, factors: availableFactors)
        appleVideoSRCandidate = !videoScales.isEmpty
        if let first = videoScales.first { appleVideoSRFactor = first }
        scalePopup.item(at: 3)?.isEnabled = appleVideoSRCandidate
        appleVideoSRLibraryButton?.isEnabled = appleVideoSRCandidate
        applyModeVisibility()
        let sizeOK = width == 0 || height == 0 || (width <= 1920 && height <= 1080)
        anime4KCandidate = SPAnime4K.isPackagedForThisSystem() && sizeOK
        scalePopup.item(at: 4)?.isEnabled = anime4KCandidate
        anime4KLibraryButton?.isEnabled = anime4KCandidate
        cuganCandidate = SPRealCUGAN.isPackagedForThisSystem() && sizeOK
        scalePopup.item(at: 5)?.isEnabled = cuganCandidate
        cuganLibraryButton?.isEnabled = cuganCandidate
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
        clearObsoleteBudgetWarningIfNeeded()
        if profile.interpolationEngineID == "apple.lowlatency" { phaseLabel.stringValue = lowLatencyPhaseText() }
        updateAppleSRCapability()
        refreshActions()
        updateFPSOverlay()
        refreshPlanLabel()
    }

    private func updateStatsText(_ stats: [String: Any]) {
        let healthNow = ProcessInfo.processInfo.systemUptime
        if healthNow - r7LastHealthAt >= 1 {
            r7LastHealthAt = healthNow
            observeR7Health()
        }
        if let width = stats["sourceWidth"] as? Int, let height = stats["sourceHeight"] as? Int, width > 0 {
            let fps = stats["callbackFPS"] as? Double ?? 0
            let label = EnhancementText.t("Capture", "采集回调")
            sourceMetaLabel.stringValue = fps > 1 ? "\(width)×\(height) · \(label) \(String(format: "%.0f", fps)) fps" : "\(width)×\(height)"
        }
        let presented = (stats["epochPhysicalSynthetic"] as? Int) ?? 0
        let scheduled = LiveCoverage.modelScheduled(total: (stats["epochScheduled"] as? Int) ?? 0,
                                                     held: (stats["epochStaticHoldPhases"] as? Int) ?? 0)
        let limited = processor.resolvedPlan.presentationLimited
        let budgetSkipped = (stats["nativeBudgetSkippedPhases"] as? Int) ?? 0
        let attempted = max(0, scheduled - budgetSkipped)
        let short = attempted > 120 && presented * 20 < attempted * 19
        let hint = limited
            ? EnhancementText.t(" Requested rate exceeds the display refresh rate.", " 请求帧率超过显示器刷新率。")
            : (short ? EnhancementText.t(" Output is below the requested rate. A lighter engine is available.", " 实际输出低于请求。可以改用更轻的引擎。") : "")
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
        let lines = FooterMetrics.lines(target: targetText, output: rate, generation: generationRates,
            budget: budgetLimited, stalled: outputStalled, overdue: modelOverdue,
            supplemental: [coverage, budget, holds, sizeChainLabel.stringValue, hint.trimmingCharacters(in: .whitespaces)])
        statsLabel.stringValue = capture.running ? lines.primary : ""
        budgetLabel.stringValue = capture.running ? lines.secondary : ""
        budgetLabel.textColor = budgetLimited.isEmpty ? .secondaryLabelColor : .systemOrange
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
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        liveLogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeLiveLog(to: path) }
        }
    }

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

    private func writeLiveLog(to path: String, event: String? = nil, extra: [String: Any] = [:]) {
        var line: [String: Any] = [
            "t": Date().timeIntervalSince1970,
            "monotonicSeconds": ProcessInfo.processInfo.systemUptime,
            "machAbsolute": mach_absolute_time(),
            "r8ProcessID": ProcessInfo.processInfo.processIdentifier,
            "r7Passthrough": r7Flag("--khua-r7-passthrough"),
            "r7Opaque": r7Flag("--khua-r7-opaque"),
            "r7Activate": r7Flag("--khua-r7-activate"),
            "r7FullscreenGeometry": r7Flag("--khua-r7-fullscreen-geometry"),
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
            "diagnosticOwnActivated": viewerActive && r7Flag("--khua-r7-activate"),
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
                (r7Flag("--khua-r7-fullscreen-geometry") && activeSourceKind == "window" ? "diagnostic_fullscreen_input_blocked" :
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
              var data = try? JSONSerialization.data(withJSONObject: line),
              let handle = FileHandle(forWritingAtPath: path) else { return }
        data.append(0x0A)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: data)
    }

    @objc private func chooseWindow() { cancelCountdown(); inputRouter?.stop(reason:"source_changed"); interactionArmed = false; profile.sourceKind = "window"; capture.presentPicker(windows: true); persist() }
    @objc private func chooseDisplay() { cancelCountdown(); inputRouter?.stop(reason:"source_changed"); interactionArmed = false; profile.sourceKind = "display"; capture.presentPicker(windows: false); persist() }
    @objc private func reselect() { if profile.sourceKind == "display" { chooseDisplay() } else { chooseWindow() } }

    @objc func chooseFile() {
        cancelCountdown()
        inputRouter?.stop(reason:"source_changed"); interactionArmed = false
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
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
        guard !countdown.active && !filePreparing else { return }
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
        guard let ticket = countdown.begin() else { return }
        let snapshot = profile
        recordPlanEvent("countdown_started", extra: ["selectedEngine": snapshot.interpolationEngineID, "selectedModel": snapshot.modelID])
        let selectedKind = profile.sourceKind
        let selectedGeneration = capture.currentGeneration
        countdownSourceGeneration = selectedKind == "file" ? nil : selectedGeneration
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
        recordPlanEvent("submit", extra: ["requestID": requestID, "submittedEngine": request.engineID,
            "submittedModel": request.modelID, "submittedRateKind": request.rateKind == .multiplier ? "multiplier" : "fixedFPS",
            "submittedMultiplier": request.multiplier])
        processor.update(request)
        persist()
        refreshPlanLabel()
    }

    @objc private func apply() { start() }

    @objc private func stop() {
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
        capture.stop()
        viewerActive = false; viewerFollowOverride = false; viewerReturnPID = nil
        viewerControlsPanel?.orderOut(nil)
        (outputWindow as? TargetPanel)?.viewerKeyboard = false
        liveApply.cancel(); pendingApply = nil; pendingSourceGeneration = nil
        capture.paused = false
        pauseButton?.title = EnhancementText.t("Pause", "暂停")
        outputWarmupToken &+= 1
        outputMinimumCaptureHost = 0
        outputWindow?.orderOut(nil)
        targetHUD?.orderOut(nil)
        targetCountdownHUD?.orderOut(nil)
        outputPreview.refreshVisibilitySnapshot()
        processor.stop()
        lastStats = [:]
        lastStatsReceipt = 0
        updateFPSOverlay()
        statusLabel.stringValue = EnhancementText.t("Stopped", "已停止")
        statusLabel.textColor = .labelColor
        statsLabel.stringValue = ""
        budgetLabel.stringValue = ""
        refreshActions()
        refreshPlanLabel()
        refreshInteractionStatus()
    }

    @objc private func pause() {
        cancelCountdown()
        inputRouter?.stop(reason:"paused")
        interactionArmed = false
        if profile.sourceKind == "file", let player = selectedFilePlayer() {
            player.workbenchTogglePlayback()
            pauseButton?.title = player.workbenchIsPlaying ? EnhancementText.t("Pause", "暂停") : EnhancementText.t("Resume", "继续")
            return
        }
        let resuming = capture.paused
        outputMinimumCaptureHost = resuming ? Int64(mach_absolute_time()) : 0
        capture.paused.toggle()
        outputWarmupToken &+= 1
        outputWarmupStartedAt = 0
        outputWarmupWarningShown = false
        if capture.paused {
            viewerActive = false; viewerReturnPID = nil
            (outputWindow as? TargetPanel)?.viewerKeyboard = false
            outputWindow?.orderOut(nil); targetHUD?.orderOut(nil)
            targetCountdownHUD?.orderOut(nil); viewerControlsPanel?.orderOut(nil)
            outputPreview.refreshVisibilitySnapshot()
        }
        lastStats = [:]
        lastStatsReceipt = 0
        processor.resetFPSObservations()
        pauseButton?.title = capture.paused ? EnhancementText.t("Resume", "继续") : EnhancementText.t("Pause", "暂停")
        statusLabel.stringValue = capture.paused
            ? EnhancementText.t("Paused. Capture stays connected.", "已暂停，捕获仍连接")
            : EnhancementText.t("Resumed", "已继续")
        statusLabel.textColor = .labelColor
        updateTargetPanels()
        updateFPSOverlay()
        refreshInteractionStatus()
        recordPlanEvent(capture.paused ? "pause" : "resume")
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
        let previous = profile.interpolationEngineID
        readEngineSelection()
        if profile.interpolationEngineID != previous {
            if profile.interpolationEngineID == "rife.metal", !["fast", "balanced", "hq"].contains(profile.interpolationQuality) {
                profile.interpolationQuality = "fast"
            }
            if profile.interpolationEngineID == "apple.frc", !["normal", "quality"].contains(profile.interpolationQuality) {
                profile.interpolationQuality = "normal"
            }
        }
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
        let choosingSR = (scalePopup.indexOfSelectedItem == 2 && profile.scaleEngineID != "apple.low-sr" && appleSRCandidate) ||
            (scalePopup.indexOfSelectedItem == 3 && profile.scaleEngineID != "apple.video-sr" && appleVideoSRCandidate)
        if choosingSR {
            if scalePopup.indexOfSelectedItem == 3 && profile.sourceKind == "file", let player = selectedFilePlayer() {
                let size = player.workbenchSourceSize, w = size.0 * appleVideoSRFactor, h = size.1 * appleVideoSRFactor
                if w == 1280 && h == 720 { sizePopup.selectItem(at: 1) }
                else if w == 1920 && h == 1080 { sizePopup.selectItem(at: 2) }
                else if w == 2560 && h == 1440 { sizePopup.selectItem(at: 3) }
                else { sizePopup.selectItem(at: 4); widthField.stringValue = "\(w)"; heightField.stringValue = "\(h)" }
            } else { sizePopup.selectItem(at: 2) }
        }
        let animationSelected = scalePopup.indexOfSelectedItem == 4 || scalePopup.indexOfSelectedItem == 5
        sizePopup.item(at: 5)?.isEnabled = animationSelected
        sizePopup.item(at: 0)?.isEnabled = !animationSelected
        if (scalePopup.indexOfSelectedItem == 4 && profile.scaleEngineID != "anime4k" && anime4KCandidate) ||
            (scalePopup.indexOfSelectedItem == 5 && profile.scaleEngineID != "realcugan" && cuganCandidate) { sizePopup.selectItem(at: 5) }
        if !animationSelected && sizePopup.indexOfSelectedItem == 5 { sizePopup.selectItem(at: 0) }
        readControls()
        updateAppleSRCapability()
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
        fullscreenCheck.title = profile.sourceKind == "file"
            ? EnhancementText.t("Fullscreen on output display", "在输出显示器全屏")
            : (profile.sourceKind == "window"
               ? EnhancementText.t("Window mode is selected at right", "窗口输出模式在右侧选择")
               : EnhancementText.t("Fullscreen viewer (Esc to return to interaction)", "全屏预览（Esc 返回交互）"))
        fullscreenCheck.isEnabled = profile.sourceKind != "window"
        fullscreenCheck.state = profile.sourceKind == "window" ? (profile.windowOutputMode == "follow" ? .off : .on) : (profile.outputFullscreen ? .on : .off)
        fullscreenCheck.toolTip = profile.sourceKind == "window" ? EnhancementText.t(
            "Choose follow, viewer, or a fullscreen interaction mode in Window output.",
            "在窗口输出中选择跟随、观看或全屏交互。") : nil
        rifeStreamCheck.isHidden = profile.sourceKind == "file" || profile.interpolationEngineID != "rife.metal"
        let editable = WorkbenchDimensionPolicy.editable(sizeIndex: sizePopup.indexOfSelectedItem, scaleEnabled: scaleSwitch.state == .on)
        for (field, value) in [(widthField, profile.outputWidth), (heightField, profile.outputHeight)] {
            if field.isEditable != editable { field.isEditable = editable }
            if field.isSelectable != editable { field.isSelectable = editable }
            if field.currentEditor() == nil { field.stringValue = WorkbenchDimensionPolicy.text(value) }
        }
        let native2x = profile.scaleEngineID == "anime4k" || profile.scaleEngineID == "realcugan"
        if profile.sourceKind == "file" && profile.scaleEngineID == "apple.video-sr" {
            sizePopup.item(at: 0)?.title = appleVideoSRCandidate
                ? EnhancementText.t("\(appleVideoSRFactor)× source (model native)", "\(appleVideoSRFactor)×来源（模型原生）")
                : EnhancementText.t("Source × model factor", "来源 × 模型倍率")
        } else {
            sizePopup.item(at: 0)?.title = native2x ? EnhancementText.t("2× source (model native)", "2×来源（模型原生）") : EnhancementText.t("Source size", "与来源相同")
        }
        sizePopup.item(at: 5)?.title = EnhancementText.t("2× source (model native)", "2×来源（模型原生）")
        scaleQualityRow?.isHidden = profile.scaleEngineID != "realcugan"
        let targetRate = rateMode.selectedSegment == 0
        fpsPopup.isHidden = !targetRate
        customRateRow?.isHidden = !targetRate || fpsPopup.indexOfSelectedItem != 7
        multiplierControl.isHidden = targetRate
        if profile.interpolationEngineID == "apple.lowlatency" {
            phaseLabel.stringValue = lowLatencyPhaseText()
        }
    }

    @objc private func pendingTextChanged(_ notification: Notification) {
        guard (countdown.active || filePreparing), let field = notification.object as? NSTextField,
              [widthField, heightField, fpsNum, fpsDen].contains(where: { $0 === field }) else { return }
        cancelCountdown()
    }

    @objc private func appearanceChanged() {
        cancelCountdown()
        readControls()
        applyAppearance()
        persist()
    }

    @objc private func languageChanged() {
        EnhancementText.setLanguage(languageControl.selectedSegment == 0 ? "zh" : "en", in: .standard)
        func translate(_ text: String) -> String {
            EnhancementText.translated(text, chinese: EnhancementText.chinese)
        }
        func visit(_ view: NSView) {
            if view === configRows || view === recentStack || view === shareStack || view === languageControl { return }
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
        let candidate = (Bundle.main.object(forInfoDictionaryKey: "SPCandidateLabel") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        window?.title = WorkbenchTitle.text(EnhancementText.t("Quality Workbench", "画质工作台"), candidate: candidate)
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
        refreshInteractionStatus()
    }

    @objc private func motionChanged() {
        guard profile.sourceKind == "file" else { return }
        guard !applyingFileSettings else { return }
        guard let player = selectedFilePlayer() else { return }
        if player.workbenchMotionPlusRequested {
            profile.interpolationEnabled = true
            profile.rate = .multiplier(2)
            profile.interpolationEngineID = "apple.frc"
            profile.interpolationQuality = "normal"
            profile.modelID = "vt.frc.normal"
        } else {
            profile.interpolationEnabled = false
        }
        if var active = fileApplied {
            active.interpolationEnabled = player.workbenchMotionPlusRequested
            if active.interpolationEnabled {
                active.rate = .multiplier(2)
                active.interpolationEngineID = "apple.frc"
                active.interpolationQuality = "normal"
                active.modelID = "vt.frc.normal"
            }
            fileApplied = active
        }
        loadControls()
        refreshPlanLabel()
    }

    private func applyFileRequest() {
        guard let player = selectedFilePlayer() else {
            fileApplyError = EnhancementText.t("Open a video before applying file settings.", "请先打开视频，再应用文件设置。")
            statusLabel.stringValue = fileApplyError; statusLabel.textColor = .systemRed; return
        }
        guard outputScreen(for: profile.outputDisplayID) != nil else {
            fileApplyError = EnhancementText.t("The selected display is unavailable.", "所选显示器不可用。")
            statusLabel.stringValue = fileApplyError; statusLabel.textColor = .systemRed; return
        }
        guard !profile.scaleEnabled || ["lanczos", "metalfx.spatial", "apple.low-sr", "apple.video-sr", "anime4k", "realcugan"].contains(profile.scaleEngineID) else {
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
        if profile.scaleEnabled && !["lanczos", "metalfx.spatial", "apple.low-sr", "apple.video-sr", "anime4k", "realcugan"].contains(profile.scaleEngineID) { return EnhancementText.t("This scaler is not connected to file playback yet.", "这个缩放引擎尚未接入文件播放。") }
        if profile.interpolationEnabled && !["apple.frc", "rife.metal", "apple.lowlatency", "distildrba.coreml"].contains(profile.interpolationEngineID) {
            return EnhancementText.t("This interpolation engine is not connected to file playback yet; current playback is unchanged.", "这个插帧引擎尚未接入文件播放，当前播放保持不变。")
        }
        let player = selectedFilePlayer()
        if let warning = player?.workbenchFileLanczosStatus, !warning.isEmpty { return EnhancementText.runtime(warning) }
        let active = fileApplied ?? profile
        let interpolationActive = player?.workbenchMotionPlusRequested ?? false
        let mode: String
        let interpolationName = active.interpolationEngineID == "rife.metal" ? "RIFE \(active.modelID) · \(active.interpolationQuality)" : (active.interpolationEngineID == "apple.lowlatency" ? EnhancementText.t("Apple Low Latency", "Apple 低延迟") : (active.interpolationEngineID == "distildrba.coreml" ? "DistilDRBA" : "Apple FRC"))
        switch active.rate {
        case .multiplier(let value): mode = interpolationActive ? "\(interpolationName) X\(value) · " + EnhancementText.t("Experimental", "实验") : EnhancementText.t("Motion+ off", "Motion+ 关闭")
        case let .fixedFPS(n, d): mode = interpolationActive ? "\(interpolationName) \(n)/\(d) FPS · " + EnhancementText.t("Experimental", "实验") : EnhancementText.t("Motion+ off", "Motion+ 关闭")
        }
        let fps = player?.workbenchPresentedFPS ?? 0
        let size = player?.workbenchFileLanczosSize ?? (0, 0)
        let scalerName: String
        switch active.scaleEngineID {
        case "metalfx.spatial": scalerName = "MetalFX Spatial"
        case "apple.low-sr": scalerName = EnhancementText.t("Apple Low-Latency SR", "Apple 低延迟超分")
        case "apple.video-sr": scalerName = EnhancementText.t("Apple Video SR · per-frame experiment (Random)", "Apple 视频超分 · 逐帧实验（Random）")
        case "anime4k": scalerName = "Anime4K · " + EnhancementText.t("Experimental", "实验")
        case "realcugan": scalerName = "Real-CUGAN · " + EnhancementText.t("Experimental", "实验")
        default: scalerName = "Lanczos"
        }
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
        let profile = snapshot ?? self.profile
        let request = SPLivePlanRequest()
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
        switch profile.scaleEngineID {
        case "metalfx.spatial": request.scaleEngine = .metalFX
        case "apple.low-sr": request.scaleEngine = .appleLowLatencySR
        case "apple.video-sr": request.scaleEngine = .appleVideoSR
        case "anime4k": request.scaleEngine = .anime4K
        case "realcugan": request.scaleEngine = .realCUGAN
        default: request.scaleEngine = .lanczos
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
        let scaleVariant = processor.resolvedPlan.scaleQualityID ?? ""
        let parts = [processor.resolvedPlan.interpolationActive ? "\(liveEngine) \(liveModel)" : "", processor.resolvedPlan.scaleActive ? "\(scaleEngine)\(scaleEngine == "realcugan" ? " · \(scaleVariant)" : "")" : ""].filter { !$0.isEmpty }.joined(separator: " + ")
        let live: String
        if profile.sourceKind == "file" {
            let player = selectedFilePlayer()
            if player?.workbenchMotionPlusActive == true {
                let selected = fileApplied ?? profile
                let name = selected.interpolationEngineID == "rife.metal" ? "RIFE \(selected.modelID) · \(selected.interpolationQuality)" : "Apple FRC"
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
            live = EnhancementText.t("Active", "生效") + " \(parts)"
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
            || (profile.scaleEngineID == "realcugan" && profile.scaleQualityID != baseline.scaleQualityID)
            || profile.outputWidth != baseline.outputWidth
            || profile.outputHeight != baseline.outputHeight
            || (profile.sourceKind == "file" && (profile.outputDisplayID != baseline.outputDisplayID || profile.outputFullscreen != baseline.outputFullscreen))
        let pending = formDiffers ? EnhancementText.t("Pending", "待应用") + " \(Self.engineDisplayName(profile.interpolationEngineID, model: profile.modelID)) \(rate)" : ""
        sizeChainLabel.stringValue = profile.sourceKind != "file" && capture.running && processor.resolvedPlan.committed
            ? LiveSizeChain.text(lastStats, generation: capture.currentGeneration, config: processor.resolvedPlan.configVersion) : ""
        planLabel.stringValue = [live, pending, limited ? EnhancementText.t("Display is \(screenHz) Hz", "显示器 \(screenHz) Hz，不能完整呈现该帧率") : "", profile.sourceKind == "file" ? fileStatus() : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        statusLabel.toolTip = [planLabel.stringValue, sizeChainLabel.stringValue].filter { !$0.isEmpty }.joined(separator: " · ")
        if statusLabel.stringValue.isEmpty { statusLabel.stringValue = live }
        fileLimitLabel.stringValue = profile.sourceKind == "file" ? fileStatus() : ""
    }

    private static func engineDisplayName(_ engine: String, model: String) -> String {
        switch engine {
        case "apple.lowlatency": return EnhancementText.t("Apple low latency", "Apple 低延迟")
        case "apple.frc": return "Apple FRC"
        case "rife.metal": return model == "rife-v4.26" ? "RIFE 4.26" : "RIFE 4.25"
        case "distildrba.coreml": return "DistilDRBA"
        default: return engine
        }
    }

    private func loadControls() {
        interpolationSwitch.state = profile.interpolationEnabled ? .on : .off
        rifeStreamCheck.state = profile.rifeStreamEnabled ? .on : .off
        switch profile.interpolationEngineID {
        case "apple.lowlatency": enginePopup.selectItem(at: 1)
        case "rife.metal": enginePopup.selectItem(at: profile.modelID == "rife-v4.26" ? 3 : 2)
        case "distildrba.coreml": enginePopup.selectItem(at: 4)
        default: enginePopup.selectItem(at: 0)
        }
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
        scaleQualityPopup.selectItem(at: ["none", "light", "medium", "strong"].firstIndex(of: profile.scaleQualityID) ?? 0)
        updateAppleSRCapability()
        let animationSelected = profile.scaleEngineID == "anime4k" || profile.scaleEngineID == "realcugan"
        scalePopup.selectItem(at: profile.scaleEngineID == "metalfx.spatial" ? 1 : (profile.scaleEngineID == "apple.low-sr" ? 2 : (profile.scaleEngineID == "apple.video-sr" ? 3 : (profile.scaleEngineID == "anime4k" ? 4 : (profile.scaleEngineID == "realcugan" ? 5 : 0)))))
        sizePopup.item(at: 5)?.isEnabled = animationSelected
        sizePopup.item(at: 0)?.isEnabled = !animationSelected
        switch (profile.outputWidth, profile.outputHeight) {
        case (0, 0): sizePopup.selectItem(at: animationSelected ? 5 : 0)
        case (1280, 720): sizePopup.selectItem(at: 1)
        case (1920, 1080): sizePopup.selectItem(at: 2)
        case (2560, 1440): sizePopup.selectItem(at: 3)
        default: sizePopup.selectItem(at: 4)
        }
        widthField.stringValue = "\(profile.outputWidth)"
        heightField.stringValue = "\(profile.outputHeight)"
        fullscreenCheck.state = profile.sourceKind == "window" ? .on : (profile.outputFullscreen ? .on : .off)
        windowOutputPopup.selectItem(at: ["follow":0,"viewer":1,"absolute":2,"relative":3][profile.windowOutputMode] ?? 0)
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
        refreshInteractionStatus()
    }

    private func reloadQualityItems() {
        qualityPopup.removeAllItems()
        if profile.interpolationEngineID == "rife.metal" {
            qualityPopup.addItems(withTitles: ["fast", "balanced", "hq"])
            qualityPopup.selectItem(at: ["fast": 0, "balanced": 1, "hq": 2][profile.interpolationQuality] ?? 1)
            qualityPopup.isHidden = false
            phaseLabel.isHidden = true
        } else if profile.interpolationEngineID == "distildrba.coreml" {
            qualityPopup.isHidden = true
            phaseLabel.isHidden = false
            phaseLabel.stringValue = EnhancementText.t("720p input · X2 · Experimental", "720p 来源 · X2 · 实验")
        } else if profile.interpolationEngineID == "apple.lowlatency" {
            qualityPopup.isHidden = true
            phaseLabel.isHidden = false
            phaseLabel.stringValue = lowLatencyPhaseText()
        } else {
            qualityPopup.addItems(withTitles: [
                EnhancementText.t("Normal", "标准"),
                EnhancementText.t("Quality", "质量"),
            ])
            qualityPopup.selectItem(at: profile.interpolationQuality == "quality" ? 1 : 0)
            qualityPopup.isHidden = false
            phaseLabel.isHidden = true
        }
        compatibilityButton.isHidden = profile.interpolationEngineID != "apple.lowlatency"
        interpolationQualityRow?.isHidden = qualityPopup.isHidden
    }

    private func lowLatencyPhaseText() -> String {
        func sizeText(_ multiplier: Int) -> String {
            let fileSize = selectedFilePlayer()?.workbenchSourceSize
            let width = profile.sourceKind == "file" ? (fileSize?.0 ?? 0) : ((lastStats["sourceWidth"] as? Int) ?? 0)
            let height = profile.sourceKind == "file" ? (fileSize?.1 ?? 0) : ((lastStats["sourceHeight"] as? Int) ?? 0)
            guard width > 0 && height > 0 else { return "X\(multiplier)" }
            let w=profile.outputWidth, h=profile.outputHeight
            let before = profile.sourceKind != "file" && profile.scaleEnabled && profile.scaleEngineID == "lanczos" &&
                w > 0 && h > 0 && w < width && h < height && w * height == h * width
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
    }

    private func readControls() {
        profile.interpolationEnabled = interpolationSwitch.state == .on
        profile.rifeStreamEnabled = rifeStreamCheck.state == .on
        readEngineSelection()
        if profile.interpolationEngineID == "rife.metal" {
            let title = qualityPopup.titleOfSelectedItem ?? "balanced"
            profile.interpolationQuality = ["fast", "balanced", "hq"].contains(title) ? title : "balanced"
        } else if profile.interpolationEngineID == "apple.frc" {
            profile.interpolationQuality = qualityPopup.indexOfSelectedItem == 1 ? "quality" : "normal"
            profile.modelID = profile.interpolationQuality == "quality" ? "vt.frc.quality" : "vt.frc.normal"
        }
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
        profile.scaleEngineID = scalePopup.indexOfSelectedItem == 1 ? "metalfx.spatial" : (scalePopup.indexOfSelectedItem == 2 ? "apple.low-sr" : (scalePopup.indexOfSelectedItem == 3 ? "apple.video-sr" : (scalePopup.indexOfSelectedItem == 4 ? "anime4k" : (scalePopup.indexOfSelectedItem == 5 ? "realcugan" : "lanczos"))))
        if profile.scaleEngineID == "realcugan" { profile.scaleQualityID = ["none", "light", "medium", "strong"][max(0, min(3, scaleQualityPopup.indexOfSelectedItem))] }
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
        profile.windowOutputMode = ["follow", "viewer", "absolute", "relative"][max(0,min(3,windowOutputPopup.indexOfSelectedItem))]
        profile.viewMode = ["enhanced", "original", "compare"][max(0, viewMode.selectedSegment)]
        profile.appearance = ["system", "light", "dark"][max(0, appearanceControl.selectedSegment)]
        profile.captureLimit = ["auto", "30", "60"][max(0, min(2, captureCapPopup.indexOfSelectedItem))]
        profile.soundMode = "sourceApplication"
        let displayIndex = max(0, min(displayIDs.count - 1, displayPopup.indexOfSelectedItem))
        profile.outputDisplayID = displayIDs[displayIndex]
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

    @objc private func interactionModeChanged() {
        cancelCountdown()
        inputRouter?.stop(reason: "mode_changed")
        interactionArmed = false; interactionFailure = ""
        readControls(); persist(); applyModeVisibility(); refreshPlanLabel(); updateTargetPanels(); refreshInteractionStatus()
    }

    // Requests happen only in response to these explicit button actions.
    @objc private func requestInputMonitoring() {
        if !CGRequestListenEventAccess(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        refreshInteractionStatus()
    }
    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshInteractionStatus()
    }
    @objc private func requestEventAccess() {
        if !CGRequestPostEventAccess(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(url)
        }
        refreshInteractionStatus()
    }

    private func refreshInteractionStatus() {
        let requested = profile.windowOutputMode
        let permission = LiveInputRouter.Permission.preflight()
        let showPermissions = profile.sourceKind == "window" && isInteractiveMode(requested)
        inputMonitoringButton.isHidden = !showPermissions || permission.listen
        accessibilityButton.isHidden = !showPermissions || permission.accessibility
        eventAccessButton.isHidden = !showPermissions || requested != "absolute" || permission.post
        let releaseWarning = (inputRouter?.cleanupUnconfirmed ?? 0) > 0 ? EnhancementText.t("\nButton release not confirmed; check the source.", "\n按键释放未确认，请检查来源。") : ""
        guard profile.sourceKind == "window" else {
            interactionStateLabel.stringValue = EnhancementText.t("Window interaction is available only for window sources.", "全屏交互仅适用于窗口来源。") + releaseWarning
            return
        }
        guard isInteractiveMode(requested) else {
            interactionStateLabel.stringValue = (requested == "viewer" ? EnhancementText.t("Viewer blocks input.", "观看模式不转发输入。") : EnhancementText.t("Source-aligned output keeps direct input.", "按来源位置增强，可直接操作。")) + releaseWarning
            return
        }
        let requestedText = requested == "relative" ? EnhancementText.t("relative", "相对输入") : EnhancementText.t("pointer", "指针")
        let activeText = inputRouter?.ready == true ? EnhancementText.t("route active; verify source response", "路由运行中，请检查来源响应") : EnhancementText.t("not active", "未生效")
        let listen = permission.listen ? EnhancementText.t("granted", "已授权") : EnhancementText.t("missing", "未授权")
        let post = requested == "relative" ? EnhancementText.t("not needed", "不需要") : (permission.post ? EnhancementText.t("granted", "已授权") : EnhancementText.t("missing", "未授权"))
        let accessibility = permission.accessibility ? EnhancementText.t("granted", "已授权") : EnhancementText.t("missing", "未授权")
        let issueText: String
        switch interactionFailure {
        case "input_monitoring_missing", "listen_permission_missing": issueText = EnhancementText.t("input monitoring required", "需要输入监听权限")
        case "event_modification_missing", "post_permission_missing": issueText = EnhancementText.t("event posting required for release", "需要事件发送权限以释放按键")
        case "accessibility_missing": issueText = EnhancementText.t("accessibility permission required", "需要辅助功能权限")
        case "comparison_unsupported": issueText = EnhancementText.t("comparison unavailable", "对比画面不支持交互")
        case "geometry_unavailable": issueText = EnhancementText.t("waiting for verified geometry", "等待有效画面位置")
        case "target_unavailable", "target_changed": issueText = EnhancementText.t("source is no longer active", "来源窗口已失焦或变化")
        case "tap_create_failed", "tap_enable_failed", "tap_disabled": issueText = EnhancementText.t("input route unavailable", "输入路由不可用")
        case "apply_to_start": issueText = EnhancementText.t("apply to start", "应用设置后开始")
        case "release_mouse_buttons": issueText = EnhancementText.t("release mouse buttons to prepare", "松开鼠标按键以准备交互")
        case "bootstrap_unavailable": issueText = EnhancementText.t("input preparation unavailable", "输入准备不可用")
        case "waiting_source_focus": issueText = EnhancementText.t("switch to the source window", "请切回来源窗口")
        case "source_obstructed_waiting": issueText = EnhancementText.t("waiting for obstruction to clear", "等待遮挡消失")
        case "source_obstructed": issueText = EnhancementText.t("source is covered or window state unknown", "来源被遮挡或窗口状态未知")
        case "source_outside_displays": issueText = EnhancementText.t("mapped point is outside active displays", "映射位置不在活动显示器内")
        case "geometry_invalidated": issueText = EnhancementText.t("source position changed", "来源位置已变化")
        default: issueText = ""
        }
        let issue = issueText.isEmpty ? "" : " · \(issueText)"
        interactionStateLabel.stringValue = EnhancementText.t("Requested: \(requestedText) · \(activeText)\(issue)\nMonitoring: \(listen) · Posting: \(post) · Accessibility: \(accessibility)\nExit: Ctrl+Option+Esc", "请求：\(requestedText) · \(activeText)\(issue)\n监听：\(listen) · 发送：\(post) · 辅助功能：\(accessibility)\n退出：Control+Option+Esc") + releaseWarning
    }

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
        guard r7Diagnostics, CommandLine.arguments.contains("--khua-p1-ax-diagnostics"), AXIsProcessTrusted(),
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
            else { self.updateTargetPanels(); self.refreshInteractionStatus() }
        })
        inputRouter = router
        return router
    }

    private func reconcileInputRouter(target: CaptureTarget, interactive: Bool) {
        guard interactive, interactionArmed, case let .window(id, owner) = target else {
            if inputRouter?.active == true { inputRouter?.stop(reason:"not_interactive") }
            refreshInteractionStatus(); return
        }
        let permission = LiveInputRouter.Permission.preflight()
        guard permission.permits(relative: applied.windowOutputMode == "relative") else {
            if inputRouter?.active == true { inputRouter?.stop(reason:"permission_missing") }
            interactionFailure = !permission.listen ? "input_monitoring_missing" : (!permission.accessibility ? "accessibility_missing" : "event_modification_missing")
            refreshInteractionStatus(); return
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
            interactionFailure = "geometry_unavailable"; refreshInteractionStatus(); return
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
        refreshInteractionStatus()
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
        let opaque = r7Flag("--khua-r7-opaque") ? EnhancementText.t("Overlay: opaque", "遮罩：不透明") : EnhancementText.t("Overlay: clear", "遮罩：透明")
        let focus = r7Flag("--khua-r7-activate") ? EnhancementText.t("Focus: output", "焦点：输出") : EnhancementText.t("Focus: source", "焦点：来源")
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
        p0OpaqueOverride = !r7Flag("--khua-r7-opaque")
        refreshP0ControlTitles()
        updateTargetPanels()
        recordPlanEvent("p0_opaque_changed", extra: ["p0ControlSurface": p0MainActionInProgress ? "main" : "overlay"])
    }

    @objc private func toggleP0Activation() {
        guard p0ControlsEnabled else { return }
        let enable = !r7Flag("--khua-r7-activate")
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
        if targetDecisionReason == "target_identity_changed_in_ordered_list" || (targetDecisionReason != "target_metadata_incomplete" && targetDecisionReason != "window_list_unavailable" && TargetOverlayPolicy.shouldCancel(exists: state.exists, onscreen: state.onscreen, wasOnscreen: targetWasOnscreen)) {
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
                interactionFailure = "waiting_source_focus"; outputHiddenReason = "waiting_source_focus"; refreshInteractionStatus(); return
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
        let planActive = processor.resolvedPlan.committed && (processor.resolvedPlan.interpolationActive || processor.resolvedPlan.scaleActive || r7Flag("--khua-r7-passthrough") || (profile.sourceKind == "window" && applied.windowOutputMode != "follow"))
        let windowTarget: Bool
        if case .window = target { windowTarget = true } else { windowTarget = false }
        // Fullscreen geometry for a window is a non-interactive diagnostic only.
        let diagnosticFullscreen = windowTarget && r7Flag("--khua-r7-fullscreen-geometry")
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
            outputHiddenReason = "interaction_restricted"; refreshInteractionStatus(); return
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
                outputHiddenReason = mayWait ? "source_obstructed_waiting" : "source_obstructed"; refreshInteractionStatus(); return
            }
            guard interactionObstructionWait.observe(blocked: false, now: ProcessInfo.processInfo.systemUptime,
                generation: capture.currentGeneration, config: processor.resolvedPlan.configVersion) else {
                inputRouter?.stop(reason: "obstruction_timeout"); interactionArmed = false; interactionFailure = "source_obstructed"
                outputPreview.invalidateSharedGeometry(); outputWindow?.orderOut(nil); viewerControlsPanel?.orderOut(nil)
                outputPreview.refreshVisibilitySnapshot(); outputHiddenReason = "source_obstructed"; refreshInteractionStatus(); return
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
                outputHiddenReason = "bootstrap_unavailable"; refreshInteractionStatus(); return
            }
        }
        let explicitViewer = windowTarget && applied.windowOutputMode == "viewer"
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
            let opaque = interactionAvailable ? false : (windowTarget ? r7Flag("--khua-r7-opaque") : true)
            panel.isOpaque = opaque
            panel.backgroundColor = opaque ? .black : .clear
            outputPreview.layer?.isOpaque = opaque
            outputPreview.setFollowTargetContent(followsWindow)
            // A scaled fullscreen picture is not aligned with the source.
            // Absorb pointer input instead of misdirecting it underneath; the
            // aligned follow-window mode retains normal click-through.
            panel.ignoresMouseEvents = !fullscreen || (interactionAvailable && inputRouter?.ready == true)
            let diagnosticActivate = windowTarget && !interactionAvailable && r7Flag("--khua-r7-activate")
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
        if countdown.active || fpsSwitch.state == .on {
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
            if countdown.active {
                let timerFrame = NSRect(x: hudFrame.midX - 41, y: hudFrame.midY - 41, width: 82, height: 82)
                if countdownPanel.frame != timerFrame { countdownPanel.setFrame(timerFrame, display: true) }
                if !countdownPanel.isVisible { countdownPanel.orderFrontRegardless() }
            } else { countdownPanel.orderOut(nil) }
            let requestedFPSVisible = fpsSwitch.state != .on || fpsPanel.isVisible
            let requestedCountdownVisible = !countdown.active || countdownPanel.isVisible
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
        [window?.windowNumber, outputWindow?.windowNumber, targetHUD?.windowNumber, targetCountdownHUD?.windowNumber, viewerControlsPanel?.windowNumber].compactMap { $0 }.filter { $0 > 0 }
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

    func windowWillClose(_ notification: Notification) { stop() }
}
