#!/usr/bin/env python3
"""CPU-only analysis of independent four-stage filler / five-stage real work.

Never starts a model or experiment. GPU intervals are compared only with other
Metal GPU intervals; CPU wall/phase/tick timestamps remain in their own domain.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from decimal import Decimal as D
from pathlib import Path

import analyze as sustained

NS = 1_000_000_000
MIN_REAL_PER_BIN = 12
REAL_GPU_RATIO_LIMIT = D("1.3")
REAL_WALL_P95_LIMIT_MS = D("30.8")
GUARD_NS = 3_000_000
REAL_SHA = "ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74"
EXTRA_SHA = "729ea555016da98e207bc4570e0be81dddbbd37302f7330c89696da798fba22d"


def merge_intervals(intervals):
    merged = []
    for a, b in sorted((a, b) for a, b in intervals):
        if b < a:
            raise ValueError("Reversed GPU interval")
        if not merged or a > merged[-1][1]:
            merged.append([a, b])
        else:
            merged[-1][1] = max(merged[-1][1], b)
    return merged


def duration(intervals):
    return sum((b - a for a, b in merge_intervals(intervals)), D(0))


def intersect(left, right):
    result = []
    a, b = merge_intervals(left), merge_intervals(right)
    i = j = 0
    while i < len(a) and j < len(b):
        lo, hi = max(a[i][0], b[j][0]), min(a[i][1], b[j][1])
        if hi > lo:
            result.append((lo, hi))
        if a[i][1] <= b[j][1]:
            i += 1
        else:
            j += 1
    return result


def interval_map(context_data):
    """One explicit role/context at a time, including observation count checks."""
    series, coverage = sustained.build_job_series(context_data)
    observations = defaultdict(list)
    for index, row in enumerate(context_data.get("roots", [])):
        identity = (row.get("contextID"), row.get("jobID"), row.get("stage"), row.get("rootIndex"))
        observations[identity].append((row.get("observationSequence", index), index, row))
    intervals = defaultdict(list)
    invalid_ids = {tuple(x) for x in coverage["invalid_unique_root_ids"]}
    for identity, rows in observations.items():
        if identity[2] != 3 or identity in invalid_ids:
            continue
        valid = [row for _, _, row in sorted(rows, key=lambda x: (x[0], x[1])) if sustained.root_is_valid(row)]
        if valid:
            row = valid[-1]
            intervals[identity[:2]].append((D(row["gpuStartSeconds"]), D(row["gpuEndSeconds"])))
    valid_jobs = {(j["contextID"], j["jobID"]) for j in series if j["GPU_valid"]}
    return series, coverage, {k: merge_intervals(v) for k, v in intervals.items() if k in valid_jobs}


def phase_ledger(bounds, rows):
    """Always close tick accounting, including phases ending after nominal end."""
    if not bounds:
        return {"closed": False, "reason": "missing_phase"}
    planned = bounds["requestedSeconds"] * 24
    ticks = [sustained.integer(j.get("scheduledSlot")) for j in rows]
    before = [sustained.integer(j.get("missedSlotsBefore")) for j in rows]
    valid_ticks = bool(rows) and all(t is not None and 0 <= t < planned for t in ticks)
    gaps = [ticks[0]] + [b - a - 1 for a, b in zip(ticks, ticks[1:])] if valid_ticks else None
    expected_tail = int(planned) - ticks[-1] - 1 if valid_ticks else None
    checks = {
        "planned_integer": planned == int(planned),
        "reported_job_count": bounds["jobCount"] == len(rows),
        "strict_tick_order": valid_ticks and all(a < b for a, b in zip(ticks, ticks[1:])),
        "each_skip_matches_observed_tick_gap": gaps is not None and before == gaps,
        "skip_before_total": gaps is not None and bounds["skippedSlotsBeforeJobs"] == sum(gaps),
        "trailing_skip_count": expected_tail is not None and bounds["trailingMissedSlots"] == expected_tail,
        "planned_equals_jobs_and_missed": bounds["missedSlots"] is not None and planned == len(rows) + bounds["missedSlots"],
        "missed_equals_before_plus_tail": gaps is not None and expected_tail is not None and bounds["missedSlots"] == sum(gaps) + expected_tail,
        "targets_match_absolute_grid": valid_ticks and all(j.get("targetNs") == bounds["startNs"] + t * NS // 24 for j, t in zip(rows, ticks)),
    }
    return {"closed": all(checks.values()), "plannedTicks": int(planned), "realJobs": len(rows),
            "reportedMissedTicks": bounds["missedSlots"], "checks": checks,
            "scope": "Completed phase only; uncompleted schedules remain inconclusive, never closed by a residual."}


def real_performance(data, series):
    config = data.get("configuration", {})
    phases = {}
    for name in ("baseline", "measurement"):
        bounds = sustained.phase_bounds(data, name)
        jobs = [j for j in series if j["phase"] == name]
        bins, unplaced, outside = sustained.make_bins(data, series, name, bounds, MIN_REAL_PER_BIN)
        phases[name] = {"bounds": bounds, **sustained.job_profile(jobs), "bins": bins,
                        "completion": sustained.classify_phase_completion("A", bounds, jobs, config),
                        "ledger": phase_ledger(bounds, jobs), "unplacedJobIDs": unplaced,
                        "outsideObservedHorizonJobIDs": outside}
    prefix = phases["baseline"]
    formal = phases["measurement"]
    reference = prefix["GPU_union_ms"]["p50"] if prefix["GPU_union_ms"] else None
    median = formal["GPU_union_ms"]["p50"] if formal["GPU_union_ms"] else None
    prefix_wall = prefix["wall_ms"]["p50"] if prefix["wall_ms"] else None
    wall_p95 = formal["wall_ms"]["p95"] if formal["wall_ms"] else None
    ratio = median / reference if median is not None and reference else None
    spike = sustained.onset_analysis(formal["bins"], reference, D(2))
    low = [b["index"] for b in formal["bins"] if b["jobs"] < MIN_REAL_PER_BIN]
    invalid = [b["index"] for b in formal["bins"] if b["GPU_bin_status"] == "invalid"]
    first_gate = (False if low or spike["classification"] == "spike_observed" else
                  True if formal["bins"] and not invalid and spike["classification"] == "no_spike_observed" else None)
    return {"phases": phases, "prefixWallMedianGate": prefix_wall < sustained.PREFIX_WALL_EXCLUSIVE_MS if prefix_wall is not None else None,
            "ownPrefixGpuUnionMedianMs": reference, "formalGpuUnionMedianRatio": ratio,
            "formalWallP95Ms": wall_p95, "burst": spike,
            "lowSampleCompleteBins": low, "invalidCompleteBins": invalid,
            "gates": {"noGpuBurstAndAtLeast12RealJobsEveryCompleteCpuBin": first_gate,
                      "gpuUnionMedianRatioAtMost1_3": ratio <= REAL_GPU_RATIO_LIMIT if ratio is not None else None,
                      "realWallP95AtMost30_8ms": wall_p95 <= REAL_WALL_P95_LIMIT_MS if wall_p95 is not None else None},
            "lowSampleRule": "A known complete bin with <12 real jobs fails gate 1, but does not itself establish a GPU burst. Error/invalid/overflow/unclosed evidence takes precedence as inconclusive."}


def gpu_coverage(real_series, extra_series, real_intervals, extra_intervals):
    formal = [j for j in real_series if j["phase"] == "measurement"]
    base = {"isGate": False, "clock": "Metal GPU seconds only", "automaticTask": None}
    if not formal or any(not j["GPU_valid"] for j in formal):
        return {**base, "status": "unknown", "reason": "formal_real_GPU_coverage_invalid"}
    real = merge_intervals(v for j in formal for v in real_intervals.get((j["contextID"], j["jobID"]), []))
    if not real:
        return {**base, "status": "unknown", "reason": "no_real_GPU_anchor"}
    start, end = real[0][0], real[-1][1]
    extra_jobs = [j for j in extra_series if j["phase"] in ("baseline", "measurement")]
    missing = [j["jobID"] for j in extra_jobs if not j["GPU_valid"]]
    extra = intersect([v for j in extra_jobs for v in extra_intervals.get((j["contextID"], j["jobID"]), [])], [(start, end)])
    combined = merge_intervals(real + extra)
    overlap = intersect(real, extra)
    count = int(end - start)
    bins = []
    for i in range(count):
        window = [(start + i, start + i + 1)]
        bins.append({"index": i, "knownUnionFraction": duration(intersect(combined, window)),
                     "status": "unknown_missing_extra_GPU" if missing else "known"})
    return {**base, "status": "unknown_missing_extra_GPU" if missing else "known",
            "startGpuSeconds": start, "endGpuSeconds": end, "spanSeconds": end-start,
            "realUnionSeconds": duration(real), "knownExtraUnionSeconds": duration(extra),
            "knownCombinedUnionSeconds": duration(combined), "knownOverlapSeconds": duration(overlap),
            "knownCombinedFraction": duration(combined)/(end-start) if end > start else None,
            "coverageExactForRecordedIntervals": not missing,
            "invalidExtraJobIDs": missing, "completeGpuClockBins": count,
            "partialGpuTailSeconds": end-start-count, "bins": bins,
            "scope": "First formal real GPU start to last formal real GPU end; operational baseline/formal extra intervals clipped to this span. Warmup/setup excluded. Overlapping roots and roles are unioned once, not active-cycle utilization or CPU time."}


def overlap_review(real_jobs, real_series, real_intervals, extra_series, extra_intervals):
    extra_lookup = {j["jobID"]: j for j in extra_series}
    all_extra = merge_intervals(v for values in extra_intervals.values() for v in values)
    series_lookup = {j["jobID"]: j for j in real_series}
    rows = []
    for raw in real_jobs:
        if raw.get("phase") != "measurement":
            continue
        jid = raw.get("jobID")
        real = series_lookup[jid]
        intervals = real_intervals.get((real["contextID"], jid))
        predecessor = raw.get("lastExtraIDAtRealStart")
        prev = extra_lookup.get(predecessor)
        previous_intervals = extra_intervals.get((prev["contextID"], predecessor)) if prev else None
        overlap_ms = D(0) if predecessor == 0 else duration(intersect(intervals, previous_intervals))*1000 if intervals is not None and previous_intervals is not None else None
        rows.append({"realJobID": jid, "lastExtraIDAtRealStart": predecessor,
                     "extraStateObservationNs": raw.get("extraStateObservationNs"),
                     "extraInFlightAtRealStart": raw.get("extraInFlightAtRealStart"),
                     "referencedExtraPhase": prev["phase"] if prev else None,
                     "referencedExtraGpuOverlapMs": overlap_ms,
                     "anyExtraGpuOverlapMs": duration(intersect(intervals, all_extra))*1000 if intervals is not None else None,
                     "realLaunchLatenessMs": D(raw["wallStartNs"]-raw["targetNs"])/1_000_000 if sustained.integer(raw.get("wallStartNs")) is not None and sustained.integer(raw.get("targetNs")) is not None else None})
    return {"rows": rows, "referencedOverlapUnknown": sum(x["referencedExtraGpuOverlapMs"] is None for x in rows),
            "referencedOverlapPositive": sum(x["referencedExtraGpuOverlapMs"] is not None and x["referencedExtraGpuOverlapMs"] > 0 for x in rows),
            "allExtraOverlapPositive": sum(x["anyExtraGpuOverlapMs"] is not None and x["anyExtraGpuOverlapMs"] > 0 for x in rows),
            "referencedOverlapMs": sustained.distribution(x["referencedExtraGpuOverlapMs"] for x in rows if x["referencedExtraGpuOverlapMs"] is not None),
            "realLaunchLatenessMs": sustained.distribution(x["realLaunchLatenessMs"] for x in rows if x["realLaunchLatenessMs"] is not None),
            "scope": "GPU intersections within the shared explicit device's Metal GPU timestamp domain. CPU lateness is separate; overlap is observation, not proof that the extra job caused a slowdown."}


def frozen_threshold(extra_jobs, recorded):
    warm = [j for j in extra_jobs if j.get("phase") == "extra_warmup"]
    valid = [j for j in warm if sustained.integer(j.get("wallNs")) is not None
             and sustained.integer(j.get("wallStartNs")) is not None
             and sustained.integer(j.get("wallEndNs")) is not None
             and j["wallNs"] == j["wallEndNs"] - j["wallStartNs"] > 0
             and j.get("generated") is True and not j.get("error")]
    numerator = ceiling = exact = None
    issues = []
    if len(warm) != 20 or len(valid) != 20:
        issues.append("extra_warmup_not_20_successful_full_wall_intervals")
    else:
        wall = sorted(j["wallNs"] for j in valid)
        numerator = 19 * wall[18] + wall[19]
        exact = D(numerator) / 20
        ceiling = (numerator + 19) // 20
        if recorded.get("source") != "extra_warmup20_wall_type7_p95":
            issues.append("wrong_frozen_F_source")
        if recorded.get("numerator") != numerator or recorded.get("denominator") != 20:
            issues.append("frozen_F_rational_mismatch")
        if recorded.get("admissionNs") != ceiling:
            issues.append("frozen_F_integer_ceiling_mismatch")
    return {"valid": not issues, "warmupCount": len(warm), "validWarmupCount": len(valid),
            "recomputedNumerator": numerator, "denominator": 20, "exactNs": exact,
            "admissionNs": ceiling, "recorded": recorded, "issues": issues,
            "warmupJobIDs": [j.get("jobID") for j in warm],
            "wallMs": sustained.distribution(D(j["wallNs"])/1_000_000 for j in valid),
            "rule": "For exactly 20 integer wall samples, type-7 p95=(19*x[18]+x[19])/20; ceil is equivalent for integer remaining>=F+3ms. Frozen for both prefix and formal."}


def admissions_review(data, fill, F_ns):
    real = {j.get("jobID"): j for j in data.get("jobs", [])}
    extra = {j.get("requestID"): j for j in fill.get("extraJobs", []) if j.get("phase") != "extra_warmup"}
    offers = fill.get("admissions", [])
    worker = defaultdict(list)
    for row in fill.get("workerDecisions", []):
        worker[row.get("offerID")].append(row)
    issues, rows = [], []
    ids = [o.get("offerID") for o in offers]
    if len(ids) != len(set(ids)):
        issues.append("duplicate_offer_ids")
    request_ids = [j.get("requestID") for j in fill.get("extraJobs", []) if j.get("phase") != "extra_warmup"]
    if len(request_ids) != len(set(request_ids)):
        issues.append("multiple_extra_jobs_for_one_offer")
    for o in offers:
        oid = o.get("offerID")
        j = real.get(o.get("sourceRealJobID"))
        phase = data.get("phases", {}).get(o.get("phase"), {})
        next_tick = o.get("nextTickNs")
        stamp = o.get("offerDecisionNs")
        expected_next = (phase["startNs"] + (j["scheduledSlot"] + 1) * NS // 24
                         if j and sustained.integer(j.get("scheduledSlot")) is not None and "startNs" in phase else None)
        valid_times = all(sustained.integer(x) is not None for x in (next_tick, stamp, F_ns))
        eligible = next_tick - stamp >= F_ns + GUARD_NS if valid_times else None
        checks = {
            "source_real_job_found": j is not None,
            "phase_and_slot_match": bool(j) and j.get("phase") == o.get("phase") and j.get("scheduledSlot") == o.get("realSlot"),
            "next_tick_is_immediate_absolute_tick": expected_next is not None and next_tick == expected_next
                and o.get("nextTickSlot") == j["scheduledSlot"] + 1,
            "check_after_real_completion": bool(j) and sustained.integer(stamp) is not None and stamp >= j.get("wallEndNs", stamp+1),
            "remaining_matches_clamped_same_cpu_clock": valid_times and o.get("remainingNs") == max(0, next_tick - stamp),
            "frozen_F_and_guard_match": F_ns is not None and o.get("frozenFAdmissionNs") == F_ns and o.get("guardNs") == GUARD_NS,
            "time_eligibility_matches": eligible is not None and o.get("timeEligible") is eligible,
            "admitted_only_if_time_eligible_and_not_busy": not o.get("offerAdmitted") or (eligible is True and o.get("busy") is False),
            "no_new_offer_across_phase_boundary": not o.get("offerAdmitted") or
                (sustained.integer(phase.get("requestedEndNs")) is not None and sustained.integer(next_tick) is not None and next_tick < phase["requestedEndNs"]),
        }
        ws = worker.get(oid, [])
        ej = extra.get(oid)
        if o.get("offerAdmitted") is True:
            checks["one_worker_terminal_decision"] = len(ws) == 1
        else:
            checks["unadmitted_has_no_worker_or_extra_job"] = not ws and ej is None
        w = ws[0] if len(ws) == 1 else None
        if w:
            wt = sustained.integer(w.get("workerDecisionNs"))
            worker_eligible = next_tick - wt >= F_ns + GUARD_NS if valid_times and wt is not None else None
            checks["worker_clock_and_eligibility_match"] = (worker_eligible is not None and wt >= stamp
                and w.get("remainingNs") == max(0, next_tick-wt) and w.get("timeEligible") is worker_eligible)
            if w.get("extraJobID") not in (None, 0):
                checks["started_job_matches_worker_and_request"] = (ej is not None and ej.get("jobID") == w["extraJobID"]
                    and ej.get("phase") == o.get("phase") and worker_eligible is True
                    and sustained.integer(ej.get("wallStartNs")) is not None and ej["wallStartNs"] >= wt)
            else:
                checks["worker_no_start_has_no_job"] = ej is None
        issues.extend({"offerID": oid, "check": k} for k, ok in checks.items() if not ok)
        rows.append({"offerID": oid, "sourceRealJobID": o.get("sourceRealJobID"), "phase": o.get("phase"),
                     "realSlot": o.get("realSlot"), "timeEligible": eligible, "busy": o.get("busy"),
                     "offerAdmitted": o.get("offerAdmitted"), "reason": o.get("reason"),
                     "signedRemainingAtOfferNs": next_tick-stamp if valid_times else None,
                     "workerDisposition": w.get("disposition") if w else None,
                     "workerSignedRemainingNs": next_tick-w["workerDecisionNs"] if w and sustained.integer(next_tick) is not None and sustained.integer(w.get("workerDecisionNs")) is not None else None,
                     "actualExtraJobID": ej.get("jobID") if ej else None,
                     "postRealToOfferCheckMs": D(stamp-j["wallEndNs"])/1_000_000 if j and sustained.integer(stamp) is not None else None,
                     "offerToExtraStartMs": D(ej["wallStartNs"]-stamp)/1_000_000 if ej and sustained.integer(stamp) is not None else None,
                     "extraEndedAfterNextTickMinusGuard": ej["wallEndNs"] > next_tick-GUARD_NS if ej and sustained.integer(next_tick) is not None else None,
                     "extraEndedAfterNextTick": ej["wallEndNs"] > next_tick if ej and sustained.integer(next_tick) is not None else None,
                     "checks": checks})
    if set(worker) - set(ids):
        issues.append("worker_decision_without_offer")
    if set(extra) - set(ids):
        issues.append("extra_job_without_offer")
    source_ids = [o.get("sourceRealJobID") for o in offers]
    if len(source_ids) != len(set(source_ids)):
        issues.append("multiple_offers_after_same_real_job")
    expected_sources = {j["jobID"] for j in real.values() if j.get("phase") in ("baseline", "measurement") and j.get("generated") is True}
    if set(source_ids) != expected_sources:
        issues.append("each_completed_real_tick_must_have_one_offer_decision")
    phase_counts = {}
    for name in ("baseline", "measurement"):
        phase = data.get("phases", {}).get(name, {})
        seconds = sustained.number(phase.get("requestedSeconds"))
        planned = int(seconds * 24) if seconds is not None and seconds * 24 == int(seconds * 24) else None
        subset = [r for r in rows if r["phase"] == name]
        eligible = sum(r["timeEligible"] is True for r in subset)
        started = sum(r["actualExtraJobID"] is not None for r in subset)
        phase_counts[name] = {"allPlannedTicksDenominator": planned, "realJobs": sum(j.get("phase")==name for j in real.values()),
                             "recordedOfferDecisions": len(subset), "timeEligibleTicks": eligible,
                             "actualExtraExecutionTicks": started,
                             "timeEligibleFractionAllPlanned": D(eligible)/planned if planned else None,
                             "actualExtraFractionAllPlanned": D(started)/planned if planned else None,
                             "eligibleButBusy": sum(r["timeEligible"] is True and r["busy"] is True for r in subset),
                             "timeEligibleAndNotBusyWithinPhase": sum(r["timeEligible"] is True and r["busy"] is False and r["reason"] != "phase_end" for r in subset),
                             "admittedOffers": sum(r["offerAdmitted"] is True for r in subset),
                             "workerDispositionCounts": dict(Counter(str(r["workerDisposition"]) for r in subset if r["offerAdmitted"] is True))}
    return {"closed": not issues, "issues": issues, "phases": phase_counts, "rows": rows,
            "isGate": False, "coverageThreshold": None,
            "scope": "Temporal eligibility at real-completion offer and worker-start recheck are distinct. Actual extra job start is joined by offerID/requestID. Both ratios retain all planned ticks, including skipped real ticks. There is no 90% filler gate or scheduling-bug inference."}


def identity_review(data, fill):
    real = data.get("modelIdentity") or {}
    observed = (fill.get("fillerModelIdentityObserved") or {}).get("values", {})
    validated = fill.get("fillerModelIdentityValidated") or {}
    checks = {
        "real_original_five_stage": real.get("sha256") == REAL_SHA and real.get("stageCount") == 5
            and real.get("tensorCount") == 158 and real.get("overrideApplied") is False,
        "extra_observed_four_stage": observed.get("sha256") == EXTRA_SHA and observed.get("stageCount") == 4
            and observed.get("tensorCount") == 128 and observed.get("containerVersion") == 2 and observed.get("overrideApplied") is False,
        "extra_validated_four_stage": validated.get("sha256") == EXTRA_SHA and validated.get("stageCount") == 4
            and validated.get("tensorCount") == 128 and validated.get("containerVersion") == 2 and validated.get("overrideApplied") is False,
        "same_explicit_device": data.get("deviceRegistryID") is not None and data.get("deviceRegistryID") == fill.get("deviceRegistryID"),
    }
    return {"checks": checks, "allKnownMatched": all(checks.values()), "real": real,
            "extraObserved": fill.get("fillerModelIdentityObserved"), "extraValidated": validated,
            "realDeviceRegistryID": data.get("deviceRegistryID"), "extraDeviceRegistryID": fill.get("deviceRegistryID"),
            "extraInterpolatorInstance": fill.get("interpolatorInstance")}


def recording_review(data, fill, real_series, extra_series, real_coverage, extra_coverage):
    problems = []
    for role, ctx, jobs, roots in (("real", 1, data.get("jobs", []), data.get("roots", [])),
                                  ("extra", 2, fill.get("extraJobs", []), fill.get("extraRoots", []))):
        if any(r.get("role") != role or r.get("contextID") != ctx for r in jobs + roots):
            problems.append(role + "_role_or_context_namespace_mismatch")
        owner = data if role == "real" else fill
        if owner.get("rootObservationsDropped") != 0 or owner.get("traceOverflowTotal") != 0:
            problems.append(role + "_missing_or_nonzero_overflow_counters")
        if owner.get("rootObservationsAttempted") != len(roots):
            problems.append(role + "_root_observation_accounting_mismatch")
        if any(j.get("error") for j in jobs):
            problems.append(role + "_job_error")
    if data.get("jobLimitReached") is not False or fill.get("overflow") is not False:
        problems.append("capacity_overflow_or_unknown")
    if fill.get("firstFailure"):
        problems.append("extra_first_failure")
    for role, coverage, series in (("real", real_coverage, real_series), ("extra", extra_coverage, extra_series)):
        if coverage["duplicate_job_ids"] or coverage["invalid_unique_root_ids"]:
            problems.append(role + "_duplicate_job_or_invalid_root")
        if any(not j["GPU_valid"] for j in series):
            problems.append(role + "_invalid_job_GPU_or_wall_evidence")
        intervals = sorted((j["wallStartNs"], j["wallEndNs"]) for j in series
                           if j["wallStartNs"] is not None and j["wallEndNs"] is not None)
        if any(a[1] > b[0] for a, b in zip(intervals, intervals[1:])):
            problems.append(role + "_overlapping_CPU_pushes_violate_single_inflight")
    rw = [j for j in real_series if j["phase"] == "warmup"]
    ew = [j for j in extra_series if j["phase"] == "extra_warmup"]
    prefix = [j for j in real_series if j["phase"] == "baseline"]
    if len(rw) != 20 or len(ew) != 20:
        problems.append("warm20_counts_incomplete")
    elif (any(j["wallStartNs"] is None or j["wallEndNs"] is None for j in rw+ew)
          or max(j["wallEndNs"] for j in rw) > min(j["wallStartNs"] for j in ew)):
        problems.append("warm_real20_then_extra20_order_not_verified")
    if prefix and ew and all(j["wallStartNs"] is not None and j["wallEndNs"] is not None for j in prefix+ew):
        if max(j["wallEndNs"] for j in ew) > min(j["wallStartNs"] for j in prefix):
            problems.append("prefix_started_before_extra_warmup_completed")
    return {"valid": not problems, "problems": problems,
            "realCoverage": real_coverage, "extraCoverage": extra_coverage,
            "roleJobCounts": {"real": dict(Counter(j["phase"] for j in real_series)),
                              "extra": dict(Counter(j["phase"] for j in extra_series))},
            "drainStartNs": fill.get("drainStartNs"), "drainEndNs": fill.get("drainEndNs"),
            "activeOfferIDAtDrain": fill.get("activeOfferIDAtDrain"),
            "scope": "Role/context namespaces are separated before root union and copied-observation accounting. Final drain is retained outside real phase durations; prefix/formal statistics do not inherit it."}


def classify(data, performance, evidence_problems, setup_failed=False):
    if setup_failed or data.get("status") == "setup_failed":
        return "setup_failed", "explicit_setup_identity_or_output_validation_failure"
    if evidence_problems:
        return "inconclusive", "error_invalid_overflow_or_unclosed_evidence"
    if data.get("status") == "baseline_not_ready" and performance["prefixWallMedianGate"] is False:
        return "baseline_not_ready", "prefix_wall_p50_not_strictly_below_36_264667ms_no_formal_result"
    if data.get("status") != "complete" or data.get("functionalComplete") is not True:
        return "inconclusive", "formal_run_not_complete"
    if performance["prefixWallMedianGate"] is not True:
        return "inconclusive", "formal_run_without_valid_prefix_gate"
    gates = performance["gates"]
    if any(v is False for v in gates.values()):
        return "fail", "at_least_one_frozen_real_performance_condition_failed"
    if any(v is None for v in gates.values()):
        return "inconclusive", "required_performance_evidence_unknown"
    return "pass", "all_three_real_performance_conditions_passed_filler_ratio_not_a_gate"


def output_review(fill):
    warm = [j for j in fill.get("extraJobs", []) if j.get("phase") == "extra_warmup"]
    output = fill.get("outputValidation") or {}
    variance = sustained.number(output.get("sampleLuminanceVariance"))
    digest = output.get("outputSHA256")
    checks = {
        "all_twenty_warm_deliveries_valid": len(warm) == 20 and all(j.get("generated") is True and j.get("warmOutputRepresentationValid") is True for j in warm),
        "last_BGRA8_representation": output.get("representationValid") is True and output.get("width") == 1814
            and output.get("height") == 1142 and output.get("pixelFormat") == int.from_bytes(b"BGRA", "big")
            and output.get("iosurfaceBacked") is True and sustained.integer(output.get("bytesPerRow")) is not None
            and output["bytesPerRow"] >= 1814 * 4,
        "last_visible_pixel_hash_recorded": isinstance(digest, str) and len(digest) == 64 and all(c in "0123456789abcdef" for c in digest.lower()),
        "fixed_64x64_sample_positive_variance": output.get("sampleCount") == 4096 and variance is not None
            and variance > 0 and output.get("sampleVariancePositive") is True,
        "internal_float_not_claimed_observed": output.get("internalFloatTensorsObserved") is False,
    }
    return {"checks": checks, "passed": all(checks.values()), "recorded": output,
            "warmOutputValidationCount": sum(j.get("warmOutputRepresentationValid") is True for j in warm),
            "scope": "Frozen clarification accepts BGRA8 delivery and positive sampled luma variance. Internal FP16 tensors are unobserved; no tensor-finite or quality inference is made."}


def analyze(data, source):
    if data.get("format") != sustained.FORMAT:
        raise ValueError("Unsupported native format")
    fill = data.get("realWorkFill")
    if not isinstance(fill, dict) or fill.get("enabled") is not True:
        raise ValueError("Missing enabled realWorkFill report")
    extra_data = {"contextID": 2, "jobs": fill.get("extraJobs", []), "roots": fill.get("extraRoots", []),
                  **{k: fill.get(k) for k in ("rootObservationsAttempted", "rootObservationsDropped", "traceOverflowTotal")}}
    real_series, real_cov, real_intervals = interval_map(data)
    extra_series, extra_cov, extra_intervals = interval_map(extra_data)
    performance = real_performance(data, real_series)
    identities = identity_review(data, fill)
    output = output_review(fill)
    threshold = frozen_threshold(fill.get("extraJobs", []), fill.get("frozenF") or {})
    admissions = admissions_review(data, fill, threshold["admissionNs"])
    recording = recording_review(data, fill, real_series, extra_series, real_cov, extra_cov)
    problems = list(recording["problems"])
    if not identities["allKnownMatched"]:
        problems.append("required_model_or_device_identity_not_verified")
    if not output["passed"]:
        problems.append("required_BGRA8_delivery_check_not_verified")
    if not threshold["valid"]:
        problems.append("frozen_F_not_verified")
    if not admissions["closed"]:
        problems.append("admission_worker_job_ledger_not_closed")
    config = data.get("configuration", {})
    if (config.get("mode") != "paced24" or config.get("targetHz") != 24 or config.get("seconds") != 180
            or config.get("baselineSeconds") != 5):
        problems.append("real_schedule_configuration_not_frozen_contract")
    active_phases = ["baseline"] + (["measurement"] if data.get("formalStarted") is True or data.get("status") == "complete" else [])
    for name in active_phases:
        phase = performance["phases"][name]
        if not phase["ledger"]["closed"]:
            problems.append(name + "_tick_ledger_not_closed")
        if phase["completion"]["status"] == "incomplete_or_unverified":
            problems.append(name + "_phase_incomplete")
        if phase["unplacedJobIDs"] or phase["outsideObservedHorizonJobIDs"]:
            problems.append(name + "_job_start_outside_observed_phase")
    if (data.get("baselineGate") or {}).get("passed") is not performance["prefixWallMedianGate"]:
        problems.append("native_and_recomputed_prefix_gate_disagree")
    classification, reason = classify(data, performance, problems)
    coverage = (gpu_coverage(real_series, extra_series, real_intervals, extra_intervals)
                if identities["checks"]["same_explicit_device"] else
                {"status": "unknown", "isGate": False, "reason": "shared_explicit_device_not_verified"})
    overlap = (overlap_review(data.get("jobs", []), real_series, real_intervals, extra_series, extra_intervals)
               if identities["checks"]["same_explicit_device"] else {"status": "unknown_device"})
    return {"format": "odf-air-real-work-fill-review-v1", "source": source,
            "classification": classification, "classificationReason": reason,
            "nativeStatus": data.get("status"), "nativeFirstFailure": data.get("firstFailure"),
            "nativeFailureKind": data.get("failureKind"), "extraFirstFailure": fill.get("firstFailure"),
            "setupSucceeded": data.get("setupSucceeded"),
            "functionalComplete": data.get("functionalComplete"), "formalStarted": data.get("formalStarted"),
            "contract": {"fillerModelSHA256": EXTRA_SHA, "realModelSHA256": REAL_SHA,
                         "frozenThresholdSource": "same-process extra warm20 type-7 p95, ceil ns; rebuilt only in each separately authorized fresh prefix process",
                         "prefixWallMedianStrictLimitMs": sustained.PREFIX_WALL_EXCLUSIVE_MS,
                         "formalSeconds": 180, "realCpuBinWidthSeconds": 1, "minimumRealJobsPerFullBin": 12,
                         "burst": "5 consecutive valid complete CPU-start bins with median real GPU union >=2x own prefix median",
                         "realGpuMedianRatioInclusiveLimit": REAL_GPU_RATIO_LIMIT,
                         "realWallP95InclusiveLimitMs": REAL_WALL_P95_LIMIT_MS,
                         "fillerCoverageGate": None, "energyMeasured": False,
                         "priority": "error, invalid, overflow or unclosed ledger -> inconclusive; otherwise failure of any real performance condition -> fail"},
            "identities": identities, "outputValidation": output, "frozenF": threshold,
            "recording": recording, "realPerformance": performance,
            "extraProfiles": {p: sustained.job_profile([j for j in extra_series if j["phase"]==p])
                              for p in sorted({j["phase"] for j in extra_series})},
            "admissions": admissions, "combinedGpuCoverage": coverage, "overlap": overlap,
            "thermalSamples": data.get("thermalSamples", []), "hostClock": data.get("hostClock"),
            "evidenceProblems": problems, "realJobSeries": real_series, "extraJobSeries": extra_series,
            "limits": ["No CPU-minus-GPU absolute subtraction, kernel clock, active-cycle, frequency or energy inference.",
                       "Filler proportions are descriptive; the withdrawn 90% condition is not applied. Low filler use does not turn a real-performance pass into failure or prove a scheduler bug.",
                       "There is no numerical threshold here proving B-like load shape; observations alone do not establish why real costs changed.",
                       "No new experiment, App run or repeat is started by this analyzer. Prior attempts and first failures remain separate."]}


def json_default(value):
    if isinstance(value, D):
        return float(value)
    raise TypeError(type(value).__name__)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--environment", type=Path, help="Existing coordinator-state.json; records provenance and observed local attempts")
    args = parser.parse_args()
    data, source = sustained.read_json(args.input)
    try:
        report = analyze(data, source)
    except (KeyError, ValueError, TypeError, ArithmeticError) as error:
        report = {"format": "odf-air-real-work-fill-review-v1", "source": source,
                  "classification": "setup_failed" if data.get("status") == "setup_failed" else "inconclusive",
                  "classificationReason": "explicit_native_setup_failure_partial_report" if data.get("status") == "setup_failed" else "input_or_schema_error",
                  "firstAnalysisFailure": str(error), "nativeStatus": data.get("status"),
                  "nativeFirstFailure": data.get("firstFailure"), "automaticTask": None}
    report["analyzerSHA256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    report["reusedSustainedAnalyzerSHA256"] = hashlib.sha256(Path(sustained.__file__).read_bytes()).hexdigest()
    if args.environment:
        env, receipt = sustained.read_json(args.environment)
        report["environment"] = {"source": receipt,
                                 **{k: env.get(k) for k in ("status", "preferences_unchanged", "started_utc", "completed_utc", "attempts")}}
        observed_attempts = []
        for path in sorted(args.environment.parent.glob("attempt-*/native.json")):
            attempt, r = sustained.read_json(path)
            observed_attempts.append({"directory": path.parent.name, "source": r, "status": attempt.get("status"),
                                      "formalStarted": attempt.get("formalStarted"), "firstFailure": attempt.get("firstFailure"),
                                      "frozenF": (attempt.get("realWorkFill") or {}).get("frozenF"),
                                      "baselineGate": attempt.get("baselineGate")})
        report["observedLocalAttemptThresholds"] = observed_attempts
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, default=json_default, ensure_ascii=False, indent=2)+"\n")
    print(json.dumps({"classification": report["classification"], "reason": report["classificationReason"],
                      "gates": report.get("realPerformance", {}).get("gates"),
                      "frozenF": report.get("frozenF", {}).get("admissionNs"), "output": str(args.output)}, default=json_default))


if __name__ == "__main__":
    main()
