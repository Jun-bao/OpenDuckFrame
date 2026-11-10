#!/usr/bin/env python3
"""CPU-only analysis of one existing gap-fill diagnostic run.

Usage:
  python3 -B analyze_gap_fill.py --input native.json \
    --environment coordinator-state.json --output review.json

Imports the unchanged real-job analyzer. Never launches native/GPU work, retunes
fill parameters, or starts the conditionally proposed 600-second follow-up.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from collections import Counter, defaultdict
from decimal import Decimal as D
from pathlib import Path

import analyze as real_analysis

NS = D(1_000_000_000)
COVERAGE_TARGET = D("0.85")
PASSING_BIN_TARGET = D("0.95")
MAX_UNKNOWN_FRACTION = D("0.05")
GPU_MEDIAN_RATIO_LIMIT = D("1.3")
GUARD_NS = 3_000_000
VALIDATION_MIN_MS = D("0.5")
VALIDATION_MAX_MS = D("2.0")
OPERATIONAL_PHASES = {"baseline", "measurement"}
CALIBRATION_PHASES = {"calibration_pilot", "calibration_validation"}


def merge_intervals(intervals):
    merged = []
    for start, end in sorted((a, b) for a, b in intervals):
        if end < start:
            raise ValueError("Reversed GPU interval")
        if not merged or start > merged[-1][1]:
            merged.append([start, end])
        else:
            merged[-1][1] = max(merged[-1][1], end)
    return merged


def intersection_length(intervals, start, end):
    return sum((max(D(0), min(b, end) - max(a, start)) for a, b in intervals), D(0))


def fill_valid(record):
    start = real_analysis.number(record.get("gpuStartSeconds"))
    end = real_analysis.number(record.get("gpuEndSeconds"))
    begin = real_analysis.integer(record.get("commitBeginNs"))
    finish = real_analysis.integer(record.get("commitEndNs"))
    mask = real_analysis.integer(record.get("validityMask"))
    return (record.get("status") == 4 and mask is not None and mask & 7 == 7
            and start is not None and end is not None and 0 < start <= end
            and begin is not None and finish is not None and 0 < begin <= finish)


def collect_fills(gap):
    raw = gap.get("calibration", {}).get("records", []) + gap.get("fills", [])
    grouped, malformed = defaultdict(list), []
    for index, record in enumerate(raw):
        fill_id = real_analysis.integer(record.get("fillID"))
        if fill_id is None or fill_id <= 0:
            malformed.append(index)
        else:
            grouped[fill_id].append(record)
    entries = {}
    for fill_id, copies in grouped.items():
        valid = [r for r in copies if fill_valid(r)]
        fingerprints = {(r.get("phase"), r.get("iterations"), r.get("commitBeginNs"),
                         r.get("commitEndNs"), r.get("plannedNextTickNs"), r.get("guardNs"),
                         real_analysis.number(r.get("gpuStartSeconds")),
                         real_analysis.number(r.get("gpuEndSeconds"))) for r in valid}
        chosen = valid[-1] if valid else copies[-1]
        issues = []
        if not valid:
            issues.append("invalid_or_missing_GPU_commit_status")
        if len(fingerprints) > 1:
            issues.append("conflicting_complete_observations")
        if chosen.get("phase") not in OPERATIONAL_PHASES | CALIBRATION_PHASES:
            issues.append("unknown_phase")
        ok = not issues
        entries[fill_id] = {"fillID": fill_id, "record": chosen, "valid": ok,
                            "issues": issues, "copies": len(copies),
                            "interval": (D(chosen["gpuStartSeconds"]) * NS,
                                         D(chosen["gpuEndSeconds"]) * NS) if ok else None}
    attempted = real_analysis.integer(gap.get("recordsAttempted"))
    dropped = real_analysis.integer(gap.get("recordsDropped"))
    accounting = {"recordsAttempted": attempted, "recordsDropped": dropped,
                  "overflow": gap.get("overflow"), "raw_record_rows": len(raw),
                  "unique_committed_fillIDs": len(entries), "malformed_row_indices": malformed,
                  "duplicate_observation_rows": sum(len(v) - 1 for v in grouped.values()),
                  "invalid_fillIDs": [k for k, v in entries.items() if not v["valid"]],
                  "count_closed": attempted is not None and dropped is not None
                                  and attempted == len(entries) + dropped,
                  "count_scope": "Pilot + validation + operational committed CBs; guard-rejected noncommits are separate"}
    return entries, accounting


def calibration_review(gap, entries):
    c = gap.get("calibration", {})
    groups = {phase: [x for x in entries.values() if x["record"].get("phase") == phase]
              for phase in CALIBRATION_PHASES}
    pilot = groups["calibration_pilot"]
    validation = groups["calibration_validation"]
    durations = lambda rows: [(x["interval"][1] - x["interval"][0]) / D(1_000_000)
                              for x in rows if x["valid"]]
    pstats = real_analysis.distribution(durations(pilot))
    vstats = real_analysis.distribution(durations(validation))
    initial = real_analysis.integer(c.get("initialIterations"))
    scaled = real_analysis.integer(c.get("scaledIterations"))
    reported_pilot = real_analysis.number(c.get("pilotMedianMs"))
    expected_scaled = None
    if initial is not None and initial > 0 and reported_pilot is not None and reported_pilot > 0:
        # Replicate the recorded Swift Double expression and positive ties-away rounding.
        ratio = float(initial) / float(reported_pilot)
        if math.isfinite(ratio):
            expected_scaled = math.floor(ratio + 0.5)
    checks = {"pilot_exactly5_valid": len(pilot) == 5 and all(x["valid"] for x in pilot),
              "validation_exactly5_valid": len(validation) == 5 and all(x["valid"] for x in validation),
              "only10_calibration_commits": len(pilot) + len(validation) == 10,
              "target_is_1ms": real_analysis.number(c.get("targetMilliseconds")) == 1,
              "pilot_fixed_initial_iterations": initial is not None and initial > 0
                  and all(x["record"].get("iterations") == initial for x in pilot),
              "one_proportional_integer_conversion": expected_scaled is not None
                  and scaled == expected_scaled and 1 <= scaled <= 4_294_967_295,
              "validation_fixed_scaled_iterations": scaled is not None
                  and all(x["record"].get("iterations") == scaled for x in validation),
              "validation_GPU_median_in_inclusive_range": bool(vstats)
                  and VALIDATION_MIN_MS <= vstats["p50"] <= VALIDATION_MAX_MS,
              "native_passed": c.get("passed") is True}
    return {"passed": all(checks.values()), "checks": checks, "native_status": c.get("status"),
            "native_firstFailure": c.get("firstFailure"), "initialIterations": initial,
            "scaledIterations": scaled, "expected_scaled_from_recorded_pilot": expected_scaled,
            "recorded_iteration_conversion": c.get("iterationConversion"),
            "pilot_GPU_duration_ms": pstats, "validation_GPU_duration_ms": vstats,
            "native_pilotMedianMs": c.get("pilotMedianMs"),
            "native_validationMedianMs": c.get("validationMedianMs"),
            "records": [{"fillID": x["fillID"], "phase": x["record"].get("phase"),
                         "iterations": x["record"].get("iterations"), "valid": x["valid"],
                         "GPU_duration_ms": (x["interval"][1] - x["interval"][0]) / D(1_000_000) if x["valid"] else None,
                         "native_durationMs": x["record"].get("durationMs"), "issues": x["issues"]}
                        for x in sorted(pilot + validation, key=lambda x: x["fillID"])],
            "scope": "All 10 calibration CBs retained separately; none contributes to prefix/measurement coverage or real-job medians"}


def real_intervals(data, real):
    context = data.get("contextID", 1)
    candidates = defaultdict(list)
    for index, root in enumerate(data.get("roots", [])):
        if root.get("stage") != 3:
            continue
        key = (root.get("contextID", context), root.get("jobID"), root.get("stage"), root.get("rootIndex"))
        if real_analysis.root_is_valid(root):
            candidates[key].append((root.get("observationSequence", index), index, root))
    invalid = {tuple(k) for k in real["coverage"]["invalid_unique_root_ids"]}
    by_job = defaultdict(list)
    for key, copies in candidates.items():
        if key in invalid:
            continue
        root = max(copies, key=lambda item: (item[0], item[1]))[2]
        by_job[key[:2]].append((D(root["gpuStartSeconds"]) * NS, D(root["gpuEndSeconds"]) * NS))
    return {k: merge_intervals(v) for k, v in by_job.items()}


def uncertain_spans(sequence, start, end):
    """Use same-stream causal ordering, never CPU-to-GPU absolute subtraction."""
    known = [x for x in sequence if x["valid"] and x["interval"] is not None]
    violations = [(a["id"], b["id"]) for a, b in zip(known, known[1:])
                  if a["interval"][1] > b["interval"][0]]
    bad = [i for i, x in enumerate(sequence) if not x["valid"] and x.get("may_affect", True)]
    if bad and violations:
        return [{"start": start, "end": end, "reason": "stream_order_does_not_bound_missing_intervals"}], violations
    # One pass in each direction avoids quadratic scans when timing is widely unavailable.
    previous_at, following_at = [], [None] * len(sequence)
    previous = following = None
    for x in sequence:
        previous_at.append(previous)
        if x["valid"]:
            previous = x
    for i in range(len(sequence) - 1, -1, -1):
        following_at[i] = following
        if sequence[i]["valid"]:
            following = sequence[i]
    spans = []
    for i in bad:
        previous, following = previous_at[i], following_at[i]
        lower = previous["interval"][1] if previous else start
        upper = following["interval"][0] if following else end
        if upper >= start and lower <= end:
            spans.append({"start": max(start, lower), "end": min(end, upper),
                          "id": sequence[i]["id"], "reason": "missing_or_invalid_GPU_interval",
                          "previous_valid_id": previous["id"] if previous else None,
                          "next_valid_id": following["id"] if following else None})
    return spans, violations


def add_lengths_to_bins(intervals, anchor, count):
    values = [D(0)] * count
    full_end = anchor + count * NS
    for a, b in merge_intervals(intervals):
        a, b = max(a, anchor), min(b, full_end)
        if b <= a:
            continue
        first = max(0, int((a - anchor) // NS))
        last = min(count - 1, int((b - anchor) // NS))
        for index in range(first, last + 1):
            values[index] += max(D(0), min(b, anchor + (index + 1) * NS) - max(a, anchor + index * NS))
    return values


def coverage_review(data, real, by_job, fills, accounting):
    formal = [j for j in real["job_series"] if j["phase"] == "measurement"]
    result = {"status": "inconclusive", "passed": False,
              "scope": "GPU-clock bins, distinct from the CPU-formal bins used for the real-job burst criterion"}
    if not formal:
        return {**result, "reason": "No formal real jobs"}
    keys = [(j["contextID"], j["jobID"]) for j in formal]
    if (not formal[0]["GPU_valid"] or not formal[-1]["GPU_valid"]
            or not by_job.get(keys[0]) or not by_job.get(keys[-1])):
        return {**result, "reason": "First/last formal real GPU anchor unavailable; no replacement anchor selected"}
    anchor = by_job[keys[0]][0][0]
    last_end = by_job[keys[-1]][-1][1]
    if last_end <= anchor:
        return {**result, "reason": "GPU anchor order invalid"}
    count = int((last_end - anchor) // NS)
    if count <= 0:
        return {**result, "reason": "No complete GPU-clock second"}
    real_valid_intervals = [iv for key in keys for iv in by_job.get(key, [])]
    operational = [x for x in fills.values() if x["record"].get("phase") in OPERATIONAL_PHASES]
    fill_valid_intervals = [x["interval"] for x in operational if x["valid"]]
    real_sequence = []
    for job, key in zip(formal, keys):
        iv = by_job.get(key)
        real_sequence.append({"id": job["jobID"], "valid": job["GPU_valid"] and bool(iv),
                              "interval": (iv[0][0], iv[-1][1]) if job["GPU_valid"] and iv else None})
    fill_sequence = [{"id": x["fillID"], "valid": x["valid"], "interval": x["interval"],
                      "may_affect": x["record"].get("phase") not in CALIBRATION_PHASES}
                     for x in sorted(fills.values(), key=lambda x: x["fillID"])]
    real_unknown, real_order = uncertain_spans(real_sequence, anchor, last_end)
    fill_unknown, fill_order = uncertain_spans(fill_sequence, anchor, last_end)
    global_unknown = []
    if (accounting["recordsDropped"] != 0 or accounting["overflow"] is not False
            or not accounting["count_closed"] or accounting["malformed_row_indices"]):
        global_unknown.append("fill_record_loss_or_accounting_unresolved")
    if data.get("rootObservationsDropped") != 0 or data.get("traceOverflowTotal") != 0:
        global_unknown.append("real_root_record_loss_or_overflow")
    if not real_analysis.integer(data.get("deviceRegistryID")) or data.get("deviceRegistryID") != data.get("gapFill", {}).get("deviceRegistryID"):
        global_unknown.append("shared_Metal_device_unverified")
    unknown_spans = real_unknown + fill_unknown
    if global_unknown:
        unknown_spans.append({"start": anchor, "end": last_end, "reason": global_unknown})
    unknown_bins = set()
    for span in unknown_spans:
        a, b = max(span["start"], anchor), min(span["end"], anchor + count * NS)
        if b < a:
            continue
        lower = max(0, int((a - anchor) // NS))
        upper = min(count - 1, int((b - anchor) // NS))
        unknown_bins.update(range(lower, upper + 1))
    combined = merge_intervals(real_valid_intervals + fill_valid_intervals)
    covered = add_lengths_to_bins(combined, anchor, count)
    real_covered = add_lengths_to_bins(real_valid_intervals, anchor, count)
    fill_covered = add_lengths_to_bins(fill_valid_intervals, anchor, count)
    bins, passed = [], 0
    for index in range(count):
        q = covered[index] / NS
        if not 0 <= q <= 1:
            raise ValueError("GPU union length outside its clipped bin")
        status = "unknown_not_met" if index in unknown_bins else "pass" if q >= COVERAGE_TARGET else "below_target"
        passed += status == "pass"
        bins.append({"GPU_bin_index": index, "start_gpu_seconds": (anchor + index * NS) / NS,
                     "end_gpu_seconds": (anchor + (index + 1) * NS) / NS,
                     "known_union_coverage": q, "status": status,
                     "known_real_union_ms": real_covered[index] / D(1_000_000),
                     "known_fill_union_ms": fill_covered[index] / D(1_000_000),
                     "known_union_ms": covered[index] / D(1_000_000),
                     "coverage_margin_to_85percent_ms": (covered[index] - NS * COVERAGE_TARGET) / D(1_000_000)})
    unknown_fraction = D(len(unknown_bins)) / count
    passing_fraction = D(passed) / count
    gate = unknown_fraction <= MAX_UNKNOWN_FRACTION and passing_fraction >= PASSING_BIN_TARGET
    return {**result, "status": "satisfied" if gate else "inconclusive", "passed": gate,
            "first_formal_real_jobID": formal[0]["jobID"], "last_formal_real_jobID": formal[-1]["jobID"],
            "anchor_GPU_seconds": anchor / NS, "last_formal_real_GPU_end_seconds": last_end / NS,
            "GPU_span_seconds": (last_end - anchor) / NS, "full_GPU_second_bins": count,
            "partial_GPU_tail_seconds": (last_end - anchor - count * NS) / NS,
            "partial_GPU_tail_known_union_ms": intersection_length(combined, anchor + count * NS, last_end) / D(1_000_000),
            "CPU_to_GPU_head_tail_alignment": "unknown; CPU/GPU origins not subtracted",
            "passing_bins": passed, "passing_fraction": passing_fraction,
            "unknown_bins": len(unknown_bins), "unknown_fraction": unknown_fraction,
            "known_below_target_bins": count - passed - len(unknown_bins),
            "minimum_passing_bins": (95 * count + 99) // 100,
            "maximum_unknown_bins": (5 * count) // 100,
            "aggregate_known_coverage_over_full_bins": sum(covered, D(0)) / (count * NS),
            "aggregate_is_not_the_gate": True, "GPU_second_bins": bins,
            "uncertain_GPU_spans_ns": unknown_spans, "global_unknown_reasons": global_unknown,
            "fill_single_inflight_order_violations": fill_order,
            "real_serial_push_order_violations": real_order,
            "invalid_localization": "Only adjacent valid GPU intervals in the same single-inflight fill stream or serial synchronous real-job sequence bound missing timing. No CPU-to-GPU epoch subtraction. Unlocatable loss marks all potentially affected bins unknown.",
            "phase_rule": "Operational baseline/measurement fills may contribute only where their physical GPU intervals intersect the formal real GPU span. Calibration never contributes. Partial bins excluded; unknown full bins remain in the denominator and cannot pass."}


def guard_review(fills):
    rows, counts = [], Counter()
    for x in sorted(fills.values(), key=lambda x: x["fillID"]):
        r = x["record"]
        if r.get("phase") not in OPERATIONAL_PHASES:
            continue
        begin, end, tick, native_guard = (real_analysis.integer(r.get(k)) for k in
                                         ("commitBeginNs", "commitEndNs", "plannedNextTickNs", "guardNs"))
        boundary = tick - GUARD_NS if tick is not None else None
        if begin is None or end is None or boundary is None or begin > end or native_guard != boundary:
            status = "invalid_or_missing"
        elif begin >= boundary:
            status = "after_violation"
        elif end > boundary:
            status = "crossed_unknown"
        else:
            status = "before"
        counts[status] += 1
        rows.append({"fillID": x["fillID"], "phase": r.get("phase"), "classification": status,
                     "native_guardBoundary": r.get("guardBoundary"),
                     "commit_begin_minus_boundary_ms": D(begin - boundary) / D(1_000_000) if begin is not None and boundary is not None else None,
                     "commit_end_minus_boundary_ms": D(end - boundary) / D(1_000_000) if end is not None and boundary is not None else None,
                     "native_classification_matches": status == r.get("guardBoundary")})
    return {"counts": dict(counts), "records": rows,
            "scope": "CPU commit bracket relative to plannedNextTickNs−3ms. guardNs is the absolute CPU boundary, not a duration. Submission guard does not require GPU completion before the tick; crossed_unknown is separate from GPU-coverage unknown."}


def overlap_review(data, real, by_job, fills):
    raw_jobs = {(j.get("contextID", data.get("contextID", 1)), j["jobID"]): j for j in data.get("jobs", [])}
    rows, counts, overlap_values, lateness = [], Counter(), [], []
    for job in real["job_series"]:
        if job["phase"] != "measurement":
            continue
        key = (job["contextID"], job["jobID"])
        raw = raw_jobs[key]
        previous = real_analysis.integer(raw.get("lastFillIDAtRealStart"))
        start, tick, observation = (real_analysis.integer(raw.get(k)) for k in
                                    ("wallStartNs", "targetNs", "fillStateObservationNs"))
        late = D(start - tick) / D(1_000_000) if start is not None and tick is not None else None
        if late is not None:
            lateness.append(late)
        overlap = None
        predecessor = fills.get(previous)
        if previous == 0 and raw.get("fillInFlightAtRealStart") is False:
            status, overlap = "explicit_no_predecessor", D(0)
        elif previous is None or predecessor is None:
            status = "unknown_predecessor"
        elif not predecessor["valid"] or not job["GPU_valid"] or key not in by_job:
            status = "unknown_GPU_interval"
        else:
            a, b = predecessor["interval"]
            overlap = intersection_length(by_job[key], a, b) / D(1_000_000)
            status = "overlap" if overlap > 0 else "no_overlap"
        counts[status] += 1
        if overlap is not None:
            overlap_values.append(overlap)
        rows.append({"jobID": job["jobID"], "lastFillIDAtRealStart": previous,
                     "predecessor_phase": predecessor["record"].get("phase") if predecessor else None,
                     "fillInFlightAtRealStart": raw.get("fillInFlightAtRealStart"),
                     "status": status, "GPU_interval_intersection_ms": overlap,
                     "real_launch_lateness_ms": late, "native_launchLagNs": raw.get("launchLagNs"),
                     "missedSlotsBefore": raw.get("missedSlotsBefore"),
                     "fill_state_observation_to_wall_start_ms": D(start - observation) / D(1_000_000)
                         if start is not None and observation is not None and observation > 0 else None})
    return {"counts": dict(counts), "known_overlap_ms_including_known_zero": real_analysis.distribution(overlap_values),
            "real_launch_lateness_ms": real_analysis.distribution(lateness), "jobs": rows,
            "scope": "Intersection of the explicitly referenced last-fill GPU interval and that real job's own root union. No closest-time matching and no CPU/GPU origin subtraction. Calibration may be a predecessor for lookup only; it never contributes to coverage. Residency overlap is not proof of simultaneous active shaders."}


def analyze_gap_fill(data, source):
    gap = data.get("gapFill")
    if not isinstance(gap, dict):
        raise ValueError("gapFill report missing")
    real = real_analysis.analyze_arm(data, source, "A")
    fills, accounting = collect_fills(gap)
    calibration = calibration_review(gap, fills)
    by_job = real_intervals(data, real)
    coverage = coverage_review(data, real, by_job, fills, accounting)
    guards = guard_review(fills)
    overlaps = overlap_review(data, real, by_job, fills)
    prefix_gpu = real["GPU_reference"]["same_arm_prefix_valid_GPU_union_p50_ms"]
    formal_gpu = real["measurement"]["GPU_union_ms"]
    prefix_wall = real["baseline"]["wall_ms"]
    formal_wall = real["measurement"]["wall_ms"]
    gpu_ratio = formal_gpu["p50"] / prefix_gpu if formal_gpu and prefix_gpu else None
    wall_ratio = formal_wall["p50"] / prefix_wall["p50"] if formal_wall and prefix_wall else None
    ratio_known = gpu_ratio is not None and real["baseline"]["GPU_invalid_jobs"] == 0 and real["measurement"]["GPU_invalid_jobs"] == 0
    ratio_gate = gpu_ratio <= GPU_MEDIAN_RATIO_LIMIT if ratio_known else None
    burst = real["primary_spike"]["classification"]
    no_burst = True if burst == "no_spike_observed" else False if burst == "spike_observed" else None
    deviations = []
    if gap.get("enabled") is not True or data.get("configuration", {}).get("gapFillEnabled") is not True:
        deviations.append("gap_fill_not_declared_enabled")
    if gap.get("contractVersion") != "opus-gap-fill-20261109-v1":
        deviations.append("unexpected_gap_fill_contract_version")
    if not real_analysis.integer(data.get("deviceRegistryID")) or data.get("deviceRegistryID") != gap.get("deviceRegistryID"):
        deviations.append("same_Metal_device_unverified")
    if guards["counts"].get("after_violation", 0):
        deviations.append("definite_commit_guard_violation")
    if coverage.get("fill_single_inflight_order_violations") or coverage.get("real_serial_push_order_violations"):
        deviations.append("GPU_stream_order_contradicts_serial_contract")
    if gap.get("finalPendingUnresolved") is True:
        deviations.append("final_pending_fill_unresolved")
    elif gap.get("finalPendingUnresolved") is not False:
        deviations.append("final_pending_state_missing")
    if data.get("status") == "calibration_failed" or not calibration["passed"]:
        decision = "startup_failure_calibration_failed_or_unverified"
    elif data.get("status") == "baseline_not_ready":
        decision = "prefix_not_ready_stop"
    elif not real["protocol_eligible"] or deviations:
        decision = "inconclusive_protocol_or_recording_stop"
    elif not coverage["passed"]:
        decision = "inconclusive_coverage_stop_no_retuning"
    elif no_burst is None or ratio_gate is None:
        decision = "inconclusive_real_job_timing_stop"
    elif no_burst is False:
        decision = "real_GPU_burst_observed_stop"
    elif ratio_gate is False:
        decision = "real_GPU_median_ratio_above_1_3_stop"
    else:
        decision = "three_conditions_satisfied_conditional_600s_eligibility_only"
    formal_fills = [x for x in fills.values() if x["record"].get("phase") == "measurement"]
    baseline_fills = [x for x in fills.values() if x["record"].get("phase") == "baseline"]
    return {"native_gap_fill_contract": gap.get("contractVersion"), "real_job_analysis": real,
            "fill_accounting": accounting, "calibration": calibration,
            "fill_counts_by_phase": dict(Counter(x["record"].get("phase") for x in fills.values())),
            "operational_fill_GPU_duration_ms": {phase: real_analysis.distribution(
                (x["interval"][1] - x["interval"][0]) / D(1_000_000) for x in rows if x["valid"])
                for phase, rows in (("baseline", baseline_fills), ("measurement", formal_fills))},
            "operational_fill_records": [{"fillID": x["fillID"], "phase": x["record"].get("phase"),
                                          "valid": x["valid"], "issues": x["issues"],
                                          "GPU_duration_ms": (x["interval"][1] - x["interval"][0]) / D(1_000_000) if x["valid"] else None,
                                          "native_durationMs": x["record"].get("durationMs")}
                                         for x in sorted(baseline_fills + formal_fills, key=lambda x: x["fillID"])],
            "GPU_clock_coverage": coverage, "CPU_commit_guard": guards,
            "last_fill_next_real_overlap": overlaps,
            "finish_pending_observation": {k: gap.get(k) for k in ("pendingFillIDAtFinish", "pendingStatusAtFinish",
                  "finishWaitBeginNs", "finishWaitEndNs", "finalPendingUnresolved")},
            "guardRejectedBeforeCommitCount": gap.get("guardRejectedBeforeCommitCount"),
            "protocol_deviations": deviations,
            "three_conditions": {"GPU_coverage_rule_satisfied": coverage["passed"],
                                 "no_real_GPU_burst_in_CPU_second_bins": no_burst,
                                 "formal_real_GPU_p50_over_prefix": gpu_ratio,
                                 "GPU_ratio_known_for_complete_real_cohort": ratio_known,
                                 "GPU_p50_ratio_le1_3": ratio_gate,
                                 "CPU_wall_p50_ratio_report_only": wall_ratio},
            "decision": decision, "automatic_next_run": False,
            "positive_interpretation_limit": "Only the observed intermittent-load-associated slowdown may be called avoidable in this setup. No frequency knowledge, active-cycle utilization, 600s result, App result, quality or product acceptance is inferred."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Existing gap-fill native JSON")
    parser.add_argument("--environment", type=Path, help="Existing coordinator-state.json; observations only")
    parser.add_argument("--output", type=Path, required=True, help="CPU analysis JSON output")
    args = parser.parse_args()
    protected = {args.input.resolve()}
    if args.environment is not None:
        protected.add(args.environment.resolve())
    if args.output.resolve() in protected:
        parser.error("Output must not overwrite raw input or coordinator evidence")
    data, source = real_analysis.read_json(args.input)
    try:
        analysis = analyze_gap_fill(data, source)
    except (ValueError, KeyError, TypeError, ArithmeticError) as error:
        analysis = {"decision": "inconclusive_input_or_schema_error", "error": str(error),
                    "automatic_next_run": False}
    try:
        environment = real_analysis.read_environment(args.environment)
    except (OSError, ValueError, KeyError, TypeError) as error:
        environment = {"status": "environment_unknown", "reason": str(error)}
    result = {"schema": "odf-air-gap-fill-analysis-v1", "source": source,
              "analyzer_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "real_analyzer_sha256": hashlib.sha256(Path(real_analysis.__file__).read_bytes()).hexdigest(),
              "frozen_contract": {"coverage_per_full_GPU_bin": COVERAGE_TARGET,
                                  "minimum_fraction_passing_full_GPU_bins": PASSING_BIN_TARGET,
                                  "unknown_fraction_exclusive_inconclusive_limit": MAX_UNKNOWN_FRACTION,
                                  "real_GPU_median_ratio_inclusive_limit": GPU_MEDIAN_RATIO_LIMIT,
                                  "CPU_submission_guard_ns": GUARD_NS,
                                  "pilot_CBs": 5, "validation_CBs": 5,
                                  "validation_GPU_median_inclusive_ms": [VALIDATION_MIN_MS, VALIDATION_MAX_MS],
                                  "real_burst": "Unchanged CPU-formal half-open complete 1s bins; >=12 jobs/bin; >=2x own prefix real GPU-union median for >=5 consecutive valid bins",
                                  "CPU_wall_ratio_is_not_a_gate": True,
                                  "coverage_unknowns": "Remain in full-bin denominator as not-met; never imputed as zero idle/GPU work",
                                  "clock_rule": "GPU interval unions/intersections stay in the shared Metal GPU clock; guard/lateness stay in DispatchTime CPU ns; no unknown-origin subtraction or kernel clock"},
              "analysis": analysis, "environment": environment,
              "scope": "Read-only CPU analysis; no new GPU, calibration, parameter search, retry, automatic 600s task, performance-state setting or user-preference change."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2,
                                    default=lambda x: float(x) if isinstance(x, D) else str(x)) + "\n")
    print(json.dumps({"output": str(args.output), "decision": analysis["decision"],
                      "automatic_next_run": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
