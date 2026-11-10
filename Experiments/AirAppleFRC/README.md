# Isolated Apple FRC native diagnostic

This reuses the canonical `SPFRCEngine.mm` and `SPFrameBudgetMetal.mm`, their
inline headers, and the existing `FrameBudget.metal`. The fresh copy adds only
setup observation of the actual configuration attributes and session result.
No product file, RIFE runtime, shader math, or user preference is modified.

Prepare/build with an explicitly selected existing Xcode:

```text
DEVELOPER_DIR=XCODE_DEVELOPER_DIR python3 -B Experiments/AirAppleFRC/prepare_native.py
  --source-root REPO --output FRESH_PRIVATE_DIRECTORY
```

The script offline-compiles the original shader and compiles three Objective-C++
units concurrently (at most three CPU workers). It never runs the binary or
creates a VT/Metal session. Portable files are `air-apple-frc`, adjacent
`FrameBudget.metallib`, and the source/build receipt (plus repository licence).

CPU capability-only CLI:

```text
air-apple-frc --output ABS-new.json --capability-only
```

This reads OS metadata and static `isSupported` only. It creates no configuration,
processor, session, Metal device, or pixel buffer. Its declared size/format
requirements are not proof that an actual 1814×1142 session succeeds. Dynamic
supported formats/attributes are exported only from real engine `openSlot`.

The one authorized native run is coordinated separately:

```text
air-apple-frc --output ABS-new.json --seconds 120 --baseline-seconds 5
  --cancel-file ABS
```

Configuration is product Normal/revision1/usePrecomputedFlow=false, two sessions,
output capacity8, one request in flight, `submitPair`'s actual default Random.
`CHUANFLOW_FRC_CONTINUOUS` must be absent; there is no Sequential attempt or
fallback run. Fixture source images are the same 1814×1142 shift0/7 BGRA patterns
as the old RIFE native test. Setup converts each once on CPU to 420v NV12 using
BT.709 video-range coefficients, 2×2 chroma averaging and nearest quantization;
input/converted hashes and conversion durations are retained. This setup cost
is outside service timing, matching the product's captured-NV12 input boundary.

Pairs follow A,B,A,B… with 24 Hz PTS; skipped ticks remain explicit. Each service
interval starts immediately before attempting B's public engine submission and
ends at the first instruction of the final NV12 engine completion. It includes
both NV12→RGBAHalf conversions, VT processing, output conversion and delivery.
It is **submit→ready wall time**, not Apple GPU time. It excludes window capture,
the App presenter, one-time fixture setup, hashes, logging and JSON export.

Warm20 complete pairs precede an independent prefix5s and formal120s. Prefix is
Apple's own wall baseline; no RIFE 36.26ms gate or prefix retry applies. Prefix
and formal share one absolute24Hz timeline; stale ticks skip without catch-up.
Each callback has a 10-second diagnostic deadline; missing/late/error output is
retained, never converted into a successful sample. A marker cancels the run;
an in-flight completion may arrive afterwards and is reported separately.

All hot-path records are bounded scalars (maximum4,000 jobs), converted to JSON
only at the end. Per-pair autorelease pools match the App's release boundary.
No per-job pixel hashing is performed; only setup images and the final output
are hashed. Output status, actual dimensions/format, cancellation, rejected
submissions, skipped ticks and unissued remaining slots remain separate.

The final raw report has explicit setup success/failure, actual config/session
events, prefix/formal host-clock bounds, per-job submit/ready times, and both
planned/submitted and submitted/completed accounting. `run_native.py` owns Air
cooldown/HID/session checks and the single invocation; `analyze_native.py` owns
the frozen30.8ms p95, 2×/five-bin and minimum12-successful-jobs/bin decisions.
An `isSupported` result or successful CPU build is not a performance or product
acceptance result. No training is performed.
