"""Offline packaging-contract tests. All build/signing subprocesses are mocked."""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "build_experiment_trial", Path(__file__).resolve().parents[1] / "build_experiment_trial.py"
)
trial = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(trial)


class TrialBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name).resolve()
        self.output = self.repo / "trial"
        self.weight = self.repo / "original.rmw"
        self.weight.write_bytes(bytes(range(256)))
        self.assets = self.repo / "private-input.json"
        self.row = {
            "id": "finetune-a", "file_name": "finetune-a.rmw",
            "source_path": str(self.weight), "sha256": trial.sha256(self.weight),
            "graph_id": "4.25", "mask_update": "accumulate", "description": "Fixture",
        }
        self.assets.write_text(json.dumps({"schema": 1, "models": [self.row]}))
        self.commands = []
        self.source = {"head": "fixture-head", "source_sha256": "fixture-source", "git_status": "", "file_count": 1}

    def arguments(self):
        return ["--repo", str(self.repo), "--output", str(self.output),
                "--assets-manifest", str(self.assets), "--skip-dependencies"]

    def fake_subprocess(self, command, **kwargs):
        self.commands.append(command)
        self.assertEqual(kwargs["env"]["ODF_ENABLE_SPARKLE"], "false")
        self.assertEqual(kwargs["env"]["ODF_SPARKLE_FEED_URL"], "")
        self.assertEqual(kwargs["env"]["ODF_SPARKLE_PUBLIC_ED_KEY"], "")
        if command[0] == "/usr/bin/xcodebuild":
            configuration = command[command.index("-configuration") + 1]
            app = self.output / configuration / "OpenDuckFrame.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Resources").mkdir()
            (app / "Contents/MacOS/OpenDuckFrame").write_bytes(configuration.encode())
            with (app / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleIdentifier": f"{trial.BUNDLE_PREFIX}.{configuration.lower()}",
                               "CFBundleName": "OpenDuckFrame", "CFBundleDisplayName": "OpenDuckFrame",
                               "CFBundleExecutable": "OpenDuckFrame", "SUFeedURL": "must-be-removed"}, stream)
        if command[0].endswith("/bundle_libs.sh"):
            # The signer must see the final Info.plist and sanitized, unchanged weights.
            app = Path(command[1])
            data = json.loads((app / "Contents/Resources/experiment-models.json").read_text())
            self.assertNotIn("source_path", data["models"][0])
            self.assertEqual(set(data["models"][0]), set(trial.MODEL_FIELDS))
            self.assertEqual((app / "Contents/Resources/ExperimentModels/finetune-a.rmw").read_bytes(), self.weight.read_bytes())
            with (app / "Contents/Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            self.assertIs(info["ODFExperimentTrial"], True)
            self.assertNotIn("SUFeedURL", info)
        return subprocess.CompletedProcess(command, 0)

    def invoke(self, runner):
        with patch.object(trial.shutil, "which", return_value="/fixture/xcodegen"), \
             patch.object(trial, "source_identity", return_value=self.source), \
             patch.object(trial.subprocess, "run", side_effect=runner), \
             redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return trial.main(self.arguments())

    def test_both_configurations_are_real_commands_and_packaged_before_signing(self):
        self.assertEqual(self.invoke(self.fake_subprocess), 0)
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["status"], "succeeded")
        self.assertEqual([row["configuration"] for row in manifest["packages"]], ["Debug", "Release"])
        builds = [command for command in self.commands if command[0] == "/usr/bin/xcodebuild"]
        for configuration, command in zip(("Debug", "Release"), builds):
            self.assertEqual(command[command.index("-configuration") + 1], configuration)
            self.assertEqual(command[command.index("-jobs") + 1], "4")
            self.assertIn(f"ODF_BUNDLE_ID={trial.BUNDLE_PREFIX}.{configuration.lower()}", command)
            self.assertIn(f"CONFIGURATION_BUILD_DIR={self.output / configuration}", command)
        self.assertEqual(len(builds), 2)
        self.assertFalse(any(command[0].endswith("/build.sh") or "pluginkit" in command[0] or "lsregister" in command[0] for command in self.commands))
        self.assertEqual(self.weight.read_bytes(), bytes(range(256)))

    def test_bad_asset_hash_stops_before_any_external_command(self):
        self.row["sha256"] = "0" * 64
        self.assets.write_text(json.dumps({"schema": 1, "models": [self.row]}))
        self.assertEqual(self.invoke(self.fake_subprocess), 2)
        self.assertEqual(self.commands, [])
        self.assertFalse(self.output.exists())

    def test_release_failure_is_retained_without_claiming_pair_success(self):
        def fail_release(command, **kwargs):
            if command[0] == "/usr/bin/xcodebuild" and "Release" in command:
                self.commands.append(command)
                return subprocess.CompletedProcess(command, 65)
            return self.fake_subprocess(command, **kwargs)

        self.assertEqual(self.invoke(fail_release), 1)
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["status"], "failed")
        self.assertEqual(manifest["stage"], "build-Release")
        self.assertEqual([row["configuration"] for row in manifest["packages"]], ["Debug"])
        self.assertEqual(manifest["commands"][-1]["returncode"], 65)


if __name__ == "__main__":
    unittest.main()
