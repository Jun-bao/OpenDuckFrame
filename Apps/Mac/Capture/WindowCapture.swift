import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import VideoToolbox
@preconcurrency import ScreenCaptureKit

private final class PoolTicket: NSObject {
    let onRelease: () -> Void
    init(_ onRelease: @escaping () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}

/// Copies a borrowed capture surface into an app-owned pool buffer before the
/// ScreenCaptureKit callback returns. The destination is never the source IOSurface.
private final class OwnedFrameCopier {
    private let budgetBytes: Int
    private var pool: CVPixelBufferPool?
    private var session: VTPixelTransferSession?
    private var width = 0
    private var height = 0
    private var format: OSType = 0
    private var frameBytes = 0
    private var cap = 0
    private let lock = NSLock()
    private var inUse = 0
    private var peak = 0
    private var poolDrops = 0
    private var aliased = 0
    private var copyNs: [Int64] = []

    init(budgetBytes: Int = 96 * 1024 * 1024) {
        self.budgetBytes = budgetBytes
    }

    func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        if pool == nil || sourceWidth != width || sourceHeight != height || sourceFormat != format {
            guard prepare(width: sourceWidth, height: sourceHeight, format: sourceFormat) else { return nil }
        }
        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        let aux: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: cap as NSNumber]
        let created = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux as CFDictionary, &destination)
        guard created == kCVReturnSuccess, let destination else {
            lock.lock()
            poolDrops += 1
            lock.unlock()
            return nil
        }
        let started = mach_absolute_time()
        var transferred = false
        if let session {
            transferred = VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr
        }
        let sourceSurface = CVPixelBufferGetIOSurface(source)?.toOpaque()
        let destinationSurface = CVPixelBufferGetIOSurface(destination)?.toOpaque()
        if sourceSurface != nil && sourceSurface == destinationSurface {
            lock.lock()
            aliased += 1
            lock.unlock()
            transferred = false
        }
        if !transferred && !copyPlanes(from: source, to: destination) {
            lock.lock()
            poolDrops += 1
            lock.unlock()
            return nil
        }
        copyAttachments(from: source, to: destination)
        let elapsed = hostToNs(mach_absolute_time() - started)
        let ticket = PoolTicket { [weak self] in self?.noteReturned() }
        CVBufferSetAttachment(destination, "app.khuaplayer.capture.poolTicket" as CFString, ticket, .shouldNotPropagate)
        lock.lock()
        inUse += 1
        peak = max(peak, inUse)
        copyNs.append(elapsed)
        if copyNs.count > 512 { copyNs.removeFirst(copyNs.count - 512) }
        lock.unlock()
        return destination
    }

    func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let samples = copyNs.sorted()
        let p95: Double
        if samples.isEmpty {
            p95 = -1
        } else {
            p95 = Double(samples[(samples.count - 1) * 95 / 100]) / 1_000_000
        }
        return [
            "ownedInUse": inUse,
            "ownedPeak": peak,
            "ownedFrameBytes": frameBytes,
            "ownedCap": cap,
            "ownedBudgetBytes": budgetBytes,
            "poolDrops": poolDrops,
            "aliasedTransfers": aliased,
            "copyP95ms": p95,
            "sckBufferRetained": false,
        ]
    }

    private func noteReturned() {
        lock.lock()
        inUse = max(0, inUse - 1)
        lock.unlock()
    }

    private func prepare(width: Int, height: Int, format: OSType) -> Bool {
        self.width = width
        self.height = height
        self.format = format
        frameBytes = OwnedFrameCopier.byteCount(width: width, height: height, format: format)
        var count = frameBytes > 0 ? budgetBytes / frameBytes : 4
        if count < 4 { count = 4 }
        if count > 16 { count = 16 }
        cap = count
        let buffer: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, buffer as CFDictionary, &created) == kCVReturnSuccess,
              let created else { return false }
        pool = created
        var transfer: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer) == noErr {
            session = transfer
        } else {
            session = nil
        }
        return true
    }

    private static func byteCount(width: Int, height: Int, format: OSType) -> Int {
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            return width * height * 3 / 2
        }
        return width * height * 4
    }

    private func copyPlanes(from source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planes = CVPixelBufferGetPlaneCount(source)
        if planes == 0 {
            guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(destination) else { return false }
            let rows = CVPixelBufferGetHeight(source)
            let rowBytes = min(CVPixelBufferGetBytesPerRow(source), CVPixelBufferGetBytesPerRow(destination))
            for row in 0..<rows {
                memcpy(to.advanced(by: row * CVPixelBufferGetBytesPerRow(destination)),
                       from.advanced(by: row * CVPixelBufferGetBytesPerRow(source)),
                       rowBytes)
            }
            return true
        }
        for plane in 0..<planes {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return false }
            let rows = CVPixelBufferGetHeightOfPlane(source, plane)
            let rowBytes = min(CVPixelBufferGetBytesPerRowOfPlane(source, plane), CVPixelBufferGetBytesPerRowOfPlane(destination, plane))
            for row in 0..<rows {
                memcpy(to.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(destination, plane)),
                       from.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(source, plane)),
                       rowBytes)
            }
        }
        return true
    }

    private func copyAttachments(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        let keys = [
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferCGColorSpaceKey,
        ]
        for key in keys {
            if let value = CVBufferGetAttachment(source, key, nil)?.takeUnretainedValue() {
                CVBufferSetAttachment(destination, key, value, .shouldPropagate)
            }
        }
    }

    private func hostToNs(_ host: UInt64) -> Int64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Int64(host) * Int64(info.numer) / Int64(info.denom)
    }
}

