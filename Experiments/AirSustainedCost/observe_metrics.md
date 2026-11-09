# Rootless metrics observer integration

The coordinator optionally adds the `observe_metrics.py` sidecar and a separate
CPU analysis step. Existing native/model sources, filler code, frozen binaries
and old evidence remain untouched. The coordinator owns all native parameters,
HID/cooldown/session checks and single-run limits. Original A/B observation uses
the original native binary and model with both filler modes disabled.

Set `metrics_observer` in the arm configuration to the object passed below.
Without it, the existing native-only path remains available. A sampler failure
before native launch prevents that launch; a failure afterward preserves the
single native run and ends the arm as `observation_incomplete`, without a retry.

```python
observer = MetricsObserver({
    "binary_path": "/ABS/macmon",
    "source_receipt_path": "/ABS/source-receipt.json",  # optional, read-only
    # "source_receipt_sha256": "...",                 # optional exact receipt
    # "expected_uid": actual_session_uid,              # optional runtime check
}, attempt_dir)
observer.start()
# Existing one-second coordinator loop: helper checks, observer.poll(),
# observer.clock_if_due(). No added high-frequency reader thread.
observer.ready_for_native(minimum_lead_seconds=10)
observer.mark_native_started(pid=native_pid)
# Keep the same one-second loop throughout the unchanged native invocation.
observer.mark_native_finished(returncode=native_returncode)
observer.stop_after_native(post_seconds=10)
# For a pre-roll/Popen refusal: observer.abort(reason), without fake native times.
# observer.close() is an idempotent final cleanup; only its own sampler PID is stopped.
```

Normal mode requires a non-root effective user (optionally matching runtime
`expected_uid`) and exact macmon0.11 SHA28f8d2b5… . It launches once with
`pipe --samples 0 --soc-info --interval 1000`, forcing `MACMON_FORCE_CLPC=1`.
There is no sudo, service, permission/power change, fallback or sampler restart.
Lead begins with the first usable sample after the discarded first valid sample,
which is conservative relative to first valid receipt. Normal lead and post-roll
must each be at least10 seconds. Limits are3,600 samples,65,536 bytes per stdout
line,2MiB stderr,10,000 events and3,600 seconds per sampler. Bounds stop only the
owned sampler. Observer errors after native start remain observational failures;
they never delete, rewrite or cancel native results.

Each attempt gets a fresh `metrics/` directory; replay refuses existing output.
Files: `metadata.json`, `samples.jsonl`, `events.jsonl`, `anchors.jsonl`,
`stdout.raw`, `stderr.raw`. Raw stdout/stderr bytes and full source JSON are kept.
The sample envelope records original timestamp spelling and exact epoch ns,
parent receive monotonic/UTC ns, line/sample sequence, discard and validity.
`payload` is the complete macmon object, preserving GPU,CPU tiers,power,temperature,
memory and SoC information. Stderr stays separate and does not invalidate good
JSON merely by existing. Malformed/missing core observations, EOF and bounds
preserve `first_error`; sample UTC gaps are events, never fabricated samples.

Every10 seconds (plus lifecycle endpoints), the observer reads:
`Python monotonic before → mach_absolute_time before → UTC time_ns → mach after →
Python monotonic after`. It records raw mach ticks, timebase numer/denom and
explicit converted ns, alongside Python clock implementation/resolution/units.
`native_start`/`native_end` metadata hold monotonic/UTC stamps and their PID/exit.
No `DispatchTime.rawValue` is treated as elapsed ns and no clock offset is assumed0.

Analysis aligns source UTC through these mach brackets. Receive times diagnose
polling/buffering delay only; that delay is not added to alignment uncertainty.
The frozen uncertainty is the nominal sample's ±1s plus bracket error. Adjacent
anchor UTC-relative-mach changes>50ms are unknown in the separate analyzer.
Samples describe aggregate whole-SoC/host estimates and active-state residency,
not shader utilization, per-process energy, or formal product power acceptance.

CPU-fake checks use the same wrapper with an explicit private Python child
instead of macmon, short test-only time limits, real local clock reads and no
model/GPU invocation. Run `test_observe_metrics.py --output-dir FRESH_PRIVATE_DIR`.
The normal coordinator never sets those private test hooks.

After both arms finish, analyze their existing files without starting a sampler
or model:

```sh
python3 -B Experiments/AirSustainedCost/analyze_observed_comparison.py \
  --arm-a /ABS/A/attempt-01/native.json \
  --arm-b /ABS/B/attempt-01/native.json \
  --output /ABS/NEW-comparison.json
```

The default observer input is each native file's sibling `metrics/` directory;
the environment input is `coordinator-state.json` above its attempt directory.
Explicit `--observer-a/b` and `--environment-a/b` paths are also supported.
Frequency comparisons use equal-time CPU bins, require the frozen minimum
windows and at most10% missing observations, and report descriptive consistency
only. Native throughput remains separate from application playback FPS.

## Resident keepalive diagnostic

`resident_keepalive_enabled: true` selects the separately compiled native
keepalive diagnostic. It requires `metrics_observer`, paced24/180 and both older
filler modes disabled. The original model and Core metallib remain unchanged;
the new executable includes `native/ResidentKeepAlive.swift`. Its environment
flag is `ODF_AIR_RESIDENT_KEEPALIVE_DIAGNOSTIC=1`, defaulting to0.

The independent queue dispatches one threadgroup with
`pipeline.threadExecutionWidth` threads per command buffer. At most2 CBs share
one tracked private scratch buffer. After model warmup, five pilot CBs, one
iteration conversion and five validation CBs freeze a roughly1ms workload.
The worker covers the separate prefix and formal phases without adding any
admission check or wait to real pushes; cleanup drains it after phase timing.
Its errors, timestamps and actual CB durations remain in `residentKeepAlive`;
`diagnosticInvalid` prevents treating an asynchronous failure as a valid result.

The1814×1142 geometry is a mechanism diagnostic. Application acceptance must
separately record actual capture, model processing and presentation geometry;
it cannot infer the user's original-window performance from this native run.

Analyze a settled keepalive run with a manifest frozen before the data is read:

```sh
python3 -B Experiments/AirSustainedCost/analyze_keepalive.py \
  --input /ABS/attempt-01/native.json \
  --manifest /ABS/analysis-manifest.json \
  --output /ABS/NEW-keepalive-review.json
```

The manifest pins the new executable, original model, observer helper,
configuration and source/resource evidence. This analysis uses its own native
identity check rather than treating the new executable as the old A/B binary.
Optional `--reference-facts` adds descriptive power comparisons with frozen old
facts. It does not start another measurement or alter the acceptance gates.
