import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import VideoToolbox
@preconcurrency import ScreenCaptureKit

// Explicit controlled-fixture decoder. It samples only the high-contrast
// barcode in an owned buffer; marker and complement failures stay unknown.
enum R8FixtureDecoder {
    static func decode(_ buffer: CVPixelBuffer) -> UInt32? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let planar = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard planar || format == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        guard let base, width >= 128, height >= 80 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let marker = [true, true, false, true, false, false, true, true]
        for row in 0...70 {
            let y = min(height - 1, Int(Double(height) * (0.02 + Double(row) * 0.004)))
            var bits = [Bool](); bits.reserveCapacity(64)
            for column in 0..<64 {
                let x = min(width - 1, Int(Double(width) * (0.08 + 0.84 * (Double(column) + 0.5) / 64)))
                let offset = y * stride + x * (planar ? 1 : 4)
                let level = planar ? Int(bytes[offset]) : (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
                if level > 175 { bits.append(true) }
                else if level < 80 { bits.append(false) }
                else { break }
            }
            guard bits.count == 64 else { continue }
            guard Array(bits[0..<8]) == marker, Array(bits[56..<64]) == Array(marker.reversed()) else { continue }
            var value: UInt32 = 0
            var valid = true
            for i in 0..<24 {
                if bits[8+i] == bits[32+i] { valid = false; break }
                value = (value << 1) | (bits[8+i] ? 1 : 0)
            }
            if valid { return value }
        }
        return nil
    }
}

// Isolated self-window diagnostic only. The caller serializes these methods on
// its capture queue, exactly as WindowCapture does for the same two helpers.
@objc(SPSelfWindowCaptureBridge)
final class SPSelfWindowCaptureBridge: NSObject {
    private let gate = ContentFrameGate()
    private let copier = OwnedFrameCopier()

    @objc(acceptsBuffer:generation:hostNs:)
    func acceptsBuffer(_ buffer: CVPixelBuffer, generation: UInt64, hostNs: Int64) -> Bool {
        gate.evaluate(buffer: buffer, generation: generation, hostNs: hostNs) != .duplicate
    }

    @objc(copyBuffer:)
    func copyBuffer(_ buffer: CVPixelBuffer) -> SPOwnedPixelBuffer? {
        guard let copy = copier.copy(buffer) else { return nil }
        return SPOwnedPixelBuffer(retaining: copy)
    }

    @objc var lastFailurePoolExhausted: Bool { copier.lastFailurePoolExhausted }

    @objc(snapshotAtHostNs:generation:)
    func snapshot(atHostNs hostNs: Int64, generation: UInt64) -> [String: Any] {
        ["contentGate": gate.diagnostics(nowNs: hostNs, expectedGeneration: generation),
         "ownedCopy": copier.snapshot()]
    }
}

