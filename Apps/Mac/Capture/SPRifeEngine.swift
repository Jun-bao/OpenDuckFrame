import CoreVideo
import CoreMedia
import CryptoKit
import Foundation
import RifeMetal
import VideoToolbox
import os

@objc(SPRifeBridge)
final class SPRifeBridge: NSObject {
    static let packageVersion = "0.1.8"
    static let packageCommit = "ac6408022eb6bc1a53181f5b2716a9f5ded507c2"
    static let model426SHA256 = "01c6ce74e26a3b2eb3430eb2c0bdb490e2725cb2f2bf6136c2b0e98148bc0ee1"

    private let resourceBundle: Bundle
    override init() { self.resourceBundle = .main; super.init() }
    @objc(initWithResourceBundle:)
    init(resourceBundle: Bundle) { self.resourceBundle = resourceBundle; super.init() }

    private let exec = DispatchQueue(label: "app.openduckframe.rife", qos: .userInitiated)
    private let state = NSLock()
    private var interpolator: RifeInterpolator?
    private var transfer: VTPixelTransferSession?
    private var epoch: UInt64 = 0
    private var loadedModelID = ""
    private var loadedQuality = "fast"
    private var loadedExperiment: [String: Any] = [:]
    // Only touched on exec. Retaining the source prevents pixel-buffer pool reuse.
    private var stream: RifeStream?
    private var streamEpoch: UInt64 = 0
    @objc var liveStreamEnabled = false
    private var contractFailNext = false // exec queue only
    private var pressureResetQueued = false // protected by state
    private var streamPreviousFormat: OSType = 0
    private var streamPrevious: CVPixelBuffer?
    private var streamKey: SPRifeContinuityKey?
    private var outputPool: CVPixelBufferPool?
    private let diagnosticLock = NSLock()
    private var diagnosticCounts: [String: Int] = [:]
    private var convertSamplesMs: [Double] = [], pushSamplesMs: [Double] = []
    private var recentJobs: [[String: Any]] = []
    private func count(_ name: String) {
        diagnosticLock.lock(); diagnosticCounts[name, default: 0] += 1; diagnosticLock.unlock()
    }
    private let traceLog = OSLog(subsystem: "app.chuanflow.throughput", category: "RIFE")

    @objc(prepareModelID:quality:width:height:error:)
    func prepare(modelID: String, quality: String, width: Int32, height: Int32) throws {
        let tier = Self.tier(quality)
        let url = try Self.url(for: modelID, bundle: resourceBundle)
        let experiment = try SPRifeExperiments.resolve(modelID: modelID, originalURL: url, bundle: resourceBundle)
        let options = experiment.map {
            RifeExperimentOptions(gpuIO: $0.selection.ioOptimized, replaceMask: $0.selection.replaceMask)
        } ?? RifeExperimentOptions()
        let engine = try RifeInterpolator(configuration: RifeConfiguration(
            modelURL: experiment?.url ?? url, qualityTier: tier, preferredDevice: nil,
            experimentOptions: options))
        let previousNV = try Self.nv12(width: Int(width), height: Int(height), luma: 32)
        let currentNV = try Self.nv12(width: Int(width), height: Int(height), luma: 180)
        let previous = try ownedBGRA(previousNV)
        let current = try ownedBGRA(currentNV)
        let warmed = try engine.interpolate(previous: previous, current: current, timesteps: [0.5])
        guard warmed.count == 1 else { throw Self.error(2, "RIFE 预热没有返回中间帧") }
        guard CVPixelBufferGetWidth(warmed[0]) == Int(width), CVPixelBufferGetHeight(warmed[0]) == Int(height) else {
            throw Self.error(2, "RIFE 预热输出尺寸和来源不一致")
        }
        state.lock()
        epoch &+= 1
        interpolator = engine
        loadedModelID = modelID
        loadedQuality = tier.rawValue
        loadedExperiment = experiment?.diagnostics ?? [:]
        state.unlock()
    }

