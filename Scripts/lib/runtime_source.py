#!/usr/bin/env python3
"""Public runtime ownership and deterministic source fingerprints."""
import hashlib
import os
from pathlib import Path
import sys

MANAGED = (
    'Modules/VideoEnhancement',
    'Modules/MediaCore/Bridge', 'Modules/MediaCore/Core', 'Modules/MediaCore/Shaders',
    'Modules/Captions', 'Platform/macOS/Audio', 'Platform/macOS/Rendering',
    'Apps/Mac/UI', 'Apps/Mac/CaptionsHost', 'Apps/Mac/CaptionsUI',
    'Apps/Mac/QuickLook/Preview', 'Apps/Mac/Support/OpenDuckFrame-Bridging-Header.h',
    'Apps/Mac/Resources/Localizable.xcstrings',
)
LEGACY = ('Bridge', 'Core', 'Shaders', 'UI', 'Captions', 'CaptionsUI',
          'QuickLook/Preview', 'Resources/Localizable.xcstrings')


def checked_path(root, relative):
    candidate = root
    if candidate.is_symlink():
        raise ValueError(f'managed root must not be a symlink: {candidate}')
    for part in Path(relative).parts:
        candidate /= part
        if candidate.is_symlink():
            raise ValueError(f'managed path must not be a symlink: {candidate}')
    return candidate


def runtime_files(root):
    for relative in LEGACY:
        path = checked_path(root, relative)
        if path.is_symlink() or path.is_file() or (path.is_dir() and any(path.rglob('*'))):
            raise ValueError(f'obsolete runtime path remains: {relative}')
    result = {}
    for relative in MANAGED:
        candidate = checked_path(root, relative)
        if not candidate.exists():
            raise ValueError(f'missing managed source: {relative}')
        for path in ([candidate] if candidate.is_file() else candidate.rglob('*')):
            if path.is_symlink():
                raise ValueError(f'managed source must not be a symlink: {path}')
            if path.is_file():
                result[path.relative_to(root).as_posix()] = path
            elif not path.is_dir():
                raise ValueError(f'nonregular managed source: {path}')
    return result


def managed_digest(root):
    files = runtime_files(root)
    digest = hashlib.sha256()
    for relative in sorted(files, key=os.fsencode):
        name = os.fsencode(relative)
        contents = files[relative].read_bytes()
        digest.update(len(name).to_bytes(8, 'big'))
        digest.update(name)
        digest.update(len(contents).to_bytes(8, 'big'))
        digest.update(contents)
    return digest.hexdigest()


if __name__ == '__main__':
    try:
        print(managed_digest(Path(sys.argv[1]).resolve()))
    except (ValueError, OSError) as error:
        raise SystemExit(f'error: {error}')
