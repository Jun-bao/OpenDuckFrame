#if ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC
import Foundation
import Metal
import CryptoKit
import os
import Darwin

private func spKeeperNowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private enum SPResidentKeepAliveError: LocalizedError {
    case native(String), calibration(String), cancelled, capacity

    var errorDescription: String? {
        switch self {
        case .native(let message), .calibration(let message): return message
        case .cancelled: return "keeper preparation cancelled"
        case .capacity: return "keeper diagnostic capacity reached"
        }
    }
}

enum SPResidentKeepAliveMetallib {
    static let diagnosticSHA256 = "ccea3d2f9675947963f446fb08ad3718164ef7624b4075a280f31edff716d67e"

    static func productionSHA256(bundle: Bundle) throws -> String {
        guard let url = bundle.url(forResource: "gap-fill", withExtension: "sha256") else {
            throw SPResidentKeepAliveError.native("keeper bundled metallib SHA256 is missing")
        }
        let data = try Data(contentsOf: url)
        guard data.count == 65, data.last == 10,
              let expected = String(data: data.dropLast(), encoding: .utf8), isValidSHA256(expected) else {
            throw SPResidentKeepAliveError.native("keeper bundled metallib SHA256 is invalid")
        }
        return expected
    }

    static func isValidSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func matches(actual: String, expected: String) -> Bool {
        isValidSHA256(expected) && actual == expected
    }
}

struct SPResidentKeepAliveRecord: Encodable {
    let cbID: UInt64
    let phase: String
    let iterations: UInt32
    let commitBeginNs: UInt64
    let commitEndNs: UInt64
    var terminalObservedNs: UInt64?
    var status: UInt32 = 0
    var validityMask: UInt32 = 1
    var gpuStartSeconds: Double = 0
    var gpuEndSeconds: Double = 0
    var gpuDurationMs: Double?
    var error: String?

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "cbID": cbID, "phase": phase, "iterations": iterations,
            "commitBeginNs": commitBeginNs, "commitEndNs": commitEndNs,
            "status": status, "validityMask": validityMask,
            "gpuStartSeconds": spKeeperJSONNumber(gpuStartSeconds),
            "gpuEndSeconds": spKeeperJSONNumber(gpuEndSeconds)
        ]
        if let terminalObservedNs { result["terminalObservedNs"] = terminalObservedNs }
        if let gpuDurationMs { result["gpuDurationMs"] = spKeeperJSONNumber(gpuDurationMs) }
        if let error { result["error"] = error }
        return result
    }
}

private func spKeeperJSONNumber(_ value: Double) -> Any {
    if value.isFinite { return value }
    if value.isNaN { return "NaN" }
    return value > 0 ? "+Infinity" : "-Infinity"
}

/// A fixed-grid description. It never stores reconstructed percentile points.
final class SPResidentKeepAliveDurationAggregate {
    static let binCount = 20_000
    private(set) var count: UInt64 = 0
    private(set) var validTimingCount: UInt64 = 0
    private(set) var errorCount: UInt64 = 0
    private(set) var commandErrorCount: UInt64 = 0
    private(set) var invalidTimingCount: UInt64 = 0
    private(set) var minimumMs: Double?
    private(set) var maximumMs: Double?
    private(set) var sumMs: Double = 0
    private(set) var firstCommitBeginNs: UInt64?
    private(set) var lastTerminalObservedNs: UInt64?
    private(set) var bins = [UInt64](repeating: 0, count: binCount)
    private(set) var overUpperBoundCount: UInt64 = 0
    private(set) var tailMinimumMs: Double?
    private(set) var tailMaximumMs: Double?
    private(set) var tailSumMs: Double = 0

    /// Exact floor of the recorded Float64 millisecond value times 1000.
    /// In this range the significand-times-1000 product fits below 2^63.
    static func binIndex(milliseconds value: Double) -> Int {
        if value == 20 { return binCount - 1 }
        let bits = value.bitPattern
        let exponentBits = Int((bits >> 52) & 0x7ff)
        if exponentBits == 0 { return 0 }
        let significand = (bits & ((UInt64(1) << 52) - 1)) | (UInt64(1) << 52)
        let rightShift = 1075 - exponentBits
        if rightShift >= 64 { return 0 }
        return Int((significand * 1000) >> rightShift)
    }

    func append(_ row: SPResidentKeepAliveRecord) {
        count += 1
        if row.status == 5 { commandErrorCount += 1 }
        if row.error != nil || row.status == 5 { errorCount += 1 }
        firstCommitBeginNs = min(firstCommitBeginNs ?? row.commitBeginNs, row.commitBeginNs)
        if let terminal = row.terminalObservedNs {
            lastTerminalObservedNs = max(lastTerminalObservedNs ?? terminal, terminal)
        }
        guard row.status == 4, row.validityMask == 7, row.error == nil,
              let value = row.gpuDurationMs, value.isFinite, value > 0 else {
            invalidTimingCount += 1
            return
        }
        validTimingCount += 1
        minimumMs = min(minimumMs ?? value, value)
        maximumMs = max(maximumMs ?? value, value)
        sumMs += value
        if value > 20 {
            overUpperBoundCount += 1
            tailMinimumMs = min(tailMinimumMs ?? value, value)
            tailMaximumMs = max(tailMaximumMs ?? value, value)
            tailSumMs += value
        } else {
            bins[Self.binIndex(milliseconds: value)] += 1
        }
    }

    private func interval(atRank rank: UInt64) -> [String: Any] {
        var cumulative: UInt64 = 0
        for index in bins.indices {
            cumulative += bins[index]
            if rank < cumulative {
                return ["kind": "microsecond-bin", "index": index,
                        "lowerMicroseconds": index, "upperMicroseconds": index + 1,
                        "lowerInclusive": true, "upperInclusive": index == Self.binCount - 1]
            }
        }
        return ["kind": "over-20ms-tail", "lowerMilliseconds": 20,
                "lowerInclusive": false,
                "minimumMs": tailMinimumMs.map { $0 as Any } ?? NSNull(),
                "maximumMs": tailMaximumMs.map { $0 as Any } ?? NSNull()]
    }

    private func quantileRanks(_ probability: Double) -> Any {
        guard validTimingCount > 0 else { return NSNull() }
        let position = probability * Double(validTimingCount - 1)
        let lower = UInt64(position.rounded(.down))
        let upper = UInt64(position.rounded(.up))
        return ["probability": probability, "n": validTimingCount,
                "lowerRankIndex": lower, "upperRankIndex": upper,
                "interpolationWeight": position - Double(lower),
                "lowerRankDurationInterval": interval(atRank: lower),
                "upperRankDurationInterval": interval(atRank: upper)]
    }