    @objc(submitPrevious:current:timesteps:token:completion:)
    func submit(previous: CVPixelBuffer, current: CVPixelBuffer, timesteps: [NSNumber], token: UInt64, completion: @escaping (UInt64, [SPOwnedPixelBuffer]?, Double, Error?) -> Void) -> Bool {
        let phases = timesteps.map(\.floatValue)
        guard !phases.isEmpty, phases.allSatisfy({ $0 > 0 && $0 < 1 }) else { return false }
        state.lock()
        let engine = interpolator
        let seen = epoch
        state.unlock()
        guard let engine else { return false }
        exec.async {
            self.state.lock()
            let currentEpoch = self.epoch
            self.state.unlock()
            if currentEpoch != seen {
                completion(token, nil, 0, Self.error(1, "RIFE 结果属于旧会话"))
                return
            }
            let started = ProcessInfo.processInfo.systemUptime
            let trace = ProcessInfo.processInfo.environment["CHUANFLOW_THROUGHPUT_TRACE"] == "1"
            let log = self.traceLog
            let signpost = trace ? OSSignpostID(log: log) : .invalid
            if trace { os_signpost(.begin, log: log, name: "RIFE stateless", signpostID: signpost) }
            defer { if trace { os_signpost(.end, log: log, name: "RIFE stateless", signpostID: signpost) } }
            do {
                let left = try self.ownedBGRA(previous)
                let right = try self.ownedBGRA(current)
                let frames = try engine.interpolate(previous: left, current: right, timesteps: phases)
                guard frames.count == phases.count else {
                    completion(token, nil, 0, Self.error(2, "RIFE 输出数量和相位不一致"))
                    return
                }
                let owned: [SPOwnedPixelBuffer] = frames.map { buffer in
                    CVBufferPropagateAttachments(left, buffer)
                    Self.attach709IfMissing(buffer)
                    return SPOwnedPixelBuffer(retaining: buffer)
                }
                let elapsed = SPPerformanceSimulation.current.finish(started: started)
                completion(token, owned, elapsed, nil)
            } catch {
                completion(token, nil, max(0, ProcessInfo.processInfo.systemUptime - started), Self.explain(error))
            }
        }
        return true
    }

