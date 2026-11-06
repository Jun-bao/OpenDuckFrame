# RifeMetal runtime sources

Run `Scripts/prepare_rife_runtime.sh` from any directory. It verifies the
archive pinned in `ThirdParty/deps.lock.json`, applies `stream-io.patch`, and
atomically prepares a library-only Swift package in `runtime/`. Preparation
does not compile code or use the GPU. Repeated calls reuse a matching recipe
stamp; recipe inputs include the complete dependency lock and the local
package, patch, helper, and license files.

The upstream baseline is `cinemore/rife-metal` 0.1.8 at
`ac6408022eb6bc1a53181f5b2716a9f5ded507c2`. Its two library targets and
`CompileMetalShaders` plugin are retained. The upstream CLI, tests, and
`swift-argument-parser` dependency are excluded from the generated package.

The production patch changes stream IO only:

- IOSurface-backed BGRA inputs use GPU edge replication on the original
  padded grid. RGBA and other input buffers retain the CPU padding path.
- Fast and Balanced allocate caller-visible output dimensions and use the
  existing cropped final GPU writer. The into-buffer API keeps its original
  BGRA/IOSurface guard and CPU crop fallback.

`PaddedFrameConvert.swift` and `PaddedFrameConvert.metal` are the canonical
helper sources, also used by the experiment harness. The internal padded
dimensions, downsample sampler, IFNet, accumulated mask, original weights,
cache rotation, timesteps, and fallback behavior are retained. Experimental
fusion, tail trimming, graph variants, training, and diagnostic options are
not included in the generated runtime.

`runtime/source-origin.json` records the upstream commit/version and hashes
of the patch, helpers, patched Swift files, package manifest, original model,
and license notices. It contains no local machine paths. The upstream
[Apache-2.0 license](LICENSE) and [Practical-RIFE MIT notice](THIRD-PARTY.md)
are preserved in this directory and in the generated package.
