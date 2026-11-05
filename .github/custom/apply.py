#!/usr/bin/env python3
"""Applies the brand configuration to a checkout of the FlClash sources.

Text branding always runs: application name, Android application id, macOS
bundle id, and the Windows product strings. Icon replacement is opt-in through
``replaceIcon`` and degrades to the upstream icons whenever the custom icon is
missing or unusable, because a missing icon must never fail a build.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

CONFIG_PATH = Path('.github/custom/brand.json')
ICON_PATH = Path('.github/custom/icons/app-icon.png')
STATE_PATH = Path('.github/custom/.branding/state.json')

DEFAULTS: dict[str, object] = {
    'appName': 'FlClash',
    'androidApplicationId': 'com.follow.clash',
    'macosBundleId': 'com.follow.clash',
    'windowsProductName': 'FlClash',
    'windowsCompanyName': 'com.follow',
    'windowsPublisherUrl': 'https://github.com/chen08209/FlClash',
    'repository': 'chen08209/FlClash',
    'telegramUrl': 'https://t.me/FlClash',
    'replaceIcon': False,
    'signingMode': 'self-signed',
}

SIGNING_MODES = ('self-signed', 'official')

ANDROID_ID_RE = re.compile(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$')
WINDOWS_NAME_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
REPOSITORY_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$')

TELEGRAM_ITEM = re.compile(
    r"\n[ \t]*_buildLinkItem\(\n"
    r"[ \t]*glyph: AppGlyphs\.send,\n"
    r"[ \t]*title: 'Telegram',\n"
    r"[ \t]*url: '[^']*',\n"
    r"[ \t]*label: '[^']*',\n"
    r"[ \t]*\),"
)

ANDROID_LAUNCHER_SIZES = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
}
MACOS_ICON_SIZES = (16, 32, 64, 128, 256, 512, 1024)
WINDOWS_ICON_SIZES = (16, 24, 32, 48, 64, 128, 256)


def load_config(root: Path) -> dict[str, object]:
    config = dict(DEFAULTS)
    path = root / CONFIG_PATH
    if path.exists():
        loaded = json.loads(path.read_text(encoding='utf-8'))
        if not isinstance(loaded, dict):
            raise SystemExit(f'branding: {path} must hold a JSON object')
        unknown = sorted(set(loaded) - set(DEFAULTS))
        if unknown:
            raise SystemExit(f'branding: unknown keys in {path}: {", ".join(unknown)}')
        config.update(loaded)

    for key, value in config.items():
        if key == 'replaceIcon':
            if not isinstance(value, bool):
                raise SystemExit(f'branding: {key} must be true or false')
            continue
        if key == 'telegramUrl':
            # An empty value drops the Telegram row from the about page.
            if not isinstance(value, str):
                raise SystemExit(f'branding: {key} must be a string')
            if value and not value.startswith(('http://', 'https://')):
                raise SystemExit(f'branding: {key} must be an http(s) URL or empty: {value}')
            continue
        if not isinstance(value, str) or not value.strip():
            raise SystemExit(f'branding: {key} must be a non-empty string')

    if not REPOSITORY_RE.match(config['repository']):  # type: ignore[arg-type]
        raise SystemExit(
            'branding: repository must look like owner/name, it drives the update check: '
            f'{config["repository"]}'
        )

    if config['signingMode'] not in SIGNING_MODES:
        raise SystemExit(f'branding: signingMode must be one of {", ".join(SIGNING_MODES)}')
    for key in ('androidApplicationId', 'macosBundleId'):
        if not ANDROID_ID_RE.match(config[key]):  # type: ignore[arg-type]
            raise SystemExit(f'branding: {key} is not a valid reverse-domain id: {config[key]}')
    if not WINDOWS_NAME_RE.match(config['windowsProductName']):  # type: ignore[arg-type]
        raise SystemExit(
            'branding: windowsProductName becomes the executable name, so it may only '
            f'hold letters, digits, dot, dash and underscore: {config["windowsProductName"]}'
        )
    return config


def substitute(path: Path, pattern: str, replacement: str, changed: list[str], root: Path) -> None:
    if not path.exists():
        raise SystemExit(f'branding: expected {path} to exist')
    text = path.read_text(encoding='utf-8')
    updated, count = re.subn(pattern, lambda _: replacement, text, count=1, flags=re.MULTILINE)
    if count == 0:
        if replacement in text:
            return
        raise SystemExit(f'branding: {pattern!r} not found in {path}')
    if updated != text:
        path.write_text(updated, encoding='utf-8')
        changed.append(str(path.relative_to(root)))


def insert_after(path: Path, pattern: str, lines: list[str], changed: list[str], root: Path) -> None:
    """Adds lines after the first match, keeping its indentation and staying idempotent."""
    text = path.read_text(encoding='utf-8')
    if all(f'{line}' in text for line in lines):
        return
    match = re.search(pattern, text, flags=re.MULTILINE)
    if match is None:
        raise SystemExit(f'branding: {pattern!r} not found in {path}')
    indent = match.group(1) if match.groups() else '    '
    insertion = ''.join(f'\n{indent}{line}' for line in lines)
    path.write_text(text[: match.end()] + insertion + text[match.end() :], encoding='utf-8')
    changed.append(str(path.relative_to(root)))


def apply_android(root: Path, config: dict[str, object], changed: list[str]) -> None:
    app_name = str(config['appName'])
    application_id = str(config['androidApplicationId'])

    substitute(
        root / 'android/app/build.gradle.kts',
        r'applicationId = "[^"]*"',
        f'applicationId = "{application_id}"',
        changed,
        root,
    )
    substitute(
        root / 'android/common/src/main/res/values/strings.xml',
        r'<string name="app_name">[^<]*</string>',
        f'<string name="app_name">{app_name}</string>',
        changed,
        root,
    )
    # Honor and Huawei installers read the certificate from the JAR signature and
    # report "no certificate" for a v2-only APK, which is what upstream ships.
    insert_after(
        root / 'android/app/build.gradle.kts',
        r'^([ \t]*)keyPassword = releaseKeyPassword$',
        ['enableV1Signing = true', 'enableV2Signing = true'],
        changed,
        root,
    )


def apply_macos(root: Path, config: dict[str, object], changed: list[str]) -> None:
    app_info = root / 'macos/Runner/Configs/AppInfo.xcconfig'
    substitute(app_info, r'^PRODUCT_NAME = .*$', f'PRODUCT_NAME = {config["appName"]}', changed, root)
    substitute(
        app_info,
        r'^PRODUCT_BUNDLE_IDENTIFIER = .*$',
        f'PRODUCT_BUNDLE_IDENTIFIER = {config["macosBundleId"]}',
        changed,
        root,
    )
    substitute(
        root / 'macos/packaging/dmg/make_config.yaml',
        r'^title: .*$',
        f'title: {config["appName"]}',
        changed,
        root,
    )
    substitute(
        root / 'macos/packaging/dmg/make_config.yaml',
        r'^    path: .*\.app$',
        f'    path: {config["appName"]}.app',
        changed,
        root,
    )


def apply_windows(root: Path, config: dict[str, object], changed: list[str]) -> None:
    product_name = str(config['windowsProductName'])
    company = str(config['windowsCompanyName'])
    cmake = root / 'windows/CMakeLists.txt'
    substitute(cmake, r'^project\(.* LANGUAGES CXX\)$', f'project({product_name} LANGUAGES CXX)', changed, root)
    substitute(cmake, r'^set\(BINARY_NAME ".*"\)$', f'set(BINARY_NAME "{product_name}")', changed, root)

    rc = root / 'windows/runner/Runner.rc'
    substitute(rc, r'VALUE "CompanyName", "[^"]*"', f'VALUE "CompanyName", "{company}"', changed, root)
    substitute(rc, r'VALUE "FileDescription", "[^"]*"', f'VALUE "FileDescription", "{product_name}"', changed, root)
    substitute(rc, r'VALUE "ProductName", "[^"]*"', f'VALUE "ProductName", "{product_name}"', changed, root)
    substitute(
        rc,
        r'VALUE "OriginalFilename", "[^"]*"',
        f'VALUE "OriginalFilename", "{product_name}.exe"',
        changed,
        root,
    )
    substitute(
        root / 'windows/runner/main.cpp',
        r'window\.Create\(L"[^"]*"',
        f'window.Create(L"{product_name}"',
        changed,
        root,
    )


def apply_links(root: Path, config: dict[str, object], changed: list[str]) -> None:
    """Points the in-app links at this repository instead of upstream."""
    repository_value = str(config['repository'])
    substitute(
        root / 'lib/common/constant.dart',
        r"^const repository = '[^']*';$",
        f"const repository = '{repository_value}';",
        changed,
        root,
    )

    about = root / 'lib/views/about.dart'
    telegram = str(config['telegramUrl']).strip()
    if telegram:
        label = telegram.split('://', 1)[-1].rstrip('/')
        substitute(about, r"url: 'https://t\.me/[^']*'", f"url: '{telegram}'", changed, root)
        substitute(about, r"label: 't\.me/[^']*'", f"label: '{label}'", changed, root)
        return

    text = about.read_text(encoding='utf-8')
    updated, count = TELEGRAM_ITEM.subn('', text, count=1)
    if count == 0:
        print('branding: no Telegram link to drop from the about page', file=sys.stderr)
        return
    about.write_text(updated, encoding='utf-8')
    changed.append(str(about.relative_to(root)))


def _load_icon(root: Path, platform_icons: list[tuple[Path, object]]) -> None:
    """Writes every platform icon from the custom source image."""
    from PIL import Image, ImageDraw

    source = root / ICON_PATH
    image = Image.open(source)
    image.load()
    image = image.convert('RGBA')
    width, height = image.size
    if min(width, height) < 512:
        raise ValueError(f'{ICON_PATH} is {width}x{height}, needs at least 512x512')
    if abs(width - height) > max(2, min(width, height) // 50):
        raise ValueError(f'{ICON_PATH} is {width}x{height}, needs to be square')

    def resize(size: int, rounded: bool) -> Image.Image:
        layer = image.resize((size, size), Image.LANCZOS)
        if not rounded:
            return layer
        mask = Image.new('L', (size * 4, size * 4), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
        layer.putalpha(mask.resize((size, size), Image.LANCZOS))
        return layer

    for path, size in platform_icons:
        path.parent.mkdir(parents=True, exist_ok=True)
        suffix = path.suffix.lower()
        rounded = path.stem.endswith('_round')
        layer = resize(int(size), rounded)
        if suffix == '.ico':
            layer.save(path, format='ICO', sizes=[(s, s) for s in WINDOWS_ICON_SIZES])
        elif suffix == '.webp':
            layer.save(path, format='WEBP', lossless=True)
        else:
            layer.save(path, format='PNG')


def android_icon_targets(root: Path) -> list[tuple[Path, object]]:
    res = root / 'android/app/src/main/res'
    targets: list[tuple[Path, object]] = []
    for density, size in ANDROID_LAUNCHER_SIZES.items():
        targets.append((res / f'mipmap-{density}/ic_launcher.webp', size))
        targets.append((res / f'mipmap-{density}/ic_launcher_round.webp', size))
        tv = res / f'mipmap-television-{density}/ic_launcher.webp'
        if tv.parent.exists():
            targets.append((tv, size))
    return targets


def macos_icon_targets(root: Path) -> list[tuple[Path, object]]:
    iconset = root / 'macos/Runner/Assets.xcassets/AppIcon.appiconset'
    return [(iconset / f'app_icon_{size}.png', size) for size in MACOS_ICON_SIZES]


def windows_icon_targets(root: Path) -> list[tuple[Path, object]]:
    return [(root / 'windows/runner/resources/app_icon.ico', 256)]


def replace_icons(root: Path, platform: str, changed: list[str]) -> bool:
    source = root / ICON_PATH
    if not source.exists():
        print(f'branding: {ICON_PATH} is missing, keeping the upstream icons', file=sys.stderr)
        return False
    targets: list[tuple[Path, object]] = []
    if platform in ('android', 'all'):
        targets += android_icon_targets(root)
    if platform in ('macos', 'all'):
        targets += macos_icon_targets(root)
    if platform in ('windows', 'all'):
        targets += windows_icon_targets(root)
    try:
        _load_icon(root, targets)
    except ImportError:
        print('branding: Pillow is not installed, keeping the upstream icons', file=sys.stderr)
        return False
    except Exception as error:  # noqa: BLE001 - any unusable icon keeps the upstream assets
        print(f'branding: keeping the upstream icons, {error}', file=sys.stderr)
        return False

    changed.extend(str(path.relative_to(root)) for path, _ in targets if path.exists())
    if platform in ('android', 'all'):
        # The adaptive icon still points at the upstream vector foreground, so the
        # density bitmaps above only take effect once those layers are gone.
        for adaptive in (
            'mipmap-anydpi-v26/ic_launcher.xml',
            'mipmap-anydpi-v26/ic_launcher_round.xml',
            'mipmap-television-anydpi-v26/ic_launcher.xml',
        ):
            path = root / 'android/app/src/main/res' / adaptive
            if path.exists():
                path.unlink()
                changed.append(f'removed {path.relative_to(root)}')
    return True


def read_version(root: Path) -> tuple[str, str]:
    text = (root / 'pubspec.yaml').read_text(encoding='utf-8')
    match = re.search(r'^version:\s*(\S+)$', text, re.MULTILINE)
    if not match:
        raise SystemExit('branding: pubspec.yaml has no version line')
    full = match.group(1)
    return full.split('+', 1)[0], full


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default='.', help='checkout to brand')
    parser.add_argument(
        '--platform',
        default='all',
        choices=['android', 'macos', 'windows', 'all'],
        help='platform resources to touch',
    )
    parser.add_argument('--state-out', default=str(STATE_PATH), help='where to write the resolved values')
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    config = load_config(root)
    changed: list[str] = []

    if args.platform in ('android', 'all'):
        apply_android(root, config, changed)
    if args.platform in ('macos', 'all'):
        apply_macos(root, config, changed)
    if args.platform in ('windows', 'all'):
        apply_windows(root, config, changed)
    apply_links(root, config, changed)

    icon_replaced = False
    if config['replaceIcon']:
        icon_replaced = replace_icons(root, args.platform, changed)
    elif (root / ICON_PATH).exists():
        print('branding: replaceIcon is false, keeping the upstream icons', file=sys.stderr)

    version, version_full = read_version(root)
    state = {
        'appName': config['appName'],
        'version': version,
        'versionFull': version_full,
        'androidApplicationId': config['androidApplicationId'],
        'macosBundleId': config['macosBundleId'],
        'windowsProductName': config['windowsProductName'],
        'windowsCompanyName': config['windowsCompanyName'],
        'windowsPublisherUrl': config['windowsPublisherUrl'],
        'repository': config['repository'],
        'telegramUrl': config['telegramUrl'],
        'replaceIcon': config['replaceIcon'],
        'iconReplaced': icon_replaced,
        'signingMode': config['signingMode'],
        'files': sorted(changed),
    }
    state_path = Path(args.state_out)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, indent=2) + '\n', encoding='utf-8')

    print(f'branding: {config["appName"]} {version} ({config["androidApplicationId"]})')
    print(f'branding: icons {"replaced" if icon_replaced else "kept upstream"}')
    for name in sorted(changed):
        print(f'  {name}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
