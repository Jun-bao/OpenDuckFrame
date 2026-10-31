#!/usr/bin/env python3
"""Verify the packaged app's Mach-O closure and reproducibility metadata."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from typing import Iterable

import build_manifest


class BundleError(RuntimeError):
    pass


def run(command: list[str]) -> str:
    result = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if result.returncode != 0:
        raise BundleError(f"command failed ({result.returncode}): {' '.join(command)}\n{result.stdout}")
    return result.stdout


def is_macho(path: Path) -> bool:
    result = subprocess.run(
        ["/usr/bin/file", "-b", str(path)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        errors="replace",
    )
    return result.returncode == 0 and "Mach-O" in result.stdout


def find_machos(app: Path) -> list[Path]:
    contents = app / "Contents"
    result = [path for path in contents.rglob("*") if path.is_file() and is_macho(path)]
    return sorted(result, key=lambda path: path.as_posix())


def parse_dependencies(path: Path) -> list[str]:
    lines = run(["otool", "-L", str(path)]).splitlines()[1:]
    dependencies: list[str] = []
    for line in lines:
        match = re.match(r"\s*(.+?)\s+\(compatibility version", line)
        if match:
            dependencies.append(match.group(1))
    try:
        image_id = run(["otool", "-D", str(path)]).splitlines()[1]
    except (BundleError, IndexError):
        image_id = ""
    return [dependency for dependency in dependencies if dependency != image_id]


def parse_rpaths(path: Path) -> list[str]:
    lines = run(["otool", "-l", str(path)]).splitlines()
    rpaths: list[str] = []
    in_rpath = False
    for line in lines:
        stripped = line.strip()
        if stripped == "cmd LC_RPATH":
            in_rpath = True
        elif in_rpath and stripped.startswith("path "):
            rpaths.append(stripped[5:].split(" (offset", 1)[0])
            in_rpath = False
        elif stripped.startswith("cmd "):
            in_rpath = False
    return rpaths


def expand_token(path: str, loader: Path, executable_dir: Path) -> Path | None:
    if path == "@loader_path":
        return loader.parent
    if path.startswith("@loader_path/"):
        return loader.parent / path[len("@loader_path/") :]
    if path == "@executable_path":
        return executable_dir
    if path.startswith("@executable_path/"):
        return executable_dir / path[len("@executable_path/") :]
    if path.startswith("/"):
        return Path(path)
    return None


def ensure_inside_app(candidate: Path, app: Path, dependency: str) -> Path:
    resolved = candidate.resolve()
    try:
        resolved.relative_to(app.resolve())
    except ValueError as exc:
        raise BundleError(f"dependency escapes app bundle: {dependency} -> {resolved}") from exc
    if not resolved.is_file():
        raise BundleError(f"bundle dependency is missing: {dependency} -> {resolved}")
    return resolved


def resolve_dependency(
    dependency: str,
    image: Path,
    app: Path,
    executable_dir: Path,
    image_rpaths: Iterable[str],
    executable_rpaths: Iterable[str],
) -> Path | None:
    if dependency.startswith("/usr/lib/") or dependency.startswith("/System/Library/"):
        return None
    if dependency.startswith("/"):
        raise BundleError(f"non-system absolute dependency: {image}: {dependency}")
    if dependency.startswith("@loader_path") or dependency.startswith("@executable_path"):
        candidate = expand_token(dependency, image, executable_dir)
        if candidate is None:
            raise BundleError(f"cannot expand dependency: {dependency}")
        return ensure_inside_app(candidate, app, dependency)
    if dependency.startswith("@rpath/"):
        suffix = dependency[len("@rpath/") :]
        for rpath in list(image_rpaths) + list(executable_rpaths):
            root = expand_token(rpath, image, executable_dir)
            if root is None:
                continue
            candidate = root / suffix
            if candidate.is_file():
                return ensure_inside_app(candidate, app, dependency)
        raise BundleError(f"unresolved @rpath dependency: {image}: {dependency}")
    raise BundleError(f"unsupported relative dependency: {image}: {dependency}")


def executable_dir_for(image: Path, app: Path, default_dir: Path) -> Path:
    """Nested bundle executables (.appex) resolve @executable_path against
    their own Contents/MacOS, not the host app's."""
    for parent in image.parents:
        if parent.name == "MacOS" and parent.parent.name == "Contents":
            return parent
        if parent == app:
            break
    return default_dir


def version_tuple(version: str) -> tuple[int, ...]:
    try:
        return tuple(int(component) for component in version.split("."))
    except ValueError as exc:
        raise BundleError(f"invalid version: {version}") from exc


