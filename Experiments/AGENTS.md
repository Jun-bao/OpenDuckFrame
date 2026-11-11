# Controlled research

These directories contain independently scoped diagnostics, model trials and training work.
Start with the README of the specific experiment named by the task.
The shipping app's visible configuration is defined in [Apps/Mac/UI](../Apps/Mac/UI/AGENTS.md).
Runtime preparation and upstream provenance are covered by [ThirdParty](../ThirdParty/AGENTS.md).

## Execution boundary

A request to inspect or document an experiment authorizes reading its code and existing results.
Training, GPU runs, long benchmarks and diagnostic app copies need the current task's explicit scope and resource budget.
Keep baseline inputs, model hashes, resolution, quality, IO/cache mode, clocks and attempt limits fixed for comparisons.
Respect experiment-owned cancellation, cooldown and lock mechanisms when running an authorized task.
Preserve existing results and failures; choose fresh output locations as required by the experiment.
Preparation, CPU-only identity checks, GPU inference and real app playback establish different facts.

## Artifact and product boundary

Keep datasets, model outputs, training checkpoints and raw local logs outside tracked source.
Retain source/model hashes, build identity, parameters, timing definitions and denominators with results.
An experiment's private backend or model option does not become an ordinary workbench feature automatically.
Old Air-specific measurements and simulated timings apply only to their recorded conditions.
Promoting a result into the product requires an explicit implementation task and normal-entry verification.
Diagnostic app copies must follow the root installation rule and be cleaned up at the end of their authorized task.
App/registration cleanup preserves source trees, settings, checkpoints and logs.
