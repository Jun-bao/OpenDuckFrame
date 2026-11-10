#!/usr/bin/env python3
"""CPU-only review of an existing Apple FRC native report; never runs a job.

The measured quantity is B submit -> final NV12 completion wall time, entirely
in CLOCK_UPTIME_RAW. There are no Apple GPU timestamps in this diagnostic.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec = 40
D = Decimal
NS = 1_000_000_000
FORMAT = "odf-air-apple-frc-native-v1"
P95_LIMIT_NS = 30_800_000
MIN_JOBS = 12
BURST_RATIO = 2
BURST_BINS = 5


def integer(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def quantile(values, probability):
    values = sorted(D(v) for v in values)
    if not values:
        return None
    position = D(len(values) - 1) * D(str(probability))
    index = int(position)
    return values[index] + (values[min(index + 1, len(values) - 1)] - values[index]) * (position - index)


def distribution_ns(values):
    if not values:
        return None
    return {"n": len(values), "min": D(min(values)) / 1_000_000,
            **{f"p{p}": quantile(values, D(p) / 100) / 1_000_000 for p in (50, 95, 99)},
            "max": D(max(values)) / 1_000_000}


def read_json(path):
    blob = path.read_bytes()
    def reject(value):
        raise ValueError(f"Non-finite JSON number: {value}")
    return json.loads(blob, parse_float=D, parse_constant=reject), {
        "name": path.name, "sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob)}


def job_review(raw, index):
    issues = []
    jid = integer(raw.get("jobID"))
    start, end, returned, wall = (integer(raw.get(k)) for k in
                                ("submitNs", "readyNs", "submitReturnNs", "submitToReadyNs"))
    status = raw.get("status")
    if raw.get("accepted") is False:
        category = "rejected"
    elif raw.get("accepted") is True and raw.get("callbackSeen") is False:
        category = "missing_ready"
    elif raw.get("accepted") is True and raw.get("callbackSeen") is True:
        category = "complete" if status == "ready" else "terminal_error"
    else:
        category = "unknown"
    if category != "complete":
        issues.append("job_not_successful:" + str(status))
    if jid is None or jid <= 0:
        issues.append("invalid_job_id")
    if not (start is not None and end is not None and returned is not None and wall is not None
            and 0 < start < end and returned >= start and wall == end - start):
        issues.append("missing_or_invalid_full_service_interval")
    if category == "complete":
        if raw.get("completionToken") != jid:
            issues.append("completion_token_mismatch")
        if (raw.get("actualOutputFourCC") != "420v" or raw.get("outputWidth") != 1814
                or raw.get("outputHeight") != 1142 or raw.get("outputIOSurface") is not True):
            issues.append("invalid_completed_output")
        if raw.get("errorDomain") or raw.get("errorCode") not in (0, None) or raw.get("errorDescription"):
            issues.append("ready_has_error")
    return {"rawIndex": index, "jobID": jid, "phase": raw.get("phase"), "status": status,
            "category": category, "submitNs": start, "readyNs": end,
            "wallNs": wall if not issues else None, "issues": issues, "raw": raw}


def phase_review(name, phase, jobs, baseline_median_ns):
    issues = []
    if not isinstance(phase, dict):
        return {"present": False, "issues": ["phase_missing"], "ledgerClosed": False}, []
    count_keys = ("plannedSlots", "submittedCount", "completeCount", "terminalErrorCount",
                  "missingReadyCount", "rejectedCount", "skippedSlots",
                  "unissuedRemainingSlots", "unfinishedCount")
    counts = {k: integer(phase.get(k)) for k in count_keys}
    counts_valid = all(v is not None and v >= 0 for v in counts.values())
    checks = {}
    if counts_valid:
        c = counts
        checks = {
            "planned_equals_submitted_skip_unissued": c["plannedSlots"] == c["submittedCount"] + c["skippedSlots"] + c["unissuedRemainingSlots"],
            "submitted_equals_four_outcomes": c["submittedCount"] == sum(c[k] for k in ("completeCount", "terminalErrorCount", "missingReadyCount", "rejectedCount")),
            "unfinished_equals_explicit_failures_unissued": c["unfinishedCount"] == sum(c[k] for k in ("terminalErrorCount", "missingReadyCount", "rejectedCount", "unissuedRemainingSlots")),
            "planned_equals_complete_skip_unfinished": c["plannedSlots"] == c["completeCount"] + c["skippedSlots"] + c["unfinishedCount"],
            "submitted_matches_job_rows": c["submittedCount"] == len(jobs),
        }
        categories = Counter(j["category"] for j in jobs)
        for category, field in (("complete", "completeCount"), ("terminal_error", "terminalErrorCount"),
                                ("missing_ready", "missingReadyCount"), ("rejected", "rejectedCount")):
            checks["rows_match_" + field] = categories[category] == c[field]
    else:
        issues.append("missing_or_invalid_explicit_ledger_counts")
    start, end, requested_end = (integer(phase.get(k)) for k in ("startNs", "endNs", "requestedEndNs"))
    seconds = 5 if name == "baseline" else 120
    time_valid = (start is not None and end is not None and requested_end is not None
                  and 0 < start <= end and requested_end == start + seconds * NS)
    if not time_valid or phase.get("requestedSeconds") != seconds:
        issues.append("invalid_phase_boundaries_or_duration")
    if counts.get("plannedSlots") != seconds * 24:
        issues.append("planned_slots_not_fixed_24hz_duration")
    previous = -1
    skipped_before = 0
    ticks = []
    for job in jobs:
        raw = job["raw"]
        tick, missed = integer(raw.get("tick")), integer(raw.get("missedSlotsBefore"))
        if tick is None or not previous < tick < seconds * 24:
            issues.append("invalid_or_nonincreasing_tick:" + str(job["jobID"]))
            continue
        ticks.append(tick)
        if missed != tick - previous - 1:
            issues.append("missed_before_does_not_match_tick_gap:" + str(job["jobID"]))
        skipped_before += tick - previous - 1
        previous = tick
        if time_valid and raw.get("targetNs") != start + tick * NS // 24:
            issues.append("target_not_absolute_24hz_tick:" + str(job["jobID"]))
        if time_valid and (job["submitNs"] is None or not start <= job["submitNs"] < requested_end):
            issues.append("submission_outside_requested_phase:" + str(job["jobID"]))
    trailing_skipped = None
    if counts_valid and len(ticks) == len(jobs):
        trailing_skipped = seconds * 24 - previous - 1 - counts["unissuedRemainingSlots"]
        checks["skips_match_observed_tick_gaps_and_reported_unissued"] = (
            trailing_skipped >= 0 and skipped_before + trailing_skipped == counts["skippedSlots"])
    issues.extend("ledger:" + key for key, ok in checks.items() if not ok)
    walls = [j["wallNs"] for j in jobs if j["wallNs"] is not None]
    bins = []
    duration = cutoff = None
    if time_valid:
        duration = D(end - start) / NS
        cutoff = min(end, requested_end)
        for i in range((cutoff - start) // NS):
            rows = [j for j in jobs if j["submitNs"] is not None
                    and start + i * NS <= j["submitNs"] < start + (i + 1) * NS]
            valid = [j["wallNs"] for j in rows if j["wallNs"] is not None]
            median = quantile(valid, ".5")
            valid_bin = len(valid) >= MIN_JOBS and len(valid) == len(rows) and baseline_median_ns is not None
            bins.append({"index": i, "startSeconds": i, "endSeconds": i + 1,
                         "submittedCount": len(rows), "successfulValidCount": len(valid),
                         "invalidCount": len(rows) - len(valid), "validForBurst": valid_bin,
                         "lowCount": len(valid) < MIN_JOBS,
                         "medianWallMs": median / 1_000_000 if median is not None else None,
                         "high": median >= baseline_median_ns * BURST_RATIO if valid_bin else None})
    streak = 0
    onset = None
    for row in bins:
        streak = streak + 1 if row["high"] is True else 0
        if streak >= BURST_BINS and onset is None:
            onset = row["index"] - BURST_BINS + 1
    status = "incomplete"
    if time_valid and phase.get("complete") is True:
        if end >= requested_end:
            status = "observed_through_requested_end"
        elif (counts_valid and counts["unissuedRemainingSlots"] == 0 and all(checks.values())
              and 0 < requested_end - end < D(NS) / 24):
            status = "scheduled_complete_with_idle_tail"
        else:
            issues.append("complete_phase_has_unexplained_unobserved_tail")
    return {
        "present": True, "nativeComplete": phase.get("complete"), "observationStatus": status,
        "startNs": start, "endNs": end, "requestedEndNs": requested_end,
        "observedSeconds": duration, "counts": counts, "ledgerChecks": checks,
        "ledgerClosed": counts_valid and bool(checks) and all(checks.values()) and not issues,
        "tickGapsBeforeJobs": skipped_before,
        "trailingSkippedTicksImpliedByLastTickAndReportedUnissued": trailing_skipped,
        "successfulValidWallMs": distribution_ns(walls),
        "statisticsUseAllSuccessfulPhaseJobsIncludingCompletionsAfterCutoff": True,
        "actualSuccessfulHz": D(len(walls)) / duration if duration else None,
        "nativeActualHz": phase.get("actualHz"),
        "completeCpuBins": len(bins),
        "observedPartialTailSeconds": D((cutoff - start) % NS) / NS if cutoff is not None else None,
        "unobservedRequestedTailSeconds": D(max(0, requested_end - end)) / NS if time_valid else None,
        "postRequestedCompletionObservationSeconds": D(max(0, end - requested_end)) / NS if time_valid else None,
        "lowCountBins": [b["index"] for b in bins if b["lowCount"]],
        "invalidBins": [b["index"] for b in bins if b["invalidCount"]],
        "burstDetected": onset is not None,
        "firstDetectedOnsetSeconds": onset,
        "confirmationAtSeconds": onset + BURST_BINS if onset is not None else None,
        "earlierUnknownBins": [b["index"] for b in bins if not b["validForBurst"] and (onset is None or b["index"] < onset)],
        "issues": issues, "bins": bins,
    }, walls


def analyze(data):
    problems = []
    if data.get("format") != FORMAT:
        problems.append("unexpected_raw_format")
    jobs = [job_review(j, i) for i, j in enumerate(data.get("jobs", []))]
    duplicate_ids = [jid for jid, n in Counter(j["jobID"] for j in jobs).items() if n > 1]
    if duplicate_ids:
        problems.append("duplicate_job_ids")
    bad_jobs = [{k: v for k, v in j.items() if k != "raw"} for j in jobs if j["issues"]]
    unknown_phases = sorted({str(j["phase"]) for j in jobs if j["phase"] not in ("warmup", "baseline", "measurement")})
    if unknown_phases:
        problems.append("unknown_job_phase")
    groups = {p: [j for j in jobs if j["phase"] == p] for p in ("warmup", "baseline", "measurement")}
    prefix_walls = [j["wallNs"] for j in groups["baseline"] if j["wallNs"] is not None]
    prefix_median = quantile(prefix_walls, ".5")
    phases = data.get("phases", {})
    baseline, _ = phase_review("baseline", phases.get("baseline"), groups["baseline"], prefix_median)
    formal, walls = phase_review("measurement", phases.get("measurement"), groups["measurement"], prefix_median)
    if len(groups["warmup"]) != 20:
        problems.append("warmup_not_20_records")
    if prefix_median is None or prefix_median <= 0:
        problems.append("no_valid_own_prefix_wall_baseline")
    if (baseline.get("startNs") is not None and formal.get("startNs") is not None
            and formal["startNs"] != baseline["startNs"] + 5 * NS):
        problems.append("formal_not_on_shared_prefix_plus_5s_anchor")
    config = data.get("configuration", {})
    expected = {"engine": "apple.frc", "width": 1814, "height": 1142, "mode": "paced24",
                "targetHz": 24, "seconds": 120, "baselineSeconds": 5, "warmup": 20,
                "sessionsRequested": 2, "outputCapacity": 8, "quality": "Normal",
                "revision": 1, "submissionMode": "Random", "singleRequestInFlight": True}
    mismatch = {k: {"expected": v, "actual": config.get(k)} for k, v in expected.items() if config.get(k) != v}
    if mismatch or (data.get("setupSucceeded") is True and data.get("actualSessionCount") != 2):
        problems.append("configuration_or_actual_session_mismatch")
    p95 = quantile(walls, ".95")
    p95_pass = p95 <= P95_LIMIT_NS if p95 is not None else None
    ledgers_ok = baseline["ledgerClosed"] and formal["ledgerClosed"]
    run_complete = (data.get("status") == "complete" and data.get("functionalComplete") is True
                    and data.get("formalStarted") is True and baseline.get("nativeComplete") is True
                    and formal.get("nativeComplete") is True)
    if data.get("setupSucceeded") is False and data.get("status") != "capability_only":
        result, reason = "setup_failed", "explicit_setup_failure_no_performance_conclusion"
    elif bad_jobs or problems or not ledgers_ok or not run_complete:
        result, reason = "inconclusive", "job_error_missing_ready_incomplete_run_or_accounting_evidence"
    elif p95_pass is False or formal.get("burstDetected") is True:
        result, reason = "fail", "full_service_p95_or_detected_wall_burst"
    elif p95_pass is None or not formal.get("completeCpuBins") or formal.get("lowCountBins") or formal.get("invalidBins"):
        result, reason = "inconclusive", "insufficient_complete_cpu_bin_evidence"
    else:
        result, reason = "pass", "all_frozen_native_gates_met"
    return {
        "format": "odf-air-apple-frc-native-review-v1", "classification": result, "classificationReason": reason,
        "contract": {"service": "B submit to final NV12 completion wall; CLOCK_UPTIME_RAW only",
                     "quantile": "linear type-7", "p95LimitMs": D("30.8"),
                     "prefixSeconds": 5, "warmupJobs": 20, "formalSeconds": 120,
                     "burstRatio": BURST_RATIO, "consecutiveCompleteBins": BURST_BINS,
                     "minimumSuccessfulJobsPerCompleteCpuBin": MIN_JOBS,
                     "binAssignment": "half-open submit-start CPU bins; full latency stays with its submission",
                     "errorPrecedence": "any warmup/prefix/formal job error or missing ready, unclosed ledger, or incomplete evidence -> inconclusive before performance gates",
                     "skipThreshold": None, "historicalRifeWallPrefixGateApplied": False,
                     "screeningScope": "30.8ms is a frozen screening condition, not hardware impossibility or an App guarantee"},
        "nativeStatus": data.get("status"), "functionalComplete": data.get("functionalComplete"),
        "setupSucceeded": data.get("setupSucceeded"), "firstFailure": data.get("firstFailure"),
        "failurePhase": data.get("failurePhase"), "setupError": data.get("setupError"),
        "stoppedRequestAfterInvalidation": data.get("stoppedRequestAfterInvalidation"),
        "configuration": config, "configurationMismatches": mismatch,
        "actualSessionCount": data.get("actualSessionCount"), "actualSetupEvents": data.get("actualSetupEvents"),
        "capability": data.get("capability"), "device": data.get("device"), "fixtureSetup": data.get("fixtureSetup"),
        "lastOutputSHA256": data.get("lastOutputSHA256"),
        "jobCount": len(jobs), "duplicateJobIDs": duplicate_ids, "unknownJobPhases": unknown_phases,
        "jobStatusCounts": dict(Counter(j["status"] for j in jobs)),
        "warmup": {"count": len(groups["warmup"]), "successfulValidWallMs": distribution_ns([j["wallNs"] for j in groups["warmup"] if j["wallNs"] is not None])},
        "baseline": baseline, "measurement": formal,
        "observations": {"formalSuccessfulSubsetP95Pass": p95_pass,
                         "allFormalRowsSuccessfulAndValid": len(walls) == len(groups["measurement"]),
                         "ownPrefixWallP50Ms": prefix_median / 1_000_000 if prefix_median is not None else None,
                         "burstThresholdMs": prefix_median * BURST_RATIO / 1_000_000 if prefix_median is not None else None},
        "invalidJobs": bad_jobs, "evidenceProblems": problems,
        "thermalSamples": data.get("thermalSamples", []),
        "limits": ["No Apple GPU execution/residency, frequency, heat cause or energy inference.",
                   "Successful-subset statistics do not repair job errors, missing ready or incomplete phases.",
                   "No tail bin is fabricated; a closed schedule with less than one tick of idle tail retains its actual endpoint.",
                   "No task, repeat, App run or long run is started by this analyzer."]}


def json_default(value):
    if isinstance(value, D):
        return float(value)
    raise TypeError(type(value).__name__)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--environment", type=Path, help="Optional existing coordinator-state.json; provenance only")
    args = parser.parse_args()
    data, receipt = read_json(args.input)
    report = analyze(data)
    report["input"] = receipt
    report["analyzerSHA256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if args.environment:
        env, env_receipt = read_json(args.environment)
        report["environment"] = {"input": env_receipt,
                                 **{k: env.get(k) for k in ("status", "native_status", "native_sha256", "preferences_unchanged", "started_utc", "completed_utc", "preflight_before", "preflight_after")},
                                 "rawHashMatchesCoordinator": env.get("native_sha256") == receipt["sha256"],
                                 "preferencesHashesEqual": env.get("preferences_before") == env.get("preferences_after") if env.get("preferences_before") is not None and env.get("preferences_after") is not None else None}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, default=json_default, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"classification": report["classification"], "reason": report["classificationReason"],
                      "formalWallMs": report["measurement"].get("successfulValidWallMs"),
                      "burstOnsetSeconds": report["measurement"].get("firstDetectedOnsetSeconds"),
                      "output": str(args.output)}, default=json_default, ensure_ascii=False))


if __name__ == "__main__":
    main()