def verify_metallib(path: Path) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise BundleError(f"missing or empty metallib: {path}")
    description = run(["/usr/bin/file", "-b", str(path)])
    if "MetalLib executable (MacOS)" not in description:
        raise BundleError(f"invalid macOS metallib: {path}: {description.strip()}")


def verify_captions_framework(app: Path, main_bundle_id: str) -> Path:
    """The on-demand download UI must be present even without a build manifest.

    It is loaded with Bundle.load, so the normal linked-dependency closure
    cannot detect a missing embedded framework in an App Store archive.
    """
    framework = app / "Contents/Frameworks/KhuaPlayerCaptionsUI.framework"
    info_path = framework / "Resources/Info.plist"
    if not main_bundle_id:
        raise BundleError("main app has no bundle identifier")
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise BundleError(f"caption UI framework Info.plist is missing or invalid: {info_path}") from exc
    if not isinstance(info, dict):
        raise BundleError(f"caption UI framework Info.plist is not a dictionary: {info_path}")
    expected_id = f"{main_bundle_id}.CaptionsUI"
    if info.get("CFBundleIdentifier") != expected_id:
        raise BundleError(f"caption UI framework bundle identifier must be {expected_id}")
    if info.get("CFBundleExecutable") != "KhuaPlayerCaptionsUI":
        raise BundleError("caption UI framework executable must be KhuaPlayerCaptionsUI")
    binary = framework / "KhuaPlayerCaptionsUI"
    if not binary.is_file():
        raise BundleError(f"caption UI framework executable is missing: {binary}")
    return ensure_inside_app(binary, app, "KhuaPlayerCaptionsUI.framework")


def verify_update_usage_privacy(app: Path, info: dict) -> None:
    privacy_path = app / "Contents/Resources/PrivacyInfo.xcprivacy"
    try:
        with privacy_path.open("rb") as handle:
            privacy = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise BundleError("main app privacy manifest is missing or invalid") from exc
    if privacy.get("NSPrivacyTracking") is not False:
        raise BundleError("privacy manifest must not declare advertising tracking")
    if info.get("SPUpdateUsageEnabled") is not True:
        if privacy.get("NSPrivacyCollectedDataTypes") != []:
            raise BundleError("inactive update statistics require the neutral privacy manifest")
        return
    if (info.get("SUFeedURL") != "https://khua.app/updates/appcast.xml"
            or not info.get("SUPublicEDKey")
            or info.get("SUEnableSystemProfiling") is not False):
        raise BundleError("update statistics require the official feed with system profiling off")
    declarations = privacy.get("NSPrivacyCollectedDataTypes", [])
    expected = {"NSPrivacyCollectedDataTypeDeviceID",
                "NSPrivacyCollectedDataTypeProductInteraction",
                "NSPrivacyCollectedDataTypeOtherDataTypes"}
    if not isinstance(declarations, list) or any(not isinstance(item, dict) for item in declarations):
        raise BundleError("invalid update statistics privacy declarations")
    if {item.get("NSPrivacyCollectedDataType") for item in declarations} != expected:
        raise BundleError("update statistics privacy declarations are incomplete")
    for item in declarations:
        if (item.get("NSPrivacyCollectedDataTypeLinked") is not True
                or item.get("NSPrivacyCollectedDataTypeTracking") is not False
                or item.get("NSPrivacyCollectedDataTypePurposes") != ["NSPrivacyCollectedDataTypePurposeAnalytics"]):
            raise BundleError("incorrect update statistics privacy purpose or linkage")