    func dictionary() -> [String: Any] {
        var nonzero: [[String: Any]] = []
        for index in bins.indices where bins[index] > 0 {
            nonzero.append(["index": index, "count": bins[index]])
        }
        return [
            "count": count, "validTimingCount": validTimingCount,
            "errorCount": errorCount, "commandErrorCount": commandErrorCount,
            "invalidTimingCount": invalidTimingCount,
            "minDurationMs": minimumMs.map { $0 as Any } ?? NSNull(),
            "maxDurationMs": maximumMs.map { $0 as Any } ?? NSNull(),
            "sumDurationMs": spKeeperJSONNumber(sumMs),
            "sumMeaning": "Sequential Float64 addition in terminal-record order",
            "firstCommitBeginNs": firstCommitBeginNs.map { $0 as Any } ?? NSNull(),
            "lastTerminalObservedNs": lastTerminalObservedNs.map { $0 as Any } ?? NSNull(),
            "histogram": [
                "binWidthNanoseconds": 1000, "binCount": Self.binCount,
                "upperEdgeMilliseconds": 20, "nonzeroBins": nonzero,
                "binning": "Exact Float64 value against rational 1us edges; half-open bins, exact20ms in final closed-upper bin",
                "overUpperBoundCount": overUpperBoundCount,
                "tailMinimumMs": tailMinimumMs.map { $0 as Any } ?? NSNull(),
                "tailMaximumMs": tailMaximumMs.map { $0 as Any } ?? NSNull(),
                "tailSumMs": spKeeperJSONNumber(tailSumMs),
                "percentileRankIntervals": ["p50": quantileRanks(0.5), "p95": quantileRanks(0.95), "p99": quantileRanks(0.99)],
                "percentileScope": "Descriptive type7 rank-bin intervals only. Original duration point values cannot be reconstructed."
            ]
        ]
    }

    func frozenCopy() -> SPResidentKeepAliveDurationAggregate {
        let copy = SPResidentKeepAliveDurationAggregate()
        copy.count = count; copy.validTimingCount = validTimingCount
        copy.errorCount = errorCount; copy.commandErrorCount = commandErrorCount
        copy.invalidTimingCount = invalidTimingCount
        copy.minimumMs = minimumMs; copy.maximumMs = maximumMs; copy.sumMs = sumMs
        copy.firstCommitBeginNs = firstCommitBeginNs
        copy.lastTerminalObservedNs = lastTerminalObservedNs
        copy.bins = bins; copy.overUpperBoundCount = overUpperBoundCount
        copy.tailMinimumMs = tailMinimumMs; copy.tailMaximumMs = tailMaximumMs
        copy.tailSumMs = tailSumMs
        return copy
    }
}

/// Called only under the keeper's existing state lock. Appending cannot stop,
/// throw, schedule or signal the worker when diagnostic retention saturates.
final class SPResidentKeepAliveAccounting {
    static let prefixCapacity = 1024
    static let suffixCapacity = 1024
    let allTerminals: SPResidentKeepAliveDurationAggregate
    let operational: SPResidentKeepAliveDurationAggregate
    private(set) var byPhase: [String: SPResidentKeepAliveDurationAggregate] = [:]
    private(set) var prefix: [SPResidentKeepAliveRecord] = []
    private var suffix: [SPResidentKeepAliveRecord] = []
    private var suffixNextIndex = 0

    init(allTerminals: SPResidentKeepAliveDurationAggregate = .init(),
         operational: SPResidentKeepAliveDurationAggregate = .init()) {
        self.allTerminals = allTerminals
        self.operational = operational
        prefix.reserveCapacity(Self.prefixCapacity)
        suffix.reserveCapacity(Self.suffixCapacity)
    }

    func frozenCopy() -> SPResidentKeepAliveAccounting {
        let copy = SPResidentKeepAliveAccounting(allTerminals: allTerminals.frozenCopy(),
                                                operational: operational.frozenCopy())
        copy.byPhase = byPhase.mapValues { $0.frozenCopy() }
        copy.prefix = prefix; copy.suffix = suffix; copy.suffixNextIndex = suffixNextIndex
        return copy
    }

    func append(_ row: SPResidentKeepAliveRecord) {
        allTerminals.append(row)
        if let phase = byPhase[row.phase] {
            phase.append(row)
        } else {
            let phase = SPResidentKeepAliveDurationAggregate()
            phase.append(row)
            byPhase[row.phase] = phase
        }
        guard !row.phase.hasPrefix("calibration_") else { return }
        operational.append(row)
        if prefix.count < Self.prefixCapacity { prefix.append(row) }
        if suffix.count < Self.suffixCapacity {
            suffix.append(row)
        } else {
            suffix[suffixNextIndex] = row
            suffixNextIndex = (suffixNextIndex + 1) % Self.suffixCapacity
        }
    }

    func snapshot() -> (aggregation: [String: Any], diagnosticRecords: [String: Any]) {
        let orderedSuffix = Array(suffix[suffixNextIndex...]) + Array(suffix[..<suffixNextIndex])
        let lastPrefixID = prefix.last?.cbID ?? 0
        let suffixDistinct = orderedSuffix.filter { $0.cbID > lastPrefixID }
        let retained = UInt64(prefix.count + suffixDistinct.count)
        let aggregation: [String: Any] = [
            "schema": "odf-keeper-bounded-aggregate-v1", "dataClass": "b",
            "scope": "Exact counts and duration aggregates include calibration; diagnostic details retain operational CBs only.",
            "allTerminals": allTerminals.dictionary(),
            "operational": operational.dictionary(),
            "byPhase": byPhase.mapValues { $0.dictionary() }
        ]
        let diagnostics: [String: Any] = [
            "prefixCapacity": Self.prefixCapacity, "suffixCapacity": Self.suffixCapacity,
            "operationalCount": operational.count, "retainedDistinctCount": retained,
            "omittedCount": operational.count - retained,
            "boundedDetails": operational.count > retained,
            "prefix": prefix.map(\.dictionary), "suffix": orderedSuffix.map(\.dictionary),
            "scope": "Intentional b-class detail omission. It never changes keeper execution or aggregate counts."
        ]
        return (aggregation, diagnostics)
    }
}

struct SPResidentKeepAliveCalibration: Encodable {
    let initialPilotIterations: UInt32 = 65_536
    let targetMilliseconds = SPResidentCalibrationPolicy.targetMs
    let pilotCount = 5, validationCount = 5
    let minimumValidationMs = SPResidentCalibrationPolicy.minimumMs, maximumValidationMs = SPResidentCalibrationPolicy.maximumMs
    let maximumValidationRounds = SPResidentCalibrationPolicy.maximumValidationRounds
    let iterationConversion = "Measured feedback: round(currentIterations * targetMilliseconds / medianMs); midpoint for a valid monotone low/high bracket; UInt32 bounds; at most three validation rounds; unchanged final [0.5,2]ms gate"
    var status = "not_started"
    var pilotMedianMs: Double?
    var scaledIterations: UInt32?
    var validationMedianMs: Double?
    var passed = false
    var firstFailure: String?
    var validationRounds: [[String: Double]] = []
    var records: [SPResidentKeepAliveRecord] = []
}

struct SPResidentKeepAliveConfiguration: Encodable {
    let deviceRegistryID: UInt64
    let deviceName: String
    let queueLabel = "ODF resident keepalive diagnostic"
    let kernel = "air_gap_fill"
    let metallibSHA256: String
    let startAcknowledgement = "Plan state accepted only; worker ownership handoff and GPU submission are asynchronous"
    let deviceHandoffBudgetMs = 100, drainBudgetMs = 100
    let maximumQueuedCommandBuffers = 2
    let threadgroups = [1, 1, 1]
    let threadsPerThreadgroup: [Int]
    let threadExecutionWidth: Int
    let scratchBytes: Int
    let storageMode = "private"
    let hazardTrackingMode = "tracked"
    let resourceUsage = "write; explicit encoder.useResource"
    let resourceSharing = "Only keeper CBs share scratch; no model input/output/resource is shared"
    let diagnosticPrefixCapacity = SPResidentKeepAliveAccounting.prefixCapacity
    let diagnosticSuffixCapacity = SPResidentKeepAliveAccounting.suffixCapacity
    let recordAccounting = "recordsAttempted includes calibration and operational committed CBs. Exact terminal aggregates include both. Operational first/last details are b-class diagnostics; intentional omission is separate from aggregate loss."
    let validityMaskMeaning = "1=commit bracket, 2=terminal status, 4=completed finite positive GPU interval; complete=7"
    let cpuClock = "DispatchTime.uptimeNanoseconds, same coordinate as real job wall and phase clocks"
    let gpuTimeScope = "Command-buffer residency seconds; single-SIMD-group ALU duration is a process-internal frequency proxy, not active cycles or direct frequency"
    let phaseAssignment = "Phase captured under state lock at commit; phase marks retain actual CPU boundaries. markPhase never drains or joins the worker."

