# Air sustained native cost

Isolate the sustained RIFE service-cost rise without a window, ScreenCaptureKit,
presenter, model training, or app preferences. This is a native diagnostic, not
FPS, picture-quality, or thermal-cause acceptance.

`prepare_native.py --source TRACE_RUNTIME --output FRESH_RUNTIME` copies the frozen
combined trace runtime without modifying its library, shader, or weight bytes.
It adds the executable target and offline-compiles its independent diagnostic
`GapFill.metal` with the selected Xcode's `metal`/`metallib` tools. No GPU work is
executed by preparation and the original Core shader is untouched. Build Swift with
`swift build -c release --product air-sustained-cost --jobs 4`.

Before a GPU invocation, the same executable can read and validate the model on
CPU only:

```text
air-sustained-cost --identity-check-only --model-path ABS.rmw
  --model-sha256 HEX64 --output ABS-new.json
```

This branch runs before Harness or Metal initialization. It uses the real
`WeightStore(url:)` data parser and the same strict validator as the later
runtime identity check, retaining the values and Swift dynamic types. The
version is strictly `UInt32(1)`; treating it as `Int` would reject the valid
model. Its result is explicitly CPU-parsed identity, not a GPU-load observation.
The normal inference path still independently validates its actual loaded store.

The native CLI requires explicit absolute paths:

```text
air-sustained-cost --mode paced24 --seconds 180 --baseline-seconds 5
  --model-path ABS.rmw --model-sha256 HEX64 --output ABS.json --cancel-file ABS
```

Use `continuous --seconds 120` for arm B. Both arms accept only the original
SHA `ef29a643a76a9202600458a23dddce16919337ef01743d0fbe817684ec990f74`.
Set `ODF_AIR_SERVICE_TRACE=1` before launch; unset the App model override, dump and
profile variables. Source fixtures match the old cost probe: two preallocated
1814×1142 BGRA/IOSurface buffers (shifts 0/7), a preallocated caller output,
FP16/Fast (internal scale 0.25), GPU IO, accumulated masks, one cached previous
Head. Model identity comes from the actual loaded weight store.

Each invocation primes once, performs 20 warmups, then runs a separate 5-second
prefix at the arm's cadence. The **pre-data Opus correction**
`opus-sustained-predata-v2-20261109` requires prefix push-wall p50 **strictly below
36.264667 ms** (2× the historical 18.1323335 ms). The former ±10% gate is withdrawn;
the deviation is reported only. Failed prefixes return `baseline_not_ready` and
never begin the formal phase. Cooldown, limited prefix retries and the single
formal invocation per arm belong to `run_arm.py`, not this executable.

A uses absolute uptime-anchored 24 Hz slots, skips elapsed slots and never sends
catch-up jobs. B has no pacing sleep. `jobs.wallNs` covers only synchronous
`stream.push(input, into: output)`; tracing, pacing, cancellation, thermal reads,
hashing and JSON are outside that timer. Existing runtime waits remain inside.
The new trace-bearing package is not byte-identical to the old cost binary.
Each push and its trace read have a caller autorelease pool, drained outside the
push timer. The App already has this boundary; the old short cost caller did not.
This prevents retaining disposable objects across CLI jobs, without claiming that
the old caller was observed to leak or grow in memory.
`pixelHash` reads every active BGRA row (1814×1142×4 = 8,286,352 bytes), not a sparse
sample. It runs twice before stream setup for the two inputs and once after the
run for the last output, never per job or during either measured phase. B's
`actualHz` includes serial trace reads, caller-pool draining, cancellation checks,
thermal/progress work and loop overhead. No pacing sleep does not mean 100% GPU
utilization; initial/final image hashes are outside its phase denominator.

The final JSON keeps separate `baseline` and `measurement` phase bounds, every
push, complete root scalar observations, and approximately one thermal-state
sample per second on the same serial loop. Missed thermal sample slots are
reported rather than backfilled. All phase/wall/target/thermal nanoseconds share
`DispatchTime.uptimeNanoseconds`; raw trace host ticks retain their recorded mach
timebase. GPU/kernel timestamps are exported as reported, with validity/coverage
bits. GPU residency is not GPU active cycles. Repeated roots retain their original
identity and observation sequence; the analysis keeps the latest observation.
Storage limits are 20,000 pushes and 300,000 root observations; overflow stops
with the observed prefix retained, never silently truncates a successful run.