// Fixture-only orange motion evidence. The three rows are in full-buffer
// coordinates; failure to see a coherent stripe is explicitly unknown.
enum R8FixtureMotionProbe {
    static func sample(_ buffer: CVPixelBuffer) -> [String: Any] {
        let started = mach_absolute_time()
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        func result(_ valid: Bool, _ centroid: Double, _ first: Int, _ last: Int, _ active: Int, _ width: Int, _ reason: String) -> [String: Any] {
            let elapsed = Double(mach_absolute_time() - started) * Double(timebase.numer) / Double(max(1, timebase.denom))
            return ["valid": valid, "centroidX": centroid, "centroidNorm": valid ? centroid / Double(width) : -1,
                    "firstX": first, "lastX": last, "activeColumns": active, "bufferWidth": width,
                    "sampleDurationNs": elapsed, "reason": reason, "rows": [0.41, 0.43, 0.45],
                    "coordinateSpace": "full_pixel_buffer", "metric": "orange_chroma_weighted_centroid"]
        }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let planar = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard (planar || format == kCVPixelFormatType_32BGRA), width >= 128, height >= 80 else {
            return result(false, -1, -1, -1, 0, width, "unsupported")
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return result(false, -1, -1, -1, 0, width, "lock_failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let p0 = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else {
            return result(false, -1, -1, -1, 0, width, "missing_base")
        }
        let bytes = p0.assumingMemoryBound(to: UInt8.self)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let uv = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) : nil
        let uvStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) : 0
        if planar && uv == nil { return result(false, -1, -1, -1, 0, width, "missing_chroma") }
        let ys = [0.41, 0.43, 0.45].map { min(height - 1, Int(Double(height) * $0)) }
        var sum: Double = 0, weighted: Double = 0
        var first = width, last = -1, active = 0
        for x in 0..<width {
            var votes = 0, strength = 0
            for y in ys {
                let score: Int
                if planar {
                    let offset = (y / 2) * uvStride + (x / 2) * 2
                    let luminance = Int(bytes[y * stride + x])
                    score = luminance > 35 ? max(0, min(Int(uv![offset + 1]) - 128, 128 - Int(uv![offset]))) : 0
                } else {
                    let offset = y * stride + x * 4
                    let b = Int(bytes[offset]), g = Int(bytes[offset + 1]), r = Int(bytes[offset + 2])
                    score = r > 50 ? max(0, min(r - g, g - b)) : 0
                }
                if score >= 8 { votes += 1; strength += score }
            }
            if votes >= 2 {
                first = min(first, x); last = x; active += 1
                sum += Double(strength); weighted += Double(strength) * Double(x)
            }
        }
        let span = last >= first ? last - first + 1 : 0
        let valid = span >= max(8, width / 100) && span <= width / 4 && active * 100 >= span * 65 && sum > 0
        return result(valid, valid ? weighted / sum : -1, valid ? first : -1, valid ? last : -1, active, width,
                      valid ? "ok" : "no_coherent_orange_stripe")
    }
}

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
    private var poolExhaustions = 0
    private var allocationFailures = 0
    private var prepareFailures = 0
    private var copyFailures = 0
    private(set) var lastFailurePoolExhausted = false
    private var aliased = 0
    private var copyNs: [Int64] = []

    init(budgetBytes: Int = 96 * 1024 * 1024) {
        self.budgetBytes = budgetBytes
    }

    func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        lastFailurePoolExhausted = false
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        if pool == nil || sourceWidth != width || sourceHeight != height || sourceFormat != format {
            guard prepare(width: sourceWidth, height: sourceHeight, format: sourceFormat) else {
                lock.lock(); prepareFailures += 1; poolDrops += 1; lock.unlock()
                return nil
            }
        }
        guard let pool else { return nil }
        var destination: CVPixelBuffer?
        let aux: [CFString: Any] = [kCVPixelBufferPoolAllocationThresholdKey: cap as NSNumber]
        let created = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux as CFDictionary, &destination)
        guard created == kCVReturnSuccess, let destination else {
            lastFailurePoolExhausted = created == kCVReturnWouldExceedAllocationThreshold
            lock.lock()
            if lastFailurePoolExhausted { poolExhaustions += 1 } else { allocationFailures += 1 }
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
            copyFailures += 1
            poolDrops += 1
            lock.unlock()
            return nil
        }
        copyAttachments(from: source, to: destination)
        let elapsed = hostToNs(mach_absolute_time() - started)
        let ticket = PoolTicket { [weak self] in self?.noteReturned() }
        CVBufferSetAttachment(destination, "app.openduckframe.capture.poolTicket" as CFString, ticket, .shouldNotPropagate)
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
            "poolExhaustions": poolExhaustions,
            "allocationFailures": allocationFailures,
            "prepareFailures": prepareFailures,
            "copyFailures": copyFailures,
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
    private final class ResizeStreamBox: @unchecked Sendable {
        let stream: SCStream
        init(_ stream: SCStream) { self.stream = stream }
    }
    private final class ShareableResult: @unchecked Sendable {
        let value: Result<SCShareableContent, Error>
        init(_ value: Result<SCShareableContent, Error>) { self.value = value }
    }
    var onFrame: (@Sendable (CVPixelBuffer, Int64, Int64, Int64, Int64, UInt64) -> Void)?
    var onGeometry: (@Sendable ([String: Any]?, UInt64) -> Void)?
    var onRawFrame: (@Sendable (Int64, Int64, Int64, Int32, Int32, UInt64) -> Void)?
    var onStatus: (@Sendable (String, Bool) -> Void)?
    var onNote: (@Sendable (Int) -> Void)?
    var onSource: (@Sendable (String, String, String) -> Void)?
    var onGeneration: (@Sendable (UInt64) -> Void)?
    var onDiagnostic: (@Sendable (String) -> Void)?
    var onPoolPressure: (@Sendable (UInt64) -> Void)?
    var excludedWindowIDs: () -> [Int] = { [] }
    private let pauseLock = NSLock()
    private var pauseValue = false
    var paused: Bool {
        get { pauseLock.lock(); defer { pauseLock.unlock() }; return pauseValue }
        set {
            pauseLock.lock(); pauseValue = newValue; pauseLock.unlock()
            if newValue { geometryLock.lock(); frameGeometryReceipt = nil; geometryLock.unlock() }
        }
    }
    private(set) var running = false
    private(set) var currentGeneration: UInt64 = 0
    private(set) var target: CaptureTarget?
    /// 0 is automatic. 30 and 60 set SCStream.minimumFrameInterval and do not change the output rate.
    var captureCapFPS: Int = 0
    var canRestart: Bool { filter != nil }

    private var stream: SCStream?
    private let streamBinding = CaptureStreamBinding()
    private let queue = DispatchQueue(label: "app.openduckframe.capture", qos: .userInitiated)
    private var filter: SCContentFilter?
    private var filterRectAtStart: CGRect?
    private var selectionRevision: UInt64 = 0
    private var streamUsesBiplanar = true
    private var confirmedResizeSize: CaptureResizePolicy.Size?
    private var resizePolicy: CaptureResizePolicy?
    private var resizeTimer: DispatchSourceTimer?
    private var resizeRevision: UInt64 = 0
    private var resizeCounters = CaptureResizeCounters()
    private var resizeLastTarget: CaptureResizePolicy.Size?
    private var resizeLastConfirmMs: Double = -1
    private var resizeEvents: [[String: Any]] = []
    private var resizePendingConfirm: (size: CaptureResizePolicy.Size, from: CaptureResizePolicy.Size, start: Int64)?
    private var resizeLastFrame: (size: CaptureResizePolicy.Size, host: Int64)?
    private let resizeObservationLock = NSLock()
    private var resizeObservedGeneration: UInt64 = 0
    private var resizeObservedTarget: CaptureResizePolicy.Size?
    private var resizeObservedBuffer: CaptureResizePolicy.Size?
    private var resizeWatch: (generation: UInt64, size: CaptureResizePolicy.Size, start: Int64, notified: Bool)?
    private let resizeDiagnosticsLock = NSLock()
    private var resizeDiagnosticsValue: [String: Any] = [:]
    private let geometryLock = NSLock()
    private var screenRectGeneration: UInt64 = 0
    private var screenRectValue: CGRect?
    private var screenRectHost: UInt64 = 0
    private var geometryTarget: CaptureTarget?
    private var frameGeometryReceipt: CompleteFrameGeometryReceipt?
    private var pickerArmed = false
    private var issuedGeneration: UInt64 = 0
    private var completeCount = 0
    private var idleCount = 0
    private var blankCount = 0
    private var suspendedCount = 0
    private var stoppedCount = 0
    private var acceptedCount = 0
    private var receivedSequence: UInt64 = 0
    private var lastReceivedHost: UInt64 = 0
    private var lastFrameStatus: Int = -1
    private var lastDisplayTime: UInt64 = 0
    private var lastDirtyRectCount = -1
    private var lastDirtyRectArea: Double = 0
    private var lastCompleteHost: UInt64 = 0
    private var lastAcceptedHost: UInt64 = 0
    private var requestedCaptureFPS = 0
    private var pausedDrops = 0
    private var retiredDrops = 0
    private let copier = OwnedFrameCopier()
    private let contentFrameGate = ContentFrameGate()
    private let contentTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info
    }()
    private func contentHostNs(_ host: UInt64) -> Int64 {
        Int64(Double(host) * Double(contentTimebase.numer) / Double(max(1, contentTimebase.denom)))
    }
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var firstPTS = CMTime.invalid
    private var lastPTS = CMTime.invalid
    private var firstHost: UInt64 = 0
    private var lastHost: UInt64 = 0
    private var borrowedPeak = 0
    private var r8FixtureEvents: [[String: Any]] = []
    private var r8FixtureSuccess: UInt64 = 0
    private var r8FixtureFailure: UInt64 = 0
    private var r8FixtureEnabled: Bool {
        let args = CommandLine.arguments
        func absolute(_ flag: String) -> Bool {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return false }
            return args[i + 1].hasPrefix("/")
        }
        return args.contains("--odf-r8-fixture-diagnostics") && args.contains("--odf-r8-quality-diagnostics") && args.contains("--odf-pixel-diagnostics") &&
            absolute("--odf-isolated-profile") && absolute("--odf-live-log")
    }

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
            let result = ShareableResult(content.map { .success($0) } ?? .failure(error ?? NSError(domain: "app.openduckframe.capture", code: 1)))
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
                let result = ShareableResult(content.map { .success($0) } ?? .failure(error ?? NSError(domain: "app.openduckframe.capture", code: 1)))
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

    private func commit(filter: SCContentFilter, restartSize: CaptureResizePolicy.Size? = nil) {
        self.filter = filter
        filterRectAtStart = filter.contentRect
        if #available(macOS 15.2, *) {
            if filter.style == .display, let display = filter.includedDisplays.first {
                target = .display(id: display.displayID)
            } else if filter.style != .display, let window = filter.includedWindows.first, let app = window.owningApplication {
                target = .window(id: window.windowID, owner: app.processID)
            } else { target = nil }
        } else { target = nil }
        issuedGeneration += 1
        let generation = issuedGeneration
        currentGeneration = generation
        resizeCounters.reset(generation: generation)
        resizeLastTarget = nil; resizeLastConfirmMs = -1; resizeEvents.removeAll(); resizePendingConfirm = nil; resizeLastFrame = nil
        publishResizeDiagnostics()
        geometryLock.lock()
        screenRectGeneration = generation
        screenRectValue = nil
        screenRectHost = 0
        frameGeometryReceipt = nil
        geometryTarget = target
        geometryLock.unlock()
        completeCount = 0
        idleCount = 0
        blankCount = 0
        suspendedCount = 0
        acceptedCount = 0
        receivedSequence = 0
        r8FixtureEvents.removeAll(keepingCapacity: true)
        r8FixtureSuccess = 0; r8FixtureFailure = 0
        lastReceivedHost = 0
        lastFrameStatus = -1
        lastDisplayTime = 0
        lastDirtyRectCount = -1
        lastDirtyRectArea = 0
        lastCompleteHost = 0
        lastAcceptedHost = 0
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
        let chosen = restartSize ?? CaptureResizePolicy.Size(width: pixelSize.width, height: pixelSize.height)
        confirmedResizeSize = chosen
        startStream(filter: filter, width: chosen.width, height: chosen.height, biplanar: true, generation: generation)
    }

    @discardableResult
    func restart() -> Bool {
        guard let filter else {
            onDiagnostic?("restart refused: no authorized filter")
            onStatus?("请重新选择窗口或显示器", true)
            return false
        }
        selectionRevision &+= 1
        let remembered = confirmedResizeSize
        stopStream()
        commit(filter: filter, restartSize: remembered)
        return true
    }

    func stop() {
        selectionRevision &+= 1
        onDiagnostic?("stop requested; filter \(filter == nil ? "absent" : "kept")")
        stopStream()
    }

    private func stopStream() {
        stopResizeMonitoring(note: "stream stopped")
        let current = stream
        streamBinding.retire()
        geometryLock.lock(); frameGeometryReceipt = nil; geometryLock.unlock()
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
        requestedCaptureFPS = captureCapFPS == 30 || captureCapFPS == 60 ? captureCapFPS : 0
        let isWindow = filter.style == .window
        let configuration = CaptureStreamConfiguration.make(width: width, height: height, biplanar: biplanar, capFPS: captureCapFPS, window: isWindow)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            self.stream = stream
            streamUsesBiplanar = biplanar
            resizePolicy = CaptureResizePolicy(generation: generation, configured: .init(width: width, height: height))
            streamBinding.activate(stream, generation: generation)
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
                            self.geometryLock.lock(); self.frameGeometryReceipt = nil; self.geometryLock.unlock()
                            self.onDiagnostic?("start failed: \(error.localizedDescription)")
                            self.onStatus?("捕获没有开始：\(error.localizedDescription)", true)
                        }
                    } else {
                        self.running = true
                        self.startResizeMonitoringIfNeeded(stream: stream, generation: generation)
                        self.onStatus?(biplanar ? "正在捕获" : "正在捕获（BGRA，将转换）", false)
                    }
                }
            }
        } catch {
            if biplanar {
                onDiagnostic?("addStreamOutput failed: \(error.localizedDescription); retry BGRA")
                startStream(filter: filter, width: width, height: height, biplanar: false, generation: generation)
            } else {
                geometryLock.lock(); frameGeometryReceipt = nil; geometryLock.unlock()
                onDiagnostic?("addStreamOutput failed: \(error.localizedDescription)")
                onStatus?("捕获没有开始：\(error.localizedDescription)", true)
            }
        }
    }

    private func publishResizeDiagnostics() {
        func rectArray(_ r: CGRect?) -> Any { guard let r else { return NSNull() }; return [r.minX, r.minY, r.width, r.height] }
        let isWindow = filter?.style == .window
        let childWindowsRequested: Any
        if #available(macOS 14.2, *), isWindow { childWindowsRequested = false }
        else { childWindowsRequested = NSNull() }
        let value: [String: Any] = ["includeChildWindowsRequested": childWindowsRequested,
            "requested": resizeCounters.requested, "completed": resizeCounters.completed,
            "failed": resizeCounters.failed, "confirmed": resizeCounters.confirmed,
            "lastTarget": resizeLastTarget.map { [$0.width, $0.height] } as Any? ?? NSNull(),
            "configured": resizePolicy.map { [$0.configured.width, $0.configured.height] } as Any? ?? NSNull(),
            "filterContentAtStart": rectArray(filterRectAtStart), "filterContentCurrent": rectArray(filter?.contentRect),
            "filterPointPixelScale": filter.map { Double($0.pointPixelScale) } as Any? ?? NSNull(),
            "confirmationScope": "buffer dimensions only; content geometry not independently confirmed",
            "lastConfirmMs": resizeLastConfirmMs]
        resizeDiagnosticsLock.lock(); resizeDiagnosticsValue = ["resize": value, "resizeEvents": resizeEvents]; resizeDiagnosticsLock.unlock()
    }
    private func startResizeMonitoringIfNeeded(stream: SCStream, generation: UInt64) {
        stopResizeMonitoring(note: "new stream")
        guard self.stream === stream, currentGeneration == generation, case .window = target,
              let size = confirmedResizeSize else { publishResizeDiagnostics(); return }
        resizePolicy = CaptureResizePolicy(generation: generation, configured: size)
        publishResizeDiagnostics()
    }
    private func stopResizeMonitoring(note: String) {
        resizeRevision &+= 1; resizeTimer?.cancel(); resizeTimer = nil; resizePolicy = nil
        resizePendingConfirm = nil; resizeLastFrame = nil
        resizeObservationLock.lock(); resizeObservedGeneration = 0; resizeObservedTarget = nil; resizeObservedBuffer = nil; resizeWatch = nil; resizeObservationLock.unlock()
    }
    private func scheduleResize(stream: SCStream, generation: UInt64) {
        resizeTimer?.cancel(); resizeTimer = nil
        guard let policy = resizePolicy, policy.inFlight == nil, policy.candidate != nil else { return }
        let now = Int64(DispatchTime.now().uptimeNanoseconds)
        let remaining = max(0, policy.candidateSince + CaptureResizePolicy.quietNs - now)
        let revision = resizeRevision
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .nanoseconds(Int(remaining)))
        timer.setEventHandler { [weak self, weak stream] in
            guard let self, let stream, self.resizeRevision == revision, self.stream === stream,
                  self.currentGeneration == generation, self.running else { return }
            self.resizeTimer = nil
            let start = Int64(DispatchTime.now().uptimeNanoseconds)
            guard let request = self.resizePolicy?.tick(nowNs: start, running: true) else { return }
            let from = self.resizePolicy!.configured
            self.resizeCounters.requested += 1; self.resizeLastTarget = request.size
            self.resizeEvents.append(["host": start, "from": [from.width, from.height], "to": [request.size.width, request.size.height], "result": "requested", "elapsedMs": 0])
            if self.resizeEvents.count > 16 { self.resizeEvents.removeFirst() }
            self.publishResizeDiagnostics()
            let config = CaptureStreamConfiguration.make(width: request.size.width, height: request.size.height,
                biplanar: self.streamUsesBiplanar, capFPS: self.captureCapFPS, window: true)
            self.resizeObservationLock.lock()
            self.resizeWatch = (generation, request.size, start, false)
            self.resizeObservationLock.unlock()
            let streamBox = ResizeStreamBox(stream)
            stream.updateConfiguration(config) { [weak self, streamBox] error in
                let message = error?.localizedDescription
                DispatchQueue.main.async {
                    let stream = streamBox.stream
                    guard let self, self.resizeRevision == revision, self.stream === stream,
                          self.currentGeneration == generation, self.resizePolicy?.inFlight == request else { return }
                    let now = Int64(DispatchTime.now().uptimeNanoseconds)
                    self.resizePolicy?.complete(request, success: message == nil, nowNs: now)
                    if message == nil {
                        self.resizeCounters.completed += 1; self.resizePendingConfirm = (request.size, from, start)
                        self.confirmResizeIfObserved()
                    } else {
                        self.resizeCounters.failed += 1
                        self.resizeObservationLock.lock(); self.resizeWatch = nil; self.resizeObservationLock.unlock()
                    }
                    self.resizeEvents.append(["host": now, "from": [from.width, from.height], "to": [request.size.width, request.size.height],
                        "result": message == nil ? "completed" : "failed", "elapsedMs": Double(now-start)/1e6])
                    if self.resizeEvents.count > 16 { self.resizeEvents.removeFirst() }
                    self.publishResizeDiagnostics(); self.scheduleResize(stream: stream, generation: generation)
                }
            }
        }
        resizeTimer = timer; timer.resume()
    }
    private func confirmResizeIfObserved() {
        guard let pending = resizePendingConfirm, let frame = resizeLastFrame,
              frame.size == pending.size, frame.host >= pending.start else { return }
        confirmedResizeSize = pending.size; resizeCounters.confirmed += 1
        resizeObservationLock.lock(); resizeWatch = nil; resizeObservationLock.unlock()
        resizeLastConfirmMs = Double(frame.host - pending.start) / 1e6; resizePendingConfirm = nil
        resizeEvents.append(["host": frame.host, "from": [pending.from.width, pending.from.height], "to": [frame.size.width, frame.size.height],
                             "result": "confirmed", "elapsedMs": resizeLastConfirmMs])
        if resizeEvents.count > 16 { resizeEvents.removeFirst() }
    }
    // Called on the capture queue. Coalesce unchanged targets/buffer sizes here,
    // so static or repeated frames never enqueue a main-thread task each frame.
    private func observeResizeGeometry(_ geometry: [String: Any], image: CVPixelBuffer, stream: SCStream, generation: UInt64, host: UInt64) {
        guard let screen = geometry["screenRect"] as? [CGFloat], screen.count == 4,
              let content = geometry["contentRect"] as? [CGFloat], content.count == 4,
              let scale = geometry["scaleFactor"] as? Double,
              let desired = CaptureResizePolicy.target(screenRect: CGRect(x: screen[0], y: screen[1], width: screen[2], height: screen[3]),
                contentRect: CGRect(x: content[0], y: content[1], width: content[2], height: content[3]), scaleFactor: scale) else { return }
        let buffer = CaptureResizePolicy.Size(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        let frameHost = contentHostNs(host)
        resizeObservationLock.lock()
        var changed = resizeObservedGeneration != generation || resizeObservedTarget != desired || resizeObservedBuffer != buffer
        if var watch = resizeWatch, watch.generation == generation, watch.size == buffer, frameHost >= watch.start, !watch.notified {
            watch.notified = true; resizeWatch = watch; changed = true
        }
        resizeObservedGeneration = generation; resizeObservedTarget = desired; resizeObservedBuffer = buffer
        resizeObservationLock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self, weak stream] in
            guard let self, let stream, self.stream === stream, self.currentGeneration == generation,
                  self.running, case .window = self.target, self.resizePolicy != nil else { return }
            self.resizeLastFrame = (buffer, frameHost); self.confirmResizeIfObserved()
            self.resizePolicy?.observe(desired, nowNs: frameHost)
            self.publishResizeDiagnostics(); self.scheduleResize(stream: stream, generation: generation)
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
        if let generation = streamBinding.snapshot(stream) {
            _ = streamBinding.withCurrent(stream, generation: generation) {
                geometryLock.lock()
                if screenRectGeneration == generation { frameGeometryReceipt = nil }
                geometryLock.unlock()
                onGeometry?(nil, generation)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.stream === stream else {
                self.onDiagnostic?("retired stream stopped: \(error.localizedDescription)")
                return
            }
            self.running = false
            self.stopResizeMonitoring(note: "stream delegate stopped")
            self.queue.async { self.stoppedCount += 1 }
            self.onDiagnostic?("stream stopped: \(error.localizedDescription)")
            self.onStatus?("来源中断：\(error.localizedDescription)", true)
            self.onNote?(2)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let generation = streamBinding.snapshot(stream) else {
            retiredDrops += 1
            if retiredDrops <= 3 || retiredDrops % 60 == 0 {
                onDiagnostic?("ignored sample from a retired stream")
            }
            return
        }
        receivedSequence &+= 1
        lastReceivedHost = mach_absolute_time()
        if #available(macOS 13.1, *),
           let items = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let dictionary = items.first?[.screenRect] as? NSDictionary,
           let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
           rect.width > 1, rect.height > 1, rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite {
            geometryLock.lock()
            if screenRectGeneration == generation { screenRectValue = rect; screenRectHost = lastReceivedHost }
            geometryLock.unlock()
        }
        let observedStatus = frameStatus(sampleBuffer)
        lastFrameStatus = observedStatus?.rawValue ?? -1
        if let items = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]], let info = items.first {
            lastDisplayTime = (info[.displayTime] as? NSNumber)?.uint64Value ?? 0
            if let dictionaries = info[.dirtyRects] as? [NSDictionary] {
                let rects = dictionaries.compactMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                if rects.count == dictionaries.count && rects.allSatisfy({ $0.width.isFinite && $0.height.isFinite }) {
                    lastDirtyRectCount = rects.count
                    lastDirtyRectArea = rects.reduce(0) { $0 + Double(max(0, $1.width) * max(0, $1.height)) }
                } else { lastDirtyRectCount = -1; lastDirtyRectArea = 0 }
            } else { lastDirtyRectCount = -1; lastDirtyRectArea = 0 }
        }
        let status = observedStatus ?? .complete // preserve prior display compatibility
        if status == .idle {
            idleCount += 1
            if idleCount <= 3 || idleCount % 60 == 0 {
                onDiagnostic?("idle \(idleCount) complete \(completeCount)")
            }
            onNote?(1)
            return
        }
        if status == .blank || status == .suspended || status == .stopped {
            _ = streamBinding.withCurrent(stream, generation: generation) {
                geometryLock.lock()
                if screenRectGeneration == generation { frameGeometryReceipt = nil }
                geometryLock.unlock()
                onGeometry?(nil, generation)
            }
            if status == .blank { blankCount += 1 }
            if status == .suspended { suspendedCount += 1 }
            if status == .stopped { stoppedCount += 1 }
            onDiagnostic?("status \(status.rawValue) blank \(blankCount) suspended \(suspendedCount)")
            onNote?(2)
            return
        }
        completeCount += 1
        lastCompleteHost = mach_absolute_time()
        onNote?(0)
        guard !paused, let image = sampleBuffer.imageBuffer else {
            _ = streamBinding.withCurrent(stream, generation: generation) {
                geometryLock.lock()
                if screenRectGeneration == generation { frameGeometryReceipt = nil }
                geometryLock.unlock()
            }
            if paused {
                pausedDrops += 1
                if pausedDrops <= 3 || pausedDrops % 60 == 0 {
                    onDiagnostic?("paused; dropped complete \(completeCount)")
                }
            }
            return
        }
        let captureHost = lastReceivedHost
        let frameGeometry = geometryMetadata(sampleBuffer, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image), generation: generation)
        guard streamBinding.withCurrent(stream, generation: generation, {
            geometryLock.lock()
            if screenRectGeneration == generation {
                frameGeometryReceipt = observedStatus == .complete && !paused && CMSampleBufferIsValid(sampleBuffer) && CMSampleBufferDataIsReady(sampleBuffer)
                    ? CompleteFrameGeometryReceipt(geometry: frameGeometry, host: captureHost) : nil
            }
            geometryLock.unlock()
            onGeometry?(frameGeometry, generation)
        }) else { retiredDrops += 1; return }
        if let frameGeometry { observeResizeGeometry(frameGeometry, image: image, stream: stream, generation: generation, host: captureHost) }
        // Geometry remains current even for a duplicate, but duplicate pixels do
        // not become native-cadence evidence or enter the processor queue.
        if contentFrameGate.evaluate(buffer: image, generation: generation, hostNs: contentHostNs(captureHost)) == .duplicate { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsNum: Int64
        let ptsDen: Int64
        let validPTS = time.isValid && !time.isIndefinite && time.timescale > 0
        if validPTS {
            ptsNum = time.value
            ptsDen = Int64(time.timescale)
        } else {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            let host = Int64(mach_absolute_time())
            ptsNum = host * Int64(info.numer) / Int64(info.denom)
            ptsDen = 1_000_000_000
        }
        // Only metadata leaves this callback; do not retain the borrowed SCK
        // surface. Observe even when the owned capture pool cannot copy it.
        if CaptureCallbackPolicy.isRawCadenceEvidence(status: observedStatus,
                                                       valid: CMSampleBufferIsValid(sampleBuffer),
                                                       dataReady: CMSampleBufferDataIsReady(sampleBuffer)) {
            guard streamBinding.withCurrent(stream, generation: generation, {
                onRawFrame?(ptsNum, validPTS ? ptsDen : 0, Int64(captureHost),
                            Int32(CVPixelBufferGetWidth(image)), Int32(CVPixelBufferGetHeight(image)), generation)
            }) else { retiredDrops += 1; return }
        }
        borrowedPeak = max(borrowedPeak, 1)
        guard let owned = copier.copy(image) else {
            if copier.lastFailurePoolExhausted { onPoolPressure?(generation) }
            if completeCount <= 5 || completeCount % 30 == 0 {
                onDiagnostic?(copier.lastFailurePoolExhausted ? "capture pool full; dropped complete \(completeCount)" : "capture copy failed; dropped complete \(completeCount)")
            }
            return
        }
        let readyHost = mach_absolute_time()
        let timescale = CMTimeScale(min(max(ptsDen, 1), Int64(Int32.max)))
        if !firstPTS.isValid { firstPTS = time.isValid ? time : CMTime(value: ptsNum, timescale: timescale) }
        lastPTS = time.isValid ? time : CMTime(value: ptsNum, timescale: timescale)
        if firstHost == 0 { firstHost = captureHost }
        lastHost = captureHost
        pixelWidth = CVPixelBufferGetWidth(owned)
        pixelHeight = CVPixelBufferGetHeight(owned)
        let geometryKey = "app.openduckframe.capture.geometry" as CFString
        CVBufferRemoveAttachment(owned, geometryKey)
        if let frameGeometry { CVBufferSetAttachment(owned, geometryKey, frameGeometry as CFDictionary, .shouldNotPropagate) }
        let admitted = streamBinding.withCurrent(stream, generation: generation) {
            onFrame?(owned, ptsNum, ptsDen, Int64(captureHost), Int64(readyHost), generation)
        }
        guard admitted else { retiredDrops += 1; return }
        if r8FixtureEnabled {
            let sequence = R8FixtureDecoder.decode(owned)
            let motion = R8FixtureMotionProbe.sample(owned)
            let attachment = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
            geometryLock.lock()
            let sourceTarget = screenRectGeneration == generation ? geometryTarget : nil
            geometryLock.unlock()
            var sourceWindowID: Any = NSNull(), sourcePID: Any = NSNull(), sourceDisplayID: Any = NSNull()
            switch sourceTarget {
            case let .window(id, owner): sourceWindowID = id; sourcePID = owner
            case let .display(id): sourceDisplayID = id
            case nil: break
            }
            func rectValue(_ key: SCStreamFrameInfo) -> Any {
                guard let dictionary = attachment?[key] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                      rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return NSNull() }
                return [rect.origin.x, rect.origin.y, rect.width, rect.height]
            }
            if sequence != nil { r8FixtureSuccess &+= 1 } else { r8FixtureFailure &+= 1 }
            r8FixtureEvents.append(["generation": generation, "receivedSequence": receivedSequence,
                "captureHost": captureHost, "readyHost": readyHost, "ptsNum": ptsNum, "ptsDen": ptsDen,
                "decoded": sequence != nil, "frameNumber": sequence.map(Int.init) ?? -1, "motion": motion,
                "bufferPixels": [pixelWidth, pixelHeight], "contentRectSurfacePoints": rectValue(.contentRect),
                "screenRect": rectValue(.screenRect), "contentScale": (attachment?[.contentScale] as? NSNumber).map { $0 as Any } ?? NSNull(),
                "scaleFactor": (attachment?[.scaleFactor] as? NSNumber).map { $0 as Any } ?? NSNull(),
                "sourceWindowID": sourceWindowID, "sourcePID": sourcePID, "sourceDisplayID": sourceDisplayID,
                "geometryVersion": NSNull()])
            if r8FixtureEvents.count > 128 { r8FixtureEvents.removeFirst(r8FixtureEvents.count - 128) }
        }
        acceptedCount += 1
        lastAcceptedHost = captureHost
        if completeCount <= 5 || completeCount % 30 == 0 {
            onDiagnostic?("\(pixelWidth)x\(pixelHeight) complete \(completeCount) idle \(idleCount) pts \(ptsNum)/\(ptsDen) host \(captureHost) generation \(generation)")
        }
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
        geometryLock.lock()
        let geometry = screenRectGeneration == currentGeneration ? frameGeometryReceipt?.geometry : nil
        geometryLock.unlock()
        var report: [String: Any] = [
            "generation": currentGeneration,
            "lastContentRect": geometry?["contentRect"] ?? NSNull(),
            "lastScreenRect": geometry?["screenRect"] ?? NSNull(),
            "lastScaleFactor": geometry?["scaleFactor"] ?? NSNull(),
            "lastContentScale": geometry?["contentScale"] ?? NSNull(),
            "running": running,
            "paused": paused,
            "captureCapFPS": captureCapFPS,
            "requestedCaptureFPS": requestedCaptureFPS,
            "receivedSequence": receivedSequence,
            "lastReceivedHost": lastReceivedHost,
            "r8Fixture": ["enabled": r8FixtureEnabled, "decoded": r8FixtureSuccess, "failed": r8FixtureFailure,
                           "events": r8FixtureEvents, "note": "owned buffer samples; frame number is source-drawn sequence modulo 2^24"],
            "lastFrameStatus": lastFrameStatus,
            "lastDisplayTimeMachAbsolute": lastDisplayTime,
            "lastDirtyRectCount": lastDirtyRectCount,
            "lastDirtyRectAreaPixels": lastDirtyRectArea,
            "lastCompleteHost": lastCompleteHost,
            "lastAcceptedHost": lastAcceptedHost,
            "captureRateNote": requestedCaptureFPS == 0 ? "system maximum request; actual cadence may be lower" : "requested ceiling, not measured source FPS",
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
        for (key, value) in contentFrameGate.diagnostics(nowNs: contentHostNs(mach_absolute_time()), expectedGeneration: currentGeneration) {
            report[key] = value
        }
        resizeDiagnosticsLock.lock()
        report["resize"] = resizeDiagnosticsValue["resize"] ?? [:]
        report["resizeEvents"] = resizeDiagnosticsValue["resizeEvents"] ?? []
        resizeDiagnosticsLock.unlock()
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

    private func frameStatus(_ sample: CMSampleBuffer) -> SCFrameStatus? {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = array.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return nil }
        return status
    }

    // A missing/invalid attachment is deliberately not reconstructed from a
    // previous frame; the receiving geometry authority must invalidate it.
    private func geometryMetadata(_ sample: CMSampleBuffer, width: Int, height: Int, generation: UInt64) -> [String: Any]? {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let screenDictionary = info[.screenRect] as? NSDictionary,
              let contentDictionary = info[.contentRect] as? NSDictionary,
              let screen = CGRect(dictionaryRepresentation: screenDictionary as CFDictionary),
              let content = CGRect(dictionaryRepresentation: contentDictionary as CFDictionary),
              let factor = info[.scaleFactor] as? NSNumber, let contentScale = info[.contentScale] as? NSNumber,
              [Double(screen.minX), Double(screen.minY), Double(screen.width), Double(screen.height), Double(content.minX), Double(content.minY), Double(content.width), Double(content.height),
               factor.doubleValue, contentScale.doubleValue].allSatisfy({ $0.isFinite }),
              screen.width > 0, screen.height > 0, content.width > 0, content.height > 0,
              factor.doubleValue > 0, contentScale.doubleValue > 0 else { return nil }
        geometryLock.lock()
        let selected = screenRectGeneration == generation ? geometryTarget : nil
        geometryLock.unlock()
        guard case let .window(id, owner) = selected, id != 0, owner > 0 else { return nil }
        let value: [String: Any] = ["generation": generation, "windowID": id, "pid": owner,
            "bufferWidth": width, "bufferHeight": height,
            "screenRect": [screen.minX, screen.minY, screen.width, screen.height],
            "contentRect": [content.minX, content.minY, content.width, content.height],
            "scaleFactor": factor, "contentScale": contentScale]
        return value
    }

    func latestFrameGeometrySnapshot() -> (geometry: [String: Any], host: UInt64)? {
        geometryLock.lock(); defer { geometryLock.unlock() }
        guard screenRectGeneration == currentGeneration, let receipt = frameGeometryReceipt else { return nil }
        return (receipt.geometry, receipt.host)
    }

    func latestScreenRect() -> CGRect? {
        geometryLock.lock()
        defer { geometryLock.unlock() }
        return screenRectGeneration == currentGeneration ? screenRectValue : nil
    }

    func latestScreenRectSnapshot() -> (rect: CGRect, host: UInt64)? {
        geometryLock.lock()
        defer { geometryLock.unlock() }
        guard screenRectGeneration == currentGeneration, let rect = screenRectValue, screenRectHost > 0 else { return nil }
        return (rect, screenRectHost)
    }
}