    init(deviceRegistryID: UInt64, deviceName: String, threadsPerThreadgroup: [Int],
         threadExecutionWidth: Int, scratchBytes: Int,
         metallibSHA256: String = SPResidentKeepAliveMetallib.diagnosticSHA256) {
        self.deviceRegistryID = deviceRegistryID; self.deviceName = deviceName
        self.threadsPerThreadgroup = threadsPerThreadgroup
        self.threadExecutionWidth = threadExecutionWidth; self.scratchBytes = scratchBytes
        self.metallibSHA256 = metallibSHA256
    }
}

struct SPResidentKeepAlivePhaseMark: Encodable {
    let phase: String
    let stampNs: UInt64
}

struct SPResidentKeepAliveLifecycle: Encodable {
    var startRequestedNs: UInt64?
    var workerBeganNs: UInt64?
    var firstOperationalCommitBeginNs: UInt64?
    var stopRequestedNs: UInt64?
    var stopReason: String?
    var drainBeginNs: UInt64?
    var drainEndNs: UInt64?
    var workerEndedNs: UInt64?
    var pendingAtDrainStart = 0
    var maximumPendingObserved = 0
    var pendingAtEnd = 0
    var drainTimedOut = false
    var requestToDrainEndNs: UInt64?
    var deviceClaimWaitBeginNs: UInt64?
    var deviceClaimAcquiredNs: UInt64?
    var deviceClaimWaitTimedOut = false
}

struct SPResidentKeepAliveReport {
    let enabled = true
    let contractVersion = "opus-app-resident-keepalive-20261109-stage1-v1"
    let configuration: SPResidentKeepAliveConfiguration
    let instanceID = UUID().uuidString
    var planToken: UInt64?
    var generation: UInt64?
    var configVersion: UInt64?
    var deviceClaimPassed = false
    var calibration = SPResidentKeepAliveCalibration()
    var lifecycle = SPResidentKeepAliveLifecycle()
    var phaseMarks: [SPResidentKeepAlivePhaseMark] = []
    var accounting = SPResidentKeepAliveAccounting()
    var recordsAttempted = 0
    var recordsDropped = 0
    var overflow = false
    var unknownTimingCount = 0
    var firstFailure: String?
}

func spKeeperConfigurationDictionary(_ value: SPResidentKeepAliveConfiguration) -> [String: Any] {
    [
        "deviceRegistryID": value.deviceRegistryID, "deviceName": value.deviceName,
        "queueLabel": value.queueLabel, "kernel": value.kernel, "metallibSHA256": value.metallibSHA256,
        "startAcknowledgement": value.startAcknowledgement,
        "deviceHandoffBudgetMs": value.deviceHandoffBudgetMs, "drainBudgetMs": value.drainBudgetMs,
        "maximumQueuedCommandBuffers": value.maximumQueuedCommandBuffers,
        "threadgroups": value.threadgroups, "threadsPerThreadgroup": value.threadsPerThreadgroup,
        "threadExecutionWidth": value.threadExecutionWidth, "scratchBytes": value.scratchBytes,
        "storageMode": value.storageMode, "hazardTrackingMode": value.hazardTrackingMode,
        "resourceUsage": value.resourceUsage, "resourceSharing": value.resourceSharing,
        "diagnosticPrefixCapacity": value.diagnosticPrefixCapacity,
        "diagnosticSuffixCapacity": value.diagnosticSuffixCapacity,
        "recordAccounting": value.recordAccounting, "validityMaskMeaning": value.validityMaskMeaning,
        "cpuClock": value.cpuClock, "gpuTimeScope": value.gpuTimeScope, "phaseAssignment": value.phaseAssignment
    ]
}

func spKeeperCalibrationDictionary(_ value: SPResidentKeepAliveCalibration) -> [String: Any] {
    var result: [String: Any] = [
        "initialPilotIterations": value.initialPilotIterations, "targetMilliseconds": value.targetMilliseconds,
        "pilotCount": value.pilotCount, "validationCount": value.validationCount,
        "minimumValidationMs": value.minimumValidationMs, "maximumValidationMs": value.maximumValidationMs,
        "maximumValidationRounds": value.maximumValidationRounds, "validationRounds": value.validationRounds,
        "iterationConversion": value.iterationConversion, "status": value.status,
        "passed": value.passed, "records": value.records.map(\.dictionary)
    ]
    if let pilot = value.pilotMedianMs { result["pilotMedianMs"] = spKeeperJSONNumber(pilot) }
    if let scaled = value.scaledIterations { result["scaledIterations"] = scaled }
    if let validation = value.validationMedianMs { result["validationMedianMs"] = spKeeperJSONNumber(validation) }
    if let failure = value.firstFailure { result["firstFailure"] = failure }
    return result
}

func spKeeperLifecycleDictionary(_ value: SPResidentKeepAliveLifecycle) -> [String: Any] {
    var result: [String: Any] = [
        "pendingAtDrainStart": value.pendingAtDrainStart, "maximumPendingObserved": value.maximumPendingObserved,
        "pendingAtEnd": value.pendingAtEnd, "drainTimedOut": value.drainTimedOut,
        "deviceClaimWaitTimedOut": value.deviceClaimWaitTimedOut
    ]
    let optionalTimes: [(String, UInt64?)] = [
        ("startRequestedNs", value.startRequestedNs), ("workerBeganNs", value.workerBeganNs),
        ("firstOperationalCommitBeginNs", value.firstOperationalCommitBeginNs),
        ("stopRequestedNs", value.stopRequestedNs), ("drainBeginNs", value.drainBeginNs),
        ("drainEndNs", value.drainEndNs), ("workerEndedNs", value.workerEndedNs),
        ("requestToDrainEndNs", value.requestToDrainEndNs),
        ("deviceClaimWaitBeginNs", value.deviceClaimWaitBeginNs),
        ("deviceClaimAcquiredNs", value.deviceClaimAcquiredNs)
    ]
    for (key, value) in optionalTimes {
        if let value { result[key] = value }
    }
    if let reason = value.stopReason { result["stopReason"] = reason }
    return result
}

private func spKeeperFullSnapshot(_ value: SPResidentKeepAliveReport,
                                  aggregation: [String: Any], diagnostics: [String: Any],
                                  pending: Int, stopping: Bool, started: Bool) -> [String: Any] {
    var result: [String: Any] = [
        "enabled": value.enabled, "contractVersion": value.contractVersion,
        "instanceID": value.instanceID, "configuration": spKeeperConfigurationDictionary(value.configuration),
        "deviceClaimPassed": value.deviceClaimPassed,
        "calibration": spKeeperCalibrationDictionary(value.calibration),
        "lifecycle": spKeeperLifecycleDictionary(value.lifecycle),
        "phaseMarks": value.phaseMarks.map { ["phase": $0.phase, "stampNs": $0.stampNs] as [String: Any] },
        "recordsAttempted": value.recordsAttempted, "recordsDropped": value.recordsDropped,
        "overflow": value.overflow, "unknownTimingCount": value.unknownTimingCount,
        "recordingSchema": "odf-keeper-bounded-aggregate-v1",
        "aggregation": aggregation, "diagnosticRecords": diagnostics,
        "pendingCount": pending, "stopRequested": stopping, "started": started
    ]
    if let token = value.planToken { result["planToken"] = token }
    if let generation = value.generation { result["generation"] = generation }
    if let config = value.configVersion { result["configVersion"] = config }
    if let failure = value.firstFailure { result["firstFailure"] = failure }
    return result
}

