"""Whole-block analysis; conditional short-window intervals, not acceptance."""
import argparse
import json
from pathlib import Path

import numpy as np


def interval_coverage(segments):
    """Union of observed CB residency envelopes; not GPU active shader time."""
    intervals = sorted((s["gpu_start_s"], s["gpu_end_s"]) for s in segments
                       if s["gpu_start_s"] > 0 and s["gpu_end_s"] >= s["gpu_start_s"])
    if not intervals:
        return None
    end, union = -np.inf, 0.0
    for start, stop in intervals:
        union += max(0.0, stop - max(start, end))
        end = max(end, stop)
    return dict(observed_cb_residency_union_ms=union * 1000,
                observed_cb_span_ms=(end - intervals[0][0]) * 1000,
                valid_observed_segments=len(intervals),
                scope="observed CB envelopes only; neither exhaustive GPU work nor active shader cycles")


def estimate(a, b, iid_indices, moving_indices):
    d = a - b
    ci = lambda x: [float(v) for v in np.quantile(x, [.025, .975])]
    relative = 1 - b.mean() / a.mean()
    correlation = float(np.corrcoef(d[:-1], d[1:])[0, 1]) if d[:-1].std() and d[1:].std() else None
    return dict(baseline_mean_ms=float(a.mean()), candidate_mean_ms=float(b.mean()),
                mean_saved_ms=float(d.mean()), relative_saving=float(relative),
                whole_block_ci95_ms=ci(d[iid_indices].mean(1)),
                moving_block_length3_ci95_ms=ci(d[moving_indices].mean(1)),
                whole_block_relative_ci95=ci(1 - b[iid_indices].mean(1) / a[iid_indices].mean(1)),
                block_mean_saved_ms=d.tolist(), lag1_block_difference_correlation=correlation,
                interval_caveat=f"{len(d)} adjacent time blocks, not independent sessions; all intervals are approximate and short-window conditional")


def analyze(report, intervention="submission"):
    rows = report["result"]["records"]
    blocks = sorted({r["block"] for r in rows})
    assert blocks == list(range(len(blocks)))
    rng = np.random.default_rng(20261106)
    n = len(blocks)
    iid = rng.integers(0, n, size=(30000, n))
    starts = rng.integers(0, n, size=(30000, (n + 2) // 3))
    moving = ((starts[:, :, None] + np.arange(3)) % n).reshape(30000, -1)[:, :n]
    result = {}
    suffix = "native" if intervention == "native-leaky" else "deferred"
    change = "activation_change" if intervention == "native-leaky" else "submission_change"
    for cadence in ("30Hz", "continuous"):
        values = {}
        descriptions = {}
        for variant in ("d0", "ds", "d0_" + suffix, "ds_" + suffix):
            filtered = [r for r in rows if r["cadence"] == cadence and r["variant"] == variant]
            values[variant] = np.array([np.mean([np.mean([s["host_ms"] for s in r["samples"]])
                                               for r in filtered if r["block"] == block]) for block in blocks])
            pooled = [s for r in filtered for s in r["samples"]]
            descriptions[variant] = dict(n_calls=len(pooled), pooled_mean_ms=float(np.mean([s["host_ms"] for s in pooled])),
                                         pooled_median_ms=float(np.median([s["host_ms"] for s in pooled])),
                                         pooled_p95_ms=float(np.quantile([s["host_ms"] for s in pooled], .95)),
                                         max_observed_allocated_bytes=max(r["device_current_allocated_bytes"] for r in filtered),
                                         thermal_states=sorted({r["thermal_state"] for r in filtered}))
            if cadence == "30Hz":
                descriptions[variant].update(
                    crossed_next_arrival=sum(not s["completed_before_next_source_arrival"] for s in pooled),
                    max_start_lag_ms=max(s["start_lag_ms"] for s in pooled),
                    p95_completion_from_nominal_ms=float(np.quantile([s["completion_from_nominal_ms"] for s in pooled], .95)))
        comparisons = {name: estimate(values[a], values[b], iid, moving) for name, a, b in (
            ("primary_default_student", "d0", "ds"),
            ("d0_" + change, "d0", "d0_" + suffix),
            ("ds_" + change, "ds", "ds_" + suffix),
            ("student_under_" + suffix, "d0_" + suffix, "ds_" + suffix),
            ("joint_change", "d0", "ds_" + suffix))}
        interaction = (values["ds"] - values["ds_" + suffix]) - (values["d0"] - values["d0_" + suffix])
        comparisons["interaction"] = dict(mean_ms=float(interaction.mean()),
            whole_block_ci95_ms=np.quantile(interaction[iid].mean(1), [.025, .975]).tolist(),
            note="student intervention saving minus dense intervention saving; not an isolated per-buffer cost")
        result[cadence] = dict(descriptive=descriptions, comparisons=comparisons)
    return dict(blocks=n, by_cadence=result,
                primary="30Hz / " + ("d0_activation_change" if intervention == "native-leaky" else "primary_default_student") + ", three alpha block means equally weighted",
                profiler_enabled=report["profiling_enabled"],
                scope="four-arm randomized short-window mechanism experiment; no independent-video or product acceptance")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--result", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--intervention", choices=("submission", "native-leaky"), default="submission")
    args = ap.parse_args()
    summary = analyze(json.loads(args.result.read_text()), args.intervention)
    args.output.write_text(json.dumps(summary, indent=2) + "\n")
    for cadence, result in summary["by_cadence"].items():
        print(cadence, json.dumps(result["comparisons"]))
