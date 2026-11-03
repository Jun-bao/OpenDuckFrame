#!/usr/bin/env python3
"""Dependency-lock queries, build fingerprints, and hermetic config checks."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Iterable


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_LOCK = ROOT / "ThirdParty" / "deps.lock.json"


class LockError(RuntimeError):
    pass


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_lock(path: pathlib.Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LockError(f"cannot read dependency lock {path}: {exc}") from exc
    if data.get("schema") != 1 or not isinstance(data.get("dependencies"), dict):
        raise LockError(f"unsupported dependency lock schema in {path}")
    for name, dependency in data["dependencies"].items():
        if not isinstance(dependency, dict):
            raise LockError(f"dependency {name!r} must be an object")
        for key in ("version", "url", "archive", "source_dir", "sha256"):
            value = dependency.get(key)
            if not isinstance(value, str) or not value:
                raise LockError(f"dependency {name!r} has invalid {key!r}")
        if not re.fullmatch(r"[0-9a-f]{64}", dependency["sha256"]):
            raise LockError(f"dependency {name!r} has invalid sha256")
        for patch in dependency.get("patches", []):
            if not isinstance(patch, dict) or not re.fullmatch(
                r"[0-9a-f]{64}", str(patch.get("sha256", ""))
            ):
                raise LockError(f"dependency {name!r} has an invalid patch entry")
    return data


def nested_value(value: Any, fields: Iterable[str]) -> Any:
    for field in fields:
        if isinstance(value, dict) and field in value:
            value = value[field]
        elif isinstance(value, list) and field.isdigit() and int(field) < len(value):
            value = value[int(field)]
        else:
            raise LockError(f"lock field not found: {field}")
    return value


def display_path(path: pathlib.Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(ROOT).as_posix()
    except ValueError:
        return str(resolved)


def command_version(path: str) -> str:
    attempts = ([path, "--version"], [path, "-version"], [path, "version"])
    for command in attempts:
        try:
            result = subprocess.run(
                command,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=10,
                env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
            )
        except (OSError, subprocess.TimeoutExpired):
            continue
        output = result.stdout.strip()
        if result.returncode == 0 and output:
            return output[:4096]
    return "version unavailable"


def resolve_tool(spec: str) -> tuple[str, str]:
    if "=" in spec:
        name, requested = spec.split("=", 1)
        path = requested
    else:
        name = spec
        path = shutil.which(spec) or ""
    if not name or not path:
        raise LockError(f"required tool not found: {spec}")
    resolved = str(pathlib.Path(path).resolve())
    if not pathlib.Path(resolved).is_file():
        raise LockError(f"required tool not found: {path}")
    return name, resolved


def toolchain_record(tool_specs: Iterable[str]) -> dict[str, Any]:
    tools: dict[str, Any] = {}
    for spec in sorted(set(tool_specs)):
        name, path = resolve_tool(spec)
        tools[name] = {"path": path, "version": command_version(path)}
    return {
        "host_machine": platform.machine(),
        "sdkroot": os.environ.get("SDKROOT", ""),
        "macosx_deployment_target": os.environ.get("MACOSX_DEPLOYMENT_TARGET", ""),
        "tools": tools,
    }


def fingerprint_record(
    lock_path: pathlib.Path,
    dependency_names: Iterable[str],
    input_paths: Iterable[pathlib.Path],
    stamp_paths: Iterable[pathlib.Path],
    tool_specs: Iterable[str],
    parameters: Iterable[str] = (),
) -> dict[str, Any]:
    lock = load_lock(lock_path)
    dependencies: dict[str, Any] = {}
    for name in sorted(set(dependency_names)):
        try:
            dependencies[name] = lock["dependencies"][name]
        except KeyError as exc:
            raise LockError(f"dependency not found in lock: {name}") from exc

    inputs: dict[str, str] = {}
    for path in sorted({path.resolve() for path in input_paths}, key=str):
        if not path.is_file():
            raise LockError(f"fingerprint input does not exist: {path}")
        inputs[display_path(path)] = sha256_file(path)

    stamps: dict[str, str] = {}
    for path in sorted({path.resolve() for path in stamp_paths}, key=str):
        if not path.is_file():
            raise LockError(f"required dependency stamp does not exist: {path}")
        stamps[display_path(path)] = sha256_file(path)

    parameter_values: dict[str, str] = {}
    for parameter in parameters:
        if "=" not in parameter:
            raise LockError(f"recipe parameter must be NAME=VALUE: {parameter}")
        name, value = parameter.split("=", 1)
        if not name or name in parameter_values:
            raise LockError(f"invalid or duplicate recipe parameter: {parameter}")
        parameter_values[name] = value

    return {
        "schema": 1,
        # Package provenance requires every installed prefix to agree on one
        # complete lock revision. Include the full lock hash in the recipe so
        # changing an unrelated entry also refreshes otherwise reusable stamps
        # instead of leaving bundle verification permanently unsatisfiable.
        "dependency_lock_sha256": sha256_file(lock_path),
        "target": lock.get("target", {}),
        "dependencies": dependencies,
        "inputs": inputs,
        "dependency_stamps": stamps,
        "parameters": parameter_values,
        "toolchain": toolchain_record(tool_specs),
    }


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")


def recipe_hash(record: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_json(record)).hexdigest()


def atomic_write_json(path: pathlib.Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary = pathlib.Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(data, handle, sort_keys=True, indent=2, ensure_ascii=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def parse_feature_values(config: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in config.splitlines():
        match = re.match(r"^([A-Z0-9_]+)=(.*)$", line)
        if match:
            values[match.group(1)] = match.group(2).strip()
    return values


def verify_ffmpeg_config(config_path: pathlib.Path, allowed_roots: Iterable[pathlib.Path]) -> None:
    try:
        config = config_path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise LockError(f"cannot read FFmpeg config {config_path}: {exc}") from exc

    features = parse_feature_values(config)
    forbidden_features = (
        "CONFIG_VULKAN",
        "CONFIG_XLIB",
        "CONFIG_XCB",
        "CONFIG_XCB_SHM",
        "CONFIG_XCB_SHAPE",
        "CONFIG_XCB_XFIXES",
    )
    enabled = [name for name in forbidden_features if features.get(name) == "yes"]
    if enabled:
        raise LockError("forbidden FFmpeg features enabled: " + ", ".join(enabled))

    verify_search_paths([config_path], allowed_roots)


def verify_search_paths(
    config_paths: Iterable[pathlib.Path], allowed_roots: Iterable[pathlib.Path]
) -> None:
    configs: list[str] = []
    for config_path in config_paths:
        try:
            configs.append(config_path.read_text(encoding="utf-8", errors="replace"))
        except OSError as exc:
            raise LockError(f"cannot read build config {config_path}: {exc}") from exc
    config = "\n".join(configs)
    allowed = [path.resolve() for path in allowed_roots]
    sdkroot = os.environ.get("SDKROOT")
    if sdkroot:
        allowed.append(pathlib.Path(sdkroot).resolve())
    allowed.extend((pathlib.Path("/usr/lib"), pathlib.Path("/System/Library")))

    bad_paths: list[str] = []
    # Only inspect compiler/linker search arguments. Tool locations such as a
    # Homebrew pkg-config binary do not become runtime or header dependencies.
    for match in re.finditer(r"(?:^|[\s=])-(?:I|L|F)\s*(/[^\s\"']+)", config):
        candidate = pathlib.Path(match.group(1)).resolve()
        if not any(candidate == root or root in candidate.parents for root in allowed):
            bad_paths.append(str(candidate))
    enabled_packages = sorted(
        set(
            re.findall(
                r"^(X11|Vulkan)_FOUND(?::BOOL)?=(?:1|ON|TRUE|YES)$",
                config,
                flags=re.MULTILINE | re.IGNORECASE,
            )
        )
    )
    forbidden_search_roots = (
        "/opt/homebrew/include",
        "/opt/homebrew/lib",
        "/usr/local/include",
        "/usr/local/lib",
        "/opt/X11/include",
        "/opt/X11/lib",
        "/VulkanSDK/",
    )
    leaked_roots = sorted(
        root for root in forbidden_search_roots if root in config
    )
    forbidden_libraries = sorted(
        set(
            re.findall(
                r"(?:^|\s)-l(X11|Xext|Xrender|xcb|vulkan)(?=\s|$)",
                config,
                flags=re.MULTILINE,
            )
        )
    )
    if bad_paths or enabled_packages or leaked_roots or forbidden_libraries:
        details = sorted(set(bad_paths)) + leaked_roots + [
            f"{package}_FOUND" for package in enabled_packages
        ] + [
            f"-l{library}" for library in forbidden_libraries
        ]
        raise LockError("external include/library path in build config: " + ", ".join(details))


def add_fingerprint_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--dependency", action="append", default=[])
    parser.add_argument("--input", action="append", default=[])
    parser.add_argument("--stamp", action="append", default=[])
    parser.add_argument("--tool", action="append", default=[])
    parser.add_argument("--parameter", action="append", default=[])


def fingerprint_from_args(args: argparse.Namespace) -> dict[str, Any]:
    return fingerprint_record(
        pathlib.Path(args.lock),
        args.dependency,
        [pathlib.Path(path) for path in args.input],
        [pathlib.Path(path) for path in args.stamp],
        args.tool,
        args.parameter,
    )


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", default=str(DEFAULT_LOCK))
    subparsers = parser.add_subparsers(dest="command", required=True)

    get_parser = subparsers.add_parser("get")
    get_parser.add_argument("dependency")
    get_parser.add_argument("field", nargs="+")

    recipe_parser = subparsers.add_parser("recipe-hash")
    add_fingerprint_arguments(recipe_parser)

    stamp_parser = subparsers.add_parser("write-stamp")
    stamp_parser.add_argument("--output", required=True)
    add_fingerprint_arguments(stamp_parser)

    match_parser = subparsers.add_parser("stamp-matches")
    match_parser.add_argument("--stamp", required=True)
    match_parser.add_argument("--recipe-hash", required=True)

    config_parser = subparsers.add_parser("verify-ffmpeg-config")
    config_parser.add_argument("--config", required=True)
    config_parser.add_argument("--allow-root", action="append", default=[])

    search_parser = subparsers.add_parser("verify-search-paths")
    search_parser.add_argument("--config", action="append", required=True)
    search_parser.add_argument("--allow-root", action="append", default=[])
    return parser


def main(argv: list[str] | None = None) -> int:
    args = create_parser().parse_args(argv)
    try:
        if args.command == "get":
            lock = load_lock(pathlib.Path(args.lock))
            dependency = lock["dependencies"].get(args.dependency)
            if dependency is None:
                raise LockError(f"dependency not found in lock: {args.dependency}")
            value = nested_value(dependency, args.field)
            if isinstance(value, (dict, list)):
                print(json.dumps(value, sort_keys=True, separators=(",", ":")))
            else:
                print(value)
        elif args.command == "recipe-hash":
            print(recipe_hash(fingerprint_from_args(args)))
        elif args.command == "write-stamp":
            record = fingerprint_from_args(args)
            record["recipe_sha256"] = recipe_hash(record)
            atomic_write_json(pathlib.Path(args.output), record)
        elif args.command == "stamp-matches":
            try:
                stamp = json.loads(pathlib.Path(args.stamp).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                return 1
            return 0 if stamp.get("recipe_sha256") == args.recipe_hash else 1
        elif args.command == "verify-ffmpeg-config":
            verify_ffmpeg_config(
                pathlib.Path(args.config),
                [pathlib.Path(path) for path in args.allow_root],
            )
        elif args.command == "verify-search-paths":
            verify_search_paths(
                [pathlib.Path(path) for path in args.config],
                [pathlib.Path(path) for path in args.allow_root],
            )
        else:  # pragma: no cover - argparse makes this unreachable
            raise LockError(f"unknown command: {args.command}")
    except (KeyError, LockError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