fileprivate struct SPAirKeeperSessionState {
    var report: SPResidentKeepAliveReport
    let pending: Int
    let stopping: Bool
    let started: Bool
    let phase: String
    let hostTicks: UInt64
    let uptimeNs: UInt64
    let utcUnixSeconds: Double

    func dictionary(includeRecords: Bool) -> [String: Any] {
        var result: [String: Any]
        if includeRecords {
            let records = report.accounting.snapshot()
            result = spKeeperFullSnapshot(report, aggregation: records.aggregation,
                                          diagnostics: records.diagnosticRecords,
                                          pending: pending, stopping: stopping, started: started)
        } else {
            result = ["instanceID": report.instanceID,
                      "recordsAttempted": report.recordsAttempted,
                      "recordsDropped": report.recordsDropped,
                      "overflow": report.overflow,
                      "unknownTimingCount": report.unknownTimingCount,
                      "pendingCount": pending, "stopRequested": stopping, "started": started,
                      "firstFailure": report.firstFailure.map { $0 as Any } ?? NSNull()]
        }
        var lifecycle = spKeeperLifecycleDictionary(report.lifecycle)
        if report.lifecycle.drainBeginNs == nil { lifecycle["pendingAtDrainStart"] = NSNull() }
        if report.lifecycle.drainEndNs == nil { lifecycle["pendingAtEnd"] = NSNull() }
        result["lifecycle"] = lifecycle
        result["planToken"] = report.planToken.map { $0 as Any } ?? NSNull()
        result["generation"] = report.generation.map { $0 as Any } ?? NSNull()
        result["configVersion"] = report.configVersion.map { $0 as Any } ?? NSNull()
        result["firstFailure"] = report.firstFailure.map { $0 as Any } ?? NSNull()
        result["diagnosticInvalid"] = report.firstFailure != nil || report.overflow
            || report.lifecycle.drainTimedOut || report.lifecycle.deviceClaimWaitTimedOut
        result["currentPhase"] = phase
        result["observedHostTicks"] = hostTicks
        result["observedUptimeNs"] = uptimeNs
        result["observedUTCUnixSeconds"] = utcUnixSeconds
        return result
    }
}

fileprivate final class SPAirKeeperSessionEntry {
    let sequence: UInt64
    let bridgeID: String
    private let context: [String: Any]
    private let lock = NSLock()
    private weak var keeper: SPResidentKeepAlive?
    private weak var journal: SPAirKeeperSessionJournal?
    private var lastState: SPAirKeeperSessionState
    private var frozenState: SPAirKeeperSessionState?
    private var retirement: [String: Any]?
    private var postCutoffState: SPAirKeeperSessionState?
    private var postCutoffKind: String?
    private var postCutoffObservations: UInt64 = 0
    private var deviceClaimReleasedHostTicks: UInt64?

    init(sequence: UInt64, bridgeID: String, keeper: SPResidentKeepAlive,
         journal: SPAirKeeperSessionJournal, state: SPAirKeeperSessionState, context: [String: Any]) {
        self.sequence = sequence; self.bridgeID = bridgeID
        self.context = context
        self.keeper = keeper; self.journal = journal; lastState = state
    }

    func record(_ state: SPAirKeeperSessionState, kind: String, reason: String? = nil) {
        let accepted = journal?.record(state, kind: kind, reason: reason, sequence: sequence, bridgeID: bridgeID) == true
        lock.lock()
        if accepted, frozenState == nil { lastState = state }
        if !accepted {
            postCutoffState = state; postCutoffKind = kind
            postCutoffObservations &+= 1
        }
        if kind == "device_claim_released" { deviceClaimReleasedHostTicks = state.hostTicks }
        if accepted, kind == "retired" {
            retirement = ["hostTicks": state.hostTicks, "uptimeNs": state.uptimeNs,
                          "utcUnixSeconds": state.utcUnixSeconds, "reason": reason ?? ""]
        }
        lock.unlock()
    }

    func freeze() {
        lock.lock(); let live = keeper; lock.unlock()
        let actual = live?.captureKeeperSessionState(freezeAccounting: true)
        lock.lock()
        if frozenState == nil {
            var copied = actual ?? lastState
            if actual == nil { copied.report.accounting = copied.report.accounting.frozenCopy() }
            frozenState = copied
        }
        lock.unlock()
    }

    func dictionary(includeRecords: Bool, recordingBoundaryKnown: Bool,
                    cutoffHostTicks: UInt64?) -> [String: Any] {
        lock.lock()
        let live = keeper, frozen = frozenState, fallback = lastState, retired = retirement
        let post = postCutoffState, postKind = postCutoffKind, postCount = postCutoffObservations
        let released = deviceClaimReleasedHostTicks
        lock.unlock()
        let state = frozen ?? live?.captureKeeperSessionState(freezeAccounting: true) ?? fallback
        var result = state.dictionary(includeRecords: includeRecords && recordingBoundaryKnown)
        result["sessionInstanceSequence"] = sequence
        result["bridgeID"] = bridgeID
        result["bridgeIdentity"] = context
        result["rifeDeviceRegistryID"] = context["rifeDeviceRegistryID"] ?? NSNull()
        result["rifeModelIdentity"] = context["rifeModelIdentity"] ?? NSNull()
        result["retirement"] = retired.map { $0 as Any } ?? NSNull()
        result["recordingBoundaryKnown"] = recordingBoundaryKnown
        if let released, let cutoffHostTicks, released > cutoffHostTicks {
            result["deviceClaimReleasedHostTicks"] = NSNull()
        } else {
            result["deviceClaimReleasedHostTicks"] = released.map { $0 as Any } ?? NSNull()
        }
        if !recordingBoundaryKnown {
            result["aggregation"] = ["available": false, "reason": "recording window expired before a boundary snapshot"]
        }
        let actual = live?.captureKeeperSessionState(freezeAccounting: false) ?? post
        if let actual, let cutoffHostTicks, actual.hostTicks > cutoffHostTicks {
            var status = actual.dictionary(includeRecords: false)
            status["lastObservedEventKind"] = postKind.map { $0 as Any } ?? NSNull()
            status["observationsAfterCutoff"] = postCount
            status["deviceClaimReleasedHostTicks"] = released.map { $0 as Any } ?? NSNull()
            status["scope"] = "Actual status observed after the recording cutoff. It does not replace the recorded lifecycle or prove closure inside the recording window."
            result["postCutoffStatus"] = status
        }
        return result
    }

    func readiness() -> (terminal: Bool, active: Bool, unknown: Bool, pending: Int?, drain: Bool, workerEnded: Bool, failure: Bool) {
        lock.lock()
        let live = keeper, fallback = postCutoffState ?? lastState
        let released = deviceClaimReleasedHostTicks != nil
        lock.unlock()
        let state = live?.captureKeeperSessionState(freezeAccounting: false) ?? fallback
        let lifecycle = state.report.lifecycle
        let drain = lifecycle.drainEndNs != nil
        let workerEnded = lifecycle.workerEndedNs != nil
        let neverStartedStopped = !state.started && state.stopping && drain
            && state.report.calibration.status != "pilot" && state.report.calibration.status != "validation"
        let terminal = state.stopping && lifecycle.stopRequestedNs != nil && state.pending == 0 && drain
            && (state.started ? workerEnded && (!state.report.deviceClaimPassed || released) : neverStartedStopped)
        let unknown = live == nil && !terminal
        return (terminal, live != nil && !terminal, unknown, unknown ? nil : state.pending,
                drain, workerEnded, state.report.firstFailure != nil || lifecycle.drainTimedOut)
    }
}

