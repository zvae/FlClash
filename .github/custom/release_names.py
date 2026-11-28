#!/usr/bin/env python3
"""Single source of truth for this pipeline's release artifact names.

Both sides of the update check derive their names from here: the client hooks
apply.py writes into the branded app, and the artifact gate manifest.py runs
before publishing. An ABI or platform change is made once, and the gate checks
that the two sides still agree.
"""

from __future__ import annotations

# Flutter's --split-per-abi suffix, which android_verify.sh stages verbatim and
# the branded client must request for the checksum lookup to succeed.
ANDROID_ABIS = ('arm64-v8a', 'armeabi-v7a', 'x86_64')
MACOS_ARCHES = ('amd64', 'arm64')
WINDOWS_FILES = ('windows-amd64.exe', 'windows-amd64.zip')

# ReleaseArch.name -> Android artifact suffix, emitted into the client hook.
ARCH_TO_ABI = {
    'arm64': 'arm64-v8a',
    'armv7': 'armeabi-v7a',
    'amd64': 'x86_64',
}


assert set(ARCH_TO_ABI.values()) == set(ANDROID_ABIS), (
    'the client arch map and the staged ABI suffixes must describe the same APKs'
)


def expected_assets(app: str, version: str) -> set[str]:
    """Every file the release must publish for the client to update cleanly."""
    base = f'{app}-{version}-'
    names = {f'{base}android-{abi}.apk' for abi in ANDROID_ABIS}
    names |= {f'{base}macos-{arch}.dmg' for arch in MACOS_ARCHES}
    names |= {base + suffix for suffix in WINDOWS_FILES}
    return names


def update_asset_hook() -> str:
    """Dart body for updateAssetName, with the ABI map generated from ARCH_TO_ABI.

    The switch keys on (os, arch), not just arch: amd64 is x86_64 on Android but
    stays amd64 in the Windows and macOS artifact names.
    """
    cases = '\n'.join(
        f"    (ReleaseOs.android, ReleaseArch.{arch}) => '{abi}',"
        for arch, abi in ARCH_TO_ABI.items()
    )
    return (
        'String updateAssetName(String tag, SelfUpdateAsset asset) {\n'
        '  final arch = switch ((asset.os, asset.arch)) {\n'
        f'{cases}\n'
        '    (_, final other) => other.name,\n'
        '  };\n'
        '  final version = releaseVersionOfTag(tag);\n'
        "  return '$appName-$version-${asset.os.name}-$arch.${asset.extension}';\n"
        '}'
    )


UPDATE_CHECKSUMS_HOOK = '''String updateChecksumsName(String tag) {
  return 'SHA256SUMS';
}'''
