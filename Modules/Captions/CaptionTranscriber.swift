import AVFoundation
import CoreMedia
import Foundation
import Speech

// SpeechAnalyzer adapter for macOS 26 and later. Convert 16 kHz mono Int16
// reader input when the analyzer requests another format. Finalize inference
// before releasing the app execution slot, and explicitly release locale leases.
@available(macOS 26.0, *)
final class CaptionTranscriber {
    struct Segment: Sendable {
        var start: Double
        var end: Double
        var words: [CaptionWord]
    }

    enum TranscriberError: Error {
        case unsupportedLocale
        case assetUnavailable
        case audioFormat
    }

    let locale: Locale
    private var analyzerFormat: AVAudioFormat?
    private var reservation: CaptionSpeechReservations.Lease?
    private static let reservations = CaptionSpeechReservations(backend: .init(
        reserved: { await AssetInventory.reservedLocales },
        reserve: { try await AssetInventory.reserve(locale: $0) },
        release: { _ = await AssetInventory.release(reservedLocale: $0) }))
    private let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                            channels: 1, interleaved: true)!

    init(locale: Locale) {
        self.locale = locale
    }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    static func isSupported(_ locale: Locale) async -> Bool {
        await supportedLocales().contains { $0.identifier == locale.identifier }
    }

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// Install assets and reserve a locale. Download progress is in [0, 1].
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await prepareAssets(progress: progress)
        } catch {
            await close()
            throw error
        }
    }

    /// Only called after all this instance's analyzers have finished. Callers
    /// await this on success, failure and cancellation before returning a slot.
    func close() async {
        analyzerFormat = nil
        guard let held = reservation else { return }
        reservation = nil
        await Self.reservations.release(held)
    }

    private func prepareAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        guard await Self.isSupported(locale) else { throw TranscriberError.unsupportedLocale }
        try Task.checkCancellation()
        if reservation == nil { reservation = try await Self.reservations.acquire(locale) }
        try Task.checkCancellation()
        let t = makeTranscriber()
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            let poll = Task {
                while !Task.isCancelled {
                    progress(req.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            do {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await req.downloadAndInstall()
                } onCancel: {
                    req.progress.cancel()
                }
            } catch {
                poll.cancel()
                await poll.value
                throw error
            }
            poll.cancel()
            await poll.value
            try Task.checkCancellation()
            progress(1)
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
        try Task.checkCancellation()
        if analyzerFormat == nil { throw TranscriberError.assetUnavailable }
    }

    /// Transcribe mono 16 kHz Int16 PCM. startSeconds is the first sample's
    /// zero-based media time. Returned words use media timestamps; segmentBase
    /// keeps recognition segment identities distinct across jobs.
    func transcribe(pcm16k: Data, startSeconds: Double, segmentBase: Int) async throws -> [Segment] {
        try Task.checkCancellation()
        guard let fmt = analyzerFormat else { throw TranscriberError.assetUnavailable }
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [Segment] in
            var out: [Segment] = []
            for try await r in transcriber.results where r.isFinal {
                try Task.checkCancellation()
                let segmentStart = CMTimeGetSeconds(r.range.start)
                let segmentEnd = CMTimeGetSeconds(r.range.end)
                guard CaptionSpeechTiming.validRange(start: segmentStart, end: segmentEnd) else { continue }
                var words: [CaptionWord] = []
                for run in r.text.runs {
                    let text = String(r.text[run.range].characters)
                    guard let tr = run.audioTimeRange else {
                        // Attach untimed text to the preceding timed word.
                        if !words.isEmpty, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                            words[words.count - 1].text += text
                        }
                        continue
                    }
                    let wordStart = CMTimeGetSeconds(tr.start)
                    let wordEnd = CMTimeGetSeconds(tr.end)
                    if wordStart.isFinite, wordStart >= 0, wordEnd == wordStart {
                        // A point-timed suffix (for example punctuation) carries
                        // text but no additional audio evidence, just like an
                        // untimed run. Preserve it on the preceding timed word.
                        if !words.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            words[words.count - 1].text += text
                        }
                        continue
                    }
                    guard CaptionSpeechTiming.validRange(start: wordStart, end: wordEnd) else { continue }
                    let conf = run.transcriptionConfidence ?? -1
                    words.append(CaptionWord(start: wordStart, end: wordEnd,
                                             text: text, confidence: conf.isFinite ? conf : -1,
                                             segment: segmentBase + out.count))
                }
                out.append(Segment(start: segmentStart, end: segmentEnd, words: words))
            }
            return out
        }
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let cleanup = CaptionCancellationCleanup()
        return try await withTaskCancellationHandler {
            do {
                try feed(pcm16k: pcm16k, startSeconds: startSeconds, format: fmt, into: cont)
                cont.finish()
                try Task.checkCancellation()
                try await analyzer.start(inputSequence: stream)
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let result = try await collector.value
                try Task.checkCancellation()
                return result
            } catch {
                cont.finish()
                collector.cancel()
                cleanup.request { await analyzer.cancelAndFinishNow() }
                // Task cancellation alone does not finish system inference. Await system
                // cleanup before returning the app-wide execution slot.
                await cleanup.wait()
                _ = try? await collector.value
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            cont.finish()
            collector.cancel()
            cleanup.request { await analyzer.cancelAndFinishNow() }
        }
    }

    // Feed one-second chunks with integer sample timestamps to avoid accumulated drift.
    private func feed(pcm16k: Data, startSeconds: Double, format: AVAudioFormat,
                      into cont: AsyncStream<AnalyzerInput>.Continuation) throws {
        let totalFrames = pcm16k.count / 2
        guard totalFrames > 0 else { return }
        let chunk = 16000
        let direct = format.commonFormat == .pcmFormatInt16 && format.sampleRate == 16000
            && format.channelCount == 1 && format.isInterleaved
        let converter = direct ? nil : AVAudioConverter(from: inputFormat, to: format)
        if !direct, converter == nil { throw TranscriberError.audioFormat }
        converter?.primeMethod = .none
        guard let baseSample = CaptionSpeechTiming.samplePosition(seconds: startSeconds, rate: 16000),
              baseSample <= Int64.max - Int64(totalFrames) else { throw TranscriberError.audioFormat }
        var off = 0
        try pcm16k.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: Int16.self)
            while off < totalFrames {
                try Task.checkCancellation()
                let n = min(chunk, totalFrames - off)
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(n)) else {
                    throw TranscriberError.audioFormat
                }
                inBuf.frameLength = AVAudioFrameCount(n)
                memcpy(inBuf.int16ChannelData![0], src.baseAddress! + off, n * 2)
                let ts = CMTime(value: baseSample + Int64(off), timescale: 16000)
                if let converter {
                    let capacity = Double(n) * format.sampleRate / 16000 + 64
                    guard capacity.isFinite, capacity > 0, capacity < Double(UInt32.max),
                          format.sampleRate > 0, format.sampleRate < Double(Int32.max) else {
                        throw TranscriberError.audioFormat
                    }
                    let outCap = AVAudioFrameCount(capacity)
                    guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCap) else {
                        throw TranscriberError.audioFormat
                    }
                    // The converter invokes this input callback synchronously. Its initialized
                    // buffer and consumed flag belong only to this conversion.
                    nonisolated(unsafe) let conversionInput = inBuf
                    nonisolated(unsafe) var consumed = false
                    var err: NSError? = nil
                    converter.convert(to: outBuf, error: &err) { _, status in
                        if consumed { status.pointee = .noDataNow; return nil }
                        consumed = true
                        status.pointee = .haveData
                        return conversionInput
                    }
                    if let err { throw err }
                    if outBuf.frameLength > 0 {
                        guard let outputSample = CaptionSpeechTiming.samplePosition(
                            seconds: Double(baseSample + Int64(off)) / 16000, rate: format.sampleRate)
                        else { throw TranscriberError.audioFormat }
                        let tsOut = CMTime(value: outputSample, timescale: CMTimeScale(format.sampleRate))
                        cont.yield(AnalyzerInput(buffer: outBuf, bufferStartTime: tsOut))
                    }
                } else {
                    cont.yield(AnalyzerInput(buffer: inBuf, bufferStartTime: ts))
                }
                off += n
            }
        }
    }
}

