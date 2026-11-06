"""CPU-only audit of an ODF-frozen-cohort-plan-v1 export (Python + NumPy).

Usage: python3 -B analyze_frozen_timeline.py --input cohort-plan.json --output NEW_DIR

Defaults reproduce the archived 120 Hz / +2 ms diagnostic, not a new product
acceptance rule. Targets, outcomes and the input denominator are never changed.
The minimum-spacing bound is conditional; the fixed-phase bound additionally
assumes a constant period and phase for the entire cohort. SDK_V is a prediction,
not actualTime. Output is a new analysis.json, never an overwritten archive.
"""
from __future__ import annotations

import argparse
from collections import Counter
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path

import numpy as np


CONTEXT_FIELDS = ("generation", "configVersion", "measurementEpoch", "clockEpoch")
NS_PER_MS = 1_000_000
NS_PER_SECOND = 1_000_000_000


def rational(value):
    """Use the logged decimal spelling for SDK/actual doubles, without rounding ticks."""
    return Fraction(str(value))


def ratio(value):
    return {"num": value.numerator, "den": value.denominator}


def summary_ms(values):
    values = list(values)
    if not values:
        return {"n": 0}
    x = np.array([float(v / NS_PER_MS) for v in values])
    names = ("min", "p05", "median", "p95", "max")
    return {"n": len(values), **dict(zip(names, np.quantile(x, [0, .05, .5, .95, 1]).tolist()))}


def maximum_min_spacing(lower, upper, period):
    """Exact integer DP, in media order; permits arbitrary phase and gaps >= period.

    F[k] is the smallest last time after delivering k items from the prefix.
    Keep the skip state; take this item at max(lower[i], F[k-1] + period)
    only if it is <= upper[i]. Earlier last time dominates every later one.
    """
    infinity = 2**62
    best = np.full(len(lower) + 1, infinity, dtype=np.int64)
    best[0] = -infinity // 2
    count = 0
    for lo, hi in zip(lower, upper):
        # This new array is based entirely on the preceding prefix, not this item.
        candidate = np.maximum(lo, best[:count + 1] + period)
        candidate[candidate > hi] = infinity
        best[1:count + 2] = np.minimum(best[1:count + 2], candidate)
        if best[count + 1] < infinity:
            count += 1
    return count


