#!/usr/bin/env python3
"""Validate the editable source and deterministic Khua AppIcon export."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import subprocess
import sys
import zlib
from PIL import Image
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SIZES = (16, 32, 64, 128, 256, 512, 1024)
EXPECTED_LAYERS = {
    "01-Background.png",
    "03-RearRibbons.png",
    "04-PlayTriangle.png",
}
EXPECTED_SLOTS = {
    ("AppIcon-16.png", "mac", "1x", "16x16"),
    ("AppIcon-32.png", "mac", "2x", "16x16"),
    ("AppIcon-32.png", "mac", "1x", "32x32"),
    ("AppIcon-64.png", "mac", "2x", "32x32"),
    ("AppIcon-128.png", "mac", "1x", "128x128"),
    ("AppIcon-256.png", "mac", "2x", "128x128"),
    ("AppIcon-256.png", "mac", "1x", "256x256"),
    ("AppIcon-512.png", "mac", "2x", "256x256"),
    ("AppIcon-512.png", "mac", "1x", "512x512"),
    ("AppIcon-1024.png", "mac", "2x", "512x512"),
}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def fail(message: str) -> None:
    raise SystemExit(f"AppIcon validation failed: {message}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def png_properties(path: Path) -> tuple[int, int, int, int, bool, bool]:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        fail(f"not a PNG: {path}")

    position = len(PNG_SIGNATURE)
    width = height = bit_depth = color_type = -1
    has_srgb = False
    has_transparency = False
    saw_iend = False
    while position < len(data):
        if position + 12 > len(data):
            fail(f"truncated PNG chunk: {path}")
        length = struct.unpack(">I", data[position : position + 4])[0]
        chunk_type = data[position + 4 : position + 8]
        chunk_start = position + 8
        chunk_end = chunk_start + length
        crc_end = chunk_end + 4
        if crc_end > len(data):
            fail(f"truncated PNG payload: {path}")
        payload = data[chunk_start:chunk_end]
        expected_crc = struct.unpack(">I", data[chunk_end:crc_end])[0]
        actual_crc = zlib.crc32(chunk_type)
        actual_crc = zlib.crc32(payload, actual_crc) & 0xFFFFFFFF
        if actual_crc != expected_crc:
            fail(f"invalid PNG CRC: {path}")

        if chunk_type == b"IHDR":
            if length != 13:
                fail(f"invalid IHDR length: {path}")
            width, height, bit_depth, color_type = struct.unpack(">IIBB", payload[:10])
        elif chunk_type == b"sRGB":
            has_srgb = True
        elif chunk_type == b"tRNS":
            has_transparency = True
        elif chunk_type == b"IEND":
            saw_iend = True
            position = crc_end
            break
        position = crc_end

    if not saw_iend or position != len(data):
        fail(f"invalid PNG ending: {path}")
    return width, height, bit_depth, color_type, has_srgb, has_transparency


def validate_png(path: Path, size: int) -> None:
    if not path.is_file():
        fail(f"missing PNG: {path}")
    width, height, bit_depth, color_type, has_srgb, has_transparency = png_properties(path)
    if (width, height) != (size, size):
        fail(f"wrong dimensions for {path}: {width}x{height}")
    if bit_depth != 8 or color_type != 2 or has_transparency:
        fail(f"{path} must be opaque 8-bit RGB; PNG color type is {color_type}")
    if not has_srgb:
        fail(f"missing sRGB declaration: {path}")
    with Image.open(path) as image:
        corners = [image.getpixel(point) for point in ((0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1))]
        if any(blue <= red for red, green, blue in corners):
            fail(f"expected blue background at each corner: {path}")
        edges = [[image.getpixel((i, 0)) for i in range(size)],
                 [image.getpixel((i, size - 1)) for i in range(size)],
                 [image.getpixel((0, i)) for i in range(size)],
                 [image.getpixel((size - 1, i)) for i in range(size)]]
        if any(sum(all(channel >= 240 for channel in pixel) for pixel in edge) > size * 0.9 for edge in edges):
            fail(f"near-white border detected: {path}")


def validate_icon_composer_source() -> None:
    document_path = ROOT / "KhuaPlayer.icon" / "icon.json"
    document = json.loads(document_path.read_text(encoding="utf-8"))
    groups = document.get("groups")
    if not isinstance(groups, list) or len(groups) != 1:
        fail("KhuaPlayer.icon must contain exactly one layer group")
    group = groups[0]
    layers = group.get("layers")
    if not isinstance(layers, list):
        fail("KhuaPlayer.icon layers are missing")
    referenced = {layer.get("image-name") for layer in layers}
    if referenced != EXPECTED_LAYERS:
        fail(f"unexpected Icon Composer layer set: {sorted(referenced)}")

    assets_dir = ROOT / "KhuaPlayer.icon" / "Assets"
    available = {path.name for path in assets_dir.glob("*.png")}
    if available != EXPECTED_LAYERS:
        fail(f"unexpected Icon Composer assets: {sorted(available)}")
    if group.get("specular") is not False:
        fail("Icon Composer group specular must remain disabled")
    translucency = group.get("translucency", {})
    if translucency.get("enabled") is not False:
        fail("Icon Composer group translucency must remain disabled")
    if group.get("shadow", {}).get("kind") != "none":
        fail("Icon Composer group shadow must remain disabled")


def validate_manifest() -> None:
    manifest = json.loads((ROOT / "export-manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1:
        fail("unsupported export-manifest.json schema")
    original = ROOT / "ChuanFlow-Xiaochuan-FullBleed-Original.png"
    if not original.is_file() or manifest.get("original", {}).get("sha256") != sha256(original) or manifest.get("original", {}).get("file") != original.name:
        fail("full-bleed original does not match export-manifest.json")
    master = ROOT / "KhuaPlayer-StaticMaster-1024.png"
    validate_png(master, 1024)
    source = manifest.get("source", {})
    if source.get("file") != master.name or source.get("sha256") != sha256(master):
        fail("static master does not match export-manifest.json")
    if (
        source.get("width") != 1024
        or source.get("height") != 1024
        or source.get("mode") != "RGB"
        or source.get("colorSpace") != "sRGB IEC61966-2.1"
    ):
        fail("static master metadata is invalid in export-manifest.json")
    export = manifest.get("export", {})
    if export.get("alpha") is not False or export.get("colorSpace") != "sRGB IEC61966-2.1":
        fail("production export must remain opaque RGB sRGB")

    records = manifest.get("files")
    if not isinstance(records, list):
        fail("export-manifest.json files are missing")
    by_name = {record.get("file"): record for record in records}
    expected_names = {f"AppIcon-{size}.png" for size in SIZES}
    if set(by_name) != expected_names:
        fail("export-manifest.json has an unexpected file set")

    appiconset = ROOT / "AppIcon.appiconset"
    contents = json.loads((appiconset / "Contents.json").read_text(encoding="utf-8"))
    images = contents.get("images")
    if not isinstance(images, list):
        fail("AppIcon Contents.json images are missing")
    slots = {
        (image.get("filename"), image.get("idiom"), image.get("scale"), image.get("size"))
        for image in images
    }
    if len(images) != len(EXPECTED_SLOTS) or slots != EXPECTED_SLOTS:
        fail("AppIcon Contents.json does not contain the required macOS slots")
    for size in SIZES:
        filename = f"AppIcon-{size}.png"
        path = appiconset / filename
        validate_png(path, size)
        record = by_name[filename]
        if record.get("sha256") != sha256(path):
            fail(f"hash mismatch in export-manifest.json: {filename}")
        if record.get("width") != size or record.get("height") != size:
            fail(f"dimension mismatch in export-manifest.json: {filename}")
        if record.get("mode") != "RGB":
            fail(f"mode mismatch in export-manifest.json: {filename}")


def validate_asset_manifest() -> None:
    manifest_path = ROOT / "asset-manifest.txt"
    listed = {
        line.strip()
        for line in manifest_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    actual: set[str] = set()
    for path in ROOT.rglob("*"):
        if path.is_symlink():
            fail(f"source tree must not contain symlinks: {path}")
        if path.is_file() and "__pycache__" not in path.parts:
            actual.add(path.relative_to(ROOT).as_posix())
    if listed != actual:
        missing = sorted(listed - actual)
        unexpected = sorted(actual - listed)
        fail(f"asset-manifest mismatch; missing={missing}, unexpected={unexpected}")


def validate_shipping_copy(shipping: Path) -> None:
    canonical = ROOT / "AppIcon.appiconset"
    for filename in ["Contents.json", *(f"AppIcon-{size}.png" for size in SIZES)]:
        source = canonical / filename
        destination = shipping / filename
        if not destination.is_file():
            fail(f"shipping AppIcon is missing: {destination}")
        if source.read_bytes() != destination.read_bytes():
            fail(f"shipping AppIcon is out of date: {destination}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--shipping",
        type=Path,
        help="optional Xcode AppIcon.appiconset that must match the canonical export",
    )
    return parser.parse_args()


def main() -> None:
    arguments = parse_args()
    validate_icon_composer_source()
    validate_manifest()
    validate_asset_manifest()
    subprocess.run([sys.executable, str(ROOT / "export_static_appicon.py"), "--check"], check=True)
    if arguments.shipping is not None:
        validate_shipping_copy(arguments.shipping.resolve())
    print(f"AppIcon source and export validation passed: {ROOT}")


if __name__ == "__main__":
    main()