/// Start asynchronous cancellation once and await it before task completion.
private final class CaptionCancellationCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func request(_ operation: @escaping @Sendable () async -> Void) {
        lock.withLock {
            if task == nil { task = Task.detached(priority: .utility, operation: operation) }
        }
    }

    func wait() async {
        let pending = lock.withLock { task }
        await pending?.value
    }
}

// MARK: - On-demand language detection
@available(macOS 26.0, *)
enum CaptionLanguageProbe {
    /// Run one installed model per candidate language over the same audio sample.
    /// Select the highest duration-weighted mean confidence, not total confidence
    /// or covered duration. Return nil when no usable words are recognized.
    static func detect(pcm16k: Data, startSeconds: Double, candidates: [Locale],
                       progress: @escaping @Sendable (Double) -> Void) async throws -> (locale: Locale, confidence: Double)? {
        try Task.checkCancellation()
        let langs = Self.onePerLanguage(candidates)
        var best: (Locale, Double)? = nil
        if spDebugEnabled { NSLog("[Captions] 语音语言检测候选：%@", langs.map(\.identifier).joined(separator: " ")) }
        for (i, loc) in langs.enumerated() {
            try Task.checkCancellation()
            let t = CaptionTranscriber(locale: loc)
            let wall = Date()
            do {
                try await t.prepare { fraction in
                    guard fraction.isFinite else { return }
                    progress((Double(i) + min(1, max(0, fraction)) * 0.5) / Double(langs.count))
                }
                let segs = try await t.transcribe(pcm16k: pcm16k, startSeconds: startSeconds, segmentBase: 0)
                await t.close()
                let score = Self.score(segs)
                if spDebugEnabled {
                    NSLog("[Captions]   候选 %@：置信分 %.2f，%.1fs", loc.identifier, score, Date().timeIntervalSince(wall))
                }
                if best == nil || score > best!.1 { best = (loc, score) }
            } catch {
                await t.close()
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                if spDebugEnabled { NSLog("[Captions]   候选 %@ 失败：%@", loc.identifier, error.localizedDescription) }
            }
            progress(Double(i + 1) / Double(langs.count))
        }
        try Task.checkCancellation()
        guard let b = best, b.1 > 0 else { return nil }
        return (b.0, b.1)
    }