def maximum_fixed_phase(targets, period, tolerance):
    """Exact all-phase optimum for nondecreasing targets and tolerance < period.

    Each window contains at most one grid slot. Its eligible slot changes only
    at target/endpoint residues. Check closed endpoints and open intervals;
    doubled integer units represent their midpoints exactly. At a fixed phase,
    sorted targets imply ordered slots, so count distinct eligible slots.
    """
    if tolerance >= period or tolerance < 0 or period <= 0:
        raise ValueError("fixed-phase enumeration requires 0 <= tolerance < period")
    if any(b < a for a, b in zip(targets, targets[1:])):
        raise ValueError("fixed-phase enumeration requires nondecreasing media-order targets")
    x = np.asarray(targets, dtype=np.int64) * 2
    p, e = period * 2, tolerance * 2
    boundaries = np.unique(np.r_[0, x % p, (x + e) % p, p])
    phases = np.unique(np.r_[boundaries[:-1], (boundaries[:-1] + boundaries[1:]) // 2])
    maximum = 0
    arg_phase = 0
    for phase in phases:
        slot = (x - phase + p - 1) // p
        eligible = slot[phase + slot * p <= x + e]
        count = 0 if not len(eligible) else 1 + int(np.count_nonzero(np.diff(eligible)))
        if count > maximum:
            maximum, arg_phase = count, int(phase)
    return {"maximum_matched": maximum, "phase_candidates": len(phases),
            "maximizing_phase_in_doubled_units": arg_phase}


def adjacent_conflicts(targets, period, tolerance):
    """Minimum vertex cover of the path of conflicting adjacent pairs, not edge sum."""
    edges = 0
    omissions = 0
    vertices = 1
    for a, b in zip(targets, targets[1:]):
        if b - a < period - tolerance:
            edges += 1
            vertices += 1
        else:
            omissions += vertices // 2
            vertices = 1
    return {"conflicting_adjacent_pairs": edges,
            "omission_lower_bound_from_adjacent_pairs_only": omissions + vertices // 2}


def pair_audit(pairs, tick_ns):
    errors, alpha_counts, unbound = [], Counter(), []
    observed_alpha = 0
    for pair in pairs:
        observed_alpha += pair.get("alpha") is not None
        endpoints = [pair.get(k) for k in ("sourceA", "synthetic", "sourceB")]
        if any(x is None for x in endpoints):
            unbound.append({"jobID": pair.get("jobID"), "reason": "missing_endpoint"})
            continue
        a, s, b = endpoints
        pts = [Fraction(x["ptsNum"], x["ptsDen"]) for x in endpoints]
        if not pts[0] < pts[1] < pts[2]:
            unbound.append({"jobID": pair.get("jobID"), "reason": "PTS_not_A_less_S_less_B"})
            continue
        alpha = (pts[1] - pts[0]) / (pts[2] - pts[0])
        error = (s["targetHost"] - (1 - alpha) * a["targetHost"] - alpha * b["targetHost"]) * tick_ns
        alpha_counts[str(alpha)] += 1
        errors.append((error, pair.get("jobID"), s["frameID"]))
    values = [x[0] for x in errors]
    extrema = {}
    if errors:
        for name, item in (("minimum", min(errors, key=lambda x: x[0])),
                           ("maximum", max(errors, key=lambda x: x[0]))):
            extrema[name] = {"error_ns_exact": ratio(item[0]), "jobID": item[1], "syntheticFrameID": item[2]}
    return {"input_pairs": len(pairs), "time_bound_pairs": len(errors),
            "unbound": unbound, "observed_model_alpha_n": observed_alpha,
            "derived_alpha_time_counts": dict(alpha_counts),
            "alpha_meaning": "Exact media-PTS fraction only; never fills missing model alpha.",
            "error_definition": "target_S - ((1-alpha_time)*target_A + alpha_time*target_B)",
            "error_ms": summary_ms(values), "extrema": extrema,
            "absolute_error_over_one_host_tick": sum(abs(x) > tick_ns for x in values),
            "absolute_error_over_0_1ms": sum(abs(x) > NS_PER_MS / 10 for x in values),
            "boundary_endpoints_are_not_added_to_frame_denominator": True}


def actual_category(frame, tick_ns, tolerance_ns):
    actual = frame.get("actualTime")
    if frame["outcome"] != "positive":
        return frame["outcome"]
    if actual is None or actual <= 0:
        return "invalid_positive_actual"
    delta = rational(actual) * NS_PER_SECOND - frame["targetHost"] * tick_ns
    return "early" if delta < 0 else "on_time_not_early" if delta <= tolerance_ns else "late"


def timing_audit(frames, tick_ns, tolerance_ns, guard_ns, lead_ns):
    threshold = lead_ns + guard_ns - tolerance_ns
    counts = Counter()
    stages = Counter()
    stage_outcomes = Counter()
    lead_checks = {}
    for key in ("modelCompleteHost", "readyHost", "presentationEnqueueHost"):
        available = [f for f in frames if f.get(key) is not None]
        margins = [(f["targetHost"] - f[key]) * tick_ns for f in available]
        lead_checks[key] = {"observed": len(available), "missing": len(frames) - len(available),
                            "below_nominal_required_lead": sum(x < threshold for x in margins),
                            "below_lead_without_guard": sum(x < lead_ns - tolerance_ns for x in margins),
                            "lead_ms": summary_ms(margins)}
    selected, in_window, nominal_slacks, selection_reserves, sdk_leads, actual_residuals = [], Counter(), [], [], [], []
    for f in frames:
        category = actual_category(f, tick_ns, tolerance_ns)
        counts[(f["type"], category)] += 1
        # No model completion is invented for source frames or missing synth logs.
        stage = "nominal_necessary_budget_met"
        for key, label in (("modelCompleteHost", "model_completion_below_budget"),
                           ("readyHost", "output_ready_below_budget"),
                           ("presentationEnqueueHost", "admission_below_budget")):
            if f.get(key) is not None and (f["targetHost"] - f[key]) * tick_ns < threshold:
                stage = label
                break
        if f.get("readyHost") is None or f.get("presentationEnqueueHost") is None:
            stage = "missing_ready_or_admission"
        stages[stage] += 1
        stage_outcomes[(stage, f["outcome"])] += 1
        if f.get("SDK_V") is not None and f.get("tau") is not None:
            sdk_leads.append((rational(f["SDK_V"]) - rational(f["tau"])) * NS_PER_SECOND)
        if f["outcome"] == "positive" and f.get("actualTime", 0) and f.get("SDK_V") is not None:
            actual_residuals.append((rational(f["actualTime"]) - rational(f["SDK_V"])) * NS_PER_SECOND)
        if f.get("displaySelectionHost") is None:
            continue  # Superseded failure-associated ticket fields are not reservations.
        selected.append(f)
        if f.get("SDK_V") is None or f.get("tau") is None:
            in_window[("SDK_timestamps_missing", category)] += 1
            continue
        delta = rational(f["SDK_V"]) * NS_PER_SECOND - f["targetHost"] * tick_ns
        bucket = "SDK_in_old_window" if 0 <= delta <= tolerance_ns else "SDK_outside_old_window"
        in_window[(bucket, category)] += 1
        deadline = rational(f["tau"]) * NS_PER_SECOND
        if f.get("presentationEnqueueHost") is not None:
            nominal_slacks.append(deadline - guard_ns - f["presentationEnqueueHost"] * tick_ns)
        selection_reserves.append(deadline - f["displaySelectionHost"] * tick_ns)
    positive_times = sorted(rational(f["actualTime"]) for f in frames
                            if f["outcome"] == "positive" and f.get("actualTime") is not None and f["actualTime"] > 0)
    return {
        "required_nominal_lead_ns_exact": ratio(threshold),
        "required_nominal_lead_ms": float(threshold / NS_PER_MS),
        "nominal_condition": "For predicted V in [d,d+epsilon], admission <= tau-g requires d-admission >= L+g-epsilon.",
        "caveat": "g is a nominal reserve; SDK_V is predicted. These budget failures are not unconditional actual-presentation failures and are not added to spacing omissions.",
        "lead_checks": lead_checks, "earliest_observed_insufficient_stage": dict(stages),
        "stage_original_outcomes": [{"stage": a, "outcome": b, "n": n} for (a, b), n in sorted(stage_outcomes.items())],
        "actual_by_type": [{"type": a, "category": b, "n": n} for (a, b), n in sorted(counts.items())],
        "actual_on_time_not_early": sum(n for (a, b), n in counts.items() if b == "on_time_not_early"),
        "actual_early": sum(n for (a, b), n in counts.items() if b == "early"),
        "selected_frames": len(selected), "unselected_frames": len(frames) - len(selected),
        "selected_SDK_window_vs_actual": [{"SDK_window": a, "actual_category": b, "n": n} for (a, b), n in sorted(in_window.items())],
        "observed_SDK_V_minus_tau_ms": summary_ms(sdk_leads),
        "selected_admission_slack_to_nominal_selection_ms": summary_ms(nominal_slacks),
        "selected_admission_after_nominal_selection_n": sum(x < 0 for x in nominal_slacks),
        "actual_selection_before_tau_ms": summary_ms(selection_reserves),
        "positive_actual_minus_SDK_V_ms": summary_ms(actual_residuals),
        "observed_positive_time_gaps_ms": summary_ms((b - a) * NS_PER_SECOND for a, b in zip(positive_times, positive_times[1:])),
        "positive_gap_caveat": "Observed frame callbacks are not the complete physical display-slot trace.",
    }


def audit_document(document, *, period_ms=Fraction(25, 3), tolerance_ms=Fraction(2),
                   guard_ms=Fraction(1), lead_ms=Fraction("16.667"), include_phase=True):
    if document.get("schema") != "ODF-frozen-cohort-plan-v1":
        raise ValueError("expected ODF-frozen-cohort-plan-v1")
    frames = document["frames"]
    if not frames:
        raise ValueError("frames must be nonempty")
    contexts = [tuple(f["context"].get(k) for k in CONTEXT_FIELDS) for f in frames]
    if len(set(contexts)) != 1:
        raise ValueError("audit one frozen context/clock epoch at a time; do not combine clocks")
    if len({(c, f["frameID"]) for c, f in zip(contexts, frames)}) != len(frames):
        raise ValueError("duplicate frame identity; refusing to silently deduplicate the denominator")
    frames = sorted(frames, key=lambda f: (Fraction(f["ptsNum"], f["ptsDen"]), f["frameID"]))
    tick = Fraction(document["timebase"]["numer"], document["timebase"]["denom"])
    period, epsilon, guard, lead = [rational(x) * NS_PER_MS for x in (period_ms, tolerance_ms, guard_ms, lead_ms)]
    if tick <= 0 or period <= 0 or min(epsilon, guard, lead) < 0:
        raise ValueError("positive tick/period and nonnegative tolerance/guard/lead are required")
    scale = math.lcm(*(x.denominator for x in (tick, period, epsilon, guard, lead)))
    origin = min(f["targetHost"] for f in frames)
    def host_units(host):
        return int((host - origin) * tick * scale)
    targets = [host_units(f["targetHost"]) for f in frames]
    p, e = int(period * scale), int(epsilon * scale)
    # All NumPy additions, including doubled phase units, must remain exact int64.
    if max(map(abs, targets)) + p + e >= 2**59:
        raise ValueError("scaled cohort exceeds the exact int64 range; shorten the cohort or coarsen an unnecessarily precise CLI parameter")
    lower = np.array(targets, dtype=np.int64)
    upper = lower + e
    maximum = maximum_min_spacing(lower, upper, p)
    inversions = sum(b < a for a, b in zip(targets, targets[1:]))
    spacing = {"kind": "conditional_optimistic_upper_bound", "maximum_matched": maximum,
               "unavoidable_omission_lower_bound": len(frames) - maximum,
               "condition": "Physical distinct deliveries have separation >= P; preserve media order and each frozen closed [d,d+epsilon] window. Arbitrary phase is allowed.",
               "cluster_necessary_capacity": "For a nondecreasing target cluster j..k: floor((d_k-d_j+epsilon)/P)+1. Overlapping deficits must not be added.",
               **adjacent_conflicts(targets, p, e)}
    phase = {"computed": False, "condition": "Additionally requires one constant period AND phase across the entire cohort; not an unconditional display bound."}
    if include_phase and not inversions and e < p:
        result = maximum_fixed_phase(targets, p, e)
        phase.update(computed=True, **result, unavoidable_omission_lower_bound=len(frames) - result["maximum_matched"])
        phase["maximizing_phase_relative_to_min_target_ns_exact"] = ratio(Fraction(result["maximizing_phase_in_doubled_units"], 2 * scale))
    else:
        phase["reason"] = "disabled" if not include_phase else "requires nondecreasing targets and epsilon < P"
    return {
        "schema": "ODF-frozen-timeline-audit-v1", "denominator": len(frames),
        "diagnostic_scope": "The old +epsilon statistic is retained for diagnosis, not declared an independently established user acceptance requirement. No target/outcome is changed; this audit does not replace actual FPS or quality acceptance.",
        "original_outcomes": dict(Counter(f["outcome"] for f in frames)),
        "original_types": dict(Counter(f["type"] for f in frames)),
        "context": dict(zip(CONTEXT_FIELDS, contexts[0])), "original_window": document.get("window"),
        "parameters": {"period_ns_exact": ratio(period), "tolerance_ns_exact": ratio(epsilon),
                       "guard_ns_exact": ratio(guard), "reference_SDK_lead_ns_exact": ratio(lead),
                       "host_tick_ns_exact": ratio(tick), "integer_units_per_ns": scale,
                       "SDK_actual_precision": "Logged decimal values only; no assertion of exact physical-clock precision."},
        "target_inversions_in_media_order": inversions,
        "minimum_spacing": spacing, "fixed_phase": phase,
        "timing": timing_audit(frames, tick, epsilon, guard, lead),
        "pairs": pair_audit(document.get("pairs", []), tick),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path, help="New directory only; existing paths are rejected.")
    parser.add_argument("--period-ms", default="25/3", type=Fraction, help="Conditional minimum spacing / fixed period, rational or decimal (default: exact 120 Hz).")
    parser.add_argument("--tolerance-ms", default="2", type=Fraction)
    parser.add_argument("--guard-ms", default="1", type=Fraction)
    parser.add_argument("--reference-lead-ms", default="16.667", type=Fraction, help="Conditional SDK V-tau budget, not an actual display measurement.")
    parser.add_argument("--skip-phase", action="store_true", help="Skip the stronger constant-period, constant-phase diagnostic.")
    args = parser.parse_args(argv)
    if args.output.exists():
        parser.error("--output must be a new directory; no archived output is overwritten")
    data = args.input.read_bytes()
    report = audit_document(json.loads(data), period_ms=args.period_ms, tolerance_ms=args.tolerance_ms,
                            guard_ms=args.guard_ms, lead_ms=args.reference_lead_ms, include_phase=not args.skip_phase)
    report["input"] = {"name": args.input.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    report["tool"] = {"name": Path(__file__).name, "sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                      "runtime": "CPU only; Python standard library and NumPy", "numpy_version": np.__version__}
    args.output.mkdir(parents=True, exist_ok=False)
    destination = args.output / "analysis.json"
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(destination), "denominator": report["denominator"],
                      "minimum_spacing_maximum": report["minimum_spacing"]["maximum_matched"],
                      "unavoidable_omission_lower_bound": report["minimum_spacing"]["unavoidable_omission_lower_bound"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
