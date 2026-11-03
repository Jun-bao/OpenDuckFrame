#!/usr/bin/env python3
"""Validate the public product source and repository boundary."""
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

from lib.runtime_source import MANAGED, runtime_files
from verify_public_surface import check_file
from l10n import supported_languages

ROOT = Path(__file__).resolve().parents[1]


def fail(message):
    raise SystemExit(f'error: {message}')


def check_paths_and_contents(root, paths):
    """Scan tracked and non-ignored new files; never print a secret's contents."""
    artifact = re.compile(r'(^|/)(?:[^/]+\.(?:app|dSYM|xcarchive)(?:/|$)|[^/]+\.(?:dmg|ipa|zip|p12|pfx|pem|key)$|\.env(?:\.[^/]+)?$|\.DS_Store$)', re.I)
    machine = re.compile(r'(?<![\w/])/(?:Users|home)/[A-Za-z0-9._-]+(?:/|\b)|(?<![\w/])/' + 'Volumes' + r'/[^/\s,]+/[^\s,]+|(?<![\w/])/(?:private/)?var/folders/[A-Za-z0-9._-]+/')
    private_key = re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----')
    token = re.compile(r'(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)[\"\']?\s*[:=]\s*["\']([^"\'\s]{12,})["\']')
    for relative in paths:
        if relative.endswith('/.env.example') or relative == '.env.example':
            pass
        elif artifact.search(relative):
            fail(f'credential or generated artifact present: {relative}')
        path = root / relative
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as f:
            head = f.read(8192)
            if b'\0' in head:
                continue
            raw = head + f.read()
        try:
            text = raw.decode('utf-8')
        except UnicodeDecodeError:
            continue
        for line_number, line in enumerate(text.splitlines(), 1):
            if machine.search(line) or private_key.search(line):
                fail(f'personal path or private key in {relative}:{line_number}')
            match = token.search(line)
            if match and not any(p in match.group(1).lower() for p in ('example', 'placeholder', 'your_', '${', 'dummy', 'redacted', 'changeme')):
                fail(f'possible embedded credential in {relative}:{line_number}')


def main():
    paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).split(b'\0')
    check_paths_and_contents(ROOT, [os.fsdecode(p) for p in paths if p])
    files = runtime_files(ROOT)
    for relative in MANAGED:
        if not any(p == relative or p.startswith(relative + '/') for p in files):
            fail(f'empty required runtime source: {relative}')
    for relative in ('Apps/Mac/Capture/SPLiveProcessor.mm', 'Apps/Mac/Capture/SPLowLatencyEngine.mm',
                     'Apps/Mac/UI/Enhancement/EnhancementWorkbench.swift', 'Apps/Mac/Resources/Localizable.xcstrings'):
        if not (ROOT / relative).is_file():
            fail(f'missing required product source: {relative}')
    for path in files.values():
        check_file(path)
    for path in (ROOT / 'Apps/Mac/Capture').rglob('*'):
        if path.is_file():
            check_file(path)
    for relative in ('README.md', 'README.zh-CN.md', 'CONTRIBUTING.md',
                     'SECURITY.md', 'LICENSE', 'PRIVACY.md', 'TRADEMARK.md',
                     'THIRD_PARTY_NOTICES.md', 'REPOSITORY_LAYOUT.md',
                     'docs/quick-start.md', 'docs/features.md'):
        if not (ROOT / relative).is_file():
            fail(f'missing public documentation: {relative}')
    catalog = json.loads((ROOT / 'Apps/Mac/Resources/Localizable.xcstrings').read_text())
    names = catalog['strings']['app.displayName']['localizations']
    expected = {language: ('OpenDuckFrame' if language == 'zh-Hans' else 'OpenDuckFrame' if language == 'zh-Hant' else 'OpenDuckFrame') for language in supported_languages()}
    actual = {language: record.get('stringUnit', {}).get('value') for language, record in names.items()}
    if actual != expected:
        fail('app.displayName does not match the supported localized product names')
    for key, entry in catalog['strings'].items():
        for language, record in entry.get('localizations', {}).items():
            value = record.get('stringUnit', {}).get('value', '')
            if re.search(r'(?i)\bk[h]ua\b(?!\.)', value):
                fail(f'old user-visible product name in {key} ({language})')
    plist = plistlib.loads((ROOT / 'Apps/Mac/Info.plist').read_bytes())
    for key, value in {'CFBundleName': 'OpenDuckFrame', 'CFBundleDisplayName': '$(ODF_DISPLAY_NAME)', 'SPProductName': 'OpenDuckFrame'}.items():
        if plist.get(key) != value:
            fail(f'product Info.plist {key} does not match the current brand')
    project = (ROOT / 'Apps/Mac/project.yml').read_text()
    for line in ('ODF_DISPLAY_NAME: OpenDuckFrame', 'CFBundleName: OpenDuckFrame', 'CFBundleDisplayName: $(ODF_DISPLAY_NAME)', 'SPProductName: OpenDuckFrame', 'PRODUCT_NAME: OpenDuckFrame', 'EXECUTABLE_NAME: OpenDuckFrame'):
        if not re.search(r'^\s*' + re.escape(line) + r'\s*$', project, re.M):
            fail(f'project metadata missing {line}')
    print(f'Public product source and repository boundary checks passed ({len(files)} managed runtime files plus live capture).')


if __name__ == '__main__':
    main()