/// CPU witnesses survive bridge retirement. Entries retain report values and
/// bounded accounting only. The keeper, its queue and its Metal resources are weak.
@objc(SPAirKeeperSessionJournal)
final class SPAirKeeperSessionJournal: NSObject {
    static let instanceCapacity = 64
    static let eventCapacity = 4096
    private let lock = NSLock()
    private let sessionID: String
    private let beginHostTicks: UInt64
    private let deadlineHostTicks: UInt64
    private let machTimebase: [String: UInt32]
    private var entries: [SPAirKeeperSessionEntry] = []
    private var events: [[String: Any]] = []
    private var nextEventIndex = 0
    private var instanceAttempts: UInt64 = 0
    private var eventAttempts: UInt64 = 0
    private var postSealAttempts: UInt64 = 0
    private var sealedHostTicks: UInt64?
    private var sealReason: String?
    private var expired = false
    private var boundaryKnown = true

    @objc(initWithSessionID:beginHostTicks:)
    init(sessionID: String, beginHostTicks: UInt64) {
        self.sessionID = sessionID
        self.beginHostTicks = beginHostTicks
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        machTimebase = ["numer": timebase.numer, "denom": timebase.denom]
        deadlineHostTicks = beginHostTicks + 720_000_000_000 * UInt64(timebase.denom) / UInt64(timebase.numer)
        super.init()
        entries.reserveCapacity(Self.instanceCapacity)
        events.reserveCapacity(Self.eventCapacity)
    }

    fileprivate func register(_ keeper: SPResidentKeepAlive, bridgeID: String,
                              state: SPAirKeeperSessionState, context: [String: Any] = [:]) -> SPAirKeeperSessionEntry? {
        lock.lock()
        defer { lock.unlock() }
        instanceAttempts &+= 1
        guard sealedHostTicks == nil, state.hostTicks < deadlineHostTicks else {
            postSealAttempts &+= 1
            if state.hostTicks >= deadlineHostTicks { expired = true }
            return nil
        }
        guard entries.count < Self.instanceCapacity else { return nil }
        let entry = SPAirKeeperSessionEntry(sequence: instanceAttempts, bridgeID: bridgeID,
                                             keeper: keeper, journal: self, state: state, context: context)
        entries.append(entry)
        return entry
    }

    fileprivate func record(_ state: SPAirKeeperSessionState, kind: String, reason: String?,
                            sequence: UInt64, bridgeID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sealedHostTicks == nil, state.hostTicks < deadlineHostTicks else {
            postSealAttempts &+= 1
            if state.hostTicks >= deadlineHostTicks { expired = true }
            return false
        }
        eventAttempts &+= 1
        var lifecycle = spKeeperLifecycleDictionary(state.report.lifecycle)
        if state.report.lifecycle.drainBeginNs == nil { lifecycle["pendingAtDrainStart"] = NSNull() }
        if state.report.lifecycle.drainEndNs == nil { lifecycle["pendingAtEnd"] = NSNull() }
        var row: [String: Any] = ["sequence": eventAttempts, "instanceSequence": sequence,
            "instanceID": state.report.instanceID, "bridgeID": bridgeID, "kind": kind,
            "hostTicks": state.hostTicks, "uptimeNs": state.uptimeNs,
            "utcUnixSeconds": state.utcUnixSeconds,
            "planToken": state.report.planToken.map { $0 as Any } ?? NSNull(),
            "generation": state.report.generation.map { $0 as Any } ?? NSNull(),
            "configVersion": state.report.configVersion.map { $0 as Any } ?? NSNull(),
            "pendingCount": state.pending, "started": state.started, "stopRequested": state.stopping,
            "lifecycle": lifecycle,
            "firstFailure": state.report.firstFailure.map { $0 as Any } ?? NSNull()]
        if let reason { row["reason"] = reason }
        if events.count < Self.eventCapacity { events.append(row) }
        else { events[nextEventIndex] = row; nextEventIndex = (nextEventIndex + 1) % Self.eventCapacity }
        return true
    }

    @objc(summary)
    func summary() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["schema": "odf-beta-keeper-session-v1", "sessionID": sessionID,
                "machTimebase": machTimebase,
                "beginHostTicks": beginHostTicks, "recordingDeadlineHostTicks": deadlineHostTicks,
                "writePeriodSeconds": 720, "instanceCapacity": Self.instanceCapacity,
                "instanceAttempts": instanceAttempts, "retainedInstances": entries.count,
                "droppedInstances": instanceAttempts - UInt64(entries.count),
                "eventCapacity": Self.eventCapacity, "eventAttempts": eventAttempts,
                "retainedEvents": events.count, "droppedEvents": eventAttempts - UInt64(events.count),
                "postSealAttempts": postSealAttempts,
                "sealedHostTicks": sealedHostTicks.map { $0 as Any } ?? NSNull(),
                "sealReason": sealReason.map { $0 as Any } ?? NSNull(),
                "recordingExpired": expired, "recordingBoundaryKnown": boundaryKnown,
                "incomplete": instanceAttempts > UInt64(entries.count) || eventAttempts > UInt64(events.count) || expired || !boundaryKnown]
    }

    @objc(readiness)
    func readiness() -> [String: Any] {
        lock.lock(); let retained = entries, attempted = instanceAttempts; lock.unlock()
        var terminal = 0, active = 0, unknown = 0, drained = 0, ended = 0, failed = 0, pending = 0
        for entry in retained {
            let status = entry.readiness()
            if status.terminal { terminal += 1 }
            if status.active { active += 1 }
            if status.unknown { unknown += 1 }
            if status.drain { drained += 1 }
            if status.workerEnded { ended += 1 }
            if status.failure { failed += 1 }
            if let count = status.pending { pending += count }
        }
        let allRetainedTerminal = terminal == retained.count
        let pendingKnown = unknown == 0 && attempted == UInt64(retained.count)
        return ["retainedInstances": retained.count, "activeInstances": active,
                "unknownInstances": unknown, "terminalObservedInstances": terminal,
                "drainObservedInstances": drained, "workerEndedObservedInstances": ended,
                "failureInstances": failed, "pendingCount": pendingKnown ? pending as Any : NSNull(),
                "allRetainedTerminal": allRetainedTerminal,
                "allPlansObservedTerminal": allRetainedTerminal && attempted == UInt64(retained.count),
                "observedHostTicks": mach_absolute_time(), "observedUTCUnixSeconds": Date().timeIntervalSince1970]
    }

    @objc(sealRecordingAtHostTicks:reason:)
    func sealRecording(atHostTicks hostTicks: UInt64, reason: String) -> [String: Any] {
        lock.lock()
        if sealedHostTicks != nil { lock.unlock(); return summary() }
        let actual = mach_absolute_time()
        sealedHostTicks = hostTicks == 0 ? actual : hostTicks
        sealReason = reason
        expired = expired || actual >= deadlineHostTicks
        boundaryKnown = actual < deadlineHostTicks
        let retained = entries
        lock.unlock()
        for entry in retained { entry.freeze() }
        return summary()
    }

    @objc(enumerateInstancesIncludingRecords:usingBlock:)
    func enumerateInstances(includeRecords: Bool, usingBlock: (UInt64, NSDictionary) -> Bool) -> Bool {
        lock.lock()
        let retained = entries
        let known = boundaryKnown && (sealedHostTicks != nil || mach_absolute_time() < deadlineHostTicks)
        let cutoff = sealedHostTicks
        lock.unlock()
        for entry in retained {
            let more = autoreleasepool { usingBlock(entry.sequence, entry.dictionary(includeRecords: includeRecords, recordingBoundaryKnown: known, cutoffHostTicks: cutoff) as NSDictionary) }
            if !more { return false }
        }
        return true
    }

    @objc(enumerateEventsUsingBlock:)
    func enumerateEvents(usingBlock: (UInt64, NSDictionary) -> Bool) -> Bool {
        lock.lock()
        let ordered = Array(events[nextEventIndex...]) + Array(events[..<nextEventIndex])
        lock.unlock()
        for row in ordered {
            let more = autoreleasepool { usingBlock((row["sequence"] as? UInt64) ?? 0, row as NSDictionary) }
            if !more { return false }
        }
        return true
    }

    @objc(snapshotWithIncludeRecords:)
    func snapshot(includeRecords: Bool) -> [String: Any] {
        var result = summary()
        var instances: [NSDictionary] = [], lifecycleEvents: [NSDictionary] = []
        _ = enumerateInstances(includeRecords: includeRecords) { _, row in instances.append(row); return true }
        _ = enumerateEvents { _, row in lifecycleEvents.append(row); return true }
        result["instances"] = instances
        result["events"] = lifecycleEvents
        result["includeRecords"] = includeRecords
        return result
    }
}

