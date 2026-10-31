#!/usr/bin/env python3
"""Export the production Khua AppIcon from its 1024 px master."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

try:
    import PIL
    from PIL import Image, PngImagePlugin
except ModuleNotFoundError as error:
    raise SystemExit(
        "Pillow is required. Install it with: python3 -m pip install Pillow"
    ) from error


ROOT = Path(__file__).resolve().parent
DEFAULT_ORIGINAL = ROOT / "ChuanFlow-Xiaochuan-FullBleed-Original.png"
DEFAULT_MASTER = ROOT / "KhuaPlayer-StaticMaster-1024.png"
DEFAULT_OUTPUT = ROOT / "AppIcon.appiconset"
DEFAULT_MANIFEST = ROOT / "export-manifest.json"
SIZES = (16, 32, 64, 128, 256, 512, 1024)

CONTENTS = {
    "images": [
        {"filename": "AppIcon-16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
        {"filename": "AppIcon-32.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
        {"filename": "AppIcon-32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
        {"filename": "AppIcon-64.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
        {"filename": "AppIcon-128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
        {"filename": "AppIcon-256.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
        {"filename": "AppIcon-256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
        {"filename": "AppIcon-512.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
        {"filename": "AppIcon-512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
        {"filename": "AppIcon-1024.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
    ],
    "info": {"author": "xcode", "version": 1},
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stable_json(value: object) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=True) + "\n").encode("utf-8")


def atomic_write(path: Path, contents: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_bytes(contents)
    os.replace(temporary, path)


def save_png(image: Image.Image, path: Path) -> None:
    # A standard sRGB chunk has fixed bytes, unlike a newly created ICC profile
    # whose creation timestamp would make otherwise identical exports differ.
    metadata = PngImagePlugin.PngInfo()
    metadata.add(b"sRGB", b"\x00")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    image.save(
        temporary,
        format="PNG",
        optimize=True,
        compress_level=9,
        pnginfo=metadata,
    )
    os.replace(temporary, path)


def validate_master(master_path: Path) -> Image.Image:
    source = Image.open(master_path)
    source.load()
    if source.size != (1024, 1024):
        raise SystemExit(f"Master must be 1024x1024; found {source.size}")
    if source.mode != "RGB" or "transparency" in source.info:
        raise SystemExit(f"Master must be an opaque RGB PNG; found {source.mode}")
    if "srgb" not in source.info and "icc_profile" not in source.info:
        raise SystemExit("Master must declare an sRGB color profile")
    return source


def render(master_path: Path, output: Path) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    master = validate_master(master_path)

    files: list[dict[str, object]] = []
    for size in SIZES:
        image = (
            master.copy()
            if size == 1024
            else master.resize((size, size), Image.Resampling.LANCZOS)
        )
        if image.mode != "RGB":
            raise SystemExit("AppIcon output must remain opaque RGB")
        destination = output / f"AppIcon-{size}.png"
        save_png(image, destination)
        files.append(
            {
                "file": destination.name,
                "sha256": sha256(destination),
                "width": size,
                "height": size,
                "mode": "RGB",
            }
        )

    atomic_write(output / "Contents.json", stable_json(CONTENTS))
    return {
        "schemaVersion": 1,
        "original": {
            "file": DEFAULT_ORIGINAL.name,
            "sha256": sha256(DEFAULT_ORIGINAL),
            "colorSpace": "sRGB assumed; original has no embedded profile",
        },
        "source": {
            "file": master_path.name,
            "sha256": sha256(master_path),
            "width": 1024,
            "height": 1024,
            "mode": "RGB",
            "colorSpace": "sRGB IEC61966-2.1",
        },
        "export": {
            "alpha": False,
            "colorSpace": "sRGB IEC61966-2.1",
            "resampling": "Pillow LANCZOS; every size is rendered directly from the 1024 px master",
            "pillowVersion": PIL.__version__,
        },
        "files": files,
    }


def render_master(original: Path, output: Path) -> None:
    source = Image.open(original)
    source.load()
    if source.mode != "RGB" or "transparency" in source.info:
        raise SystemExit("Original must be an opaque RGB PNG")
    if source.width != source.height or source.width < 1024:
        raise SystemExit("Original must be square and at least 1024 pixels")
    if "icc_profile" in source.info:
        raise SystemExit("Original has an embedded profile; convert to sRGB explicitly")
    save_png(source.resize((1024, 1024), Image.Resampling.LANCZOS), output)


def compare_file(expected: Path, actual: Path) -> list[str]:
    if not actual.is_file():
        return [f"missing: {actual}"]
    if expected.read_bytes() != actual.read_bytes():
        return [f"out of date: {actual}"]
    return []


def check(master: Path, output: Path, manifest: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="khua-appicon-check.") as temporary:
        expected_master = Path(temporary) / "master.png"
        render_master(DEFAULT_ORIGINAL, expected_master)
        errors: list[str] = compare_file(expected_master, master)
        expected_output = Path(temporary) / "AppIcon.appiconset"
        expected_manifest = Path(temporary) / "export-manifest.json"
        manifest_value = render(master, expected_output)
        atomic_write(expected_manifest, stable_json(manifest_value))

        for size in SIZES:
            filename = f"AppIcon-{size}.png"
            errors.extend(compare_file(expected_output / filename, output / filename))
        errors.extend(compare_file(expected_output / "Contents.json", output / "Contents.json"))
        errors.extend(compare_file(expected_manifest, manifest))

        expected_pngs = {f"AppIcon-{size}.png" for size in SIZES}
        actual_pngs = {path.name for path in output.glob("*.png")}
        for filename in sorted(actual_pngs - expected_pngs):
            errors.append(f"unexpected PNG: {output / filename}")

        if errors:
            raise SystemExit("AppIcon verification failed:\n" + "\n".join(errors))

    print(f"AppIcon is reproducible and up to date: {output}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--master", type=Path, default=DEFAULT_MASTER)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--refresh-master", action="store_true", help="recreate master from the full-bleed original")
    parser.add_argument(
        "--check",
        action="store_true",
        help="regenerate in a temporary directory and compare without modifying files",
    )
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    master = arguments.master.resolve()
    output = arguments.output.resolve()
    manifest = arguments.manifest.resolve()
    if arguments.check and arguments.refresh_master:
        raise SystemExit("--check and --refresh-master cannot be combined")
    if arguments.check:
        check(master, output, manifest)
        return

    if arguments.refresh_master:
        render_master(DEFAULT_ORIGINAL, master)
    manifest_value = render(master, output)
    atomic_write(manifest, stable_json(manifest_value))
    print(f"Exported AppIcon: {output}")
    print(f"Wrote deterministic manifest: {manifest}")


if __name__ == "__main__":
    main()
