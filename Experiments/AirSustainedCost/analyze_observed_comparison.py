#!/usr/bin/env python3
"""Compare existing A/B native traces with pinned rootless macmon observations.

CPU-only. No benchmark, observer, network call, clock adjustment or retry is
started here. Reception latency is descriptive and never moves a sample.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from decimal import Decimal as D, ROUND_CEILING, ROUND_FLOOR
from pathlib import Path

import analyze as native_analysis

NS = 1_000_000_000
HALF_NS = 500_000_000
MAX_GAP_NS = 1_500_000_000
MAX_CLOCK_JUMP_NS = 50_000_000
NATIVE_SHA = "ae638ae48631ea29032177d181455edcd8883dbdc0077fe039647a24bd822449"
MODEL_SHA = "ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74"
MACMON_SHA = "28f8d2b50b1a58e032295eb658de42088a49feb8affaf42803fb707edb0f73af"


def utc_ns(value):
    """Parse the source RFC3339 timestamp without binary64 or microsecond loss."""
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"(.+T\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)", value)
    if not match:
        return None
    try:
        stamp = datetime.fromisoformat(match[1] + ("+00:00" if match[3] == "Z" else match[3]))
        delta = stamp.astimezone(timezone.utc) - datetime(1970, 1, 1, tzinfo=timezone.utc)
    except ValueError:
        return None
    return (delta.days * 86400 + delta.seconds) * NS + int((match[2] or "").ljust(9, "0"))


def read_jsonl(path):
    blob = path.read_bytes()
    rows, invalid = [], []
    for line_number, line in enumerate(blob.splitlines(), 1):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line, parse_float=D, parse_constant=native_analysis.reject_nonfinite))
        except (ValueError, TypeError) as error:
            invalid.append({"line": line_number, "error": str(error)})
    return rows, {"name": path.name, "sha256": hashlib.sha256(blob).hexdigest(), "bytes": len(blob),
                  "invalidEnvelopeLines": invalid}


def clock_segments(raw):
    anchors, rejected = [], []
    for index, a in enumerate(raw):
        keys = ("utc_epoch_ns", "mach_before_ticks", "mach_after_ticks", "timebase_numer", "timebase_denom",
                "monotonic_before_ns", "monotonic_after_ns")
        v = {k: native_analysis.integer(a.get(k)) for k in keys}
        valid = (all(x is not None for x in v.values()) and v["timebase_numer"] > 0 and v["timebase_denom"] > 0
                 and 0 < v["mach_before_ticks"] <= v["mach_after_ticks"]
                 and 0 < v["monotonic_before_ns"] <= v["monotonic_after_ns"])
        if not valid:
            rejected.append(index)
            continue
        lo = D(v["mach_before_ticks"]) * v["timebase_numer"] / v["timebase_denom"]
        hi = D(v["mach_after_ticks"]) * v["timebase_numer"] / v["timebase_denom"]
        anchors.append({"rawIndex": index, "utc": D(v["utc_epoch_ns"]), "hostLo": lo, "hostHi": hi,
                        "hostMid": (lo+hi)/2, "offsetLo": D(v["utc_epoch_ns"])-hi,
                        "offsetHi": D(v["utc_epoch_ns"])-lo,
                        "monoLo": v["monotonic_before_ns"], "monoHi": v["monotonic_after_ns"]})
    segments = []
    for a, b in zip(anchors, anchors[1:]):
        delta_lo = max(D(0), b["offsetLo"]-a["offsetHi"], a["offsetLo"]-b["offsetHi"])
        delta_hi = max(abs(b["offsetHi"]-a["offsetLo"]), abs(a["offsetHi"]-b["offsetLo"]))
        valid = b["utc"] > a["utc"] and b["hostLo"] >= a["hostHi"]
        reason = ("nonmonotonic_clock_anchor" if not valid else "clock_jump_over50ms" if delta_lo > MAX_CLOCK_JUMP_NS
                  else "clock_jump_threshold_uncertain" if delta_hi > MAX_CLOCK_JUMP_NS else None)
        segments.append({"a": a, "b": b, "valid": reason is None, "reason": reason,
                         "absoluteOffsetChangeLowerNs": delta_lo, "absoluteOffsetChangeUpperNs": delta_hi,
                         "hostSpanLo": a["hostLo"], "hostSpanHi": b["hostHi"]})
    return segments, {"anchorCount": len(anchors), "rejectedAnchorIndices": rejected,
                      "anchors": [{"rawIndex": a["rawIndex"], "utcNs": a["utc"],
                                   "machLowerNs": a["hostLo"], "machUpperNs": a["hostHi"],
                                   "parentMonotonicBeforeNs": a["monoLo"], "parentMonotonicAfterNs": a["monoHi"]}
                                  for a in anchors],
                      "segments": [{"fromAnchor": s["a"]["rawIndex"], "toAnchor": s["b"]["rawIndex"],
                                    "valid": s["valid"], "reason": s["reason"],
                                    "utcStartNs": s["a"]["utc"], "utcEndNs": s["b"]["utc"],
                                    "hostStartNs": s["hostSpanLo"], "hostEndNs": s["hostSpanHi"],
                                    "offsetChangeLowerNs": s["absoluteOffsetChangeLowerNs"],
                                    "offsetChangeUpperNs": s["absoluteOffsetChangeUpperNs"]} for s in segments],
                      "definition": "UTC is bracketed by two mach reads; ticks use exact recorded numer/denom. Nominal mapping interpolates neighboring anchor centers, with endpoint-offset envelope as anchor error. No UTC/mach zero-offset assumption; >50ms offset change or ambiguous boundary makes that segment unknown."}


def map_utc(value, segments):
    exact = {a["rawIndex"]: a for s in segments for a in (s["a"], s["b"]) if a["utc"] == value}
    if len(exact) == 1:
        a = next(iter(exact.values()))
        error = (a["hostHi"]-a["hostLo"])/2
        return {"endHostNs": a["hostMid"], "startHostNs": a["hostMid"]-NS, "anchorErrorNs": error,
                "alignmentUncertaintyNs": D(NS)+error, "fromAnchor": a["rawIndex"], "toAnchor": a["rawIndex"]}, None
    if len(exact) > 1:
        return None, "repeated_UTC_anchor_epoch_ambiguous"
    candidates = [s for s in segments if s["a"]["utc"] <= value <= s["b"]["utc"]]
    if not candidates:
        return None, "outside_clock_brackets"
    # Non-anchor timestamps never select a favorable side of an ambiguous
    # clock segment. Bad-segment CPU spans are also marked unknown in bins.
    if any(not s["valid"] for s in candidates):
        return None, ";".join(sorted({s["reason"] for s in candidates if s["reason"]}))
    s = candidates[0]
    a, b = s["a"], s["b"]
    w = (D(value)-a["utc"])/(b["utc"]-a["utc"])
    center = (1-w)*a["hostMid"] + w*b["hostMid"]
    lower = D(value)-max(a["offsetHi"], b["offsetHi"])
    upper = D(value)-min(a["offsetLo"], b["offsetLo"])
    error = max(center-lower, upper-center)
    return {"endHostNs": center, "startHostNs": center-NS, "anchorErrorNs": error,
            "alignmentUncertaintyNs": D(NS)+error,
            "fromAnchor": a["rawIndex"], "toAnchor": b["rawIndex"]}, None


def metric_values(payload):
    values = {}
    mapping = {"gpu_freq_mhz": "gpu_freq_mhz", "gpu_active_ratio": "gpu_active_ratio",
               "gpu_power_w": "gpu_power", "cpu_power_w": "cpu_power", "ane_power_w": "ane_power",
               "cpu_gpu_ane_sum_w": "all_power", "system_power_estimate_w": "sys_power"}
    for name, key in mapping.items():
        values[name] = native_analysis.number(payload.get(key))
    temp = payload.get("temp") or {}
    for name in ("cpu", "gpu"):
        values[name+"_temp_c"] = native_analysis.number(temp.get(name+"_temp_avg"))
    tiers = {x.get("label"): x for x in payload.get("cpu_tiers", [])}
    for name, label in (("ecpu", "E"), ("pcpu", "P")):
        tier = tiers.get(label, {})
        for field in ("freq_mhz", "active_ratio"):
            values[name+"_"+field] = native_analysis.number(tier.get(field, payload.get(name+"_"+field)))
    return values


def map_samples(raw, segments):
    mapped, previous_utc = [], None
    first_valid_seen = False
    for index, row in enumerate(raw):
        payload = row.get("payload")
        if not isinstance(payload, dict):
            mapped.append({"rawIndex": index, "lineSeq": row.get("line_seq"), "status": "invalid_payload"})
            continue
        u = utc_ns(payload.get("timestamp"))
        if u is None or row.get("utc_epoch_ns") != u:
            mapped.append({"rawIndex": index, "lineSeq": row.get("line_seq"), "status": "invalid_source_UTC"})
            continue
        first = not first_valid_seen
        first_valid_seen = True
        gap = u-previous_utc if previous_utc is not None else None
        point, problem = map_utc(u, segments)
        gap_start, _ = map_utc(previous_utc, segments) if previous_utc is not None else (None, None)
        previous_utc = u
        recv_utc = native_analysis.integer(row.get("receive_utc_ns"))
        metrics = metric_values(payload)
        discard = first or row.get("discard") is True
        if discard:
            status = "discarded_first_sample" if first else "discarded_by_observer"
        elif row.get("valid_for_timing") is not True:
            status = "invalid_timing_flag"
        elif gap is not None and gap <= 0:
            status = "nonmonotonic_source_UTC"
        else:
            status = problem or "mapped"
        # Parent receive time includes its one-second polling delay and is never
        # used for alignment or added to alignmentUncertaintyNs.
        entry = {"rawIndex": index, "lineSeq": row.get("line_seq"), "sampleSeq": row.get("sample_seq"),
                 "sourceUtcRaw": payload.get("timestamp"), "sourceUtcNs": u,
                 "receiveMonotonicNs": row.get("receive_monotonic_ns"),
                 "receiveUtcNs": recv_utc, "receiveDelayFromSourceUtcNs": recv_utc-u if recv_utc is not None else None,
                 "status": status, "discarded": discard, "sourceGapNs": gap,
                 "sourceGapOver1_5s": gap is not None and gap > MAX_GAP_NS, "metrics": metrics,
                 **(point or {})}
        if gap is not None and gap > MAX_GAP_NS and point and gap_start:
            entry["nominalUnobservedGapHostNs"] = [gap_start["endHostNs"], point["startHostNs"]]
        mapped.append(entry)
    return mapped


def overlap(a, b, c, d):
    return max(D(0), min(b, d)-max(a, c))


def align_bins(native, mapped, segments):
    bounds = native["measurement"]["bounds"]
    if not bounds:
        return []
    start = bounds["startNs"]
    gaps = [s["nominalUnobservedGapHostNs"] for s in mapped if "nominalUnobservedGapHostNs" in s]
    invalid_clock_spans = [(s["hostSpanLo"], s["hostSpanHi"]) for s in segments if not s["valid"]]
    bins = []
    for b in native["measurement"]["one_second_bins"]:
        lo, hi = D(start+b["index"]*NS), D(start+(b["index"]+1)*NS)
        candidates = [s for s in mapped if s["status"] == "mapped" and overlap(lo, hi, s["startHostNs"], s["endHostNs"]) >= HALF_NS]
        metric_names = sorted({k for s in candidates for k in s["metrics"]})
        metrics = {k: native_analysis.quantile([s["metrics"][k] for s in candidates if s["metrics"].get(k) is not None], '.5')
                   if any(s["metrics"].get(k) is not None for s in candidates) else None for k in metric_names}
        reasons = []
        if any(overlap(lo, hi, a, z) > 0 for a,z in gaps):
            reasons.append("sample_gap_over1_5s_nominal_unobserved_portion")
        if any(overlap(lo, hi, a, z) > 0 for a,z in invalid_clock_spans):
            reasons.append("clock_anchor_segment_unknown")
        if not candidates:
            reasons.append("no_sample_overlaps_at_least_half_second")
        freq = metrics.get("gpu_freq_mhz")
        if freq is None or freq <= 0:
            reasons.append("no_positive_active_residency_GPU_frequency")
        bins.append({"index": b["index"], "startHostNs": lo, "endHostNs": hi,
                     "observationStatus": "unknown" if reasons else "known", "unknownReasons": reasons,
                     "sampleSeqs": [s["sampleSeq"] for s in candidates], "metricsMedian": metrics,
                     "maxAlignmentUncertaintyNs": max((s["alignmentUncertaintyNs"] for s in candidates), default=None),
                     "nativeJobCount": b["jobs"], "nativeGpuBinStatus": b["GPU_bin_status"],
                     "nativeGpuUnionMedianMs": b["GPU_union_ms"]["p50"] if b["GPU_union_ms"] else None,
                     "nativeWallMedianMs": b["wall_ms"]["p50"] if b["wall_ms"] else None})
    return bins


def summarize_window(arm, begin, end, minimum_bins):
    bins = [b for b in arm["bins"] if begin <= b["index"] < end]
    known = [b for b in bins if b["observationStatus"] == "known"]
    comparable = [b for b in known if b["nativeGpuBinStatus"] == "valid"]
    missing = len(bins)-len(known)
    metric_keys = sorted({k for b in comparable for k in b["metricsMedian"]})
    metrics = {k: native_analysis.distribution(b["metricsMedian"][k] for b in comparable if b["metricsMedian"].get(k) is not None)
               for k in metric_keys}
    gpu = native_analysis.distribution(b["nativeGpuUnionMedianMs"] for b in comparable if b["nativeGpuUnionMedianMs"] is not None)
    wall = native_analysis.distribution(b["nativeWallMedianMs"] for b in comparable if b["nativeWallMedianMs"] is not None)
    native_start = arm["native"]["measurement"]["bounds"]["startNs"]
    pooled = [j for j in arm["native"]["job_series"] if j["phase"] == "measurement"
              and j["wallStartNs"] is not None and begin*NS <= j["wallStartNs"]-native_start < end*NS]
    insufficient = len(bins) < minimum_bins
    fraction = D(missing)/len(bins) if bins else None
    native_low = [b["index"] for b in bins if b["nativeGpuBinStatus"] in ("lowcount", "empty")]
    native_invalid = [b["index"] for b in bins if b["nativeGpuBinStatus"] == "invalid"]
    observer_complete = not insufficient and fraction is not None and fraction <= D('.1')
    return {"startCpuSecond": begin, "endCpuSecondExclusive": end, "completeBins": len(bins),
            "minimumCompleteBins": minimum_bins, "insufficientWindow": insufficient,
            "knownObservationBins": len(known), "missingObservationBins": missing,
            "missingFraction": fraction, "missingAbove10Percent": fraction is None or fraction > D('.1'),
            "unknownBinIndices": [b["index"] for b in bins if b["observationStatus"] != "known"],
            "nativeInvalidOrLowSampleBins": sorted(native_low+native_invalid),
            "excludedNativeLowSampleBins": native_low, "excludedNativeInvalidBins": native_invalid,
            "observationWindowComplete": observer_complete,
            "comparisonEligibleBins": len(comparable), "comparisonEligibleBinIndices": [b["index"] for b in comparable],
            "validForFrequencyComparison": observer_complete and not native_invalid,
            "metricsOverBinMedians": metrics, "gpuUnionOverBinMediansMs": gpu,
            "wallOverBinMediansMs": wall, "pooledNativeJobsDescriptiveOnly": native_analysis.job_profile(pooled),
            "GPUUnionOnObserverKnownBinsDescriptiveOnly": native_analysis.distribution(b["nativeGpuUnionMedianMs"] for b in known if b["nativeGpuUnionMedianMs"] is not None),
            "weighting": "Median inside each complete native CPU second, then equal-time median over the common observer-known and native-eligible bins for frequency and cost. Native lowcount bins are excluded from both medians, not counted as observer missing and not a whole-window veto. Pooled jobs are descriptive only."}


def frequency_classification(arms):
    a, b = arms["A"], arms["B"]
    primary = a["native"]["primary_spike"]
    if not a["native"]["protocol_eligible"] or not b["native"]["protocol_eligible"]:
        return {"classification": "unknown_native_protocol_or_evidence", "frequencyConclusion": None}
    if primary["classification"] == "no_spike_observed":
        return {"classification": "not_reproduced", "frequencyConclusion": None,
                "description": "A did not reproduce the frozen GPU-union burst. Observation conditions or observer effects may differ; this is not a repair claim and does not trigger a rerun."}
    if primary["classification"] != "spike_observed":
        return {"classification": "unknown_native_burst_evidence", "frequencyConclusion": None}
    onset, confirmation = primary["first_definite_onset_measurement_s"], primary["first_confirmation_measurement_s"]
    windows = {"A_before": summarize_window(a, 0, onset, 5),
               "A_after": summarize_window(a, confirmation+5, len(a["bins"]), 30),
               "B_formal": summarize_window(b, 0, len(b["bins"]), 60)}
    if any(not arm.get("observerIdentityVerified", False) or not arm.get("nativeAssetIdentityVerified", False) for arm in arms.values()):
        return {"classification": "observation_incomplete", "reason": "fixed_native_or_observer_identity_not_verified",
                "frequencyConclusion": None, "windows": windows}
    if any(w["insufficientWindow"] for w in windows.values()):
        return {"classification": "unknown_insufficient_window", "frequencyConclusion": None, "windows": windows}
    if any(w["missingAbove10Percent"] for w in windows.values()):
        return {"classification": "observation_incomplete", "frequencyConclusion": None, "windows": windows}
    if any(not w["validForFrequencyComparison"] for w in windows.values()):
        return {"classification": "unknown_native_window_evidence", "frequencyConclusion": None, "windows": windows}
    freq = {k: (w["metricsOverBinMedians"].get("gpu_freq_mhz") or {}).get("p50") for k,w in windows.items()}
    gpu = {k: (w["gpuUnionOverBinMediansMs"] or {}).get("p50") for k,w in windows.items()}
    if any(x is None or x <= 0 for x in [*freq.values(), *gpu.values()]):
        return {"classification": "unknown_required_median", "frequencyConclusion": None, "windows": windows}
    f_ratio = freq["A_after"]/freq["A_before"]
    b_ratio = freq["B_formal"]/freq["A_before"]
    g_ratio = gpu["A_after"]/gpu["A_before"]
    inverse = freq["A_before"]/freq["A_after"]
    conditions = {"A_frequency_after_at_most0_6_before": f_ratio <= D('.6'),
                  "GPU_union_ratio_within_inverse_frequency_plus_minus25_percent": inverse*D('.75') <= g_ratio <= inverse*D('1.25'),
                  "B_frequency_at_least0_9_A_before": b_ratio >= D('.9'),
                  "A_GPU_union_ratio_at_least2": g_ratio >= 2,
                  "A_frequency_after_at_least0_9_before": f_ratio >= D('.9')}
    if all(conditions[k] for k in list(conditions)[:3]):
        label, conclusion = "consistent_with_GPU_clock_decrease", "与 GPU 时钟下降一致"
    elif conditions["A_GPU_union_ratio_at_least2"] and conditions["A_frequency_after_at_least0_9_before"]:
        label, conclusion = "not_explained_by_recorded_GPU_core_frequency", "不能用记录的 GPU 核心时钟解释"
    else:
        label, conclusion = "descriptive_unclassified", None
    return {"classification": label, "frequencyConclusion": conclusion, "windows": windows,
            "frequencyMedianMHz": freq, "gpuUnionBinMedianMs": gpu,
            "ratios": {"A_frequency_after_over_before": f_ratio, "B_frequency_over_A_before": b_ratio,
                       "A_GPU_union_after_over_before": g_ratio, "inverse_A_frequency": inverse,
                       "inverseFrequencyAllowedRange": [inverse*D('.75'), inverse*D('1.25')]},
            "conditions": conditions, "causalConclusion": None, "automaticNextTask": None,
            "scope": "Frozen descriptive pattern only. GPU frequency is active-state residency weighted aggregate frequency, not shader cycles or per-process frequency; no unique cause or energy acceptance is inferred."}


def observer_identity(meta):
    sampler = meta.get("sampler") or {}
    user = meta.get("user") or {}
    checks = {"fixed_binary_sha": sampler.get("binary_sha256") == MACMON_SHA,
              "version0_11_0": sampler.get("version") == "0.11.0",
              "normal_binary_not_CPU_fixture": sampler.get("normal_binary") is True and meta.get("test_mode") is False,
              "forced_CLPC_without_fallback": sampler.get("forced_clpc") is True and sampler.get("legacy_fallback_enabled") is False
                  and (sampler.get("environment") or {}).get("MACMON_FORCE_CLPC") == "1",
              "normal_nonroot_user": native_analysis.integer(user.get("euid")) is not None and user["euid"] > 0,
              "scheduled1Hz": meta.get("scheduled_interval_ms") == 1000}
    return {"verified": all(checks.values()), "checks": checks,
            "scope": "Pinned observer identity and readable fields only, not calibrated under-load measurement accuracy."}


def load_arm(label, raw_path, observer_dir, environment_path):
    data, receipt = native_analysis.read_json(raw_path)
    native = native_analysis.analyze_arm(data, receipt, label)
    errors, metadata, samples, anchors, events, observer_receipts = [], {}, [], [], [], {}
    try:
        metadata, observer_receipts["metadata"] = native_analysis.read_json(observer_dir / "metadata.json")
        for name in ("samples", "anchors", "events"):
            rows, evidence = read_jsonl(observer_dir / (name + ".jsonl"))
            observer_receipts[name] = evidence
            if name == "samples": samples = rows
            elif name == "anchors": anchors = rows
            else: events = rows
            errors.extend(name + ":" + str(r) for r in evidence["invalidEnvelopeLines"])
    except (OSError, ValueError, TypeError) as error:
        errors.append(str(error))
    environment = {}
    try:
        environment, env_receipt = native_analysis.read_json(environment_path)
    except (OSError, ValueError, TypeError) as error:
        env_receipt = {"error": str(error)}
    segments, clock_review = clock_segments(anchors)
    mapped = map_samples(samples, segments)
    bins = align_bins(native, mapped, segments)
    identity = observer_identity(metadata)
    asset = (environment.get("actual_sha256") or {})
    model = data.get("modelIdentity") or {}
    asset_checks = {"original_native_ae638ae": asset.get("binary") == NATIVE_SHA,
                    "original_model_EF29": asset.get("model") == MODEL_SHA and model.get("sha256") == MODEL_SHA,
                    "no_filler_added": not (data.get("gapFill") or {}).get("enabled", False) and not (data.get("realWorkFill") or {}).get("enabled", False)}
    lead_anchor = native_analysis.integer(metadata.get("lead_anchor_receive_monotonic_ns"))
    native_start = native_analysis.integer((metadata.get("native_start") or {}).get("monotonic_ns"))
    native_end = native_analysis.integer((metadata.get("native_end") or {}).get("monotonic_ns"))
    observer_stop = native_analysis.integer((metadata.get("observer_stop") or {}).get("monotonic_ns"))
    lead = D(native_start-lead_anchor)/NS if native_start is not None and lead_anchor is not None else None
    tail = D(observer_stop-native_end)/NS if observer_stop is not None and native_end is not None else None
    receive_delays = [D(s["receiveDelayFromSourceUtcNs"])/1_000_000 for s in mapped if s.get("receiveDelayFromSourceUtcNs") is not None]
    all_count = len(bins)
    missing_count = sum(b["observationStatus"] != "known" for b in bins)
    return {"arm": label, "native": native, "nativeAssetIdentityVerified": all(asset_checks.values()),
            "nativeAssetChecks": asset_checks, "observerIdentityVerified": identity["verified"],
            "observerIdentity": identity, "observerMetadata": metadata, "observerFiles": observer_receipts,
            "observerReadErrors": errors, "observerEvents": events,
            "environment": {"source": env_receipt, "actual_sha256": asset,
                            "preferences_unchanged": environment.get("preferences_unchanged"),
                            "attempts": environment.get("attempts")},
            "clockMapping": clock_review, "mappedSamples": mapped, "bins": bins,
            "formalObservationCoverage": {"completeNativeCpuBins": all_count,
                "unknownBins": missing_count, "missingFraction": D(missing_count)/all_count if all_count else None,
                "sampleStatusCounts": dict(Counter(s["status"] for s in mapped)),
                "sourceGapsOver1_5Seconds": sum(s.get("sourceGapOver1_5s", False) for s in mapped),
                "note": "A source gap marks its nominal uncovered portion unknown; bins touched by that gap are not filled by interpolation. ±1s sample-window uncertainty does not itself mark every bin unknown."},
            "padding": {"leadFromFirstNonDiscardReceivedSampleSeconds": lead,
                        "leadAtLeast10s": lead >= 10 if lead is not None else None,
                        "tailFromNativeEndMarkSeconds": tail,
                        "tailAtLeast10s": tail >= 10 if tail is not None else None,
                        "nativePostRollSatisfied": metadata.get("post_roll_satisfied")},
            "bufferingDiagnostic": {"receiveMinusSourceUtcMs": native_analysis.distribution(receive_delays),
                                    "negativeReceiveDelayCount": sum(v < 0 for v in receive_delays),
                                    "scope": "Includes coordinator polling/pipe buffering and possible wall-clock effects. Never shifts source UTC, enters alignment uncertainty, or aligns individual jobs."}}


def json_default(value):
    if isinstance(value, D):
        return float(value)
    raise TypeError(type(value).__name__)


def native_mark_mach_bounds(arm, name):
    """Bound one event using chronological order inside its own observer only.

    A preceding anchor's last mach read is before the event. A following
    anchor's first mach read is after it. No equal rates, shared parent epoch,
    UTC offset, interpolation or reception-delay assumption is needed here.
    """
    mark = arm["observerMetadata"].get(name) or {}
    stamp = native_analysis.integer(mark.get("monotonic_ns"))
    anchors = arm["clockMapping"].get("anchors", [])
    if stamp is None:
        return {"status": "unknown", "reason": "native_mark_missing", "mark": name}
    before = [a for a in anchors if a["parentMonotonicAfterNs"] < stamp]
    after = [a for a in anchors if a["parentMonotonicBeforeNs"] > stamp]
    if not before or not after:
        return {"status": "unknown", "reason": "native_mark_not_bracketed_within_own_process", "mark": name}
    lower = max(before, key=lambda a: a["machUpperNs"])
    upper = min(after, key=lambda a: a["machLowerNs"])
    lo = lower["machUpperNs"].to_integral_value(rounding=ROUND_FLOOR)
    hi = upper["machLowerNs"].to_integral_value(rounding=ROUND_CEILING)
    if lo > hi:
        return {"status": "unknown", "reason": "inconsistent_mach_order", "mark": name}
    return {"status": "bounded", "mark": name, "localParentMonotonicNs": stamp,
            "markUtcNsDescriptiveOnly": mark.get("utc_epoch_ns"),
            "machLowerNs": lo, "machUpperNs": hi, "boundWidthNs": hi-lo,
            "rounding": "Outward to integer nanoseconds: lower floor, upper ceil",
            "precedingAnchorRawIndex": lower["rawIndex"], "followingAnchorRawIndex": upper["rawIndex"],
            "scope": "Local parent monotonic is used only for before/after ordering within this observer process; endpoint bounds themselves are recorded mach reads."}


def common_mach_cooldown(arms):
    a, b = arms["A"], arms["B"]
    a_info = a["observerMetadata"].get("clock_info") or {}
    b_info = b["observerMetadata"].get("clock_info") or {}
    timebases = [[info.get("timebase_numer"), info.get("timebase_denom")] for info in (a_info, b_info)]
    common = (all("mach_absolute_time" in str(info.get("mach_api", "")) for info in (a_info, b_info))
              and timebases[0] == timebases[1] and all(native_analysis.integer(v) is not None and v > 0 for v in timebases[0]))
    end = native_mark_mach_bounds(a, "native_end")
    start = native_mark_mach_bounds(b, "native_start")
    result = {"method": "native event bounds from each process's UTC/mach anchor chronology; subtract only common mach endpoints",
              "commonClockBasis": {"sameAirScope": "Same Air host and uninterrupted mach clock are the run contract's scope; matching API/timebase records support the conversion, not a shared parent-monotonic origin.",
                                   "A_machAPI": a_info.get("mach_api"), "B_machAPI": b_info.get("mach_api"),
                                   "timebases": timebases, "recordedAPIAndTimebaseMatch": common,
                                   "crossProcessParentMonotonicSubtractionUsed": False},
              "A_nativeEnd": end, "B_nativeStart": start,
              "secondsLowerBound": None, "secondsUpperBound": None,
              "boundWidthSeconds": None, "cooldownAtLeast300s": None}
    if common and end["status"] == "bounded" and start["status"] == "bounded":
        lo = (start["machLowerNs"]-end["machUpperNs"])/NS
        hi = (start["machUpperNs"]-end["machLowerNs"])/NS
        result.update(secondsLowerBound=lo, secondsUpperBound=hi, boundWidthSeconds=hi-lo,
                      cooldownAtLeast300s=True if lo >= 300 else False if hi < 300 else None)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for label in ("a", "b"):
        parser.add_argument("--arm-" + label, type=Path, required=True)
        parser.add_argument("--observer-" + label, type=Path, help="Defaults to the native input's sibling metrics directory")
        parser.add_argument("--environment-" + label, type=Path, help="Defaults to coordinator-state.json above the attempt directory")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    arms = {}
    for label in ("A", "B"):
        lower = label.lower()
        raw = getattr(args, "arm_" + lower)
        obs = getattr(args, "observer_" + lower) or raw.parent / "metrics"
        env = getattr(args, "environment_" + lower) or raw.parent.parent / "coordinator-state.json"
        arms[label] = load_arm(label, raw, obs, env)
    result = frequency_classification(arms)
    descriptive_windows = {}
    primary = arms["A"]["native"]["primary_spike"]
    if primary["classification"] == "spike_observed":
        descriptive_windows["A_before"] = summarize_window(arms["A"], 0, primary["first_definite_onset_measurement_s"], 5)
        descriptive_windows["A_after"] = summarize_window(arms["A"], primary["first_confirmation_measurement_s"]+5, len(arms["A"]["bins"]), 30)
    if arms["B"]["native"]["measurement"]["bounds"]:
        descriptive_windows["B_available_measurement"] = summarize_window(arms["B"], 0, len(arms["B"]["bins"]), 60)
    cooldown = common_mach_cooldown(arms)
    timing_protocol = {"cooldownCommonMachBounds": cooldown,
                       "cooldownAtLeast300s": cooldown["cooldownAtLeast300s"],
                       "parentMonotonicScope": "Lead/tail differences are within each process only; cross-process cooldown uses mach bounds.",
                       "paddingByArm": {k: v["padding"] for k,v in arms.items()}}
    if (cooldown["cooldownAtLeast300s"] is not True or any(a["padding"]["leadAtLeast10s"] is not True
            or a["padding"]["tailAtLeast10s"] is not True for a in arms.values())):
        result = {"classification": "observation_incomplete", "reason": "required_cooldown_or_observer_padding_not_verified",
                  "frequencyConclusion": None, "descriptivePatternBeforeProtocolCheck": result}
    for arm in arms.values():
        arm["native"].pop("job_series", None)  # Pooled window statistics already retained; immutable raw remains authoritative.
    report = {"format": "odf-air-rootless-observed-comparison-v1", "classification": result,
              "arms": arms, "timingProtocol": timing_protocol,
              "availableWindowsDescriptiveOnly": descriptive_windows,
              "incompleteNativeDataIsNotPromotedByDescriptiveWindows": True,
              "analyzerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "nativeAnalyzerSHA256": hashlib.sha256(Path(native_analysis.__file__).read_bytes()).hexdigest(),
              "contract": {"primaryTimestamp": "macmon source UTC mapped through UTC/mach brackets; no UTC/mach zero offset",
                           "sampleInterval": "approximately the 1 second before source UTC", "minimumOverlapFraction": D('.5'),
                           "alignmentUncertainty": "±1 second plus neighboring clock-bracket error; receive delay excluded",
                           "clockJumpUnknownThresholdMs": 50, "sourceGapThresholdSeconds": D('1.5'),
                           "missingFractionMaximumInclusive": D('.1'), "firstSampleDiscardedButRawRetained": True,
                           "A_before": "formal[0,onset), >=5 complete CPU bins", "A_after": "formal[confirmation+5,end of complete bins), >=30 bins",
                           "B": "all formal complete CPU bins, >=60", "aggregation": "within-bin median, then equal-time median over common observer-known/native-eligible bins; observation completeness keeps its original full-bin denominator; pooled jobs separate",
                           "frequencyAfterMaximumRatio": D('.6'), "B_frequencyMinimumRatio": D('.9'),
                           "inverseFrequencyRelativeTolerance": D('.25'), "noClockExplanationGpuMinimumRatio": 2,
                           "noClockExplanationFrequencyMinimumRatio": D('.9')},
              "metricSemantics": {"gpu_freq_mhz": "Active-state residency weighted mean frequency from pinned macmon; not shader cycles or per PID",
                                  "gpu_active_ratio": "Fraction of the sample interval in active GPU frequency states; not the frequency-scaled gpu_usage/ratio",
                                  "cpu_tier_frequency": "Arithmetic mean of per-core active-state average frequencies with a minimum-frequency floor",
                                  "cpu_gpu_ane_sum_w": "cpu_power+gpu_power+ane_power estimate; not whole-machine power",
                                  "system_power_estimate_w": "macmon sys_power estimate; separate from component sum"},
              "limits": ["Five rootless idle samples established that the pinned tool can read on this host, not its under-load accuracy.",
                         "Frequency classifications are descriptive consistency checks, not unique causal identification.",
                         "CPU frequency, active ratios, temperatures and SoC/system power estimates are descriptive only; no formal energy acceptance.",
                         "No per-job UTC alignment, invented samples, new GPU measurement, future-v2 change or automatic next task.",
                         "This observed A/B group is separate; historical runs and their failures are not replaced."]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, default=json_default, ensure_ascii=False, indent=2)+"\n")
    print(json.dumps({"classification": result["classification"], "frequencyConclusion": result.get("frequencyConclusion"),
                      "output": str(args.output)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
