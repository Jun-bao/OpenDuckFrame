# OpenDuckFrame agent entry

OpenDuckFrame is a native Apple silicon Mac player with window, display and file enhancement.
This repository owns the Mac app, shared media code, platform adapters and release tooling.
The mobile directory is planning material. Production website work belongs to its separate repository.

## Load context by task

Read this file, the AGENTS.md files along the selected task path, then the source needed for the task.
Follow additional links when the task crosses that boundary. Avoid loading all experiments or history.
Commands in these instructions run from the repository root unless stated otherwise.

| Task | Next entry |
| --- | --- |
| Mac targets, resources, Quick Look, captions host | [Apps/Mac/AGENTS.md](Apps/Mac/AGENTS.md) |
| Player or enhancement workbench interaction | [Apps/Mac/UI/AGENTS.md](Apps/Mac/UI/AGENTS.md) |
| Live capture, source geometry, enhancement adapters | [Apps/Mac/Capture/AGENTS.md](Apps/Mac/Capture/AGENTS.md) |
| Playback, decoding, subtitle logic | [Modules/AGENTS.md](Modules/AGENTS.md) |
| Frame scheduling, generation, file scaling | [Modules/VideoEnhancement/AGENTS.md](Modules/VideoEnhancement/AGENTS.md) |
| Mac rendering or audio output | [Platform/macOS/AGENTS.md](Platform/macOS/AGENTS.md) |
| Builds, checks, packaging automation | [Scripts/AGENTS.md](Scripts/AGENTS.md) |
| Dependencies, patches, model provenance | [ThirdParty/AGENTS.md](ThirdParty/AGENTS.md) |
| Updates, release notes, distribution | [Distribution/AGENTS.md](Distribution/AGENTS.md) |
| Icons and brand assets | [Design/AGENTS.md](Design/AGENTS.md) |
| User guides or performance claims | [docs/AGENTS.md](docs/AGENTS.md) |
| Controlled model or performance research | [Experiments/AGENTS.md](Experiments/AGENTS.md) |
| Website changes | [Website/AGENTS.md](Website/AGENTS.md) |

The general ownership map is [REPOSITORY_LAYOUT.md](REPOSITORY_LAYOUT.md).
Contribution and release requirements live in [CONTRIBUTING.md](CONTRIBUTING.md) and [RELEASING.md](RELEASING.md).

## Product boundaries

Processing is local. Preserve user media, source permissions, profiles and playback state.
The visible frame-generation choice is ODF-VFI, the four-stage structural reduction of RIFE 4.25 using upstream weights without retraining. The internal `rife-v4.25` profile and resource identifiers remain for compatibility. Existing backend and experiment code has a wider scope.
Automatic hardware/configuration detection is deferred. Keep new recommendations or automatic tuning within an explicit task.
Preserve internal SP symbols and existing interfaces unless the task calls for their migration.

## Git collaboration

Fetch and inspect the current target branch before development. Use the remote default branch when none is specified.
Protect dirty files and concurrent work, and develop on a task branch based on the current remote baseline.
Coordinate changes across app, capture, shared interfaces, resources and build definitions.
Stage only task files, inspect the exact diff, and refresh the remote baseline before opening a PR.
Human review and merge are the default. Merge only when the current task explicitly authorizes it.
Keep generated projects, app bundles, media fixtures, credentials and local logs out of commits.
Keep personal paths and machine-specific policies outside this shared repository.

## Verification and handoff

Use current source and script behavior to resolve stale documentation or graph-index results.
Run checks appropriate to the change and retain the first failure and any unverified conditions.
For repository/documentation changes, start with `./Scripts/check_public_repo.sh` using the tool environment in CONTRIBUTING.md.
For code, select relevant tests and build checks through the child instructions.
Verify native UI changes in the real app, including affected source types and window sizes.
Distinguish source checks, compilation, bundle verification, native interaction and sustained visual/performance acceptance.
Report the source revision, changed behavior, checks actually run, artifacts and remaining gaps.

## One installed app

The standard installation and normal use entry is `/Applications/OpenDuckFrame.app`.
Its canonical main bundle ID is `app.openduckframe.OpenDuckFrame`.
Keep diagnostic copies isolated to the active task, then close, unregister and recoverably remove them before handoff.
The current Release build deploys and registers a repository-root app and Quick Look extension.
Reconcile that build side effect with the standard installation before handoff.
At delivery, verify the installed path, running PID/executable, version/build and LaunchServices/Quick Look registrations.
Remove extra app copies and registrations only within the authorized cleanup scope, preserving source, settings and logs.