def verify_bundle(
    app: Path,
    lock_path: Path,
    stamps: dict[str, Path],
    verify_codesign: bool = True,
    verify_embedded_manifest: bool = True,
    licenses_dir: Path | None = None,
) -> None:
    if not app.is_dir():
        raise BundleError(f"app does not exist: {app}")
    lock = build_manifest.read_json(lock_path)
    target = lock.get("target", {})
    expected_arch = str(target.get("arch", ""))
    maximum_minos = str(target.get("macos_min", ""))
    if not expected_arch or not maximum_minos:
        raise BundleError("dependency lock has no target arch/minos")

    info_path = app / "Contents/Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise BundleError(f"invalid Info.plist: {exc}") from exc
    if str(info.get("CFBundleName", "")) != "小川帧流":
        raise BundleError("Info.plist CFBundleName must be 小川帧流")
    if str(info.get("CFBundleDisplayName", "")) != "小川帧流":
        raise BundleError("Info.plist CFBundleDisplayName must be 小川帧流")
    if info.get("SPProductName") != "小川帧流 · ChuanFlow":
        raise BundleError("Info.plist SPProductName must be 小川帧流 · ChuanFlow for About")
    executable_name = str(info.get("CFBundleExecutable", ""))
    if executable_name != "Khua":
        raise BundleError("Info.plist CFBundleExecutable must be Khua")
    main = app / "Contents/MacOS" / executable_name
    if not main.is_file():
        raise BundleError(f"main executable missing: {main}")
    if str(info.get("LSMinimumSystemVersion", "")) != maximum_minos:
        raise BundleError("Info.plist minimum system version does not match dependency lock")
    verify_update_usage_privacy(app, info)

    captions_binary = verify_captions_framework(app, str(info.get("CFBundleIdentifier", "")))

    for relative in build_manifest.REQUIRED_METALLIBS:
        verify_metallib(app / relative)

    machos = find_machos(app)
    if main not in machos:
        raise BundleError("main executable is not Mach-O")
    macho_set = {path.resolve() for path in machos}
    if captions_binary not in macho_set:
        raise BundleError(f"caption UI framework executable is not Mach-O: {captions_binary}")
    required_libass = app / "Contents/Frameworks/libass.9.dylib"
    if required_libass.resolve() not in macho_set:
        raise BundleError(f"required libass is not Mach-O: {required_libass}")
    executable_rpaths = parse_rpaths(main)
    max_tuple = version_tuple(maximum_minos)
    # Optional Anime4K is loaded only after the app checks the OS version.
    # Its separately packaged runtime may target macOS 27; it must never enter
    # the main app's ordinary Mach-O dependency graph on older systems.
    optional_anime_names = {"libplacebo.360.dylib", "libshaderc_shared.1.dylib", "liblcms2.2.dylib", "libMoltenVK.dylib", "libkhua_realcugan.dylib"}
    optional_anime = {(app / "Contents/Frameworks" / name).resolve() for name in optional_anime_names}
    for image in machos:
        archs = run(["lipo", "-archs", str(image)]).strip().split()
        if archs != [expected_arch]:
            raise BundleError(f"wrong architecture for {image}: {' '.join(archs)}")
        build_info = run(["vtool", "-show-build", str(image)])
        minos_values = re.findall(r"^\s*minos\s+([0-9.]+)\s*$", build_info, re.MULTILINE)
        if not minos_values:
            raise BundleError(f"no LC_BUILD_VERSION minos in {image}")
        for minos in minos_values:
            high_minos_optional = {"libplacebo.360.dylib", "libshaderc_shared.1.dylib", "liblcms2.2.dylib"}
            allowed_optional = image.resolve() in optional_anime and image.name in high_minos_optional and version_tuple(minos) <= version_tuple("27.0")
            if version_tuple(minos) > max_tuple and not allowed_optional:
                raise BundleError(f"minos {minos} exceeds {maximum_minos}: {image}")
        image_rpaths = parse_rpaths(image)
        image_exec_dir = executable_dir_for(image, app, main.parent)
        for dependency in parse_dependencies(image):
            resolved = resolve_dependency(
                dependency,
                image,
                app,
                image_exec_dir,
                image_rpaths,
                # Host-executable rpaths only apply to images the host loads,
                # not to nested bundles with their own executable.
                executable_rpaths if image_exec_dir == main.parent else [],
            )
            if resolved is not None and resolved.resolve() not in macho_set:
                raise BundleError(f"resolved dependency is not packaged Mach-O: {resolved}")
            if resolved is not None and resolved.resolve() in optional_anime and image.resolve() not in optional_anime:
                raise BundleError(f"optional Anime4K runtime must not be linked into the base app: {image}: {dependency}")
            if resolved is not None and image.name in {"libkhua_realcugan.dylib", "libMoltenVK.dylib"} and resolved.name in high_minos_optional:
                raise BundleError(f"macOS 14 Real-CUGAN must not depend on the macOS 27 runtime: {image}: {dependency}")
        if verify_codesign:
            run(["codesign", "--verify", "--strict", str(image)])

    # This also applies to Store archives, which intentionally have no manifest.
    build_manifest.verify_third_party_notices(
        app, licenses_dir if licenses_dir is not None else lock_path.parent / "Licenses"
    )
    if verify_embedded_manifest:
        build_manifest.verify_manifest(app, lock_path, stamps)
    if verify_codesign:
        run(["codesign", "--verify", "--strict", "--deep", str(app)])


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--stamp", action="append", default=[])
    parser.add_argument("--licenses", help="source notice directory (default: <lock directory>/Licenses)")
    parser.add_argument("--skip-codesign", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--skip-manifest", action="store_true", help=argparse.SUPPRESS)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = create_parser().parse_args(argv)
    try:
        verify_bundle(
            Path(args.app),
            Path(args.lock),
            build_manifest.parse_stamp_specs(args.stamp),
            not args.skip_codesign,
            not args.skip_manifest,
            Path(args.licenses) if args.licenses else None,
        )
    except (BundleError, build_manifest.ManifestError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