    @objc(submitLivePrevious:current:previousID:currentID:previousPTS:currentPTS:generation:clockEpoch:timesteps:token:completion:)
    func submitLive(previous: CVPixelBuffer, current: CVPixelBuffer, previousID: UInt64, currentID: UInt64,
                    previousPTS: CMTime, currentPTS: CMTime, generation: UInt64, clockEpoch: UInt64,
                    timesteps: [NSNumber], token: UInt64,
                    completion: @escaping (UInt64, [SPOwnedPixelBuffer]?, Double, Error?) -> Void) -> Bool {
        // Default remains the proven stateless bridge until equivalence is measured.
        guard liveStreamEnabled || ProcessInfo.processInfo.environment["CHUANFLOW_RIFE_STREAM"] == "1" else {
            return submit(previous: previous, current: current, timesteps: timesteps, token: token, completion: completion)
        }
        let phases = timesteps.map(\.floatValue)
        guard !phases.isEmpty, phases.allSatisfy({ $0 > 0 && $0 < 1 }),
              previousPTS.isNumeric, currentPTS.isNumeric, CMTimeCompare(previousPTS, currentPTS) < 0,
              previousID != currentID else { return false }
        state.lock(); let engine = interpolator; let seen = epoch; state.unlock()
        guard let engine else { return false }
        exec.async {
            autoreleasepool {
                let started = ProcessInfo.processInfo.systemUptime
                let trace = ProcessInfo.processInfo.environment["CHUANFLOW_THROUGHPUT_TRACE"] == "1"
                let log = self.traceLog
                let signpost = trace ? OSSignpostID(log: log) : .invalid
                if trace { os_signpost(.begin, log: log, name: "RIFE stream", signpostID: signpost) }
                defer { if trace { os_signpost(.end, log: log, name: "RIFE stream", signpostID: signpost) } }
                self.state.lock(); let active = self.epoch == seen; self.state.unlock()
                guard active else { completion(token, nil, 0, Self.error(1, "RIFE 结果属于旧会话")); return }
                var convertNs: UInt64 = 0, pushNs: UInt64 = 0
                var convertCalls = 0, pushCalls = 0
                var cacheHit: Bool?
                func measuredBGRA(_ bridge: SPRifeBridge, _ source: CVPixelBuffer) throws -> CVPixelBuffer {
                    let began = DispatchTime.now().uptimeNanoseconds
                    defer { convertNs += DispatchTime.now().uptimeNanoseconds - began; convertCalls += 1 }
                    return try bridge.ownedBGRA(source)
                }
                func measuredPush<T>(_ operation: () throws -> T) rethrows -> T {
                    let began = DispatchTime.now().uptimeNanoseconds
                    defer { pushNs += DispatchTime.now().uptimeNanoseconds - began; pushCalls += 1 }
                    return try operation()
                }
                func recordTiming(_ bridge: SPRifeBridge) -> Double {
                    let elapsed = SPPerformanceSimulation.current.finish(started: started)
                    bridge.recordStreamTiming(totalMs: elapsed * 1000,
                                              convertMs: convertCalls > 0 ? Double(convertNs) / 1e6 : nil,
                                              pushMs: pushCalls > 0 ? Double(pushNs) / 1e6 : nil,
                                              hit: cacheHit)
                    return elapsed
                }
                do {
                    let width = CVPixelBufferGetWidth(previous), height = CVPixelBufferGetHeight(previous)
                    guard width == CVPixelBufferGetWidth(current), height == CVPixelBufferGetHeight(current) else {
                        throw Self.error(2, "RIFE 输入尺寸不一致")
                    }
                    if self.stream == nil || self.streamEpoch != seen || self.stream?.width != width || self.stream?.height != height {
                        self.stream = try engine.makeStream(width: width, height: height)
                        self.streamEpoch = seen; self.streamPrevious = nil; self.streamKey = nil; self.outputPool = nil
                    }
                    let stream = self.stream!
                    if self.contractFailNext {
                        self.contractFailNext = false
                        throw Self.error(99, "injected stream failure")
                    }
                    let previousKey = SPRifeContinuityKey(address: UInt(bitPattern: Unmanaged.passUnretained(previous).toOpaque()),
                        identity: previousID, pts: previousPTS, generation: generation, clockEpoch: clockEpoch)
                    let previousFormat = CVPixelBufferGetPixelFormatType(previous)
                    let currentFormat = CVPixelBufferGetPixelFormatType(current)
                    let hit = previousFormat == currentFormat && self.streamPreviousFormat == previousFormat &&
                        self.streamPrevious === previous && self.streamKey?.matches(previousKey) == true
                    cacheHit = hit
                    if hit { self.count("hits") } else {
                        self.count("misses")
                        stream.reset(); self.streamPrevious = nil; self.streamKey = nil; self.count("resets")
                        let left = try measuredBGRA(self, previous)
                        guard try measuredPush({ try stream.push(left, timesteps: []) }).isEmpty else { throw Self.error(2, "RIFE 缓存初始化失败") }
                    }
                    let right = try measuredBGRA(self, current)
                    let frames: [CVPixelBuffer]
                    if phases.count == 1 && phases[0] == 0.5 {
                        let output = try self.pooledOutput(width: width, height: height)
                        guard try measuredPush({ try stream.push(right, into: output) }) else { throw Self.error(2, "RIFE 中间帧缺失") }
                        frames = [output]
                    } else {
                        frames = try measuredPush { try stream.push(right, timesteps: phases) }
                    }
                    guard frames.count == phases.count, frames.allSatisfy({ CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height }) else {
                        throw Self.error(2, "RIFE 输出数量或尺寸不一致")
                    }
                    self.streamPrevious = current
                    self.streamPreviousFormat = currentFormat
                    self.streamKey = SPRifeContinuityKey(address: UInt(bitPattern: Unmanaged.passUnretained(current).toOpaque()),
                        identity: currentID, pts: currentPTS, generation: generation, clockEpoch: clockEpoch)
                    self.state.lock(); let stillActive = self.epoch == seen; self.state.unlock()
                    guard stillActive else { stream.reset(); self.streamPrevious = nil; self.streamKey = nil; throw Self.error(1, "RIFE 结果属于旧会话") }
                    let owned = frames.map { buffer in
                        CVBufferPropagateAttachments(previous, buffer); Self.attach709IfMissing(buffer)
                        return SPOwnedPixelBuffer(retaining: buffer)
                    }
                    completion(token, owned, recordTiming(self), nil)
                } catch {
                    self.stream?.reset(); self.streamPrevious = nil; self.streamKey = nil; self.count("resets")
                    let failure = Self.explain(error) as NSError
                    if failure.domain == "app.openduckframe.rife" && failure.code == 10 {
                        completion(token, nil, recordTiming(self), failure)
                        return
                    }
                    // Retry with the same model, quality, resolution and phases.
                    // A retired epoch is never allowed to publish fallback output.
                    do {
                        self.state.lock(); let active = self.epoch == seen; self.state.unlock()
                        guard active else { throw Self.error(1, "RIFE 结果属于旧会话") }
                        let left = try measuredBGRA(self, previous), right = try measuredBGRA(self, current)
                        let frames = try engine.interpolate(previous: left, current: right, timesteps: phases)
                        guard frames.count == phases.count, frames.allSatisfy({
                            CVPixelBufferGetWidth($0) == CVPixelBufferGetWidth(previous) &&
                            CVPixelBufferGetHeight($0) == CVPixelBufferGetHeight(previous)
                        }) else { throw Self.error(2, "RIFE 回退输出数量或尺寸不一致") }
                        self.state.lock(); let stillActive = self.epoch == seen; self.state.unlock()
                        guard stillActive else { throw Self.error(1, "RIFE 结果属于旧会话") }
                        let owned = frames.map { buffer in
                            CVBufferPropagateAttachments(left, buffer); Self.attach709IfMissing(buffer)
                            return SPOwnedPixelBuffer(retaining: buffer)
                        }
                        self.count("fallbackSucceeded")
                        completion(token, owned, recordTiming(self), nil)
                    } catch {
                        self.count("fallbackFailed")
                        completion(token, nil, recordTiming(self), Self.explain(error))
                    }
                }
            }
        }
        return true
    }