Status and exit codes: `complete`/0, `baseline_not_ready`/3, `cancelled`/4,
`calibration_failed`/5, `failed`/1. CLI errors return 2 before model/output initialization. Existing result
files are never overwritten. A cancellation marker stops before the next push;
an in-flight synchronous push is allowed to return and its roots are preserved.

`analyze.py --arm-a A.json --arm-b B.json --output review.json` is a CPU-only
consumer. Formal bins are half-open complete one-second intervals from
measurement start, assigned by push start. Arm A needs at least 12 valid jobs per
bin; B needs 10. A burst needs five consecutive valid bins whose GPU-root-union
median is at least twice that arm's valid prefix GPU-union p50. Historical wall
18.1323335 ms is not a GPU baseline. Unknown/low-count bins break continuity; wall
and GPU measures are reported side by side, without subtracting them.

For the one gap-fill diagnostic, explicitly set
`ODF_AIR_GAP_FILL_DIAGNOSTIC=1` (default off). Only `paced24` is accepted; 180 seconds
is the current contract, while 600 seconds is available for a separately
authorized follow-up without changing the binary. Nothing starts that follow-up
automatically. The same explicitly selected `MTLDevice` is passed into RIFE and
used for the independent fill queue and private 256 KiB scratch; registry ID is
recorded. The fill kernel has 65,536 threads and no model-resource access.

After warm20, a separate calibration runs exactly five pilot CBs at 256 iterations.
Their valid GPU-duration median determines one conversion to a 1 ms target,
rounded to nearest (ties away from zero); out-of-range iterations fail rather
than clamp. Five validation CBs use that one converted value. A median outside
the inclusive [0.5, 2] ms range returns `calibration_failed`, with no retuning.
Calibration records are separate from all prefix/formal samples. Prefix5 and the
formal phase both enable fill; the real-push wall gate remains strictly <36.264667ms.

Fill is submitted only in existing paced waiting intervals, at most one CB in
flight. At nextTick−3ms no new fill may be committed. A commit bracket crossing
that boundary is `crossed_unknown`; there is no extra predicted-GPU-time margin.
An unfinished fill never makes the caller wait in front of a real tick. Its ID,
pre-push status observation and the unchanged real lateness/skipped slots are
preserved. The final remaining fill may be waited for only after all phase clocks.

`gapFill.calibration.records` and `gapFill.fills` retain all fill commit/GPU/status
scalars. GPU duration is CB residency, not active cycles or a frequency reading.
Fill IDs and accounting include calibration; missing timestamps retain validity
bits and never masquerade as zero GPU work. The one-million-record limit stops
before another commit and retains the observed prefix. Model `roots` still only
come from RIFE's context; fill never uses that trace helper. Coverage is an
analysis-time union of real and non-calibration fill GPU intervals, including
their actual overlaps, rather than an added utilization claim. Its GPU-clock
coverage bins are separate from CPU-clock burst bins. The frozen coverage/1.3×
GPU-median/5-bin burst criteria are interpreted by `analyze_gap_fill.py`.

Analyze an existing recording without launching the native executable:

```sh
python3 -B Experiments/AirSustainedCost/analyze_gap_fill.py \
  --input native.json --environment coordinator-state.json --output review.json
```

The report keeps CPU-clock burst bins and GPU-clock coverage bins separate.
Insufficient coverage is inconclusive and stops the diagnostic; it does not
authorize retuning or the 600-second follow-up. Overall coverage cannot replace
the required fraction of passing complete bins.

Portable packaging must retain the executable, all adjacent SwiftPM resource bundles,
including the executable's separate `gap-fill.metallib` bundle,
the explicitly hashed original model, licences and generated origin manifests.
The coordinator owns Air execution, idle/cooldown/session checks and packaging.

The coordinator reads frozen paths/hashes from its explicit JSON configuration.
It waits for this project's last GPU process to end plus 300 seconds and for
HID idle/session/display checks; this does not assert whole-machine GPU silence.
It records beginning/end display and CPU-process observations, keeps all failed
prefixes, and permits at most three prefixes within 30 minutes per arm. Only a
clear `baseline_not_ready` can retry after a full cooldown; formal failure,
user/session changes and `helper_error` stop that arm. Existing coordinator or
native results refuse replay. The preflight helper also refuses existing output
paths, so every call has a fresh path and its full record is retained in JSONL.
Trial preference files are only hashed; the original App is never stopped.

Paced phase completion accounts for every planned tick as a launch or skip.
An otherwise complete final idle tail shorter than one tick is reported without
inventing an additional full analysis bin. Actual phase bounds, skipped slots,
partial tails and all sample thresholds remain explicit.
