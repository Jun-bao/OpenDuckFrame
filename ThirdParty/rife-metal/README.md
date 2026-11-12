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

The stream patch changes IO:

- IOSurface-backed BGRA inputs use GPU edge replication on the original
  padded grid. RGBA and other input buffers retain the CPU padding path.
- Fast and Balanced allocate caller-visible output dimensions and use the
  existing cropped final GPU writer. The into-buffer API keeps its original
  BGRA/IOSurface guard and CPU crop fallback.

`PaddedFrameConvert.swift` and `PaddedFrameConvert.metal` are the canonical
helper sources, also used by the experiment harness. The internal padded
dimensions, downsample sampler, IFNet, accumulated mask, original weights,
cache rotation, timesteps, and fallback behavior are retained by this patch.

The shipping default is **ODF-VFI**, the four-stage accumulated-mask graph
`odf-ifnet425-fourstage-acc-v1`, derived from Practical-RIFE 4.25. Preparation
verifies the pinned original weights, then `Scripts/derive_fourstage_model.py`
removes block4 and writes the canonical RMW2 header. The encoder and retained
four blocks are byte-identical to the original; no additional training is
applied. `production-model.json` pins both source and evaluated output hashes.
The output must reproduce SHA-256
`729ea555016da98e207bc4570e0be81dddbbd37302f7330c89696da798fba22d`.
The resource filename and profile ID remain `rife-v4.25` for compatibility;
the loaded model metadata identifies the four-stage graph. This structural
reduction does not imply lossless quality for every scene.

`experiment-options.patch` and the repository-owned option/graph-contract
helpers add immutable per-interpolator trial options. The default keeps GPU
I/O enabled and accumulated masks. An explicit configuration can use the CPU
I/O reference or replace masks instead, and can load the canonical accumulated
r32/r16 RMW2 graph. RMW1 and the original 4.25/4.26 weights retain their loader.
The normal application does not expose these choices; only a locally packaged
comparison app marked `ODFExperimentTrial` provides the comparison panel.
Experimental warp fusion, tail trimming and training are not enabled here.

`runtime/source-origin.json` records the upstream commit/version and hashes
of the patch, helpers, patched Swift files, package manifest, original model,
and license notices, including the production model derivation and the experiment patch and
helpers. All are included in the preparation recipe hash. It contains no
local machine paths. The upstream
[Apache-2.0 license](LICENSE) and [Practical-RIFE MIT notice](THIRD-PARTY.md)
are preserved in this directory and in the generated package.