    private func pooledOutput(width: Int, height: Int) throws -> CVPixelBuffer {
        if outputPool == nil {
            let attrs: [String: Any] = [kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
                throw Self.error(2, "RIFE 输出池创建失败")
            }
            outputPool = pool
        }
        count("poolRequests")
        var buffer: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 4] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, outputPool!, aux, &buffer)
        if status == kCVReturnWouldExceedAllocationThreshold {
            count("poolFailures"); throw Self.error(10, "RIFE 输出池繁忙，等待已持有的画面释放。")
        }
        guard status == kCVReturnSuccess, let buffer, CVPixelBufferGetIOSurface(buffer) != nil else {
            count("poolFailures"); throw Self.error(2, "RIFE 输出池分配失败（\(status)）")
        }
        return buffer
    }

    @objc func resetLiveCacheForRateBudgetProbe() {
        // Enqueued before the first probe job on the same serial exec queue.
        exec.async {
            self.stream?.reset()
            self.streamPrevious = nil
            self.streamKey = nil
            self.streamPreviousFormat = 0
        }
    }

    @objc func relieveCapturePressure() {
        state.lock()
        if pressureResetQueued { state.unlock(); return }
        pressureResetQueued = true
        state.unlock()
        // Serialized after previously submitted work; never releases an input
        // while the stream is still using it on the GPU.
        exec.async {
            if self.streamPrevious != nil {
                self.stream?.reset(); self.streamPrevious = nil; self.streamKey = nil
                self.count("pressureResets")
            }
            self.state.lock(); self.pressureResetQueued = false; self.state.unlock()
        }
    }

    @objc func injectStreamFailureForContract() {
        exec.sync { contractFailNext = true }
    }

    // One accumulated sample per live task, including both inputs on a miss.
    // Error fallback conversion is included; stateless interpolate is not push.
    private func recordStreamTiming(totalMs: Double, convertMs: Double?, pushMs: Double?, hit: Bool?) {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        if let convertMs {
            convertSamplesMs.append(convertMs)
            if convertSamplesMs.count > 256 { convertSamplesMs.removeFirst(convertSamplesMs.count - 256) }
        }
        if let pushMs {
            pushSamplesMs.append(pushMs)
            if pushSamplesMs.count > 256 { pushSamplesMs.removeFirst(pushSamplesMs.count - 256) }
        }
        recentJobs.append([
            "totalMs": totalMs,
            "convertMs": convertMs.map { $0 as Any } ?? NSNull(),
            "pushMs": pushMs.map { $0 as Any } ?? NSNull(),
            "hit": hit.map { $0 as Any } ?? NSNull()
        ])
        if recentJobs.count > 32 { recentJobs.removeFirst(recentJobs.count - 32) }
    }

    @objc func streamDiagnostics() -> [String: Any] {
        diagnosticLock.lock()
        let counts = diagnosticCounts, convert = convertSamplesMs, push = pushSamplesMs, jobs = recentJobs
        diagnosticLock.unlock()
        func summary(_ values: [Double]) -> (median: Double, p95: Double) {
            guard !values.isEmpty else { return (-1, -1) }
            let sorted = values.sorted(), count = values.count
            return ((sorted[(count - 1) / 2] + sorted[count / 2]) / 2, sorted[(count - 1) * 95 / 100])
        }
        let convertTiming = summary(convert), pushTiming = summary(push)
        let environment = ProcessInfo.processInfo.environment["CHUANFLOW_RIFE_STREAM"] == "1"
        state.lock(); let experiment = loadedExperiment; state.unlock()
        let result: [String: Any] = ["requested": liveStreamEnabled, "effective": liveStreamEnabled || environment,
                "enableSource": liveStreamEnabled ? "request" : (environment ? "environment" : "disabled"),
                "hits": counts["hits", default: 0], "misses": counts["misses", default: 0],
                "resets": counts["resets", default: 0], "pressureResets": counts["pressureResets", default: 0], "fallbackSucceeded": counts["fallbackSucceeded", default: 0],
                "fallbackFailed": counts["fallbackFailed", default: 0], "poolRequests": counts["poolRequests", default: 0],
                "poolFailures": counts["poolFailures", default: 0],
                "convertMedianMs": convertTiming.median, "convertP95Ms": convertTiming.p95,
                "pushMedianMs": pushTiming.median, "pushP95Ms": pushTiming.p95,
                "rifeRecentJobs": jobs]
        return result.merging(experiment) { _, current in current }
    }

    @objc func invalidate() {
        state.lock()
        epoch &+= 1
        let invalidatedEpoch = epoch
        let engine = interpolator
        interpolator = nil
        state.unlock()
        exec.async {
            if self.streamEpoch < invalidatedEpoch {
                self.stream?.reset(); self.stream = nil; self.streamPrevious = nil; self.streamKey = nil; self.outputPool = nil
            }
            _ = engine
        }
    }

    @objc class func probe() -> [String: Any] {
        let bundled = RifeConfiguration.bundledModelURL
        let bundledOutsideExperiment = !bundled.path.contains("interpolation-experiment") && FileManager.default.fileExists(atPath: bundled.path)
        var report: [String: Any] = [
            "package": "cinemore/rife-metal",
            "version": packageVersion,
            "commit": packageCommit,
            "bundledModel": bundled.path,
            "bundledModelSHA256": sha256(of: bundled),
            "bundledOutsideExperiment": bundledOutsideExperiment,
            "sdrOnly": true,
            "pixelFormats": ["BGRA8", "RGBA8"],
        ]
        let fast = Self.runPixels(modelID: "rife-v4.25", quality: "fast", width: 320, height: 192, motion: 24)
        report["fast"] = fast
        report["fastNV12"] = Self.runNV12(modelID: "rife-v4.25", quality: "fast", width: 320, height: 192, motion: 24)
        report["fastPressure"] = Self.runPixels(modelID: "rife-v4.25", quality: "fast", width: 320, height: 192, motion: 80)
        report["balanced"] = Self.runPixels(modelID: "rife-v4.25", quality: "balanced", width: 640, height: 360, motion: 24)
        report["balancedPressure"] = Self.runPixels(modelID: "rife-v4.25", quality: "balanced", width: 640, height: 360, motion: 160)
        report["hq"] = Self.runPixels(modelID: "rife-v4.25", quality: "hq", width: 320, height: 192, motion: 24)
        report["model426"] = Self.runPixels(modelID: "rife-v4.26", quality: "balanced", width: 320, height: 192, motion: 24)
        if let url = try? url(for: "rife-v4.26") {
            report["model426Path"] = url.path
            report["model426SHA256"] = sha256(of: url)
            report["model426OutsideExperiment"] = !url.path.contains("interpolation-experiment")
        }
        let seamOK = (report["fastNV12"] as? [String: Any])?["ok"] as? Bool == true
        let fastOK = (fast["ok"] as? Bool) == true
        report["ok"] = bundledOutsideExperiment && fastOK && seamOK
        let digest = report["model426SHA256"] as? String
        report["model426DeclaredAvailable"] = digest == model426SHA256 && (report["model426"] as? [String: Any])?["ok"] as? Bool == true
        return report
    }

    private static func runPixels(modelID: String, quality: String, width: Int, height: Int, motion: Int) -> [String: Any] {
        let bridge = SPRifeBridge()
        do {
            try bridge.prepare(modelID: modelID, quality: quality, width: Int32(width), height: Int32(height))
        } catch {
            return ["ok": false, "modelID": modelID, "quality": quality, "error": error.localizedDescription]
        }
        guard let previous = try? buffer(width: width, height: height, value: 0),
              let current = try? buffer(width: width, height: height, value: 0) else {
            return ["ok": false, "modelID": modelID, "error": "buffer"]
        }
        let centerA = width / 2 - motion / 2
        let centerB = width / 2 + motion / 2
        paint(previous, center: centerA)
        paint(current, center: centerB)
        let phases: [Float] = [0.25, 0.5, 0.75, 1.0 / 3.0, 2.0 / 3.0]
        let done = DispatchSemaphore(value: 0)
        var frames: [SPOwnedPixelBuffer]?
        var callError: Error?
        let submitted = bridge.submit(previous: previous, current: current, timesteps: phases.map { NSNumber(value: $0) }, token: 1) { _, outputs, _, error in
            frames = outputs
            callError = error
            done.signal()
        }
        guard submitted else { return ["ok": false, "modelID": modelID, "error": "submit"] }
        done.wait()
        bridge.invalidate()
        var centers: [Double] = []
        var positions = frames?.count == phases.count && callError == nil
        for (index, box) in (frames ?? []).enumerated() {
            let center = centerOfMass(box.buffer)
            centers.append(center)
            let phase = Double(phases[index])
            let expected = Double(centerA) * (1 - phase) + Double(centerB) * phase
            let outW = CVPixelBufferGetWidth(box.buffer)
            let outH = CVPixelBufferGetHeight(box.buffer)
            if outW != width || outH != height || abs(center - expected) > 12 { positions = false }
        }
        return [
            "ok": positions,
            "modelID": modelID,
            "quality": quality,
            "error": callError?.localizedDescription ?? "",
            "centers": centers,
            "outputCount": frames?.count ?? 0,
            "motionPx": motion,
            "inputFormat": "BGRA",
        ]
    }

    private static func runNV12(modelID: String, quality: String, width: Int, height: Int, motion: Int) -> [String: Any] {
        let bridge = SPRifeBridge()
        do {
            try bridge.prepare(modelID: modelID, quality: quality, width: Int32(width), height: Int32(height))
        } catch {
            return ["ok": false, "modelID": modelID, "quality": quality, "inputFormat": "NV12", "error": error.localizedDescription]
        }
        guard let previous = try? nv12(width: width, height: height, luma: 16),
              let current = try? nv12(width: width, height: height, luma: 16) else {
            return ["ok": false, "error": "nv12", "inputFormat": "NV12"]
        }
        let centerA = width / 2 - motion / 2
        let centerB = width / 2 + motion / 2
        paintLuma(previous, center: centerA)
        paintLuma(current, center: centerB)
        let done = DispatchSemaphore(value: 0)
        var frames: [SPOwnedPixelBuffer]?
        var callError: Error?
        let submitted = bridge.submit(previous: previous, current: current, timesteps: [NSNumber(value: 0.5)], token: 2) { _, outputs, _, error in
            frames = outputs
            callError = error
            done.signal()
        }
        guard submitted else { return ["ok": false, "inputFormat": "NV12", "error": "submit"] }
        done.wait()
        bridge.invalidate()
        let center = frames?.first.map { centerOfMass($0.buffer) } ?? -1
        let expected = Double(centerA + centerB) / 2
        let box = frames?.first
        let sizeOK = box != nil && CVPixelBufferGetWidth(box!.buffer) == width && CVPixelBufferGetHeight(box!.buffer) == height
        return [
            "ok": callError == nil && sizeOK && center > 0 && abs(center - expected) <= 16,
            "modelID": modelID,
            "quality": quality,
            "inputFormat": "NV12",
            "center": center,
            "expected": expected,
            "outputCount": frames?.count ?? 0,
            "error": callError?.localizedDescription ?? "",
        ]
    }

    private static func paintLuma(_ buffer: CVPixelBuffer, center: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let size = 48
        let x0 = center - size / 2
        let y0 = height / 2 - size / 2
        for y in 0..<size {
            let py = y0 + y
            if py < 0 || py >= height { continue }
            let row = plane.advanced(by: py * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<size {
                let px = x0 + x
                if px < 0 || px >= width { continue }
                row[px] = ((x / 4) ^ (y / 4)) & 1 == 1 ? 235 : 40
            }
        }
    }

    private static func tier(_ quality: String) -> RifeQualityTier {
        switch quality {
        case "fast": return .fast
        case "hq": return .hq
        default: return .balanced
        }
    }

    private static func url(for modelID: String, bundle: Bundle = .main) throws -> URL {
        if modelID == "rife-v4.26" {
            guard let bundled = bundle.url(forResource: "rife-v4.26", withExtension: "rmw")
                    ?? bundle.url(forResource: "rife-v4.26", withExtension: "rmw", subdirectory: "Models") else {
                throw error(3, "应用里没有 rife-v4.26.rmw。4.26 是另一套权重，不能把 4.25 换名使用。")
            }
            let digest = sha256(of: bundled)
            guard digest == model426SHA256 else {
                throw error(3, "rife-v4.26.rmw 校验不符，拒绝加载。")
            }
            return bundled
        }
        guard modelID == "rife-v4.25" else { throw error(3, "所选 RIFE 模型不可用。") }
        let modelBundle = bundle.url(forResource: "RifeMetal_RifeMetal", withExtension: "bundle").flatMap(Bundle.init(url:))
        let bundled = modelBundle?.url(forResource: "rife-v4.25", withExtension: "rmw") ?? RifeConfiguration.bundledModelURL
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            throw error(4, "应用里没有 rife-v4.25.rmw")
        }
        if bundled.path.contains("interpolation-experiment") {
            throw error(5, "RIFE 4.25 仍从实验目录加载")
        }
        return bundled
    }

    private func ownedBGRA(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32RGBA {
            return source
        }
        if transfer == nil {
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
                  let session else {
                throw Self.error(8, "无法建立画面格式转换。")
            }
            transfer = session
        }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width >= 2, height >= 2 else { throw Self.error(6, "画面尺寸太小，不能交给 RIFE。") }
        let bgra = try Self.buffer(width: width, height: height, value: 0)
        let status = VTPixelTransferSessionTransferImage(transfer!, from: source, to: bgra)
        guard status == noErr else {
            throw Self.error(1, "当前画面是 \(Self.formatName(format))。RIFE 只接受 8 位 BGRA 或 RGBA，转换失败（\(status)）。HDR 不能用这套模型。")
        }
        CVBufferPropagateAttachments(source, bgra)
        Self.attach709IfMissing(bgra)
        return bgra
    }

    private static func explain(_ error: Error) -> Error {
        if let rife = error as? RifeError {
            switch rife {
            case .unsupportedPixelFormat(let format):
                return self.error(1, "RIFE 拒绝了格式 \(formatName(format))。需要先把捕获画面转成 8 位 BGRA。HDR 不能用这套模型。")
            case .dimensionMismatch:
                return self.error(2, "RIFE 的两帧尺寸不一致。")
            case .modelLoadFailed(let detail):
                return self.error(3, "RIFE 模型没有加载：\(detail)")
            case .invalidTimesteps(let detail):
                return self.error(7, "RIFE 不接受这个相位：\(detail)")
            case .inferenceFailed(let detail):
                return self.error(9, "RIFE 推理失败：\(detail)")
            case .metalUnavailable:
                return self.error(8, "这台 Mac 没有可用的 Metal，RIFE 不能运行。")
            case .shaderCompilationFailed(let detail):
                return self.error(9, "RIFE 着色器编译失败：\(detail)")
            }
        }
        return error
    }

    private static func formatName(_ format: OSType) -> String {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "NV12"
        case kCVPixelFormatType_32BGRA: return "BGRA"
        case kCVPixelFormatType_32RGBA: return "RGBA"
        default: return String(format: "0x%08x", format)
        }
    }

    private static func sha256(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func nv12(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw error(6, "无法分配 NV12 预热画面") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, 0)
            memset(plane, Int32(luma), row * rows)
        }
        if let plane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, 1)
            memset(plane, 128, row * rows)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    private static func buffer(width: Int, height: Int, value: UInt8) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw error(6, "无法分配 RIFE 画面") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                memset(base.advanced(by: y * stride), Int32(value), stride)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        attach709(buffer)
        return buffer
    }

    private static func paint(_ buffer: CVPixelBuffer, center: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let size = 72
        let x0 = center - size / 2
        let y0 = height / 2 - size / 2
        for y in 0..<size {
            let py = y0 + y
            if py < 0 || py >= height { continue }
            let row = base.advanced(by: py * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<size {
                let px = x0 + x
                if px < 0 || px >= width { continue }
                let on = ((x / 6) ^ (y / 6)) & 1 == 1
                let value: UInt8 = on ? 255 : 20
                row[px * 4] = value
                row[px * 4 + 1] = value
                row[px * 4 + 2] = value
                row[px * 4 + 3] = 255
            }
        }
    }

    private static func centerOfMass(_ buffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return -1 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return -1 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var sum = 0.0
        var weight = 0.0
        let y0 = height * 30 / 100
        let y1 = height * 70 / 100
        for y in Swift.stride(from: y0, to: y1, by: 2) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in Swift.stride(from: 0, to: width, by: 2) where row[x * 4 + 1] > 12 {
                let luma = Double(row[x * 4 + 1])
                sum += Double(x) * luma
                weight += luma
            }
        }
        return weight > 0 ? sum / weight : -1
    }

    private static func attach709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    private static func attach709IfMissing(_ buffer: CVPixelBuffer) {
        let defaults: [(CFString, CFString)] = [
            (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in defaults where CVBufferGetAttachment(buffer, key, nil) == nil {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
    }

    private static func error(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "app.openduckframe.rife", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