/// Headless test entry point; it drives the real copier and processor queues.
/// It never starts ScreenCaptureKit or shows a window.
private final class OwnedCadenceSnapshots: @unchecked Sendable {
    private let lock=NSLock()
    private var rows: [[String: Any]]=[]
    func append(_ row: [String: Any]) { lock.lock(); rows.append(row); lock.unlock() }
    func read() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows }
}

@objc(SPOwnedCaptureContract)
final class SPOwnedCaptureContract: NSObject {
    @objc static func runNative120() -> [String: Any] {
        runNative120Scenario(width:2560, height:1410, format:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, expectedCap:16)
    }

    @objc static func runNative120BGRA() -> [String: Any] {
        runNative120Scenario(width:2560, height:1440, format:kCVPixelFormatType_32BGRA, expectedCap:6)
    }

    private static func runNative120Scenario(width: Int, height: Int, format: OSType, expectedCap: Int) -> [String: Any] {
        let count=240
        let copier=OwnedFrameCopier()
        let processor=SPLiveProcessor()
        processor.ownedContractConfigureNative(width: Int32(width), height: Int32(height))
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        var raw: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                                  attrs as CFDictionary, &raw) == kCVReturnSuccess, let raw else {
            processor.stop(); return ["ok":false,"reason":"source allocation"]
        }
        // Warm the actual conversion, processor queue and playout clock outside
        // the measured interval. Negative PTS precedes every measured frame.
        for i in -3..<0 {
            autoreleasepool {
                if let owned=copier.copy(raw) {
                    processor.push(owned, ptsNum:Int64(i), ptsDen:120, host:Int64(mach_absolute_time()), generation:1)
                }
            }
        }
        _ = processor.ownedContractFence()
        Thread.sleep(forTimeInterval:0.2)
        var accepted=0, failed=0, first: UInt64=0, last: UInt64=0
        var intervalsMs: [Double] = []
        var scheduleLatenessMs: [Double] = [], copyWallMs: [Double] = []
        var info=mach_timebase_info_data_t(); mach_timebase_info(&info)
        let segments=OwnedCadenceSnapshots()
        let start=CACurrentMediaTime()
        for i in 0..<count {
            let target=start+Double(i)/120.0
            // A short, bounded busy wait avoids coalesced background sleeps;
            // host timing is still measured and must pass the pacing check.
            while CACurrentMediaTime()<target {}
            scheduleLatenessMs.append(max(0,(CACurrentMediaTime()-target)*1000))
            let host=mach_absolute_time()
            if first==0 { first=host }
            else { intervalsMs.append(Double(host-last)*Double(info.numer)/Double(info.denom)/1_000_000) }
            last=host
            processor.noteRawCapture(ptsNum:Int64(i), ptsDen:120, host:Int64(host), width:Int32(width), height:Int32(height), generation:1)
            let copyStart=CACurrentMediaTime()
            autoreleasepool {
                if let owned=copier.copy(raw) {
                    processor.push(owned, ptsNum:Int64(i), ptsDen:120, host:Int64(host), readyHost:Int64(mach_absolute_time()), generation:1)
                    accepted += 1
                } else { failed += 1 }
            }
            copyWallMs.append((CACurrentMediaTime()-copyStart)*1000)
            if [119,159,199,239].contains(i) {
                let frameNumber=i+1, requestedAt=host, poolAtRequest=copier.snapshot()
                processor.ownedContractAsyncFence { snapshot in
                    segments.append(["requestFrame":frameNumber, "requestHost":requestedAt,
                                     "processor":snapshot, "capturePoolAtRequest":poolAtRequest])
                }
            }
        }
        let fence=processor.ownedContractFence()
        let stats=processor.stats
        let pool=copier.snapshot()
        let span=Double(last-first)*Double(info.numer)/Double(info.denom)/1_000_000_000
        let fps=span>0 ? Double(count-1)/span : 0
        let sorted=intervalsMs.sorted()
        let p95=sorted.isEmpty ? -1 : sorted[(sorted.count-1)*95/100]
        let orderedCopy=copyWallMs.sorted(), orderedLateness=scheduleLatenessMs.sorted()
        let copyP95=orderedCopy.isEmpty ? -1 : orderedCopy[(orderedCopy.count-1)*95/100]
        let latenessP95=orderedLateness.isEmpty ? -1 : orderedLateness[(orderedLateness.count-1)*95/100]
        // This test targets 120 callback deliveries. The rate threshold uses
        // the gate's 95% host entry bound; 1.35 periods is its slow interval bound.
        let pacing=fps>=120*0.95 && p95>0 && p95<=1000.0/120.0*1.35
        let processed=(fence["processed"] as? NSNumber)?.intValue ?? 0
        let sources=(fence["playoutSource"] as? NSNumber)?.intValue ?? 0
        let active=(fence["nativeBudgetActive"] as? NSNumber)?.boolValue ?? false
        let samples=segments.read()
        var continuous=samples.count==4
        for i in 1..<samples.count {
            guard let previous=samples[i-1]["processor"] as? [String: Any], let current=samples[i]["processor"] as? [String: Any] else { continuous=false; continue }
            let previousProcessed=(previous["processed"] as? NSNumber)?.intValue ?? 0, currentProcessed=(current["processed"] as? NSNumber)?.intValue ?? 0
            let previousSource=(previous["playoutSource"] as? NSNumber)?.intValue ?? 0, currentSource=(current["playoutSource"] as? NSNumber)?.intValue ?? 0
            let currentSlots=(current["slots"] as? NSNumber)?.intValue ?? 0, cap=(current["slotCap"] as? NSNumber)?.intValue ?? 0
            continuous = continuous && (previous["nativeBudgetActive"] as? NSNumber)?.boolValue == true && (current["nativeBudgetActive"] as? NSNumber)?.boolValue == true &&
                currentProcessed>previousProcessed && currentSource>previousSource && currentSlots<=cap
        }
        let ok=pacing && continuous && accepted>0 && processed>0 && sources>0 && active && failed==0 && (pool["ownedCap"] as? Int)==expectedCap
        processor.stop()
        return ["ok":ok, "inputFormat":format == kCVPixelFormatType_32BGRA ? "BGRA" : "420v/NV12", "width":width, "height":height, "callbacks":count,
                "requestedCallbackHz":120, "callbackDeliveryHz":fps, "callbackIntervalP95ms":p95, "callbackIntervalsMs":intervalsMs,
                "scheduleLatenessP95ms":latenessP95, "scheduleLatenessMaxMs":scheduleLatenessMs.max() ?? -1,
                "scheduleLatenessMs":scheduleLatenessMs, "copyAndEnqueueWallP95ms":copyP95, "copyAndEnqueueWallMs":copyWallMs,
                "callbackPacingValid":pacing, "copyAccepted":accepted, "copyFailed":failed, "pumpProcessed":processed,
                "sourcePlayout":sources, "nativeBudgetActive":active, "continuousNativeSegments":continuous, "segments":samples, "processorFence":fence, "capturePool":pool,
                "rawPTSRate":stats["rawCallbackPTSRate"] ?? -1, "rawHostRate":stats["rawCallbackHostRate"] ?? -1,
                "copyAcceptedHostRate":stats["copyAcceptedHostRate"] ?? -1, "pumpArrivalRate":stats["pumpArrivalRate"] ?? -1,
                "scope":"production metadata, owned copier and processor queues with synthetic paced buffers and an unprepared RIFE bridge; no SCK, model inference, drawable, physical FPS or GUI"]
    }

    @objc static func run() -> [String: Any] {
        var results: [[String: Any]] = []
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            for cap in [4, 6, 7, 8, 16] {
                let bytes = format == kCVPixelFormatType_32BGRA ? 64 * 64 * 4 : 64 * 64 * 3 / 2
                let copier = OwnedFrameCopier(budgetBytes: bytes * cap)
                let processor = SPLiveProcessor()
                let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                               kCVPixelBufferMetalCompatibilityKey: true]
                var raw: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, format, attrs as CFDictionary, &raw) == kCVReturnSuccess,
                      let raw else { return ["ok": false, "reason": "source allocation"] }
                var accepted = 0
                for i in 1...120 {
                    autoreleasepool {
                        CVPixelBufferLockBaseAddress(raw, [])
                        let p = CVPixelBufferIsPlanar(raw) ? CVPixelBufferGetBaseAddressOfPlane(raw, 0) : CVPixelBufferGetBaseAddress(raw)
                        p?.storeBytes(of: UInt8(i), as: UInt8.self)
                        CVPixelBufferUnlockBaseAddress(raw, [])
                        if let owned = copier.copy(raw) {
                            processor.push(owned, ptsNum: Int64(i), ptsDen: 60, host: Int64(mach_absolute_time()), generation: 1)
                            accepted += 1
                        }
                    }
                    // At the smallest BGRA pool, allow the real playout clock
                    // to retire queued source slots before the next sample.
                    if cap == 4 && format == kCVPixelFormatType_32BGRA {
                        Thread.sleep(forTimeInterval: 1.0 / 60.0)
                    }
                    _ = processor.ownedContractFence()
                }
                let before = processor.ownedContractFence()
                // A distinct production-copy buffer is held only by the
                // idle redraw slot, never by held/pending/playout. Releasing
                // the local reference leaves pressure as its only releaser.
                processor.ownedContractStabilizePlayout()
                var installed = false
                var redrawToken: UInt64 = 0
                autoreleasepool {
                    if let redraw = copier.copy(raw) {
                        redrawToken = UInt64(UInt(bitPattern: Unmanaged.passUnretained(redraw).toOpaque()))
                        processor.ownedContractInstallRedraw(redraw)
                        installed = true
                    }
                }
                let redrawHeldBefore = redrawToken != 0 && processor.ownedContractRedrawIdentity() == redrawToken
                let pinned = processor.ownedContractPinOldest()
                let old = processor.ownedContractByte(forIdentity: pinned)
                var consumers: [CVPixelBuffer] = []
                while let frame = copier.copy(raw) { consumers.append(frame) }
                let exhausted = copier.copy(raw) == nil
                // Consumers remain retained through the pressure operation and
                // recovery allocation. No test-side release creates headroom.
                processor.noteCapturePoolPressure(forGeneration: 0)
                _ = processor.ownedContractFence()
                let stalePreserved = processor.ownedContractRedrawIdentity() == redrawToken && copier.copy(raw) == nil && old == processor.ownedContractByte(forIdentity: pinned)
                processor.ownedContractQueueCurrentThenStalePressure()
                _ = processor.ownedContractFence()
                let pressureReleased = installed && processor.ownedContractRedrawIdentity() == 0
                let pinnedAfterPressure = pinned != 0 && old >= 0 && old == processor.ownedContractByte(forIdentity: pinned)
                let recovered = copier.copy(raw)
                let resumed = recovered != nil
                withExtendedLifetime(consumers) { withExtendedLifetime(recovered) {} }
                processor.ownedContractCompleteIdentity(pinned, stale: true)
                let secondPin = processor.ownedContractPinOldest()
                if secondPin != 0 { processor.ownedContractCompleteIdentity(secondPin, stale: false) }
                let snapshot = copier.snapshot()
                let processed = (before["processed"] as? NSNumber)?.intValue ?? 0
                let ok = accepted >= 100 && processed >= 100 && installed && redrawHeldBefore && exhausted && stalePreserved && pinnedAfterPressure && pressureReleased && resumed && (snapshot["ownedCap"] as? Int) == cap
                results.append(["format": format, "cap": cap, "accepted": accepted, "processed": processed,
                                "independentRedrawInstalled": installed && redrawHeldBefore, "exhaustedImmediatelyBeforePressure": exhausted,
                                "stalePressurePreservedRedrawAndPin": stalePreserved, "pinnedImmutableAfterPressure": pinnedAfterPressure, "pressureReleasedRedraw": pressureReleased,
                                "resumedBeforeConsumerRelease": resumed, "ok": ok])
                processor.stop()
            }
        }
        return ["ok": results.allSatisfy { ($0["ok"] as? Bool) == true }, "results": results,
                "scope": "production copier and processor queue, synthetic input, simulated pinned completion and idle-redraw pressure; no SCK, GPU/VT job, stream cache or drawable"]
    }
}
