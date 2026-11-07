import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image


SPEC = importlib.util.spec_from_file_location("student_data", Path(__file__).parents[1] / "data.py")
data = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(data)


class DataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.data_root = self.root / "old-run" / "data"
        source = {
            "source_index": "https://example.invalid/originals/", "sequences": [], "frames": [],
            "protocol": {
                "clips": list(data.TRAIN_CLIPS + data.EVALUATION_CLIPS),
                "source_fps": [50, 1], "frame_geometry": [4, 3],
                "sampling": "four five-frame windows; original frame indices retained",
                "rgb_quantization": "original RGB8 PNG", "color": "test RGB",
            },
        }
        self.design = {
            "calibration_clips": list(data.TRAIN_CLIPS), "diagnostic_clips": list(data.EVALUATION_CLIPS),
            "calibration_blocks": [0, 2], "diagnostic_blocks": [0, 2],
            "alphas": list(data.ALPHAS), "cases": [],
        }
        for clip_number, clip in enumerate(data.TRAIN_CLIPS + data.EVALUATION_CLIPS):
            directory = self.data_root / clip
            directory.mkdir(parents=True)
            source["sequences"].append({
                "name": clip, "url": f"https://example.invalid/{clip}.y4m", "frame_count": 500,
                "header": "YUV4MPEG2 W4 H3 F50:1 Ip A1:1\\n", "fields": {"F": "50:1"},
            })
            for block, start in enumerate((62, 186, 309, 433)):
                frames = []
                for index in range(start, start + 5):
                    path = directory / f"frame{index:04d}.png"
                    Image.new("RGB", (4, 3), (clip_number * 40, index % 256, 100)).save(path)
                    source["frames"].append({
                        "sequence": clip, "index": index, "timestamp_seconds": index / 50,
                        "png": str(path), "png_sha256": data.sha256(path), "raw_sha256": "test-raw-hash",
                    })
                    frames.append(str(path))
                if block in data.BLOCKS:
                    self.design["cases"].append({
                        "id": f"{clip}-b{block}", "clip": clip, "block": block,
                        "partition": "calibration" if clip in data.TRAIN_CLIPS else "diagnostic",
                        "frames": frames, "frame_sha256": {name: data.sha256(name) for name in frames},
                    })
        source_path = self.data_root / "manifest.json"
        source_path.write_text(json.dumps(source))
        self.source_path = source_path
        self.design["dev_manifest_sha256"] = data.sha256(source_path)
        self.run_path = self.data_root.parent / "manifest.json"
        self.run_path.write_text(json.dumps({"artifacts": [{
            "path": str(source_path), "sha256": self.design["dev_manifest_sha256"],
        }]}))
        self.design_path = self.root / "design.json"
        self.save_design()
        self.output = self.root / "new-run" / "data-manifest.json"

    def save_design(self):
        self.design_path.write_text(json.dumps(self.design))

    def test_freeze_uses_only_adjacent_training_pairs_and_fixed_diagnostics(self):
        # An unopened marker in the data root stands in for unrelated/holdout data.
        (self.data_root / "unrelated-holdout").mkdir()
        touched = []
        original_open = Path.open

        def bounded_open(path, *args, **kwargs):
            self.assertNotIn("unrelated-holdout", path.parts)
            touched.append(path)
            return original_open(path, *args, **kwargs)

        with patch.object(Path, "open", bounded_open):
            manifest = data.build_manifest(self.design_path, self.output)
        self.assertEqual(manifest["counts"], {
            "training_clips": 3, "evaluation_clips": 2, "training_pngs": 60,
            "evaluation_pngs": 20, "train_pairs": 48, "calibration_pairs": 6,
            "evaluation_queries": 12, "hashed_original_pngs": 80,
            "distillation_evaluation_queries": 48,
        })
        self.assertEqual(manifest, json.loads(self.output.read_text()))
        for pair in manifest["train_pairs"]:
            self.assertIn(pair["clip"], data.TRAIN_CLIPS)
            self.assertEqual(pair["second_index"] - pair["first_index"], 1)
            self.assertEqual(pair["delta_seconds"], 0.02)
        self.assertEqual({(p["clip"], p["first_index"]) for p in manifest["calibration_pairs"]},
                         {(clip, start) for clip in data.TRAIN_CLIPS for start in (62, 309)})
        self.assertTrue(set(p["id"] for p in manifest["calibration_pairs"])
                        <= set(p["id"] for p in manifest["train_pairs"]))
        self.assertEqual(manifest["calibration"]["teacher_response_queries"], 18)
        self.assertEqual({(p["case_id"], p["alpha"]) for p in manifest["evaluation"]},
                         {(f"{clip}-b{block}", alpha) for clip in data.EVALUATION_CLIPS
                          for block in data.BLOCKS for alpha in data.ALPHAS})
        for row in manifest["evaluation"]:
            self.assertEqual(row["delta_seconds"], 0.08)
            self.assertEqual(row["baseline_fps"], 12.5)
            self.assertEqual(row["gt_index"], row["first_index"] + int(row["alpha"] * 4))
        selection = manifest["distillation_evaluation"]
        self.assertEqual(len(selection), 48)
        self.assertEqual(len({row["id"] for row in selection}), 48)
        self.assertEqual({row["clip"] for row in selection}, set(data.EVALUATION_CLIPS))
        self.assertEqual({row["alpha"] for row in selection}, set(data.ALPHAS))
        self.assertEqual(len({(row["first"], row["second"]) for row in selection}), 16)
        for row in selection:
            self.assertEqual(row["second_index"] - row["first_index"], 1)
            self.assertEqual(row["delta_seconds"], 0.02)
            self.assertEqual(row["baseline_fps"], 50)
            self.assertFalse(any(key.startswith("gt") for key in row))
        self.assertEqual(manifest["train_evaluation_overlap_groups"], [])
        self.assertFalse(manifest["independent_holdout_accessed"])
        self.assertFalse(manifest["full_source_videos_assumed_available"])
        self.assertEqual(manifest["input_hashes"][str(self.design_path)], data.sha256(self.design_path))
        # The other diagnostic windows are not hashed or opened by the builder.
        for clip in data.EVALUATION_CLIPS:
            self.assertNotIn(self.data_root / clip / "frame0186.png", touched)

    def test_missing_noncalibration_frame_does_not_bridge_the_gap(self):
        (self.data_root / "park_joy" / "frame0188.png").unlink()
        manifest = data.build_manifest(self.design_path, self.output)
        self.assertEqual(len(manifest["train_pairs"]), 46)
        self.assertFalse(any(p["first_index"] == 187 and p["second_index"] == 189
                             for p in manifest["train_pairs"]))

    def test_v2_derivation_preserves_old_freeze_without_reopening_pngs(self):
        original = data.build_manifest(self.design_path, self.output)
        # Reproduce the original schema-1 artifact, before selection rows existed.
        original.pop("distillation_evaluation")
        original.pop("distillation_evaluation_protocol")
        original.pop("evaluation_usage")
        original["counts"].pop("distillation_evaluation_queries")
        original["schema_version"] = 1
        self.output.write_text(json.dumps(original))
        frozen_bytes = self.output.read_bytes()
        v2_path = self.output.with_name("data-manifest-v2.json")
        original_open = Path.open

        def no_png_open(path, *args, **kwargs):
            self.assertNotEqual(path.suffix, ".png")
            return original_open(path, *args, **kwargs)

        with patch.object(Path, "open", no_png_open), patch.object(Image, "open", side_effect=AssertionError("PNG reopened")):
            derived = data.derive_manifest(self.output, v2_path)
        self.assertEqual(self.output.read_bytes(), frozen_bytes)
        self.assertEqual(derived["train_pairs"], original["train_pairs"])
        self.assertEqual(derived["calibration_pairs"], original["calibration_pairs"])
        self.assertEqual(derived["evaluation"], original["evaluation"])
        self.assertEqual(derived["file_sha256"], original["file_sha256"])
        self.assertEqual(derived["inventory"], original["inventory"])
        self.assertEqual(len(derived["distillation_evaluation"]), 48)
        self.assertFalse(derived["derivation"]["original_pngs_reopened"])
        self.assertEqual(derived["provenance"]["manifest_builder_source"]["sha256"], data.sha256(data.__file__))
        with self.assertRaises(FileExistsError):
            data.derive_manifest(self.output, v2_path)

    def test_rejects_unknown_partition_before_reading_source_paths(self):
        self.design["calibration_clips"][0] = "unrelated-holdout"
        self.save_design()
        with self.assertRaisesRegex(ValueError, "three fixed"):
            data.build_manifest(self.design_path, self.output)
        self.assertFalse(self.output.exists())

    def test_rejects_changed_original_png(self):
        path = self.data_root / "park_joy" / "frame0062.png"
        Image.new("RGB", (4, 3), (255, 255, 255)).save(path)
        with self.assertRaisesRegex(ValueError, "Original PNG hash changed"):
            data.build_manifest(self.design_path, self.output)
        self.assertFalse(self.output.exists())

    def test_rejects_missing_50hz_provenance(self):
        source = json.loads(self.source_path.read_text())
        source["sequences"][0]["fields"]["F"] = "25:1"
        self.source_path.write_text(json.dumps(source))
        digest = data.sha256(self.source_path)
        self.design["dev_manifest_sha256"] = digest
        self.run_path.write_text(json.dumps({"artifacts": [{"path": str(self.source_path), "sha256": digest}]}))
        self.save_design()
        with self.assertRaisesRegex(ValueError, "50 Hz header provenance"):
            data.build_manifest(self.design_path, self.output)
        self.assertFalse(self.output.exists())

    def test_refuses_existing_output_without_reading_design(self):
        self.output.parent.mkdir()
        self.output.write_text("preserve this file")
        with self.assertRaises(FileExistsError):
            data.build_manifest(self.root / "missing-design.json", self.output)
        self.assertEqual(self.output.read_text(), "preserve this file")

    def test_load_rgb_returns_cpu_nchw_normalized_float32(self):
        import torch

        path = self.root / "rgb.png"
        Image.new("RGB", (2, 3), (0, 128, 255)).save(path)
        tensor = data.load_rgb(path)
        self.assertEqual(tuple(tensor.shape), (1, 3, 3, 2))
        self.assertEqual(tensor.dtype, torch.float32)
        self.assertEqual(tensor.device.type, "cpu")
        self.assertTrue(tensor.is_contiguous())
        self.assertEqual(tensor[0, 0, 0, 0].item(), 0)
        self.assertAlmostEqual(tensor[0, 1, 0, 0].item(), 128 / 255, places=7)
        self.assertEqual(tensor[0, 2, 0, 0].item(), 1)
        self.assertLessEqual(torch.get_num_threads(), 4)


if __name__ == "__main__":
    unittest.main()