/// Prepared on the existing background prepare queue, then owned by one plan.
/// The real RIFE executor never joins this worker or reads its per-CB state.
final class SPResidentKeepAlive {
    private static let deviceOwners = OSAllocatedUnfairLock(initialState: [UInt64: String]())
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let scratch: MTLBuffer
    private let worker = DispatchQueue(label: "app.openduckframe.keeper", qos: .userInitiated)
    private let lock = NSLock()
    private let deviceID: UInt64
    private let ownerID = UUID().uuidString
    private var report: SPResidentKeepAliveReport
    private var started = false
    private var stopRequested = false
    private var currentPhase = "plan_active"
    private var pendingCount = 0
    private var nextID: UInt64 = 1
    private var sessionEntry: SPAirKeeperSessionEntry?
    private weak var attachedSessionJournal: SPAirKeeperSessionJournal?
    private var sessionIdentity: [String: Any] = [:]
    private var retirementObservedNs: UInt64?
    private var iterations: UInt32 = 65_536
    // Only calibration, then the keeper worker, accesses this queue of own CBs.
    private var pending: [(buffer: MTLCommandBuffer, record: SPResidentKeepAliveRecord)] = []

    init(device: MTLDevice, libraryURL: URL,
         expectedMetallibSHA256: String = SPResidentKeepAliveMetallib.diagnosticSHA256) throws {
        let digest = SHA256.hash(data: try Data(contentsOf: libraryURL)).map { String(format: "%02x", $0) }.joined()
        guard SPResidentKeepAliveMetallib.matches(actual: digest, expected: expectedMetallibSHA256) else {
            throw SPResidentKeepAliveError.native("keeper metallib SHA256 mismatch")
        }
        guard let queue = device.makeCommandQueue(maxCommandBufferCount: 2) else {
            throw SPResidentKeepAliveError.native("keeper independent queue unavailable")
        }
        let library = try device.makeLibrary(URL: libraryURL)
        guard let function = library.makeFunction(name: "air_gap_fill") else {
            throw SPResidentKeepAliveError.native("keeper offline function unavailable")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        let threads = pipeline.threadExecutionWidth
        let bytes = threads * MemoryLayout<UInt32>.stride
        guard threads > 0, threads <= pipeline.maxTotalThreadsPerThreadgroup,
              let scratch = device.makeBuffer(length: bytes, options: [.storageModePrivate, .hazardTrackingModeTracked]),
              scratch.hazardTrackingMode == .tracked else {
            throw SPResidentKeepAliveError.native("keeper one-SIMD-group tracked scratch unavailable")
        }
        self.queue = queue; self.pipeline = pipeline; self.scratch = scratch
        deviceID = device.registryID
        queue.label = "ODF resident keepalive diagnostic"
        scratch.label = "ODF resident keepalive private tracked scratch"
        report = .init(configuration: .init(deviceRegistryID: device.registryID, deviceName: device.name,
                       threadsPerThreadgroup: [threads, 1, 1], threadExecutionWidth: threads,
                       scratchBytes: bytes, metallibSHA256: digest))
        pending.reserveCapacity(2)
    }

    func attachSessionJournal(_ journal: SPAirKeeperSessionJournal, bridgeID: String) {
        lock.lock()
        if attachedSessionJournal !== journal {
            attachedSessionJournal = journal
            sessionEntry = journal.register(self, bridgeID: bridgeID,
                                            state: sessionStateLocked(freezeAccounting: false), context: sessionIdentity)
            recordSessionCheckpointLocked(kind: "instance_registered")
        }
        lock.unlock()
    }

    func setSessionIdentity(deviceRegistryID: UInt64, modelIdentity: [String: Any]) {
        lock.lock()
        sessionIdentity = ["rifeDeviceRegistryID": deviceRegistryID, "rifeModelIdentity": modelIdentity,
            "deviceBindingSource": "Actual preferredDevice passed to RIFE configuration and this keeper initializer"]
        lock.unlock()
    }

    private func sessionStateLocked(freezeAccounting: Bool) -> SPAirKeeperSessionState {
        var copied = report
        if freezeAccounting { copied.accounting = report.accounting.frozenCopy() }
        return SPAirKeeperSessionState(report: copied, pending: pendingCount, stopping: stopRequested,
            started: started, phase: currentPhase, hostTicks: mach_absolute_time(),
            uptimeNs: spKeeperNowNs(), utcUnixSeconds: Date().timeIntervalSince1970)
    }

    fileprivate func captureKeeperSessionState(freezeAccounting: Bool) -> SPAirKeeperSessionState {
        lock.lock(); defer { lock.unlock() }
        return sessionStateLocked(freezeAccounting: freezeAccounting)
    }

    private func recordSessionCheckpointLocked(kind: String, reason: String? = nil) {
        sessionEntry?.record(sessionStateLocked(freezeAccounting: false), kind: kind, reason: reason)
    }

    func recordRetirement(reason: String) {
        lock.lock()
        retirementObservedNs = spKeeperNowNs()
        recordSessionCheckpointLocked(kind: "retired", reason: reason)
        lock.unlock()
    }

    func operationalReadiness() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let lifecycle = report.lifecycle
        let firstCommit = lifecycle.firstOperationalCommitBeginNs
        let firstObserved = firstCommit.map { $0 > 0 } ?? false
        let operational = started && report.calibration.passed && report.deviceClaimPassed
            && firstObserved && pendingCount >= 1 && pendingCount <= 2
            && !stopRequested && retirementObservedNs == nil && lifecycle.workerEndedNs == nil
            && report.firstFailure == nil && report.unknownTimingCount == 0
            && !lifecycle.drainTimedOut && !lifecycle.deviceClaimWaitTimedOut
        return ["available": true, "operational": operational, "instanceID": report.instanceID,
                "planToken": report.planToken.map { $0 as Any } ?? NSNull(),
                "generation": report.generation.map { $0 as Any } ?? NSNull(),
                "configVersion": report.configVersion.map { $0 as Any } ?? NSNull(),
                "started": started, "stopRequested": stopRequested, "retired": retirementObservedNs != nil,
                "retirementObservedNs": retirementObservedNs.map { $0 as Any } ?? NSNull(),
                "startRequestedNs": lifecycle.startRequestedNs.map { $0 as Any } ?? NSNull(),
                "workerBeganNs": lifecycle.workerBeganNs.map { $0 as Any } ?? NSNull(),
                "firstOperationalCommitBeginNs": firstCommit.map { $0 as Any } ?? NSNull(),
                "workerEndedNs": lifecycle.workerEndedNs.map { $0 as Any } ?? NSNull(),
                "pendingCount": pendingCount, "calibrationPassed": report.calibration.passed,
                "deviceClaimPassed": report.deviceClaimPassed, "deviceRegistryID": deviceID,
                "firstFailure": report.firstFailure.map { $0 as Any } ?? NSNull(),
                "observedUptimeNs": spKeeperNowNs()]
    }

