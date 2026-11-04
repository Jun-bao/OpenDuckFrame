# Process-local performance simulation

This diagnostic mode slows RIFE service time on its serial inference worker.
It applies to both stateless file inference and cached live inference. It is
off unless `ODF_PERF_PROFILE` explicitly selects a simulation profile. Closing
the process removes the setting; no preferences or system settings are written.

The real model still runs at the requested source size, quality and phases.
Its result is held on the worker before the completion callback, while the
provider remains busy. The simulated duration is also returned to the scheduler.
Source PTS, playback clocks, output requests and deadlines are not retimed.

This is a service-time/throughput envelope, **not an M1 Pro hardware emulator**.
It does not restrict physical GPU cores, memory bandwidth, total RAM, codec
hardware or display refresh. In particular, a 128 GB host does not become a
16 GB machine. It can reproduce slow-model backpressure and missed deadlines;
it cannot establish a particular customer's exact hardware bottleneck.

## Reference range, collected 2026-11-04

The supplied photo identifies a 14-inch 2021 M1 Pro with 16 GB, but not the
CPU/GPU core configuration. The model family spans 8–10 CPU cores, 14–16 GPU
cores and 200 GB/s advertised memory bandwidth. See the [Apple specification](https://support.apple.com/en-bh/111902)
and [Apple launch information](https://www.apple.com/newsroom/2021/10/apple-unveils-game-changing-macbook-pro/).

Public, user-submitted Geekbench 6 Metal examples provide an exploratory
starting range, not a RIFE benchmark or a population confidence interval:

| Reference | Version | Score |
| --- | --- | ---: |
| [M1 Pro, 8 CPU cores, 16 GB](https://browser.geekbench.com/v6/compute/6960614) | 6.7.1 | 65,589 |
| [M1 Pro, 8 CPU cores, 16 GB](https://browser.geekbench.com/v6/compute/6959946) | 6.6.0 | 66,811 |
| [M1 Pro, 10 CPU cores, 16 GB](https://browser.geekbench.com/v6/compute/6959119) | 6.7.1 | 71,462 |
| [M5 Max, 40 GPU cores](https://browser.geekbench.com/v6/compute/6078114) | 6.6.0 | 224,610 |

The M5 Max example divided by the M1 Pro examples is approximately 3.14–3.42.
The `m1pro-16` (3.2× time) and `m1pro-14` (3.5× time) profiles round this
reference range. The profile names indicate intended exploration, not verified
RIFE latency on those GPU variants. These presets assume a comparable M5 Max
host; on a different host, use measured service times or custom values.

RIFE uses [MPSGraph and Metal](https://github.com/cinemore/rife-metal), so a CPU
quota alone does not bound its inference throughput. A generic Metal score
also cannot be converted into guaranteed RIFE FPS. Use multiple slowdown
factors and explicit latency floors, then calibrate with a real RIFE trace
when one becomes available. The customer's 17.4 FPS is an observation to
compare against, not a value used to fit the presets.

## Run

After building the app containing this change:

```sh
Scripts/with_performance_simulation.sh m1pro-16 /path/to/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame
Scripts/with_performance_simulation.sh m1pro-14 /path/to/OpenDuckFrame.app/Contents/MacOS/OpenDuckFrame
ODF_PERF_MODEL_MIN_MS=120 Scripts/with_performance_simulation.sh custom COMMAND ARGS
Scripts/with_performance_simulation.sh off COMMAND ARGS
```

The normal single-instance rules still apply to GUI launches. The automated
probe loads the app code into its own headless process, without opening or
replacing a running app.

| Variable | Meaning |
| --- | --- |
| `ODF_PERF_PROFILE` | `off` (default), `m1pro-16`, `m1pro-14`, or `custom` |
| `ODF_PERF_MODEL_SLOWDOWN` | Optional measured-task time multiplier, 1–20 |
| `ODF_PERF_MODEL_MIN_MS` | Optional minimum duration per model job, 0–2000 ms |

Each job's target duration is `max(actual worker time × slowdown, minimum)`.
This is per inference job, not per displayed frame. X2 normally generates one
midpoint per source pair; higher multipliers can produce multiple phases in
one job. No artificial delay is added to model preparation or failed stateless
inference. Live diagnostics include the delayed service time.

## Repeatable probe

```sh
Scripts/test_performance_simulation.sh
```

The script uses the existing Debug app/framework paths. They can be supplied
with `ODF_TEST_FRAMEWORKS_DIR`, `ODF_TEST_RESOURCE_APP`, and
`ODF_TEST_DEBUG_DYLIB`. `ODF_PERF_PROBE_FRAMES` defaults to 120.

The same 24 FPS SDR NV12 motion pattern is run at 1280×720 and 1920×1080, with
scaling off and RIFE 4.25 fast X2. Each size has an original-only baseline,
unrestricted RIFE, and both exploratory profiles. Controlled 20/60/120 ms copy
providers isolate generator timing from the GPU model. JSON records retain
total/original enqueue rate, provider service time, source count, maximum
original gap and accumulated playout lag. `emissionFPS` excludes held copies,
matching the production FPS meter; `enqueueFPS` includes every scheduled slot.
Repeated originals cannot count as additional generated pictures.

The regression checks require original and non-held output rates of at least
23 FPS for the 24 FPS source, less than 100 ms accumulated playout lag, and
at least 42 FPS output for the fast 20 ms control. Source counts and timestamp
order must also be preserved. Slow service is allowed to reduce generated
coverage, not stall the original stream.

The probe uses the production file generator with a paced enqueue sink and a
fixed four-slot runway. Its enqueue rates are **not physical display FPS**.
It does not exercise a decoder, audio synchronization, user GUI or capture.
The controlled copy providers validate timing only and make no image-quality
claim. Full customer reproduction still requires that customer's source,
application version and physical playback path.

## Playback deadline fix

File providers no longer wait indefinitely in the generator's emission worker.
Both queued and in-flight pairs wait only within the existing playout runway,
capped at one requested output interval with 2 ms reserved for handoff. Missing
that budget skips the pair's synthesis; its original and scheduled holds still
drain in order. A later completion cannot publish frames for a skipped pair.

Current-generation provider errors are still reported even when the originating
pair has already passed its deadline. Old-generation/old-policy results remain
ignored, and provider calls stay single-in-flight through seek and replacement.
The lifecycle regression uses a slow outstanding job followed by fast new jobs:
it requires original progress before completion, rejection of the retired
result, successful new-generation synthesis, and reporting a late engine error.

## Local follow-up after 0.1.2

The unpublished follow-up hands a scheduled original to the output queue before
waiting for its model result. The ring keeps its own retained buffer for model
input and comparison. An emitted-source flag prevents the same original from
being enqueued or returned to the decode thread twice during reset/interruption.
The synthesis deadline and late-result checks remain in place.

The timing probe records first source admission separately from the paced sink,
and reports P50/P95 lateness plus first-half/second-half P95 for longer runs.
The sink's 200 ms initial lead is a test fixture, not measured application
buffering or end-to-end display latency. Local comparisons must keep this lead,
source count, source pattern and model service time fixed.
