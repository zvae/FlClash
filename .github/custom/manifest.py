#!/usr/bin/env python3
"""Gates the collected release artifacts and writes the manifest, notes and sums.

Runs after every platform job. A single unsigned, unnotarized, mismatched or
unclaimed file fails the run before anything is published.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

GENERATED = {'SHA256SUMS', 'release-manifest.json', 'release.md'}
EXPECTED_PLATFORMS = {'android', 'windows', 'macos'}


def fail(message: str) -> None:
    print(f'::error::{message}')
    sys.exit(1)


def load_verifications(dist: Path) -> list[dict]:
    entries = []
    for path in sorted(dist.glob('verification-*.json')):
        try:
            entries.append(json.loads(path.read_text(encoding='utf-8')))
        except json.JSONDecodeError as error:
            fail(f'{path.name} is not valid JSON: {error}')
    if not entries:
        fail('no verification-*.json was uploaded by the platform jobs')
    return entries


def check_verification(entry: dict, expected: dict, signing_mode: str) -> None:
    name = f"verification-{entry.get('platform')}-{entry.get('arch', '')}"
    for key, value in expected.items():
        if entry.get(key) != value:
            fail(f'{name}: {key} is {entry.get(key)!r}, expected {value!r}')
    if entry.get('signed') is not True:
        fail(f'{name}: the artifacts are not signed')
    official = signing_mode == 'official'
    platform = entry.get('platform')
    if platform == 'macos':
        if entry.get('signingMode') != signing_mode:
            fail(f'{name}: signed in {entry.get("signingMode")!r} mode, this run expects {signing_mode!r}')
        if official:
            if entry.get('notarized') is not True:
                fail(f'{name}: the disk image is not notarized')
            if entry.get('stapled') is not True:
                fail(f'{name}: the notarization ticket is not stapled')
        elif entry.get('notarized') is not False:
            fail(f'{name}: a self-signed disk image cannot claim notarization')
    if platform == 'windows':
        signing = entry.get('signing', {})
        if signing.get('timestamped') is not True:
            fail(f'{name}: the signatures carry no timestamp')
        if signing.get('chainValidated') is not True:
            fail(f'{name}: the signature chain was not validated')
        if bool(signing.get('selfSigned')) != (not official):
            fail(f'{name}: the signature is not labelled self-signed correctly')
    if platform == 'android':
        if not entry.get('signing', {}).get('certificateSha256'):
            fail(f'{name}: the signing certificate was not recorded')


def collect_artifacts(dist: Path, entries: list[dict], app: str, version: str) -> list[Path]:
    claimed: dict[str, str] = {}
    for entry in entries:
        for name in entry.get('files', []):
            if name in claimed:
                fail(f'{name} is claimed by both {claimed[name]} and verification-{entry.get("platform")}')
            claimed[name] = f'verification-{entry.get("platform")}'

    artifacts = []
    for path in sorted(dist.iterdir()):
        if not path.is_file():
            continue
        if path.name in GENERATED or path.name.startswith('verification-'):
            continue
        if path.name not in claimed:
            fail(f'{path.name} is not covered by any platform verification')
        if not path.name.startswith(f'{app}-{version}-'):
            fail(f'{path.name} does not follow {app}-{version}-<platform>-<arch>.<ext>')
        artifacts.append(path)

    missing = sorted(set(claimed) - {path.name for path in artifacts})
    if missing:
        fail(f'verification lists files that are not in dist: {", ".join(missing)}')
    if not artifacts:
        fail('dist holds no artifact to publish')
    return artifacts


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def human_size(size: int) -> str:
    for unit in ('B', 'KiB', 'MiB', 'GiB'):
        if size < 1024 or unit == 'GiB':
            return f'{size:.0f} {unit}' if unit == 'B' else f'{size:.1f} {unit}'
        size /= 1024
    return f'{size:.1f} GiB'


def render_notes(manifest: dict) -> str:
    lines = [
        f'<!-- upstream-commit: {manifest["upstreamCommit"]} -->',
        f'# {manifest["appName"]} {manifest["tag"]}',
        '',
        f'Built from [{manifest["upstreamRepository"]}](https://github.com/{manifest["upstreamRepository"]})'
        f' tag `{manifest["upstreamTag"]}`, commit `{manifest["upstreamCommit"][:12]}`,'
        f' branded and signed by this repository.',
        '',
        '## Downloads',
        '',
        '| File | Size | SHA-256 |',
        '| --- | --- | --- |',
    ]
    for entry in manifest['files']:
        lines.append(f'| `{entry["name"]}` | {human_size(entry["size"])} | `{entry["sha256"]}` |')

    lines += ['', '## Signing', '']
    for platform, summary in manifest['signing'].items():
        for statement in summary:
            lines.append(f'- **{platform}**: {statement}')

    if manifest['signingMode'] == 'self-signed':
        lines += [
            '',
            '### Self-signed build',
            '',
            'These installers are signed with this repository\'s own certificate, not with a publicly trusted one.',
            '',
            '- Windows shows "Unknown publisher" and SmartScreen may block the first run. Check the signature and the '
            'SHA-256 above before running it, or trust the certificate from this repository first.',
            '- macOS shows "unidentified developer". Open the app with right-click, Open, or run '
            '`xattr -dr com.apple.quarantine /Applications/<App>.app` after installing it.',
            '- Nothing here is notarized by Apple, and no SmartScreen or Gatekeeper reputation is claimed.',
        ]

    lines += [
        '',
        '## Provenance',
        '',
        f'- Upstream tag: `{manifest["upstreamTag"]}`',
        f'- Upstream commit: `{manifest["upstreamCommit"]}`',
        f'- Source commit: `{manifest["sourceCommit"]}`',
        f'- Signing mode: `{manifest["signingMode"]}`',
        f'- Workflow run: {manifest["runUrl"]}',
        '',
        '`SHA256SUMS` and `release-manifest.json` cover every file above.',
        '',
    ]
    return '\n'.join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dist', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--app-name', required=True)
    parser.add_argument('--upstream-repository', required=True)
    parser.add_argument('--upstream-commit', required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--run-url', required=True)
    parser.add_argument('--signing-mode', default='self-signed', choices=['self-signed', 'official'])
    args = parser.parse_args(argv)

    dist = Path(args.dist)
    if not dist.is_dir():
        fail(f'{dist} does not exist')

    entries = load_verifications(dist)
    expected = {
        'tag': args.tag,
        'version': args.version,
        'sourceCommit': args.source_commit,
        'upstreamCommit': args.upstream_commit,
    }
    for entry in entries:
        check_verification(entry, expected, args.signing_mode)

    platforms = {entry.get('platform') for entry in entries}
    missing_platforms = EXPECTED_PLATFORMS - platforms
    if missing_platforms:
        fail(f'no verification for: {", ".join(sorted(missing_platforms))}')

    artifacts = collect_artifacts(dist, entries, args.app_name, args.version)

    files = []
    sums = []
    for path in artifacts:
        digest = sha256(path)
        files.append({'name': path.name, 'size': path.stat().st_size, 'sha256': digest})
        sums.append(f'{digest}  {path.name}')
    (dist / 'SHA256SUMS').write_text('\n'.join(sums) + '\n', encoding='utf-8')

    signing: dict[str, list[str]] = {}
    for entry in entries:
        platform = entry['platform']
        statements = signing.setdefault(platform, [])
        if platform == 'android':
            statements.append(
                f'APK signature verified with the release keystore (certificate SHA-256 '
                f'`{entry["signing"]["certificateSha256"]}`)'
            )
        elif platform == 'windows':
            statements.append(
                f'Authenticode signature on every executable and on the installer, subject '
                f'`{entry["signing"].get("subject")}`, timestamped, chain validated'
            )
        elif platform == 'macos':
            if args.signing_mode == 'official':
                statements.append(
                    f'{entry.get("arch")} disk image signed with `{entry["signing"].get("identity")}`, '
                    f'Hardened Runtime on, notarized ({entry["notarization"].get("status")}) and stapled'
                )
            else:
                statements.append(
                    f'{entry.get("arch")} disk image signed with `{entry["signing"].get("identity")}`, '
                    f'Hardened Runtime on, not notarized (self-signed)'
                )

    manifest = {
        'appName': args.app_name,
        'tag': args.tag,
        'version': args.version,
        'upstreamRepository': args.upstream_repository,
        'upstreamTag': args.tag,
        'upstreamCommit': args.upstream_commit,
        'sourceCommit': args.source_commit,
        'runUrl': args.run_url,
        'signingMode': args.signing_mode,
        'files': files,
        'signing': signing,
        'verifications': entries,
    }
    (dist / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    (dist / 'release.md').write_text(render_notes(manifest), encoding='utf-8')

    print(f'gate: {len(files)} artifact(s) across {", ".join(sorted(platforms))}')
    for entry in files:
        print(f'  {entry["name"]}  {entry["sha256"]}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
