#!/usr/bin/env python3
"""Create and verify OpenDuckFrame's deterministic embedded build manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Iterable


MANIFEST_RELATIVE_PATH = Path("Contents/Resources/BuildManifest.json")
# Shaders ship inside the shared MediaCore framework (looked up via
# bundleForClass), not the host app's Resources.
_MEDIACORE_RESOURCES = Path(
    "Contents/Frameworks/OpenDuckFrameMediaCore.framework/Versions/A/Resources"
)
REQUIRED_METALLIBS = (
    _MEDIACORE_RESOURCES / "default.metallib",
    _MEDIACORE_RESOURCES / "FrameBudget.metallib",
)
# Verbatim upstream notices retain their component directories in the shared
# framework. Every required file is also part of the embedded artifact hashes.
THIRD_PARTY_LICENSES = (
    "ArtCNN-MIT.txt",
    "THIRD_PARTY_NOTICES.txt",
    "FFmpeg/LICENSE.md",
    "FFmpeg/COPYING.LGPLv2.1",
    "FFmpeg/COPYING.LGPLv3",
    "dav1d/COPYING",
    "dav1d/PATENTS",
    "Speex/COPYING",
    "libass/COPYING",
    "libpng/LICENSE",
    "FreeType/LICENSE.TXT",
    "FreeType/FTL.TXT",
    "FreeType/GPLv2.TXT",
    "FreeType/bdf-README",
    "FreeType/pcf-README",
    "FriBidi/COPYING",
    "libunibreak/LICENCE",
    "Graphite2/COPYING",
    "Graphite2/LICENSE",
    "HarfBuzz/COPYING",
    "HarfBuzz/ms-use-COPYING",
    "Sparkle/LICENSE",
)
REQUIRED_ARTIFACTS = REQUIRED_METALLIBS + (
    Path("Contents/Frameworks/libass.9.dylib"),
    Path("Contents/Frameworks/OpenDuckFrameCaptionsUI.framework/Versions/A/OpenDuckFrameCaptionsUI"),
) + tuple(
    Path("Contents/Resources") / ("ArtCNN_C4F" + str(features) + ".mlmodelc") / name
    for features in (16, 32)
    for name in ("model.mil", "coremldata.bin", "weights/weight.bin")
) + tuple(_MEDIACORE_RESOURCES / "Licenses" / name for name in THIRD_PARTY_LICENSES)


class ManifestError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ManifestError(f"expected JSON object: {path}")
    return value


def parse_stamp_specs(specs: Iterable[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for spec in specs:
        if "=" not in spec:
            raise ManifestError(f"stamp must be NAME=PATH: {spec}")
        name, path = spec.split("=", 1)
        if not name or name in result:
            raise ManifestError(f"invalid or duplicate stamp: {spec}")
        result[name] = Path(path)
    return result


def artifact_paths(app: Path) -> list[Path]:
    paths = list(REQUIRED_ARTIFACTS)
    frameworks = app / "Contents/Frameworks"
    if frameworks.is_dir():
        for path in frameworks.rglob("*"):
            if path.is_file() and not path.is_symlink():
                paths.append(path.relative_to(app))
    macos = app / "Contents/MacOS"
    if macos.is_dir():
        for path in macos.rglob("*.dylib"):
            if path.is_file() and not path.is_symlink():
                paths.append(path.relative_to(app))
    return sorted(set(paths), key=lambda path: path.as_posix())


def artifact_hashes(app: Path) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for relative in artifact_paths(app):
        path = app / relative
        if not path.is_file() or path.stat().st_size == 0:
            raise ManifestError(f"required bundle artifact missing or empty: {relative}")
        hashes[relative.as_posix()] = sha256_file(path)
    return hashes


def _notice_names(directory: Path) -> set[str]:
    if not directory.is_dir():
        return set()
    names = set()
    for path in directory.rglob("*"):
        relative = path.relative_to(directory)
        if any(part.startswith(".") for part in relative.parts):
            continue
        if path.is_symlink():
            raise ManifestError(f"third-party notice must not be a symlink: {path}")
        if path.is_file():
            names.add(relative.as_posix())
    return names


def verify_third_party_notices(app: Path, source: Path) -> None:
    """Reject missing, stale, or unexpected notices, including incremental copies."""
    bundled = app / _MEDIACORE_RESOURCES / "Licenses"
    expected = set(THIRD_PARTY_LICENSES)
    for label, directory in (("source", source), ("bundled", bundled)):
        names = _notice_names(directory)
        if names != expected:
            raise ManifestError(
                f"{label} third-party notices differ from THIRD_PARTY_LICENSES "
                f"({directory}): extra {sorted(names - expected)}, "
                f"missing {sorted(expected - names)}"
            )
    for name in THIRD_PARTY_LICENSES:
        if (bundled / name).read_bytes() != (source / name).read_bytes():
            raise ManifestError(f"bundled third-party notice differs from source: {name}")


def public_build_record(stamp: dict[str, Any]) -> dict[str, Any]:
    """Remove checkout-local paths while retaining reproducible provenance."""
    toolchain = stamp.get("toolchain", {})
    tools: dict[str, Any] = {}
    for name, value in sorted(toolchain.get("tools", {}).items()):
        if isinstance(value, dict):
            tools[name] = {"version": value.get("version", "")}
    sdkroot = str(toolchain.get("sdkroot", ""))
    return {
        "schema": stamp.get("schema", 1),
        "recipe_sha256": stamp.get("recipe_sha256", ""),
        "dependency_lock_sha256": stamp.get("dependency_lock_sha256", ""),
        "target": stamp.get("target", {}),
        "dependencies": stamp.get("dependencies", {}),
        "inputs": stamp.get("inputs", {}),
        "toolchain": {
            "host_machine": toolchain.get("host_machine", ""),
            "sdk": Path(sdkroot).name if sdkroot else "",
            "macosx_deployment_target": toolchain.get(
                "macosx_deployment_target", ""
            ),
            "tools": tools,
        },
    }


def manifest_record(app: Path, lock_path: Path, stamps: dict[str, Path]) -> dict[str, Any]:
    lock = read_json(lock_path)
    if lock.get("schema") != 1 or not isinstance(lock.get("dependencies"), dict):
        raise ManifestError(f"unsupported dependency lock: {lock_path}")
    lock_sha256 = sha256_file(lock_path)
    dependency_builds: dict[str, Any] = {}
    for name, path in sorted(stamps.items()):
        stamp = read_json(path)
        if not stamp.get("recipe_sha256"):
            raise ManifestError(f"dependency stamp lacks recipe_sha256: {path}")
        if stamp.get("dependency_lock_sha256") != lock_sha256:
            raise ManifestError(f"dependency stamp was built from a different lock: {path}")
        dependency_builds[name] = public_build_record(stamp)
    return {
        "schema": 1,
        "target": lock.get("target", {}),
        "dependency_lock_sha256": lock_sha256,
        "dependencies": lock["dependencies"],
        "dependency_builds": dependency_builds,
        "artifacts": artifact_hashes(app),
    }


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, indent=2, ensure_ascii=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def write_manifest(app: Path, lock_path: Path, stamps: dict[str, Path]) -> Path:
    output = app / MANIFEST_RELATIVE_PATH
    atomic_write(output, manifest_record(app, lock_path, stamps))
    return output


def verify_manifest(app: Path, lock_path: Path, stamps: dict[str, Path]) -> None:
    manifest_path = app / MANIFEST_RELATIVE_PATH
    actual = read_json(manifest_path)
    expected = manifest_record(app, lock_path, stamps)
    if actual != expected:
        if actual.get("artifacts") != expected.get("artifacts"):
            raise ManifestError("bundle artifact hashes do not match BuildManifest.json")
        raise ManifestError("BuildManifest.json does not match dependency lock/stamps")


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("write", "verify"))
    parser.add_argument("--app", required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--stamp", action="append", default=[])
    return parser


def main(argv: list[str] | None = None) -> int:
    args = create_parser().parse_args(argv)
    try:
        stamps = parse_stamp_specs(args.stamp)
        if args.command == "write":
            print(write_manifest(Path(args.app), Path(args.lock), stamps))
        else:
            verify_manifest(Path(args.app), Path(args.lock), stamps)
    except ManifestError as exc:
        print(f"error: {exc}", file=os.sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