    private func requestStopLocked(reason: String) -> Bool {
        guard !stopRequested else { return false }
        stopRequested = true
        report.lifecycle.stopRequestedNs = spKeeperNowNs()
        report.lifecycle.stopReason = reason
        if !started {
            report.lifecycle.drainBeginNs = report.lifecycle.stopRequestedNs
            report.lifecycle.drainEndNs = report.lifecycle.stopRequestedNs
            report.lifecycle.requestToDrainEndNs = 0
        }
        return started
    }

    private func fail(_ message: String) {
        lock.lock()
        if report.firstFailure == nil { report.firstFailure = message }
        let watch = requestStopLocked(reason: "keeper_error")
        recordSessionCheckpointLocked(kind: "failure", reason: message)
        lock.unlock()
        if watch { watchDrainDeadline() }
    }

    private func shouldStop() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    /// This watchdog only records timeout. Own CBs retain their resources and
    /// device claim until they actually terminate on the background worker.
    private func watchDrainDeadline() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.lock.lock()
            if self.report.lifecycle.workerEndedNs == nil {
                self.report.lifecycle.drainTimedOut = true
                if self.report.firstFailure == nil { self.report.firstFailure = "keeper drain exceeded 100ms" }
                self.recordSessionCheckpointLocked(kind: "drain_timeout")
            }
            self.lock.unlock()
        }
    }

    private func submit(phase: String? = nil) throws -> Bool {
        guard pending.count < 2 else { throw SPResidentKeepAliveError.native("keeper max-two invariant") }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw SPResidentKeepAliveError.native("keeper command encoder unavailable")
        }
        var count = iterations
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(scratch, offset: 0, index: 0)
        encoder.useResource(scratch, usage: .write)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        lock.lock()
        if stopRequested { lock.unlock(); return false }
        let phase = phase ?? currentPhase
        command.label = "app-keeper-\(nextID)-\(phase)"
        let begin = spKeeperNowNs()
        command.commit()
        let end = spKeeperNowNs()
        if started, report.lifecycle.firstOperationalCommitBeginNs == nil {
            report.lifecycle.firstOperationalCommitBeginNs = begin
        }
        report.recordsAttempted += 1
        pendingCount += 1
        report.lifecycle.maximumPendingObserved = max(report.lifecycle.maximumPendingObserved, pendingCount)
        lock.unlock()
        let row = SPResidentKeepAliveRecord(cbID: nextID, phase: phase, iterations: iterations,
                                           commitBeginNs: begin, commitEndNs: end)
        nextID &+= 1
        pending.append((command, row))
        return true
    }

    private func collectOldest() {
        let current = pending.removeFirst()
        current.buffer.waitUntilCompleted()
        var row = current.record
        row.terminalObservedNs = spKeeperNowNs()
        row.status = UInt32(current.buffer.status.rawValue)
        if current.buffer.status == .completed || current.buffer.status == .error { row.validityMask |= 2 }
        row.gpuStartSeconds = current.buffer.gpuStartTime
        row.gpuEndSeconds = current.buffer.gpuEndTime
        if current.buffer.status == .completed, row.gpuStartSeconds.isFinite, row.gpuEndSeconds.isFinite,
           row.gpuStartSeconds > 0, row.gpuEndSeconds > row.gpuStartSeconds {
            row.validityMask |= 4
            row.gpuDurationMs = (row.gpuEndSeconds - row.gpuStartSeconds) * 1000
        } else {
            row.error = current.buffer.error.map { String(describing: $0) } ?? "missing valid completed GPU interval"
        }
        lock.lock()
        pendingCount -= 1
        if row.error != nil { report.unknownTimingCount += 1 }
        if row.phase.hasPrefix("calibration_") { report.calibration.records.append(row) }
        report.accounting.append(row)
        lock.unlock()
        if let failure = row.error { fail(failure) }
    }

    func calibrate(checkCancel: () throws -> Void) throws {
        defer {
            lock.lock()
            recordSessionCheckpointLocked(kind: "calibration_finished")
            lock.unlock()
        }
        func five(_ phase: String) throws -> Double {
            for _ in 0..<5 {
                try autoreleasepool {
                    try checkCancel()
                    guard try submit(phase: phase) else { throw SPResidentKeepAliveError.cancelled }
                    collectOldest()
                    try checkCancel()
                    if let failure = report.firstFailure { throw SPResidentKeepAliveError.calibration(failure) }
                }
            }
            let values = report.calibration.records.filter { $0.phase == phase }.compactMap { $0.gpuDurationMs }.sorted()
            guard values.count == 5, values[2].isFinite, values[2] > 0 else {
                throw SPResidentKeepAliveError.calibration("keeper invalid calibration timestamps")
            }
            return values[2]
        }
        do {
            lock.lock(); report.calibration.status = "pilot"; lock.unlock()
            let pilot = try five("calibration_pilot")
            lock.lock(); report.calibration.pilotMedianMs = pilot; lock.unlock()
            guard let scaled = SPResidentCalibrationPolicy.nextIterations(
                current: report.calibration.initialPilotIterations, observedMs: pilot) else {
                throw SPResidentKeepAliveError.calibration("keeper pilot iteration conversion out of range")
            }
            iterations = scaled
            lock.lock()
            report.calibration.scaledIterations = iterations
            report.calibration.status = "validation"
            lock.unlock()
            var lower: UInt32?, upper: UInt32?
            for round in 1...SPResidentCalibrationPolicy.maximumValidationRounds {
                let phase = round == 1 ? "calibration_validation" : "calibration_validation_\(round)"
                let validation = try five(phase)
                try checkCancel()
                lock.lock()
                report.calibration.validationMedianMs = validation
                report.calibration.validationRounds.append([
                    "round": Double(round), "iterations": Double(iterations), "medianMs": validation])
                lock.unlock()
                if SPResidentCalibrationPolicy.accepts(validation) {
                    lock.lock(); report.calibration.passed = true; report.calibration.status = "passed"; lock.unlock()
                    return
                }
                if validation < SPResidentCalibrationPolicy.minimumMs { lower = iterations }
                else { upper = iterations }
                guard round < SPResidentCalibrationPolicy.maximumValidationRounds,
                      let next = SPResidentCalibrationPolicy.nextIterations(
                        current: iterations, observedMs: validation, lower: lower, upper: upper),
                      next != iterations else {
                    let attempts = report.calibration.validationRounds.map {
                        "round \(Int($0["round"]!)): \(Int($0["iterations"]!)) iterations, \($0["medianMs"]!)ms"
                    }.joined(separator: "; ")
                    throw SPResidentKeepAliveError.calibration(
                        "keeper validation outside [0.5,2]ms after \(round) rounds; pilot \(pilot)ms; \(attempts)")
                }
                iterations = next
                lock.lock(); report.calibration.scaledIterations = iterations; lock.unlock()
            }
        } catch {
            lock.lock()
            report.calibration.status = "failed"
            report.calibration.firstFailure = String(describing: error)
            lock.unlock()
            fail(String(describing: error))
            throw error
        }
    }

    /// Synchronous work is limited to plan-state admission. No worker/GPU ack.
    func start(planToken: UInt64, generation: UInt64, configVersion: UInt64) -> Bool {
        lock.lock()
        let canStart = report.calibration.passed && !started && !stopRequested && planToken != 0
        guard canStart else {
            lock.unlock()
            fail("keeper start rejected: unready, stopped, duplicate or zero plan token")
            return false
        }
        started = true
        report.planToken = planToken; report.generation = generation; report.configVersion = configVersion
        report.lifecycle.startRequestedNs = spKeeperNowNs()
        recordSessionCheckpointLocked(kind: "start_requested")
        lock.unlock()
        worker.async { self.runWorker() }
        return true
    }

    /// A replaced plan may still be draining its two CBs. Handoff waits only on
    /// this private worker, with a visible 100ms failure and no overlapping owner.
    private func acquireDeviceClaim() -> Bool {
        let begin = spKeeperNowNs()
        lock.lock(); report.lifecycle.deviceClaimWaitBeginNs = begin; lock.unlock()
        while !shouldStop() {
            let wantedDevice = deviceID, owner = ownerID
            let available = Self.deviceOwners.withLock { owners in
                guard owners[wantedDevice] == nil else { return false }
                assert(owners[wantedDevice] == nil, "at most one active keeper per Metal device")
                owners[wantedDevice] = owner
                return true
            }
            if available {
                lock.lock()
                report.deviceClaimPassed = true
                report.lifecycle.deviceClaimAcquiredNs = spKeeperNowNs()
                recordSessionCheckpointLocked(kind: "device_claim_acquired")
                lock.unlock()
                return true
            }
            if spKeeperNowNs() - begin >= 100_000_000 {
                lock.lock(); report.lifecycle.deviceClaimWaitTimedOut = true; lock.unlock()
                fail("keeper device ownership handoff exceeded 100ms")
                return false
            }
            Thread.sleep(forTimeInterval: 0.00025)
        }
        return false
    }

    private func releaseDeviceClaim() {
        let wantedDevice = deviceID, owner = ownerID
        let released = Self.deviceOwners.withLock { owners in
            if owners[wantedDevice] == owner {
                owners.removeValue(forKey: wantedDevice)
                return true
            }
            return false
        }
        lock.lock()
        recordSessionCheckpointLocked(kind: released ? "device_claim_released" : "device_claim_release_unmatched")
        lock.unlock()
    }

    private func runWorker() {
        lock.lock()
        report.lifecycle.workerBeganNs = spKeeperNowNs()
        recordSessionCheckpointLocked(kind: "worker_began")
        lock.unlock()
        let claimed = acquireDeviceClaim()
        while claimed && !shouldStop() {
            autoreleasepool {
                do {
                    while pending.count < 2 && !shouldStop() {
                        if !(try submit()) { break }
                    }
                } catch { fail(String(describing: error)) }
                if !pending.isEmpty { collectOldest() }
            }
        }
        lock.lock()
        report.lifecycle.drainBeginNs = spKeeperNowNs()
        report.lifecycle.pendingAtDrainStart = pendingCount
        recordSessionCheckpointLocked(kind: "drain_begin")
        lock.unlock()
        while !pending.isEmpty { autoreleasepool { collectOldest() } }
        lock.lock()
        let end = spKeeperNowNs()
        report.lifecycle.drainEndNs = end
        report.lifecycle.pendingAtEnd = pendingCount
        report.lifecycle.workerEndedNs = end
        if let requested = report.lifecycle.stopRequestedNs {
            report.lifecycle.requestToDrainEndNs = end - requested
            if end - requested > 100_000_000 {
                report.lifecycle.drainTimedOut = true
                if report.firstFailure == nil { report.firstFailure = "keeper drain exceeded 100ms" }
            }
        }
        recordSessionCheckpointLocked(kind: "worker_ended")
        lock.unlock()
        if claimed { releaseDeviceClaim() }
    }

    func requestStop(planToken: UInt64, reason: String) {
        lock.lock()
        let matches = planToken == 0 || report.planToken == planToken
        let watch = matches && requestStopLocked(reason: reason)
        if matches { recordSessionCheckpointLocked(kind: "stop_requested", reason: reason) }
        lock.unlock()
        if watch { watchDrainDeadline() }
    }

    func markPhase(_ name: String, planToken: UInt64) {
        lock.lock()
        if report.planToken == planToken && !stopRequested {
            currentPhase = name
            report.phaseMarks.append(.init(phase: name, stampNs: spKeeperNowNs()))
        }
        lock.unlock()
    }

    func snapshot(includeRecords: Bool) -> [String: Any] {
        lock.lock()
        let copied = report
        let recordSnapshot = includeRecords ? report.accounting.snapshot() : nil
        let pending = pendingCount, stopping = stopRequested, wasStarted = started
        let phaseName = currentPhase
        lock.unlock()
        if let recordSnapshot {
            return spKeeperFullSnapshot(copied, aggregation: recordSnapshot.aggregation,
                                        diagnostics: recordSnapshot.diagnosticRecords,
                                        pending: pending, stopping: stopping, started: wasStarted)
        }
        return ["instanceID": copied.instanceID, "deviceRegistryID": deviceID,
                "planToken": copied.planToken.map { $0 as Any } ?? NSNull(),
                "generation": copied.generation.map { $0 as Any } ?? NSNull(),
                "configVersion": copied.configVersion.map { $0 as Any } ?? NSNull(),
                "started": wasStarted, "stopRequested": stopping, "pendingCount": pending,
                "currentPhase": phaseName,
                "maximumPendingObserved": copied.lifecycle.maximumPendingObserved,
                "calibrationPassed": copied.calibration.passed,
                "calibrationStatus": copied.calibration.status,
                "scaledIterations": copied.calibration.scaledIterations.map { $0 as Any } ?? NSNull(),
                "deviceClaimPassed": copied.deviceClaimPassed,
                "recordsAttempted": copied.recordsAttempted, "recordsDropped": copied.recordsDropped,
                "overflow": copied.overflow, "firstFailure": copied.firstFailure.map { $0 as Any } ?? NSNull(),
                "workerEndedNs": copied.lifecycle.workerEndedNs.map { $0 as Any } ?? NSNull(),
                "drainEndNs": copied.lifecycle.drainEndNs.map { $0 as Any } ?? NSNull(),
                "requestToDrainEndNs": copied.lifecycle.requestToDrainEndNs.map { $0 as Any } ?? NSNull(),
                "deviceClaimWaitBeginNs": copied.lifecycle.deviceClaimWaitBeginNs.map { $0 as Any } ?? NSNull(),
                "deviceClaimAcquiredNs": copied.lifecycle.deviceClaimAcquiredNs.map { $0 as Any } ?? NSNull(),
                "deviceClaimWaitTimedOut": copied.lifecycle.deviceClaimWaitTimedOut,
                "drainTimedOut": copied.lifecycle.drainTimedOut]
    }
}
#endif
