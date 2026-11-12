# Dependency sources and provenance

[deps.lock.json](deps.lock.json) pins archives, source versions, hashes and patch inputs.
[Licenses](Licenses/) and [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) record attribution.
Read [rife-metal/README.md](rife-metal/README.md) before runtime or stream-IO work.
Dependency recipes live under [Scripts](../Scripts/AGENTS.md).

## Edit the authoritative inputs

Change the lock, repository-owned patches/helpers and their recipe inputs together when the task requires a dependency update.
Preserve upstream licensing, model provenance and original-weight hashes.
Keep downloaded sources, built libraries and generated runtime directories out of commits.
Treat preparation stamps as hashes of the recipe and toolchain; an existing output alone does not prove it matches.
`Scripts/patches/README.md` records the behavior required from downstream FFmpeg patches.
Removing a patch requires equivalent behavior from the newly locked dependency and relevant regression evidence.

## RIFE runtime

`./Scripts/prepare_rife_runtime.sh` verifies the pinned archive and prepares the library-only runtime package.
It can fetch sources and replace generated runtime output; preparation itself does not compile or run GPU work.
The generated `runtime/source-origin.json` records source and helper hashes.
Edit repository-owned inputs instead of the generated runtime copy.
The normal app uses ODF-VFI with continuous caching enabled by default. Its four-stage graph and weight provenance are pinned in [production-model.json](rife-metal/production-model.json); the `rife-v4.25` resource and profile IDs remain for compatibility.
Experimental graph/IO helpers require a separately scoped experiment and matching provenance.
When packaging models or runtimes, retain their required notices and validate the actual loaded identity.