    /// Keep one locale per language, preferring the user's region, then a common variant.
    static func onePerLanguage(_ candidates: [Locale]) -> [Locale] {
        let preferred = ["en_US", "zh_CN", "yue_CN", "ja_JP", "ko_KR", "es_ES", "fr_FR", "de_DE", "it_IT", "pt_BR"]
        let region = Locale.current.region?.identifier
        var byLang: [String: [Locale]] = [:]
        var order: [String] = []
        for c in candidates {
            let lang = c.language.languageCode?.identifier ?? c.identifier
            if byLang[lang] == nil { order.append(lang) }
            byLang[lang, default: []].append(c)
        }
        return order.compactMap { lang in
            let vs = byLang[lang]!
            return vs.first { $0.region?.identifier == region }
                ?? vs.first { preferred.contains($0.identifier) }
                ?? vs.sorted { $0.identifier < $1.identifier }.first
        }
    }

    /// Duration-weighted mean confidence over valid words. Fewer than three seconds
    /// of usable evidence returns zero; this is not a voice-activity detector.
    static func score(_ segs: [CaptionTranscriber.Segment]) -> Double {
        var weighted = 0.0, dur = 0.0
        for s in segs {
            for w in s.words {
                guard CaptionSpeechTiming.validRange(start: w.start, end: w.end),
                      w.confidence.isFinite, (0...1).contains(w.confidence),
                      !w.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let d = w.end - w.start
                weighted += w.confidence * d
                dur += d
            }
        }
        return dur >= 3 && dur.isFinite && weighted.isFinite ? weighted / dur : 0
    }
}

enum CaptionSpeechTiming {
    static func validRange(start: Double, end: Double) -> Bool {
        start.isFinite && end.isFinite && start >= 0 && end > start
    }

    static func samplePosition(seconds: Double, rate: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0, rate.isFinite, rate > 0 else { return nil }
        let value = (seconds * rate).rounded()
        // Double(Int64.max) rounds up to 2^63, which must remain excluded.
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        return Int64(value)
    }
}
