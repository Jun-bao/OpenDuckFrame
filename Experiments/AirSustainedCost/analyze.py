#!/usr/bin/env python3
"""Analyze existing sustained-cost JSON on CPU; never launches a benchmark.

Example:
    python3 -B analyze.py --arm-a A.json --arm-b B.json --output review.json

One arm may be supplied for a partial readout; the four-branch interpretation then
stays unknown. The primary definition is frozen at 2x the same arm's baseline GPU
union median for five consecutive complete one-second measurement bins.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec = 40
D = Decimal
FORMAT = "odf-air-sustained-cost-v1"
SECOND_NS = 1_000_000_000
PRIMARY_RATIO = D("2")
SENSITIVITY_RATIOS = (D("1.9"), D("2"), D("2.1"))
CONSECUTIVE_BINS = 5
HISTORICAL_WALL_P50_MS = D("18.1323335")
WALL_LOWER_MS = HISTORICAL_WALL_P50_MS * D("0.9")
WALL_UPPER_MS = HISTORICAL_WALL_P50_MS * D("1.1")
PREFIX_WALL_EXCLUSIVE_MS = HISTORICAL_WALL_P50_MS * 2
DISPLAY_STATE_FIELDS = ("displayAsleep", "explicitLock", "lockKeyPresent", "onConsole",
                        "loginDone", "sessionAvailable", "sessionUIDMatchesProcess")


def reject_nonfinite(value):
    raise ValueError(f"Non-finite JSON number: {value}")


def read_json(path):
    blob = path.read_bytes()
    data = json.loads(blob, parse_float=D, parse_constant=reject_nonfinite)
    return data, {"name": path.name, "sha256": hashlib.sha256(blob).hexdigest(),
                  "bytes": len(blob)}


def number(value):
    if isinstance(value, bool) or value is None:
        return None
    try:
        result = D(value)
    except (TypeError, ValueError, ArithmeticError):
        return None
    return result if result.is_finite() else None


def integer(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def quantile(values, probability):
    values = sorted(values)
    position = D(len(values) - 1) * D(str(probability))
    index = int(position)
    return values[index] + (values[min(index + 1, len(values) - 1)] - values[index]) * (position - index)


def distribution(values):
    values = [D(v) for v in values]
    if not values:
        return None
    return {"n": len(values), "min": min(values), "p50": quantile(values, .5),
            "p95": quantile(values, .95), "max": max(values)}


def union_ms(intervals):
    """Intervals are entirely in Metal GPU host-seconds; no CPU timestamp here."""
    total = D(0)
    lower = upper = None
    for start, end in sorted(intervals):
        if lower is None:
            lower, upper = start, end
        elif start > upper:
            total += upper - lower
            lower, upper = start, end
        else:
            upper = max(upper, end)
    return (total + upper - lower) * 1000 if lower is not None else None


def root_is_valid(root):
    start, end = number(root.get("gpuStartSeconds")), number(root.get("gpuEndSeconds"))
    mask, flags = integer(root.get("validityMask")), integer(root.get("coverageFlags"))
    return (start is not None and end is not None and 0 < start <= end
            and root.get("status") == 4 and mask is not None and mask & 26 == 26
            and flags is not None and flags & 1 != 0 and flags & 14 == 0
            and root.get("commitKind") in (1, 2))


def build_job_series(data):
    context = data.get("contextID", 1)
    observations = defaultdict(list)
    copied_per_observation_job = Counter()
    for index, root in enumerate(data.get("roots", [])):
        identity = (root.get("contextID", context), root.get("jobID"),
                    root.get("stage"), root.get("rootIndex"))
        order = root.get("observationSequence", index)
        observations[identity].append((order, index, root))
        copied_per_observation_job[root.get("observedAfterJobID")] += 1
    roots_by_job = defaultdict(list)
    conflicts, invalid_roots = [], []
    for identity, rows in observations.items():
        ordered = sorted(rows, key=lambda item: (item[0], item[1]))
        valid = [row for _, _, row in ordered if root_is_valid(row)]
        # Completion may legitimately fill previously unavailable timing fields.
        fingerprints = {(number(r.get("gpuStartSeconds")), number(r.get("gpuEndSeconds")),
                         r.get("commitBeginHostTicks"), r.get("commitEndHostTicks"),
                         r.get("commitKind")) for r in valid}
        conflict = len(fingerprints) > 1
        chosen = valid[-1] if valid else ordered[-1][2]
        if conflict:
            conflicts.append(list(identity))
        if not valid or conflict:
            invalid_roots.append(list(identity))
        roots_by_job[identity[:2]].append((chosen, bool(valid) and not conflict))
    series, duplicate_jobs = [], []
    job_ids = set()
    for raw in data.get("jobs", []):
        jid = raw.get("jobID")
        identity = (raw.get("contextID", context), jid)
        issues = []
        if identity in job_ids:
            duplicate_jobs.append(list(identity))
            issues.append("duplicate_job_identity")
        job_ids.add(identity)
        start, end, wall = (integer(raw.get(k)) for k in ("wallStartNs", "wallEndNs", "wallNs"))
        wall_valid = (start is not None and end is not None and wall is not None
                      and 0 <= start < end and wall == end - start)
        if not wall_valid:
            issues.append("invalid_wall_interval")
        if raw.get("generated") is not True:
            issues.append("push_did_not_generate")
        if raw.get("traceOverflow") != 0:
            issues.append("trace_overflow_or_missing")
        expected = integer(raw.get("traceRecordCount"))
        observed = copied_per_observation_job[jid]
        if expected is None or expected != observed:
            issues.append("trace_record_count_mismatch_or_missing")
        roots = [(r, valid) for r, valid in roots_by_job[identity] if r.get("stage") == 3]
        indices = sorted(r.get("rootIndex") for r, _ in roots if integer(r.get("rootIndex")) is not None)
        if not roots:
            issues.append("no_main_push_roots")
        elif indices != list(range(len(roots))):
            issues.append("noncontiguous_main_root_indices")
        if any(not valid for _, valid in roots):
            issues.append("invalid_or_conflicting_main_root")
        gpu = union_ms([(D(r["gpuStartSeconds"]), D(r["gpuEndSeconds"]))
                        for r, valid in roots if valid]) if roots and all(v for _, v in roots) else None
        if gpu is None or gpu <= 0:
            issues.append("unavailable_or_zero_GPU_union")
        gpu_valid = not issues
        series.append({"jobID": jid, "contextID": identity[0], "phase": raw.get("phase"),
                       "sequence": raw.get("sequence"), "wallStartNs": start, "wallEndNs": end,
                       "wall_ms": D(wall) / 10**6 if wall_valid else None,
                       "GPU_union_ms": gpu if gpu_valid else None,
                       "main_root_count": len(roots), "GPU_valid": gpu_valid,
                       "invalid_reasons": issues, "generated": raw.get("generated"),
                       "scheduledSlot": raw.get("scheduledSlot"), "targetNs": raw.get("targetNs"),
                       "launchLagNs": raw.get("launchLagNs"), "missedSlotsBefore": raw.get("missedSlotsBefore"),
                       "traceRecordCount": expected, "copied_root_observations": observed})
    coverage = {"raw_root_observations": len(data.get("roots", [])),
                "unique_roots": len(observations),
                "duplicate_observations_removed": sum(len(v) - 1 for v in observations.values()),
                "valid_timing_conflicts": conflicts, "invalid_unique_root_ids": invalid_roots,
                "duplicate_job_ids": duplicate_jobs,
                "setup_and_prime_unique_roots_excluded": sum(k[2] != 3 for k in observations),
                "native_root_observations_attempted": data.get("rootObservationsAttempted"),
                "native_root_observations_dropped": data.get("rootObservationsDropped"),
                "native_trace_overflow_total": data.get("traceOverflowTotal"),
                "native_job_limit_reached": data.get("jobLimitReached"),
                "deduplication": "(contextID,jobID,stage,rootIndex), latest valid observation; conflicting complete timings invalidate the root"}
    return series, coverage


def job_profile(jobs):
    return {"jobs": len(jobs), "GPU_valid_jobs": sum(j["GPU_valid"] for j in jobs),
            "GPU_invalid_jobs": sum(not j["GPU_valid"] for j in jobs),
            "wall_ms": distribution(j["wall_ms"] for j in jobs if j["wall_ms"] is not None),
            "GPU_union_ms": distribution(j["GPU_union_ms"] for j in jobs if j["GPU_valid"]),
            "invalid_reason_counts": dict(Counter(reason for j in jobs for reason in j["invalid_reasons"]))}


def phase_bounds(data, name):
    phase = data.get("phases", {}).get(name)
    if not isinstance(phase, dict):
        return None
    start, end = integer(phase.get("startNs")), integer(phase.get("endNs"))
    requested = number(phase.get("requestedSeconds"))
    if start is None or end is None or requested is None or not 0 <= start <= end or requested <= 0:
        return None
    return {"startNs": start, "endNs": end, "requestedSeconds": requested,
            "observed_seconds": D(end - start) / SECOND_NS,
            "observed_horizon_ns": min(end - start, int(requested * SECOND_NS)),
            "jobCount": phase.get("jobCount"), "missedSlots": phase.get("missedSlots"),
            "actualHz": phase.get("actualHz"), "complete": phase.get("complete"),
            "requestedEndNs": phase.get("requestedEndNs"),
            "skippedSlotsBeforeJobs": phase.get("skippedSlotsBeforeJobs"),
            "trailingMissedSlots": phase.get("trailingMissedSlots")}


def classify_phase_completion(arm, bounds, rows, config):
    """Account for a completed paced schedule without inventing its final idle time.

    The native loop stops after the last launched/skipped tick, not after sleeping
    to requestedEndNs. This is separate from the number of observed full bins.
    """
    if not bounds:
        return {"status": "incomplete_or_unverified", "reason": "Missing phase bounds"}
    requested_end = bounds["startNs"] + int(bounds["requestedSeconds"] * SECOND_NS)
    idle = requested_end - bounds["endNs"]
    result = {"status": "incomplete_or_unverified", "requestedEndNs": bounds["requestedEndNs"],
              "actualEndNs": bounds["endNs"], "unobserved_idle_tail_ns": max(0, idle),
              "observed_complete_1s_bins": bounds["observed_horizon_ns"] // SECOND_NS,
              "observed_partial_final_bin_ns": bounds["observed_horizon_ns"] % SECOND_NS,
              "native_phase_complete": bounds["complete"]}
    if bounds["complete"] is not True or bounds["requestedEndNs"] != requested_end:
        return result
    if idle <= 0:
        result["status"] = "observed_reaches_requested_end"
        return result
    hz = number(config.get("targetHz"))
    if arm != "A" or config.get("mode") != "paced24" or hz != 24:
        return result
    planned = bounds["requestedSeconds"] * hz
    missed = integer(bounds["missedSlots"])
    slots = [integer(j["scheduledSlot"]) for j in rows]
    skips = [integer(j["missedSlotsBefore"]) for j in rows]
    expected_skips = ([slots[0]] + [b - a - 1 for a, b in zip(slots, slots[1:])]
                      if slots and all(s is not None for s in slots) else [])
    closure = (planned == int(planned) and bounds["jobCount"] == len(rows)
               and missed is not None and missed >= 0 and len(rows) + missed == int(planned)
               and bool(slots) and all(s is not None and 0 <= s < int(planned) for s in slots)
               and all(a < b for a, b in zip(slots, slots[1:]))
               and skips == expected_skips
               and bounds["skippedSlotsBeforeJobs"] == sum(skips)
               and bounds["trailingMissedSlots"] == int(planned) - slots[-1] - 1
               and missed == sum(skips) + bounds["trailingMissedSlots"])
    result.update(planned_ticks=int(planned), launched_jobs=len(rows), missed_slots=missed,
                  scheduled_tick_accounting_closed=closure, one_tick_ns=D(SECOND_NS) / hz)
    if closure and 0 < D(idle) < D(SECOND_NS) / hz:
        result["status"] = "scheduled_complete_with_idle_tail"
    return result


def make_bins(data, jobs, name, bounds, minimum_jobs):
    if not bounds:
        return [], [], []
    start, horizon = bounds["startNs"], bounds["observed_horizon_ns"]
    count = horizon // SECOND_NS
    assigned = defaultdict(list)
    unplaced, excluded = [], []
    for job in jobs:
        if job["phase"] != name:
            continue
        if job["wallStartNs"] is None:
            unplaced.append(job["jobID"])
            continue
        elapsed = job["wallStartNs"] - start
        if 0 <= elapsed < horizon:
            assigned[elapsed // SECOND_NS].append(job)
        else:
            excluded.append(job["jobID"])
    thermal = defaultdict(list)
    for sample in data.get("thermalSamples", []):
        stamp = integer(sample.get("sampleNs"))
        if sample.get("phase") == name and stamp is not None and 0 <= stamp - start < horizon:
            thermal[(stamp - start) // SECOND_NS].append({"sampleNs": stamp,
                "elapsed_seconds_from_CPU_clock": D(stamp - start) / SECOND_NS,
                "thermalState": sample.get("thermalState")})
    bins = []
    for index in range(count):
        rows = assigned[index]
        profile = job_profile(rows)
        gpu_status = ("empty" if not rows else "invalid" if not all(j["GPU_valid"] for j in rows)
                      else "lowcount" if len(rows) < minimum_jobs else "valid")
        cpu_status = ("empty" if not rows else "invalid" if any(j["wall_ms"] is None or j["generated"] is not True for j in rows)
                      else "lowcount" if len(rows) < minimum_jobs else "valid")
        profile.update(index=index, start_s=index, end_s=index + 1,
                       complete_temporal_bin=True,
                       minimum_jobs=minimum_jobs, GPU_bin_status=gpu_status,
                       CPU_bin_status=cpu_status,
                       GPU_bin_known=gpu_status == "valid", CPU_bin_known=cpu_status == "valid",
                       jobIDs=[j["jobID"] for j in rows],
                       missed_slots_reported_at_job_launch=sum(j["missedSlotsBefore"] or 0 for j in rows),
                       thermal_observations=thermal[index])
        bins.append(profile)
    return bins, unplaced, excluded


def onset_analysis(bins, reference, multiplier, metric="GPU_union_ms", status_key="GPU_bin_status"):
    if reference is None or reference <= 0:
        return {"classification": "unknown", "reason": "No valid same-arm baseline reference", "metric": metric}
    labels = []
    for b in bins:
        median = b[metric]["p50"] if b[metric] else None
        labels.append(b[status_key] if b[status_key] != "valid" else
                      "high" if median >= reference * multiplier else "low")
    definite, possible = [], []
    for i in range(max(0, len(labels) - CONSECUTIVE_BINS + 1)):
        window = labels[i:i + CONSECUTIVE_BINS]
        if all(x == "high" for x in window):
            definite.append(i)
        if all(x != "low" for x in window):
            possible.append(i)
    first = definite[0] if definite else None
    earliest_possible = possible[0] if possible else None
    classification = "spike_observed" if definite else "unknown" if possible or len(bins) < CONSECUTIVE_BINS else "no_spike_observed"
    return {"classification": classification, "multiplier": multiplier, "metric": metric,
            "threshold_ms": reference * multiplier,
            "first_definite_onset_measurement_s": first,
            "first_confirmation_measurement_s": first + CONSECUTIVE_BINS if first is not None else None,
            "earliest_possible_onset_measurement_s": earliest_possible,
            "first_onset_identified_at_1s_resolution": first is not None and first == earliest_possible,
            "high_bins": labels.count("high"), "low_bins": labels.count("low"),
            "unknown_bins": sum(x not in ("high", "low") for x in labels),
            "invalid_bins": labels.count("invalid"), "lowcount_bins": labels.count("lowcount"),
            "empty_bins": labels.count("empty"), "bin_labels": labels,
            "definition": "First index of five consecutive complete 1s bins whose complete valid-job GPU-union median is >= threshold; onset is a bin boundary, not an exact hardware-event timestamp"}


def analyze_arm(data, source, arm):
    if data.get("format", data.get("schema")) != FORMAT:
        raise ValueError("Unsupported raw format")
    jobs, coverage = build_job_series(data)
    config = data.get("configuration", {})
    baseline_bounds = phase_bounds(data, "baseline")
    measurement_bounds = phase_bounds(data, "measurement")
    base_jobs = [j for j in jobs if j["phase"] == "baseline"]
    formal_jobs = [j for j in jobs if j["phase"] == "measurement"]
    completions = {"baseline": classify_phase_completion(arm, baseline_bounds, base_jobs, config),
                   "measurement": classify_phase_completion(arm, measurement_bounds, formal_jobs, config)}
    base = job_profile(base_jobs)
    reference = base["GPU_union_ms"]["p50"] if base["GPU_union_ms"] else None
    wall_median = base["wall_ms"]["p50"] if base["wall_ms"] else None
    wall_pass = wall_median < PREFIX_WALL_EXCLUSIVE_MS if wall_median is not None else None
    minimum_jobs = 12 if arm == "A" else 10
    baseline_bins, baseline_unplaced, baseline_excluded = make_bins(data, jobs, "baseline", baseline_bounds, minimum_jobs)
    bins, unplaced, excluded = make_bins(data, jobs, "measurement", measurement_bounds, minimum_jobs)
    primary = onset_analysis(bins, reference, PRIMARY_RATIO)
    sensitivity = {str(ratio): onset_analysis(bins, reference, ratio) for ratio in SENSITIVITY_RATIOS}
    cpu_spike = onset_analysis(bins, wall_median, PRIMARY_RATIO, "wall_ms", "CPU_bin_status")
    cpu_only_windows = []
    if "bin_labels" in primary and "bin_labels" in cpu_spike:
        for index in range(max(0, len(bins) - CONSECUTIVE_BINS + 1)):
            if (all(x == "high" for x in cpu_spike["bin_labels"][index:index + CONSECUTIVE_BINS])
                    and all(x == "low" for x in primary["bin_labels"][index:index + CONSECUTIVE_BINS])):
                cpu_only_windows.append(index)
    for b in bins:
        b["GPU_median_ratio_to_prefix"] = b["GPU_union_ms"]["p50"] / reference if reference and b["GPU_union_ms"] else None
        ratio = b["GPU_median_ratio_to_prefix"]
        b["threshold_edge_1_9_to_2_1"] = ratio is not None and D("1.9") <= ratio <= D("2.1")
    expected_seconds = D(180 if arm == "A" else 120)
    eligibility_reasons = []
    if data.get("status") != "complete" or data.get("functionalComplete") is not True:
        eligibility_reasons.append("native_run_not_complete")
    if number(config.get("seconds")) != expected_seconds:
        eligibility_reasons.append("requested_duration_differs_from_arm_contract")
    if number(config.get("baselineSeconds")) != 5:
        eligibility_reasons.append("baseline_prefix_not_requested_as_5s")
    if arm == "A" and (config.get("mode") != "paced24" or number(config.get("targetHz")) != 24):
        eligibility_reasons.append("arm_A_not_declared_paced_24Hz")
    if arm == "B" and config.get("mode") != "continuous":
        eligibility_reasons.append("arm_B_not_declared_continuous")
    if (not baseline_bounds or (baseline_bounds["observed_horizon_ns"] < 5 * SECOND_NS
                               and completions["baseline"]["status"] != "scheduled_complete_with_idle_tail")):
        eligibility_reasons.append("incomplete_baseline_prefix")
    if wall_pass is not True:
        eligibility_reasons.append("historical_wall_baseline_condition_not_met_or_unknown")
    if data.get("baselineGate", {}).get("passed") is not wall_pass:
        eligibility_reasons.append("native_and_recomputed_baseline_gate_disagree")
    if base["GPU_invalid_jobs"] or not reference:
        eligibility_reasons.append("baseline_GPU_reference_has_missing_or_invalid_jobs")
    if (not measurement_bounds or (len(bins) != int(expected_seconds)
                                  and completions["measurement"]["status"] != "scheduled_complete_with_idle_tail")):
        eligibility_reasons.append("formal_time_horizon_incomplete")
    if unplaced or baseline_unplaced:
        eligibility_reasons.append("jobs_have_unplaceable_CPU_start_times")
    if coverage["duplicate_job_ids"]:
        eligibility_reasons.append("duplicate_job_identities")
    if data.get("rootObservationsDropped") != 0 or data.get("traceOverflowTotal") != 0 or data.get("jobLimitReached") is not False:
        eligibility_reasons.append("global_trace_or_capacity_coverage_incomplete")
    for name, bounds, rows in (("baseline", baseline_bounds, base_jobs), ("measurement", measurement_bounds, formal_jobs)):
        if bounds and bounds["jobCount"] != len(rows):
            eligibility_reasons.append(name + "_job_count_mismatch")
        if bounds and bounds["complete"] is not True:
            eligibility_reasons.append(name + "_native_phase_not_complete")
    first = primary.get("first_definite_onset_measurement_s")
    if first is not None and measurement_bounds:
        offset = measurement_bounds["startNs"] - baseline_bounds["startNs"] if baseline_bounds else None
        first_push = min((j["wallStartNs"] for j in jobs if j["wallStartNs"] is not None), default=None)
        primary["first_onset_since_baseline_start_s"] = D(offset) / SECOND_NS + first if offset is not None else None
        primary["first_onset_since_first_push_s"] = D(measurement_bounds["startNs"] - first_push) / SECOND_NS + first if first_push is not None else None
    segments = []
    if measurement_bounds:
        for lower in range(0, int(expected_seconds), 30):
            upper = min(lower + 30, int(expected_seconds))
            selected = [j for j in formal_jobs if j["wallStartNs"] is not None
                        and lower * SECOND_NS <= j["wallStartNs"] - measurement_bounds["startNs"] < upper * SECOND_NS]
            segments.append({"start_s": lower, "end_s": upper, **job_profile(selected)})
    phase_missed = {}
    for name, bounds in (("baseline", baseline_bounds), ("measurement", measurement_bounds)):
        rows = [j for j in jobs if j["phase"] == name]
        reported = sum(j["missedSlotsBefore"] or 0 for j in rows)
        declared = bounds["missedSlots"] if bounds else None
        slots = [j["scheduledSlot"] for j in rows if j["scheduledSlot"] is not None]
        missing_paced = [j["jobID"] for j in rows if arm == "A" and any(j[k] is None for k in
                         ("scheduledSlot", "targetNs", "launchLagNs", "missedSlotsBefore"))]
        phase_missed[name] = {"native_missedSlots": declared, "sum_missedSlotsBefore": reported,
                              "unassigned_tail_difference": declared - reported if integer(declared) is not None and not missing_paced else None,
                              "missing_paced_job_fields": missing_paced,
                              "scheduled_slots_strictly_increasing": all(a < b for a, b in zip(slots, slots[1:])) if slots else None,
                              "launch_lag_ms": distribution(D(j["launchLagNs"]) / 10**6 for j in rows if j["launchLagNs"] is not None),
                              "scope": "Skipped scheduled ticks are not generated jobs or invalid GPU samples; no catch-up work or missing thermal samples are invented"}
        if missing_paced:
            eligibility_reasons.append(name + "_paced_schedule_fields_missing")
        if arm == "A" and slots and not all(a < b for a, b in zip(slots, slots[1:])):
            eligibility_reasons.append(name + "_paced_slot_order_invalid")
    return {"arm": arm, "source": source, "runID": data.get("runID"),
            "native_status": data.get("status"), "native_failureKind": data.get("failureKind"),
            "functionalComplete": data.get("functionalComplete"), "configuration": config,
            "modelIdentity": data.get("modelIdentity"),
            "firstInputSHA256": data.get("firstInputSHA256"), "secondInputSHA256": data.get("secondInputSHA256"),
            "device": data.get("device"), "lowPowerMode": data.get("lowPowerMode"),
            "hostClock": data.get("hostClock"), "coverage": coverage,
            "phase_completion_classification": completions,
            "baseline": {"bounds": baseline_bounds, **base, "one_second_bins": baseline_bins,
                         "unplaced_jobIDs": baseline_unplaced, "outside_declared_horizon_jobIDs": baseline_excluded},
            "baseline_wall_condition": {"contractVersion": "opus-sustained-predata-v2-20261109",
                                         "reference_p50_ms": HISTORICAL_WALL_P50_MS,
                                         "threshold_exclusive_ms": PREFIX_WALL_EXCLUSIVE_MS,
                                         "comparison": "lt",
                                         "observed_prefix_p50_ms": wall_median, "passed": wall_pass,
                                         "deviation_from_historical_percent": (wall_median / HISTORICAL_WALL_P50_MS - 1) * 100 if wall_median is not None else None,
                                         "historical_plus_minus10_percent_interval_only": [WALL_LOWER_MS, WALL_UPPER_MS],
                                         "inside_historical_plus_minus10_percent_not_gate": WALL_LOWER_MS <= wall_median <= WALL_UPPER_MS if wall_median is not None else None,
                                         "native_gate": data.get("baselineGate"),
                                         "limit": "Predata correction: strict <2x historical wall median is the gate; old +/-10% is descriptive only. Reference came from a different short ABAB test without trace. Pacing/input history differ and current trace overhead is nonzero; failure is not evidence of thermal throttling or a hardware limit."},
            "GPU_reference": {"same_arm_prefix_valid_GPU_union_p50_ms": reference,
                              "valid_jobs": base["GPU_valid_jobs"], "invalid_jobs": base["GPU_invalid_jobs"],
                              "not_the_wall_reference": True},
            "measurement": {"bounds": measurement_bounds, **job_profile(formal_jobs),
                            "one_second_bins": bins, "fixed_30s_segments": segments,
                            "unplaced_jobIDs": unplaced, "outside_declared_horizon_jobIDs": excluded},
            "primary_spike": primary, "threshold_sensitivity_not_new_gates": sensitivity,
            "CPU_wall_spike_observation": cpu_spike,
            "CPU_side_without_GPU_spike": {"first_onset_measurement_s": cpu_only_windows[0] if cpu_only_windows else None,
                                            "observed": bool(cpu_only_windows),
                                            "definition": "Five consecutive valid bins with CPU wall median >=2x own prefix wall median and GPU median <2x own prefix GPU median; no subtraction and no unique CPU/thermal cause inference"},
            "missed_ticks": phase_missed,
            "thermal_samples": data.get("thermalSamples", []),
            "thermal_scope": "Actual observations only; absent seconds stay empty. thermalState is not GPU frequency or a complete power/temperature diagnosis.",
            "protocol_eligible": not eligibility_reasons, "protocol_ineligible_reasons": eligibility_reasons,
            "job_series": jobs}


def read_environment(path):
    if path is None:
        return {"status": "environment_unknown", "reason": "No coordinator-state file supplied"}
    state, source = read_json(path)
    attempts = state.get("attempts", [])
    complete = [(i, a) for i, a in enumerate(attempts) if a.get("native_status") == "complete"]
    summary = {"source": source, "coordinator_status": state.get("status"),
               "attempt_statuses": [{"index": i, "native_status": a.get("native_status")}
                                    for i, a in enumerate(attempts)]}
    if len(complete) != 1:
        return {**summary, "status": "environment_unknown", "reason": "No unique completed formal attempt"}
    index, attempt = complete[0]
    before = attempt.get("preflight_before", {}).get("result", {}).get("preflight", {})
    after = attempt.get("preflight_after", {}).get("result", {}).get("preflight", {})
    start = {k: before.get(k) for k in DISPLAY_STATE_FIELDS}
    end = {k: after.get(k) for k in DISPLAY_STATE_FIELDS}
    return {**summary, "status": "recorded_start_state_available" if all(isinstance(v, bool) for v in start.values()) else "environment_unknown",
            "completed_attempt_index": index, "start_recorded_state": start, "end_recorded_state": end,
            "process_cpu_before": attempt.get("process_cpu_before"),
            "process_cpu_after": attempt.get("process_cpu_after"),
            "scope": "Only recorded display/lock/session booleans. lockKeyPresent=false is not affirmative unlocked evidence. CPU process snapshots are not GPU-load measurements; no display ID/resolution or whole-environment equivalence is claimed."}


def compare_environments(environments):
    if any(environments.get(k, {}).get("status") != "recorded_start_state_available" for k in ("A", "B")):
        return {"status": "environment_unknown", "reason": "Missing completed-arm start-state fields"}
    a, b = (environments[k]["start_recorded_state"] for k in ("A", "B"))
    differences = {k: {"A": a[k], "B": b[k]} for k in DISPLAY_STATE_FIELDS if a[k] != b[k]}
    return {"status": "environment_different" if differences else "recorded_start_states_match",
            "differences": differences, "compared_fields": list(DISPLAY_STATE_FIELDS),
            "scope": "Equality is limited to these recorded fields, not equality of overall CPU/GPU/display environment."}


def four_branch_interpretation(arms):
    if set(arms) != {"A", "B"}:
        return {"branch": None, "classification": "unknown", "reason": "Both arms are required"}
    a, b = arms["A"], arms["B"]
    if not a.get("protocol_eligible") or not b.get("protocol_eligible"):
        return {"branch": None, "classification": "unknown", "reason": "Baseline/coverage/run contract evidence insufficient",
                "arm_reasons": {k: v.get("protocol_ineligible_reasons", [v.get("input_error")]) for k, v in arms.items()}}
    sa, sb = a["primary_spike"], b["primary_spike"]
    ca, cb = sa["classification"], sb["classification"]
    if "unknown" in (ca, cb):
        return {"branch": None, "classification": "unknown", "reason": "Invalid or empty bins can conceal a qualifying five-bin run"}
    if ca == cb == "no_spike_observed":
        return {"branch": 2, "classification": "neither_arm_spiked_under_protocol",
                "interpretation": "Opus branch 2: inspect existing App-environment evidence next. This is a protocol routing observation, not proof of one particular App cause."}
    if ca == cb == "spike_observed":
        ta, tb = sa["first_definite_onset_measurement_s"], sb["first_definite_onset_measurement_s"]
        pa, pb = sa["earliest_possible_onset_measurement_s"], sb["earliest_possible_onset_measurement_s"]
        bounds = {"A": [pa, ta], "B": [pb, tb]}
        if tb < pa:
            return {"branch": 1, "classification": "both_spiked_B_earlier",
                    "onset_measurement_s": {"A": ta, "B": tb},
                    "first_onset_bounds_s": bounds,
                    "interpretation": "Opus branch 1: observed load-associated sustained limit pattern. No thermal, frequency or unique hardware attribution; no automatic C4 run."}
        if pa == ta == pb == tb:
            return {"branch": 3, "classification": "both_spiked_in_same_one_second_onset_bin",
                    "onset_measurement_s": {"A": ta, "B": tb},
                    "interpretation": "Opus branch 3 at the declared 1s resolution: motivates read-only timed-event inspection, but does not prove exact simultaneity or load independence."}
        if not ta < pb:
            return {"branch": None, "classification": "unknown", "first_onset_bounds_s": bounds,
                    "reason": "Possible earlier unknown windows prevent strict ordering or a shared identified onset bin"}
    return {"branch": 4, "classification": "fully_observed_other_pattern_stop",
            "interpretation": "Observed pattern is outside branches 1–3. Stop this protocol; the harness alone does not establish a thermal/frequency cause or universal hardware impossibility."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arm-a", type=Path, help="Existing paced-24Hz 180s raw JSON")
    parser.add_argument("--arm-b", type=Path, help="Existing continuous 120s raw JSON")
    parser.add_argument("--environment-a", type=Path, help="A coordinator-state.json; read completed attempt's preflight/CPU snapshots")
    parser.add_argument("--environment-b", type=Path, help="B coordinator-state.json; missing state is environment_unknown")
    parser.add_argument("--output", type=Path, required=True, help="Analysis JSON output; raw files are never modified")
    args = parser.parse_args()
    inputs = {k: p for k, p in (("A", args.arm_a), ("B", args.arm_b)) if p is not None}
    if not inputs:
        parser.error("Supply at least one existing arm")
    if any(args.output.resolve() == p.resolve() for p in inputs.values()):
        parser.error("Output must not overwrite raw input")
    arms = {}
    for label, path in inputs.items():
        try:
            data, source = read_json(path)
            arms[label] = analyze_arm(data, source, label)
        except (OSError, ValueError, KeyError, TypeError, ArithmeticError) as error:
            arms[label] = {"arm": label, "protocol_eligible": False,
                           "input_error": str(error), "protocol_ineligible_reasons": ["input_or_schema_error"]}
    environments = {}
    for label, path in (("A", args.environment_a), ("B", args.environment_b)):
        try:
            environments[label] = read_environment(path)
        except (OSError, ValueError, KeyError, TypeError) as error:
            environments[label] = {"status": "environment_unknown", "reason": str(error)}
    environment_comparison = compare_environments(environments)
    observed_pattern = four_branch_interpretation(arms)
    interpretation = observed_pattern
    if observed_pattern.get("branch") is not None and environment_comparison["status"] != "recorded_start_states_match":
        interpretation = {"branch": None, "classification": "unknown",
                          "reason": environment_comparison["status"],
                          "observed_pattern_branch": observed_pattern["branch"],
                          "limit": "Timing pattern remains reported; differing/missing recorded start states do not support the controlled cross-arm interpretation."}
    result = {"schema": "odf-air-sustained-cost-analysis-v1",
              "protocol": {"bin_width_seconds": 1, "consecutive_full_bins": CONSECUTIVE_BINS,
                           "minimum_jobs_per_complete_bin": {"A": 12, "B": 10},
                           "prefix_wall_gate": "strict p50 < 36.264667ms; old +/-10% is descriptive only (predata v2 correction)",
                           "paced_idle_tail_correction": "A native-complete paced phase with every planned tick launched/skipped and an idle tail shorter than one tick is scheduled_complete_with_idle_tail. Its actual end, partial last bin and unobserved idle tail are retained; no full bin is fabricated. This corrects an analyzer-only end>=duration check, not the signed spike/performance gates.",
                           "primary_GPU_multiplier": PRIMARY_RATIO,
                           "sensitivity_multipliers": SENSITIVITY_RATIOS,
                           "percentiles": "Type-7 linear interpolation at (n-1)*p",
                           "bin_assignment": "Job phase is authoritative; formal jobs assigned by wallStartNs relative to measurement.startNs. A job crossing a bin end keeps its full completed cost in its start bin.",
                           "unknown_bins": "Empty, invalid or lowcount bins break the five-bin run and retain possible-unknown onset bounds; never filled by missed scheduled ticks.",
                           "time_domains": "CPU phase/job/thermal timestamps share declared DispatchTime.uptimeNanoseconds. GPU S/E unions use only Metal GPU seconds; no CPU/GPU absolute subtraction and no kernel clock use.",
                           "residency_limit": "GPU union is command-buffer residency, not active shader cycles. CPU wall and GPU residency may overlap and are not added as exclusive fractions."},
              "arms": arms, "environments": environments, "environment_comparison": environment_comparison,
              "observed_four_branch_pattern": observed_pattern, "interpretation": interpretation,
              "execution_scope": "Read-only CPU analysis of supplied files; no native execution, calibration, sleep, retry, thermal/frequency attribution or automatic next experiment."}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2,
                                    default=lambda x: float(x) if isinstance(x, D) else str(x)) + "\n")
    print(json.dumps({"output": str(args.output), "interpretation": result["interpretation"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
