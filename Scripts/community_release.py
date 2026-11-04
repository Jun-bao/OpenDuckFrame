#!/usr/bin/env python3
"""Package and optionally publish an ad-hoc Mac build with signed Sparkle updates.

This lane never represents an ad-hoc package as Developer ID signed or notarized.
Private update keys stay in the login Keychain. Run --help before publishing.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def run(args, **kwargs):
    return subprocess.check_output([str(x) for x in args], text=True, **kwargs).strip()


def digest(path):
    return hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()


def plist(path):
    return plistlib.loads(path.read_bytes())


def write_plist(path, value):
    path.write_bytes(plistlib.dumps(value))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='existing verified Release app; never modified')
    parser.add_argument('--verification-root', type=Path, default=ROOT, help='source checkout holding the matching dependency stamps and Sparkle tools')
    parser.add_argument('--version', required=True)
    parser.add_argument('--build-number', required=True, type=int)
    parser.add_argument('--binary-source-commit', required=True, help='full commit used to compile the supplied app')
    parser.add_argument('--notes', type=Path, required=True, help='HTML release notes, embedded in the signed feed')
    parser.add_argument('--output', type=Path, required=True, help='new output directory')
    parser.add_argument('--previous-feed', type=Path, help='existing signed appcast, to preserve earlier releases')
    parser.add_argument('--publish', action='store_true', help='publish GitHub release assets, then update the gh-pages feed')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.version) or args.build_number < 1:
        parser.error('use a semantic version and a positive build number')
    if not re.fullmatch(r'[0-9a-f]{40}', args.binary_source_commit):
        parser.error('binary source commit must be a full commit ID')
    app, verification, output = args.app.resolve(), args.verification_root.resolve(), args.output.resolve()
    notes = args.notes.resolve()
    if output.exists() or not notes.is_file():
        parser.error('output must not exist and release notes must be an existing file')
    config = json.loads((ROOT / 'Distribution/sparkle.json').read_text())
    repo, feed, key, account = (config[k] for k in ('repository', 'feedUrl', 'publicKey', 'keychainAccount'))
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repo) or not feed.startswith('https://') or not key:
        parser.error('configure a repository, HTTPS appcast and public key first')
    tools = verification / 'ThirdParty/sparkle-min/bin'
    if run([tools / 'generate_keys', '--account', account, '-p']) != key:
        raise SystemExit('Keychain public key does not match the release configuration')
    source = plist(app / 'Contents/Info.plist')
    if source.get('CFBundleIdentifier') != 'app.openduckframe.OpenDuckFrame':
        raise SystemExit('unexpected source application identity')
    if source.get('CFBundleShortVersionString') != args.version:
        raise SystemExit('source app version differs from requested release; compile that version first')
    run([verification / 'Scripts/verify_app_bundle.sh', app])
    run(['git', '-C', ROOT, 'cat-file', '-e', args.binary_source_commit + '^{commit}'])
    tag = 'v' + args.version
    published_feed = None
    if args.publish:
        current_repo = json.loads(run(['gh', 'api', 'repos/' + repo]))
        if not current_repo['permissions']['push'] or current_repo['private']:
            raise SystemExit('release repository must be public and writable')
        prior = json.loads(run(['gh', 'api', 'repos/' + repo + '/releases?per_page=100']))
        if any(r['tag_name'] == tag for r in prior):
            raise SystemExit('release tag already exists; never replace published artifacts')
        if run(['git', 'ls-remote', f'https://github.com/{repo}.git', 'refs/heads/gh-pages']):
            remote = json.loads(run(['gh', 'api', f'repos/{repo}/contents/appcast.xml?ref=gh-pages']))
            published_feed = base64.b64decode(remote['content'])
    output.mkdir(parents=True)
    stage = output / 'staging'
    stage.mkdir()
    staged = stage / 'OpenDuckFrame.app'
    run(['ditto', app, staged])
    info = staged / 'Contents/Info.plist'
    value = plist(info)
    for k in list(value):
        if k.startswith('SU') or k == 'SPUpdateUsageEnabled':
            del value[k]
    value.update(CFBundleVersion=str(args.build_number), SUFeedURL=feed,
                 SUPublicEDKey=key, SUEnableAutomaticChecks=True,
                 SUEnableSystemProfiling=False, SUVerifyUpdateBeforeExtraction=True,
                 SURequireSignedFeed=True, SUAutomaticallyUpdate=False,
                 ODFRepositoryURL='https://github.com/' + repo)
    write_plist(info, value)
    (staged / 'Contents/Resources/PRIVACY.md').write_bytes((ROOT / 'PRIVACY.md').read_bytes())
    for extension in (staged / 'Contents/PlugIns').glob('*.appex'):
        p = extension / 'Contents/Info.plist'
        v = plist(p)
        v.update(CFBundleVersion=str(args.build_number), CFBundleShortVersionString=args.version)
        write_plist(p, v)
        run(['codesign', '--force', '--sign', '-', '--preserve-metadata=entitlements', extension])
    run(['codesign', '--force', '--sign', '-', staged])
    run([verification / 'Scripts/verify_app_bundle.sh', staged])
    archive = output / f'OpenDuckFrame-{args.version}.zip'
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', staged, archive])
    with tempfile.TemporaryDirectory(prefix='odf-release-roundtrip-') as temporary:
        restored = Path(temporary) / 'OpenDuckFrame.app'
        run(['ditto', '-x', '-k', archive, temporary])
        run([verification / 'Scripts/verify_app_bundle.sh', restored])
        if plist(restored / 'Contents/Info.plist') != value:
            raise SystemExit('archive round-trip changed release metadata')
    dmgtree = output / 'dmg-content'
    dmgtree.mkdir()
    run(['ditto', staged, dmgtree / staged.name])
    (dmgtree / 'Applications').symlink_to('/Applications')
    dmg = output / 'OpenDuckFrame.dmg'
    run(['hdiutil', 'create', '-ov', '-format', 'UDZO', '-volname', 'OpenDuckFrame', '-srcfolder', dmgtree, dmg])
    run(['hdiutil', 'verify', dmg])
    feeds = output / 'feed'
    feeds.mkdir()
    feedzip = feeds / archive.name
    run(['ditto', archive, feedzip])
    (feeds / (archive.stem + '.html')).write_bytes(notes.read_bytes())
    if published_feed is not None or args.previous_feed:
        previous = output / 'previous-appcast.xml'
        previous.write_bytes(published_feed if published_feed is not None else args.previous_feed.read_bytes())
        run([tools / 'sign_update', '--account', account, '--verify', previous])
        versions = [int(n.text) for n in ET.parse(previous).findall('.//' + SPARKLE + 'version') if n.text and n.text.isdigit()]
        if versions and args.build_number <= max(versions):
            raise SystemExit('build number must exceed the published feed')
        (feeds / 'appcast.xml').write_bytes(previous.read_bytes())
    run([tools / 'generate_appcast', '--account', account, '--maximum-deltas', '0',
         '--download-url-prefix', f'https://github.com/{repo}/releases/download/{tag}/',
         '--embed-release-notes', '--link', f'https://github.com/{repo}', feeds])
    feedfile = feeds / 'appcast.xml'
    run([tools / 'sign_update', '--account', account, '--verify', feedfile])
    record = {'version': args.version, 'build': args.build_number, 'bundleIdentifier': value['CFBundleIdentifier'],
              'binarySourceCommit': args.binary_source_commit, 'packagingCommit': run(['git', '-C', ROOT, 'rev-parse', 'HEAD']),
              'codeSigning': 'ad-hoc', 'appleNotarized': False, 'updateFeed': feed, 'updatePublicKey': key,
              'sourceExecutableSHA256': digest(app / 'Contents/MacOS/OpenDuckFrame'),
              'artifacts': {p.name: digest(p) for p in (archive, dmg, feedfile)}}
    (output / 'release-record.json').write_text(json.dumps(record, indent=2) + '\n')
    sums = output / 'SHA256SUMS.txt'
    sums.write_text(''.join(f'{digest(p)}  {p.name}\n' for p in (archive, dmg)))
    print(f'Prepared {args.version} ({args.build_number}); app, archive round-trip and signed feed verified.')
    if args.publish:
        run(['gh', 'release', 'create', tag, '--repo', repo, '--draft', '--target', run(['git', '-C', ROOT, 'rev-parse', 'HEAD']),
             '--title', 'OpenDuckFrame ' + args.version, '--notes-file', notes,
             archive, dmg, sums, output / 'release-record.json'])
        run(['gh', 'release', 'edit', tag, '--repo', repo, '--draft=false', '--latest'])
        with tempfile.TemporaryDirectory(prefix='odf-feed-publish-') as temporary:
            folder = Path(temporary)
            exists = bool(run(['git', 'ls-remote', f'https://github.com/{repo}.git', 'refs/heads/gh-pages']))
            if exists:
                run(['git', 'clone', '--quiet', '--single-branch', '--branch', 'gh-pages', f'https://github.com/{repo}.git', folder])
            else:
                run(['git', 'init', '-b', 'gh-pages', folder])
                run(['git', '-C', folder, 'remote', 'add', 'origin', f'https://github.com/{repo}.git'])
            for setting in ('user.name', 'user.email'):
                run(['git', '-C', folder, 'config', setting, run(['git', '-C', ROOT, 'config', setting])])
            (folder / 'appcast.xml').write_bytes(feedfile.read_bytes())
            (folder / '.nojekyll').touch()
            run(['git', '-C', folder, 'add', 'appcast.xml', '.nojekyll'])
            run(['git', '-C', folder, '-c', 'commit.gpgsign=false', 'commit', '-m', f'Publish updates for {args.version} ({args.build_number})'])
            run(['git', '-C', folder, 'push', 'origin', 'HEAD:gh-pages'])
        print(f'Published https://github.com/{repo}/releases/tag/{tag}; feed branch updated.')


if __name__ == '__main__':
    main()
