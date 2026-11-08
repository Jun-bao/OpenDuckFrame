#!/usr/bin/env python3
r"""Build local Debug/Release experiment apps without deploying the normal app.

Example (dependencies already prepared):
  DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer \
    python3 Scripts/build_experiment_trial.py \
    --assets-manifest /private/path/assets-input.json --skip-dependencies

The private input is {"schema": 1, "models": [{"id": ..., "file_name": ...,
"source_path": ..., "sha256": ..., "graph_id": ..., "mask_update": ...,
"description": ...}]}. Relative source paths are resolved beside that JSON.
Only the public model fields are embedded. No weights are generated or changed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
from typing import Any


MODEL_FIELDS = ("id", "file_name", "sha256", "graph_id", "mask_update", "description")
BUNDLE_PREFIX = "app.openduckframe.ExperimentTrial"
DEPENDENCIES = (
    "Scripts/prepare_rife_runtime.sh",
    "Scripts/build_ffmpeg_min.sh",
    "Scripts/build_subtitle_libs.sh",
    "Scripts/build_sparkle.sh",
)
UPDATER_KEYS = (
    "SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SPUpdateUsageEnabled",
    "SUEnableSystemProfiling", "SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    temporary.replace(path)


def load_assets(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise ValueError("assets manifest must use schema 1")
    rows = data.get("models")
    if not isinstance(rows, list) or not rows:
        raise ValueError("assets manifest must contain a nonempty models list")
    models: list[dict[str, Any]] = []
    ids: set[str] = set()
    names: set[str] = set()
    for row in rows:
        if not isinstance(row, dict) or any(key not in row for key in (*MODEL_FIELDS, "source_path")):
            raise ValueError("every model must have all documented fields")
        model = {key: row[key] for key in MODEL_FIELDS}
        if any(not isinstance(model[key], str) for key in MODEL_FIELDS):
            raise ValueError("model metadata fields must be strings")
        name = model["file_name"]
        if not name or name in (".", "..") or "/" in name or "\\" in name:
            raise ValueError(f"model file_name must be a base name: {name!r}")
        if not model["id"] or model["id"] in ids or name.casefold() in names:
            raise ValueError("model ids and file names must be unique")
        if not re.fullmatch(r"[0-9a-fA-F]{64}", model["sha256"]):
            raise ValueError(f"invalid SHA-256 for {model['id']}")
        if not isinstance(row["source_path"], str) or not row["source_path"]:
            raise ValueError(f"missing source_path for {model['id']}")
        source = Path(row["source_path"]).expanduser()
        if not source.is_absolute():
            source = path.parent / source
        source = source.resolve(strict=True)
        model["sha256"] = model["sha256"].lower()
        actual = sha256(source)
        if actual != model["sha256"]:
            raise ValueError(f"model SHA-256 mismatch for {model['id']}: {actual}")
        model["source_path"] = str(source)
        models.append(model)
        ids.add(model["id"])
        names.add(name.casefold())
    return models


def git_output(repo: Path, *arguments: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(repo), *arguments])


def source_identity(repo: Path, output: Path) -> dict[str, Any]:
    """Include dirty/untracked sources and the ignored, prepared Rife package."""
    names = set(git_output(repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0"))
    paths = {repo / os.fsdecode(name) for name in names if name}
    runtime = repo / "ThirdParty/rife-metal/runtime"
    if runtime.is_dir():
        for directory, subdirs, files in os.walk(runtime):
            subdirs[:] = [name for name in subdirs if name not in (".build", ".git", ".swiftpm")]
            paths.update(Path(directory) / name for name in files)
    # The generated project is ignored by Git, but is an actual build input.
    paths.add(repo / "Apps/Mac/OpenDuckFrame.xcodeproj/project.pbxproj")
    digest = hashlib.sha256()
    count = 0
    for path in sorted(paths):
        if path.is_relative_to(output):
            continue
        if path.is_symlink():
            value = "symlink:" + os.readlink(path)
        elif path.is_file():
            value = sha256(path)
        elif not path.exists():
            value = "missing"
        else:
            continue
        digest.update(os.fsencode(str(path.relative_to(repo))) + b"\0" + value.encode() + b"\0")
        count += 1
    return {
        "head": git_output(repo, "rev-parse", "HEAD").decode().strip(),
        "source_sha256": digest.hexdigest(),
        "file_count": count,
        "git_status": git_output(repo, "status", "--porcelain=v1", "--untracked-files=all").decode(),
    }


def build_command(repo: Path, output: Path, derived: Path, configuration: str, jobs: int) -> list[str]:
    return [
        "/usr/bin/xcodebuild", "-skipPackagePluginValidation",
        "-project", str(repo / "Apps/Mac/OpenDuckFrame.xcodeproj"),
        "-scheme", "OpenDuckFrame", "-configuration", configuration,
        "-derivedDataPath", str(derived), "-jobs", str(jobs),
        "REGISTER_WITH_LAUNCH_SERVICES=NO",
        f"ODF_BUNDLE_ID={BUNDLE_PREFIX}.{configuration.lower()}",
        "ODF_DISPLAY_NAME=OpenDuckFrame", "ODF_SPARKLE_EMBEDDED=NO",
        f"CONFIGURATION_BUILD_DIR={output / configuration}", "build",
    ]


def inject_resources(app: Path, configuration: str, models: list[dict[str, Any]]) -> None:
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    expected_id = f"{BUNDLE_PREFIX}.{configuration.lower()}"
    if info.get("CFBundleIdentifier") != expected_id:
        raise ValueError(f"built bundle identifier is not {expected_id}")
    if any(info.get(key) != "OpenDuckFrame" for key in ("CFBundleName", "CFBundleDisplayName", "CFBundleExecutable")):
        raise ValueError("trial product and executable names must remain OpenDuckFrame")
    info["ODFExperimentTrial"] = True
    info["ODFExperimentBuild"] = configuration
    for key in UPDATER_KEYS:
        info.pop(key, None)
    with info_path.open("wb") as stream:
        plistlib.dump(info, stream)

    resources = app / "Contents/Resources"
    destination = resources / "ExperimentModels"
    # This is only the injected model directory in this script's own trial app.
    if destination.is_symlink():
        destination.unlink()
    elif destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for model in models:
        target = destination / model["file_name"]
        shutil.copy2(model["source_path"], target)
        if sha256(target) != model["sha256"]:
            raise ValueError(f"copied model SHA-256 mismatch for {model['id']}")
    public_models = [{key: model[key] for key in MODEL_FIELDS} for model in models]
    write_json(resources / "experiment-models.json", {"schema": 1, "models": public_models})


def package_record(app: Path, configuration: str, source: dict[str, Any]) -> dict[str, Any]:
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("ODFExperimentTrial") is not True or info.get("ODFExperimentBuild") != configuration:
        raise ValueError("signed app lost its experiment trial markers")
    if info.get("CFBundleIdentifier") != f"{BUNDLE_PREFIX}.{configuration.lower()}":
        raise ValueError("signed app has an unexpected bundle identifier")
    if any(key in info for key in UPDATER_KEYS):
        raise ValueError("trial app unexpectedly contains updater configuration")
    resources = {
        str(path.relative_to(app)): sha256(path)
        for path in sorted((app / "Contents/Resources").rglob("*")) if path.is_file()
    }
    executable = app / "Contents/MacOS/OpenDuckFrame"
    return {
        "configuration": configuration, "app": str(app), "bundle_id": info["CFBundleIdentifier"],
        "head": source["head"], "source_sha256": source["source_sha256"],
        "executable_sha256": sha256(executable),
        "info_plist_sha256": sha256(app / "Contents/Info.plist"), "resources": resources,
    }


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, default=Path(".build/ExperimentComparison"), help="relative to --repo by default")
    parser.add_argument("--assets-manifest", required=True, type=Path, help="private schema-1 model input; never embedded verbatim")
    parser.add_argument("--configuration", choices=("Debug", "Release", "both"), default="both")
    parser.add_argument("--jobs", type=int, default=4, help="maximum App xcodebuild jobs (default: 4); existing dependency recipes retain their own parallelism")
    parser.add_argument("--skip-dependencies", action="store_true", help="reuse prepared runtime and pinned native dependencies; recommended after the normal dependency preparation")
    parser.add_argument("--derived-data", type=Path, default=Path(".build"), help="reuse existing DerivedData; relative to --repo")
    parser.add_argument("--developer-dir", type=Path, help="per-command DEVELOPER_DIR override; does not change xcode-select")
    parser.add_argument("--xcodegen", default=os.environ.get("XCODEGEN"), help="xcodegen executable (default: XCODEGEN or PATH)")
    args = parser.parse_args(argv)
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        repo = args.repo.expanduser().resolve(strict=True)
        output = (repo / args.output.expanduser()).resolve()
        derived = (repo / args.derived_data.expanduser()).resolve()
        assets_path = args.assets_manifest.expanduser().resolve(strict=True)
        models = load_assets(assets_path)
        xcodegen = shutil.which(args.xcodegen or "xcodegen")
        if not xcodegen and not args.xcodegen:
            xcodegen = shutil.which("/opt/homebrew/bin/xcodegen")
        if not xcodegen:
            raise ValueError("xcodegen was not found; set --xcodegen or XCODEGEN")
        if output in (repo, repo / ".build", repo / ".build/Build/Products") or repo.is_relative_to(output):
            raise ValueError("--output must be a dedicated trial directory")
        if any((output / config / "OpenDuckFrame.app").resolve() == repo / "OpenDuckFrame.app" for config in ("Debug", "Release")):
            raise ValueError("trial output must not target the normal root app")
        marker = output / ".experiment-trial-output.json"
        if output.exists() and any(output.iterdir()) and not marker.is_file():
            raise ValueError("--output is nonempty and is not an existing experiment trial output")
        if marker.is_file() and json.loads(marker.read_text()).get("repo") != str(repo):
            raise ValueError("trial output belongs to another checkout")
        output.mkdir(parents=True, exist_ok=True)
        write_json(marker, {"schema": 1, "repo": str(repo)})
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    with (output / ".build.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("error: another trial build is using this output directory", file=sys.stderr)
            return 2
        run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + f"-{os.getpid()}"
        run_dir = output / "runs" / run_id
        run_dir.mkdir(parents=True)
        configurations = ["Debug", "Release"] if args.configuration == "both" else [args.configuration]
        env = os.environ.copy()
        env.update(ODF_ENABLE_SPARKLE="false", ODF_SPARKLE_FEED_URL="", ODF_SPARKLE_PUBLIC_ED_KEY="")
        if args.developer_dir:
            env["DEVELOPER_DIR"] = str(args.developer_dir.expanduser().resolve())
        manifest: dict[str, Any] = {
            "schema": 1, "status": "running", "run_id": run_id, "repo": str(repo),
            "output": str(output), "derived_data": str(derived), "requested_configurations": configurations,
            "jobs": args.jobs, "dependencies_skipped": args.skip_dependencies,
            "dependency_parallelism": "existing recipe defaults (not controlled by --jobs)",
            "assets_manifest": str(assets_path), "assets_manifest_sha256": sha256(assets_path),
            "models": models, "commands": [], "packages": [],
            "updater": {"project_enabled": False, "feed_configured": False,
                        "inert_framework": "pinned Sparkle framework retained solely for existing bundle verification contract"},
            "script_sha256": sha256(Path(__file__).resolve()),
        }

        def save() -> None:
            write_json(run_dir / "manifest.json", manifest)
            write_json(output / "manifest.json", manifest)

        def run(stage: str, command: list[str]) -> dict[str, Any]:
            record: dict[str, Any] = {"stage": stage, "command": command, "log": str(run_dir / f"{len(manifest['commands']):02d}-{stage}.log")}
            manifest["commands"].append(record)
            manifest["stage"] = stage
            save()
            print(f"==> {stage} (log: {record['log']})", flush=True)
            with Path(record["log"]).open("w") as log:
                result = subprocess.run(command, cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT)
            record["returncode"] = result.returncode
            save()
            if result.returncode:
                print("\n".join(Path(record["log"]).read_text(errors="replace").splitlines()[-24:]), file=sys.stderr)
                raise RuntimeError(f"{stage} failed with exit status {result.returncode}")
            return record

        try:
            save()
            if not args.skip_dependencies:
                for script in DEPENDENCIES:
                    run(Path(script).stem, [str(repo / script)])
            run("generate-project", [xcodegen, "generate", "--spec", str(repo / "Apps/Mac/project.yml"), "--project", str(repo / "Apps/Mac"), "--quiet"])
            source = source_identity(repo, output)
            manifest["source"] = source
            save()
            for configuration in configurations:
                before = source_identity(repo, output)
                if (before["head"], before["source_sha256"]) != (source["head"], source["source_sha256"]):
                    raise RuntimeError("source changed between trial configurations; rerun after edits finish")
                app = output / configuration / "OpenDuckFrame.app"
                run(f"build-{configuration}", build_command(repo, output, derived, configuration, args.jobs))
                after = source_identity(repo, output)
                if (after["head"], after["source_sha256"]) != (source["head"], source["source_sha256"]):
                    raise RuntimeError(f"source changed during {configuration}; the pair is not a same-source build")
                manifest["stage"] = f"resources-{configuration}"
                save()
                inject_resources(app, configuration, models)
                # The existing direct bundle script requires this framework even
                # when the project excludes update support. It remains unlinked,
                # with no feed/key or enable marker in the experiment app.
                run(f"inert-framework-{configuration}", ["/usr/bin/ditto", str(repo / "ThirdParty/sparkle-min/Sparkle.framework"), str(app / "Contents/Frameworks/Sparkle.framework")])
                run(f"bundle-{configuration}", [str(repo / "Scripts/bundle_libs.sh"), str(app)])
                verification = run(f"verify-{configuration}", [str(repo / "Scripts/verify_app_bundle.sh"), str(app)])
                signature = run(f"codesign-{configuration}", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
                details = run(f"signature-details-{configuration}", ["/usr/bin/codesign", "-dv", "--verbose=4", str(app)])
                package = package_record(app, configuration, source)
                package.update(status="verified", bundle_verification=verification, code_signature_verification=signature, code_signature_details=details)
                manifest["packages"].append(package)
                save()
            manifest["status"] = "succeeded"
            manifest["stage"] = "complete"
            save()
            print(f"Trial bundles verified. Manifest: {output / 'manifest.json'}")
            return 0
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
            manifest["status"] = "failed"
            manifest["error"] = str(exc)
            save()
            print(f"error: {exc}\nPartial manifest: {output / 'manifest.json'}", file=sys.stderr)
            return 1


if __name__ == "__main__":
    raise SystemExit(main())
