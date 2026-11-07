# Local experiment comparison

This is a private trial surface for comparing existing candidates, not a new
quality or performance certification. Normal builds keep their existing UI
and models. Trial preferences and profile files are separate from the normal
player, and the two trial configurations have separate instance locks.

Open **Compare Options** in the workbench sidebar. The five controls are:

| Control | What changes | Combination |
| --- | --- | --- |
| Data transfer optimization | GPU edge padding and direct output crop, or their CPU reference | Can combine with either model and either blending rule |
| Fine-tuned model | P04 terminal version 1 or 2, using the original dense graph | Replaces the low-rank choice; initially selects the original experiment's replacement-mask rule |
| Low-rank model | Product r32/r16 response-weighted initial weights or trained weights | Replaces the fine-tuned choice; initially selects accumulated masks |
| Frame blending rule | Replace the mask at each stage, or accumulate it | Can be changed independently; a new combination is not covered by an old quality result |
| Optimized build | Start the separately compiled Release or Debug trial app | Restarts the trial application; does not pretend to change compiler flags in place |

Changing controls 1–4 stops enhancement, saves the selection, and chooses
RIFE 4.25 with the streaming entry point. The source, quality tier, output
size and target rate are retained. Click **Start Enhancement** to apply the
new selection. **Turn off options 1–4** restores the original dense model,
CPU I/O and accumulated masks. The current compiler configuration remains
visible. Switching builds shares trial selections and saved trial profiles;
media playback sessions are not transferred between processes.

## Build the local pair

Use `Scripts/build_experiment_trial.py --help`. Prepare the existing pinned
dependencies first. A private schema-1 JSON manifest supplies `models`, each
with `id`, `file_name`, `source_path`, `sha256`, `graph_id`, `mask_update` and
`description`. The four model IDs are `finetune-a`, `finetune-b`,
`lowrank-initial` and `lowrank-trained`. Source paths and raw weights do not
belong in the repository. The packager verifies hashes and embeds only the
model metadata and model files in the local trial apps.

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
  python3 Scripts/build_experiment_trial.py \
  --assets-manifest /private/path/assets-input.json --skip-dependencies
```

The default output is `.build/ExperimentComparison/{Debug,Release}/OpenDuckFrame.app`.
Keep those two directories together for the build-switch button. The script
does not deploy the root application, register Quick Look, or configure the
normal update feed. Each configuration has its own build log, model hashes,
code-signing verification and same-source identity in the output manifest.

## Verification

`Scripts/test_rife_experiment_selection.sh` checks persistence of all model,
I/O and blending choices and the trial/normal instance namespaces without
running a model. `Scripts/test_workbench_store.sh` covers profile storage.
`Experiments/TrialPresets/runtime_smoke.py` exercises the actual runtime on
small synthetic frames under an explicit GPU lock. It checks all model and
option combinations, output dimensions, API paths, I/O pixel equality and
that changing models/masks really changes output. Those checks do not judge
motion quality, perceptibility, application FPS, or deadline reliability.

## 中文使用说明

在工作台左下打开“方案对比”。①数据搬运优化可以与②微调模型或③低秩模型组合；
②③只能选一个，且各有两个版本。④画面融合规则可以独立调整。⑤优化构建会重启到
另一份真正独立编译的试用应用，Debug 与 Release 文件夹需保持同级。

调整前四项后，增强会停止，回工作台点击“开始增强”应用。来源、尺寸、画质档位和
目标帧率保持；新组合的效果由实际观看判断，不沿用其他组合的旧成绩。
试用配置与正式版分开，不替换正式应用，也不发布或合并。