enum CaptureTarget: Equatable {
    case window(id: CGWindowID, owner: pid_t)
    case display(id: CGDirectDisplayID)
}

final class WindowCaptureSource: NSObject, SCStreamOutput, SCStreamDelegate, SCContentSharingPickerObserver, @unchecked Sendable {
    private final class ShareableResult: @unchecked Sendable {
        let value: Result<SCShareableContent, Error>
        init(_ value: Result<SCShareableContent, Error>) { self.value = value }
    }
    var onFrame: (@Sendable (CVPixelBuffer, Int64, Int64, Int64, Int64, UInt64) -> Void)?
    var onStatus: (@Sendable (String, Bool) -> Void)?
    var onNote: (@Sendable (Int) -> Void)?
    var onSource: (@Sendable (String, String, String) -> Void)?
    var onGeneration: (@Sendable (UInt64) -> Void)?
    var onDiagnostic: (@Sendable (String) -> Void)?
    var excludedWindowIDs: () -> [Int] = { [] }
    var paused = false
    private(set) var running = false
    private(set) var currentGeneration: UInt64 = 0
    private(set) var target: CaptureTarget?
    /// 0 is automatic. 30 and 60 set SCStream.minimumFrameInterval and do not change the output rate.
    var captureCapFPS: Int = 0
    var canRestart: Bool { filter != nil }

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "app.khuaplayer.capture", qos: .userInitiated)
    private var filter: SCContentFilter?
    private var selectionRevision: UInt64 = 0
    private let geometryLock = NSLock()
    private var screenRectGeneration: UInt64 = 0
    private var screenRectValue: CGRect?
    private var pickerArmed = false
    private var issuedGeneration: UInt64 = 0
    private var boundGeneration: UInt64 = 0
    private var completeCount = 0
    private var idleCount = 0
    private var blankCount = 0
    private var suspendedCount = 0
    private var stoppedCount = 0
    private var acceptedCount = 0
    private var pausedDrops = 0
    private var retiredDrops = 0
    private let copier = OwnedFrameCopier()
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var firstPTS = CMTime.invalid
    private var lastPTS = CMTime.invalid
    private var firstHost: UInt64 = 0
    private var lastHost: UInt64 = 0
    private var borrowedPeak = 0

    func presentPicker(windows: Bool) {
        let picker = SCContentSharingPicker.shared
        picker.isActive = true
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = windows ? .singleWindow : .singleDisplay
        configuration.allowsChangingSelectedContent = true
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        configuration.excludedWindowIDs = excludedWindowIDs()
        picker.defaultConfiguration = configuration
        if !pickerArmed {
            picker.add(self)
            pickerArmed = true
        }
        picker.present(using: windows ? .window : .display)
    }

    func refreshShareable(_ completion: @escaping @MainActor @Sendable (Result<SCShareableContent, Error>) -> Void) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            let result = ShareableResult(content.map { .success($0) } ?? .failure(error ?? NSError(domain: "app.khuaplayer.capture", code: 1)))
            DispatchQueue.main.async { completion(result.value) }
        }
    }

    func start(filter: SCContentFilter) {
        selectionRevision &+= 1
        let revision = selectionRevision
        stopStream()
        if rejectsOwnContent(filter) {
            onDiagnostic?("rejected own window")
            onStatus?("不能选择本应用的窗口或输出画面", true)
            return
        }
        target = nil
        if #available(macOS 15.2, *), filter.style == .display,
           let selected = filter.includedDisplays.first {
            // The system picker chooses a display, but its returned filter may
            // include our new panels. Rebuild it with our application excluded.
            let displayID = selected.displayID
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
                let result = ShareableResult(content.map { .success($0) } ?? .failure(error ?? NSError(domain: "app.khuaplayer.capture", code: 1)))
                DispatchQueue.main.async {
                    guard let self, self.selectionRevision == revision else { return }
                    guard case let .success(content) = result.value, let bundle = Bundle.main.bundleIdentifier,
                          let display = content.displays.first(where: { $0.displayID == displayID }) else {
                        self.onStatus?("无法安全排除本应用，请重新选择显示器。", true)
                        return
                    }
                    let own = content.applications.filter { $0.bundleIdentifier == bundle }
                    guard !own.isEmpty else {
                        self.onStatus?("无法排除本应用画面，请重新选择显示器。", true)
                        return
                    }
                    self.commit(filter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []))
                }
            }
            return
        }
        commit(filter: filter)
    }

    private func commit(filter: SCContentFilter) {
        self.filter = filter
        if #available(macOS 15.2, *) {
            if filter.style == .display, let display = filter.includedDisplays.first {
                target = .display(id: display.displayID)
            } else if filter.style != .display, let window = filter.includedWindows.first, let app = window.owningApplication {
                target = .window(id: window.windowID, owner: app.processID)
            } else { target = nil }
        } else { target = nil }
        issuedGeneration += 1
        let generation = issuedGeneration
        boundGeneration = generation
        currentGeneration = generation
        geometryLock.lock()
        screenRectGeneration = generation
        screenRectValue = nil
        geometryLock.unlock()
        completeCount = 0
        idleCount = 0
        blankCount = 0
        suspendedCount = 0
        acceptedCount = 0
        pausedDrops = 0
        retiredDrops = 0
        firstPTS = .invalid
        lastPTS = .invalid
        firstHost = 0
        lastHost = 0
        onGeneration?(generation)
        onDiagnostic?("start generation \(generation)")
        describe(filter)
        let pixelSize = pixelSize(of: filter)
        startStream(filter: filter, width: pixelSize.width, height: pixelSize.height, biplanar: true, generation: generation)
    }

    @discardableResult
    func restart() -> Bool {
        guard let filter else {
            onDiagnostic?("restart refused: no authorized filter")
            onStatus?("请重新选择窗口或显示器", true)
            return false
        }
        selectionRevision &+= 1
        stopStream()
        commit(filter: filter)
        return true
    }

    func stop() {
        selectionRevision &+= 1
        onDiagnostic?("stop requested; filter \(filter == nil ? "absent" : "kept")")
        stopStream()
    }

    private func stopStream() {
        let current = stream
        stream = nil
        running = false
        current?.stopCapture { [weak self] error in
            if let error {
                self?.onDiagnostic?("stopCapture error: \(error.localizedDescription)")
            }
        }
    }

    private func rejectsOwnContent(_ filter: SCContentFilter) -> Bool {
        let bundleID = Bundle.main.bundleIdentifier
        guard #available(macOS 15.2, *) else { return false }
        return filter.includedWindows.contains { window in
            window.owningApplication?.bundleIdentifier == bundleID
        }
    }

    private func describe(_ filter: SCContentFilter) {
        guard #available(macOS 15.2, *) else {
            onSource?(filter.style == .display ? "display" : "window", "已选来源", "")
            return
        }
        if let window = filter.includedWindows.first {
            let title = window.title ?? window.owningApplication?.applicationName ?? "窗口"
            onSource?("window", title, window.owningApplication?.bundleIdentifier ?? "")
        } else if let display = filter.includedDisplays.first {
            onSource?("display", "显示器 \(display.displayID)", "")
        } else {
            onSource?("window", "已选来源", "")
        }
    }

    private func pixelSize(of filter: SCContentFilter) -> (width: Int, height: Int) {
        let scale = CGFloat(max(filter.pointPixelScale, 1))
        var width = Int((filter.contentRect.width * scale).rounded())
        var height = Int((filter.contentRect.height * scale).rounded())
        width &= ~1
        height &= ~1
        if width < 2 || height < 2 {
            width = 1280
            height = 720
        }
        return (width, height)
    }

    private func startStream(filter: SCContentFilter, width: Int, height: Int, biplanar: Bool, generation: UInt64) {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.pixelFormat = biplanar
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        if captureCapFPS == 30 {
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        } else if captureCapFPS == 60 {
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        }
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.itur_709
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            stream.startCapture { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // A delayed start callback from a stopped/replaced stream
                    // must not restart it or change the current session state.
                    guard self.stream === stream, self.currentGeneration == generation else { return }
                    if let error {
                        if biplanar, let current = self.filter {
                            self.onDiagnostic?("biplanar start failed: \(error.localizedDescription); retry BGRA")
                            self.startStream(filter: current, width: width, height: height, biplanar: false, generation: generation)
                        } else {
                            self.running = false
                            self.onDiagnostic?("start failed: \(error.localizedDescription)")
                            self.onStatus?("捕获没有开始：\(error.localizedDescription)", true)
                        }
                    } else {
                        self.running = true
                        self.onStatus?(biplanar ? "正在捕获" : "正在捕获（BGRA，将转换）", false)
                    }
                }
            }
            self.stream = stream
        } catch {
            if biplanar {
                onDiagnostic?("addStreamOutput failed: \(error.localizedDescription); retry BGRA")
                startStream(filter: filter, width: width, height: height, biplanar: false, generation: generation)
            } else {
                onDiagnostic?("addStreamOutput failed: \(error.localizedDescription)")
                onStatus?("捕获没有开始：\(error.localizedDescription)", true)
            }
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?("选择器没有打开：\(error.localizedDescription)", true) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?("已取消选择", false) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async { [weak self] in self?.start(filter: filter) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.stream === stream else {
                self.onDiagnostic?("retired stream stopped: \(error.localizedDescription)")
                return
            }
            self.running = false
            self.queue.async { self.stoppedCount += 1 }
            self.onDiagnostic?("stream stopped: \(error.localizedDescription)")
            self.onStatus?("来源中断：\(error.localizedDescription)", true)
            self.onNote?(2)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard stream === self.stream else {
            retiredDrops += 1
            if retiredDrops <= 3 || retiredDrops % 60 == 0 {
                onDiagnostic?("ignored sample from a retired stream")
            }
            return
        }
        let generation = boundGeneration
        if #available(macOS 13.1, *),
           let items = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let dictionary = items.first?[.screenRect] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
           rect.width > 1, rect.height > 1, rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite {
            geometryLock.lock()
            if screenRectGeneration == generation { screenRectValue = rect }
            geometryLock.unlock()
        }
        let status = frameStatus(sampleBuffer)
        if status == .idle {
            idleCount += 1
            if idleCount <= 3 || idleCount % 60 == 0 {
                onDiagnostic?("idle \(idleCount) complete \(completeCount)")
            }
            onNote?(1)
            return
        }
        if status == .blank || status == .suspended || status == .stopped {
            if status == .blank { blankCount += 1 }
            if status == .suspended { suspendedCount += 1 }
            if status == .stopped { stoppedCount += 1 }
            onDiagnostic?("status \(status.rawValue) blank \(blankCount) suspended \(suspendedCount)")
            onNote?(2)
            return
        }
        completeCount += 1
        onNote?(0)
        guard !paused, let image = sampleBuffer.imageBuffer else {
            if paused {
                pausedDrops += 1
                if pausedDrops <= 3 || pausedDrops % 60 == 0 {
                    onDiagnostic?("paused; dropped complete \(completeCount)")
                }
            }
            return
        }
        let captureHost = mach_absolute_time()
        borrowedPeak = max(borrowedPeak, 1)
        guard let owned = copier.copy(image) else {
            if completeCount <= 5 || completeCount % 30 == 0 {
                onDiagnostic?("capture pool full; dropped complete \(completeCount)")
            }
            return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNum: Int64
        let ptsDen: Int64
        if time.isValid && !time.isIndefinite && time.timescale > 0 {
            ptsNum = time.value
            ptsDen = Int64(time.timescale)
        } else {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let host = Int64(mach_absolute_time())
            ptsNum = host * Int64(info.numer) / Int64(info.denom)
            ptsDen = 1_000_000_000
        }
        let readyHost = mach_absolute_time()
        let timescale = CMTimeScale(min(max(ptsDen, 1), Int64(Int32.max)))
        if !firstPTS.isValid { firstPTS = time.isValid ? time : CMTime(value: ptsNum, timescale: timescale) }
        lastPTS = time.isValid ? time : CMTime(value: ptsNum, timescale: timescale)
        if firstHost == 0 { firstHost = captureHost }
        lastHost = captureHost
        pixelWidth = CVPixelBufferGetWidth(owned)
        pixelHeight = CVPixelBufferGetHeight(owned)
        acceptedCount += 1
        if completeCount <= 5 || completeCount % 30 == 0 {
            onDiagnostic?("\(pixelWidth)x\(pixelHeight) complete \(completeCount) idle \(idleCount) pts \(ptsNum)/\(ptsDen) host \(captureHost) generation \(generation)")
        }
        onFrame?(owned, ptsNum, ptsDen, Int64(captureHost), Int64(readyHost), generation)
    }

    func diagnostics() -> [String: Any] {
        queue.sync { diagnosticsOnQueue() }
    }

    private func diagnosticsOnQueue() -> [String: Any] {
        var span = -1.0
        if firstPTS.isValid && lastPTS.isValid {
            span = CMTimeGetSeconds(CMTimeSubtract(lastPTS, firstPTS))
        }
        var hostSpan = -1.0
        if firstHost > 0 && lastHost > firstHost {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            hostSpan = Double(lastHost - firstHost) * Double(info.numer) / Double(info.denom) / 1_000_000_000
        }
        var report: [String: Any] = [
            "generation": currentGeneration,
            "running": running,
            "paused": paused,
            "captureCapFPS": captureCapFPS,
            "queueDepth": 3,
            "pixelWidth": pixelWidth,
            "pixelHeight": pixelHeight,
            "complete": completeCount,
            "idle": idleCount,
            "blank": blankCount,
            "suspended": suspendedCount,
            "accepted": acceptedCount,
            "pausedDrops": pausedDrops,
            "retiredDrops": retiredDrops,
            "borrowedPeak": borrowedPeak,
            "ptsNum": lastPTS.isValid ? lastPTS.value : 0,
            "ptsDen": lastPTS.isValid ? Int64(lastPTS.timescale) : 1,
            "ptsSpanSec": span,
            "hostSpanSec": hostSpan,
        ]
        for (key, value) in copier.snapshot() {
            report[key] = value
        }
        return report
    }

    static func copyIsolationCheck() -> [String: Any] {
        var source: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &source)
        guard let source else { return ["ok": false, "reason": "source"] }
        CVPixelBufferLockBaseAddress(source, [])
        if let base = CVPixelBufferGetBaseAddress(source) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(source) * 32)
            base.advanced(by: 4).storeBytes(of: UInt8(210), as: UInt8.self)
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        let copier = OwnedFrameCopier(budgetBytes: 1)
        var held: [CVPixelBuffer] = []
        var failed = false
        for _ in 0..<8 {
            if let copied = copier.copy(source) {
                held.append(copied)
            } else {
                failed = true
                break
            }
        }
        let copied = held.first
        let sourceSurface = CVPixelBufferGetIOSurface(source)?.toOpaque()
        let copiedSurface = copied.flatMap { CVPixelBufferGetIOSurface($0)?.toOpaque() }
        let sameSurface = sourceSurface != nil && sourceSurface == copiedSurface
        CVPixelBufferLockBaseAddress(source, [])
        if let base = CVPixelBufferGetBaseAddress(source) {
            base.advanced(by: 4).storeBytes(of: UInt8(0), as: UInt8.self)
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        var pixel = 0
        if let copied {
            CVPixelBufferLockBaseAddress(copied, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(copied) {
                pixel = Int(base.advanced(by: 4).load(as: UInt8.self))
            }
            CVPixelBufferUnlockBaseAddress(copied, .readOnly)
        }
        let snapshot = copier.snapshot()
        return [
            "ok": failed && held.count == 4 && sameSurface == false && pixel == 210,
            "held": held.count,
            "poolRejected": failed,
            "sameSurface": sameSurface,
            "pixel": pixel,
            "ownedCap": snapshot["ownedCap"] ?? 0,
        ]
    }

    private func frameStatus(_ sample: CMSampleBuffer) -> SCFrameStatus {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = array.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return .complete }
        return status
    }

    func latestScreenRect() -> CGRect? {
        geometryLock.lock()
        defer { geometryLock.unlock() }
        return screenRectGeneration == currentGeneration ? screenRectValue : nil
    }
}
