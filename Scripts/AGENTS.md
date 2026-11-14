# Build, validation and distribution automation

All commands below run from the repository root.
[Apps/Mac/Scripts/build.sh](../Apps/Mac/Scripts/build.sh) is the product build entry; [build.sh](build.sh) forwards arguments to it.
Build inputs and target configuration live in [Apps/Mac/project.yml](../Apps/Mac/project.yml).

## Choose an entry by task

- [check_public_repo.sh](check_public_repo.sh) runs source boundaries, shell syntax, resource, icon, localization and plist checks.
- [check_repo.py](check_repo.py) includes tracked and non-ignored new files in path/credential scans.
- [l10n.py](l10n.py) provides status, export/merge and `check --full` for localized strings.
- `test_*.sh` wrappers cover specific policies or integrations. Read the selected script for prerequisites and side effects.
- `test_screen_capture_permission.sh` and `test_window_permission_prompt.sh` cover the permission gate and denied-access refresh button without changing macOS privacy settings.
- [test_apple_live_size.sh](test_apple_live_size.sh) needs a built Debug app and Apple low-latency runtime support; it checks real inference and live activation without screen recording or physical presentation.
- `bash Scripts/test_low_latency_smoke_contract.sh` checks the low2k preparation predicate on CPU, including 720p and 1080p inference. The GPU smoke separately checks restored output and baseline geometry.
- [test_live_display_queue.sh](test_live_display_queue.sh) checks live display queue selection on CPU. [probe_apple_live_presentation.sh](probe_apple_live_presentation.sh) needs a built Debug app, an active graphical session and Apple low-latency support; it opens an owned window for 23 seconds and records actual presentation. Run GPU comparisons sequentially, with the same source profile and display conditions.
- [test_video_cadence.sh](test_video_cadence.sh) checks visible cadence estimation and rational retiming on CPU. The presentation probe's `auto24`/`auto25`/`auto30` profiles add a texture across sampling regions and corner animation, run for 26 seconds, and verify actual detection and pending-input release on stop. `source25` runs the same 25 FPS input with general timing.
- [verify_app_bundle.sh](verify_app_bundle.sh) checks a supplied packaged app and its manifest/dependency closure.
- [lib/build_common.sh](lib/build_common.sh) and [lib/deps_lock.py](lib/deps_lock.py) provide shared dependency/staging logic.
- [patches/README.md](patches/README.md) records downstream FFmpeg invariants.

## Side effects

`./Apps/Mac/Scripts/build.sh Release` deploys and registers a repository-root app and Quick Look copy.
`./Scripts/run.sh` builds and opens the Debug app. Choose these actions with the root installation rule in mind.
Reconcile authorized test copies and registrations with `/Applications/OpenDuckFrame.app` before handoff.
A script's successful return does not identify which existing process is running; verify its executable path and version/build.
Keep fresh output paths, transactional publication and recipe/stamp checks in scripts that create artifacts.
Preserve upstream hashes, patch inputs, cancellation and failure reporting when changing recipes.

## Release boundary

Read [RELEASING.md](../RELEASING.md) and [Distribution/AGENTS.md](../Distribution/AGENTS.md) before archive/export/notarization/publication work.
AppStore scripts use Xcode embedding/signing. The local ad-hoc bundler is a separate lane.
`community_release.py --publish` uploads assets and updates gh-pages; publishing needs current task authorization.
Keep signing keys and account credentials in their existing secure stores.
For script/document-only changes, run `./Scripts/check_public_repo.sh` with the documented check-tools Python environment.
