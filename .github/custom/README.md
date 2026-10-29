# Release pipeline

Everything the release pipeline needs lives in this directory, so none of it mixes with the application sources.

| File | Purpose |
| --- | --- |
| `brand.json` | app name, Android application id, macOS bundle id, Windows product strings, icon switch, signing mode |
| `icons/app-icon.png` | optional replacement icon, only read when `replaceIcon` is true |
| `apply.py` | writes `brand.json` into the Android, macOS and Windows resources |
| `installer.iss` | Inno Setup script for the Windows installer, all values from `BRAND_*` environment variables |
| `release.entitlements` | Hardened Runtime entitlements used when signing the macOS bundle |
| `android_verify.sh` | verifies APK signatures, package name and version, then stages the artifacts |
| `windows_sign.ps1` | Authenticode signing, packaging, and signature verification |
| `macos_sign.sh` | code signing, DMG packaging, notarization when available, verification |
| `manifest.py` | release gate: manifest, checksums and release notes |
| `make-signing-material.sh` | one-time generator for the Android keystore and the Windows and macOS certificates |

`.github/workflows/release.yaml` runs the pipeline: daily at 03:17 UTC, or by hand with an optional upstream tag and a
dry-run switch.

## Tag policy

The release tag is the upstream tag, byte for byte. Nothing is prefixed, suffixed, or rebuilt from a version number.

- The upstream tag and its commit are resolved from `chen08209/FlClash`.
- If this repository already has a release for that tag, the run stops and publishes nothing. A released version never
  gains different binaries.
- If the tag exists without a release, the tag is inspected instead of replaced: a tag this pipeline created carries an
  `Upstream-Commit:` trailer that must still match upstream, and a tag pointing anywhere else fails the run.
- A tag is created only after every platform passed, and only when it does not already exist at that commit.
- A changed upstream commit for the same tag stops the run. Nothing is force-pushed, deleted, or renamed.

The tag points at a release commit whose parent is the upstream commit: the upstream tree plus this directory. The
generated source archive therefore matches the built binaries, and each artifact records both the upstream commit and
the release commit.

## Branding

`brand.json` holds the overrides; every key defaults to the upstream value.

| Key | Effect |
| --- | --- |
| `appName` | Android label, macOS `PRODUCT_NAME` and DMG title, installer display name |
| `androidApplicationId` | `applicationId` in `android/app/build.gradle.kts`; the namespace is untouched |
| `macosBundleId` | `PRODUCT_BUNDLE_IDENTIFIER` |
| `windowsProductName` | executable name, product strings, window title |
| `windowsCompanyName` | `CompanyName` in the Windows version resource, installer publisher |
| `windowsPublisherUrl` | support and updates URLs in the installer |
| `replaceIcon` | when true, `icons/app-icon.png` replaces the Android, macOS and Windows icons |
| `signingMode` | `self-signed` (default) or `official` |

Icons are opt-in. `replaceIcon: false`, a missing image, an image under 512 px, a non-square image, or a missing Pillow
install all keep the upstream icons and let the build continue. Renaming the app never regenerates icons.

## Signing material

There is no Apple developer account here, so `signingMode` is `self-signed`: one self-signed certificate per platform,
generated once by `make-signing-material.sh`.

```bash
.github/custom/make-signing-material.sh --name FlClash --org com.follow
```

It writes `.github/custom/signing/` (git-ignored) with `release.jks`, `windows-codesign.pfx`,
`macos-codesign.p12`, `secrets.env`, and `set-secrets.sh`, then prints the values. Run `signing/set-secrets.sh` to push
every secret to the repository, or copy the values from `secrets.env` by hand. Keep the directory: rotating the
certificates means regenerating it and updating the secrets.

What the pipeline does with that material:

| Platform | Behaviour |
| --- | --- |
| Android | `apksigner verify` must pass, the debug certificate is refused, and `ANDROID_CERT_SHA256` pins the expected fingerprint |
| Windows | Every executable and library in the bundle is signed, then the ZIP, then the installer; the trust for the run is scoped to the runner and removed afterwards; timestamps, chain, validity and subject are re-checked |
| macOS | Every Mach-O is signed, the certificate is trusted for code signing on the runner only, Hardened Runtime plus `release.entitlements` are applied, the DMG is signed separately and verified |

`signingMode: official` is still supported: it requires a Developer ID Application certificate, notarizes with
`notarytool`, staples the DMG, and adds Gatekeeper assessment. It needs an Apple developer account and the `APPLE_*`
secrets below.

Self-signed builds are labelled as such everywhere: the manifest, the release notes, and each verification file. Windows
shows an unknown publisher, macOS reports an unidentified developer, and nothing claims notarization or SmartScreen
reputation.

## GitHub configuration

Settings, Secrets and variables, Actions. Values are the exact contents, not file paths.

| Name | Required | Value |
| --- | --- | --- |
| `KEYSTORE` | yes | Base64 of the Android keystore: `openssl base64 -A -in release.jks` |
| `KEY_ALIAS` | yes | Key alias inside that keystore |
| `STORE_PASSWORD` | yes | Keystore password |
| `KEY_PASSWORD` | yes | Key password |
| `ANDROID_CERT_SHA256` | optional | Certificate fingerprint; when set, the APK must match it |
| `WINDOWS_CERTIFICATE_PFX_BASE64` | yes | Base64 of the Authenticode PFX |
| `WINDOWS_CERTIFICATE_PASSWORD` | yes | PFX password |
| `WINDOWS_SIGNER_SUBJECT` | optional | Expected certificate common name; a different certificate fails the run |
| `MACOS_CERTIFICATE_P12_BASE64` | yes | Base64 of the code signing certificate and key |
| `MACOS_CERTIFICATE_PASSWORD` | yes | P12 password |
| `MACOS_KEYCHAIN_PASSWORD` | yes | Any temporary keychain password |
| `APPLE_TEAM_ID` | `official` only | Ten-character Apple developer team id |
| `APPLE_ID` | `official` only | Apple account used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | `official` only | App-specific password for that account |
| `APPLE_API_KEY_P8_BASE64` | `official` only, alternative to the pair above | Base64 of the App Store Connect `AuthKey_XXXX.p8` |
| `APPLE_API_KEY_ID` | with the API key | Key id |
| `APPLE_API_ISSUER_ID` | with the API key | Issuer id |

Also required: Settings, Actions, General, workflow permissions set to read and write, so the run can push the release
commit, create the tag, and attach assets with `GITHUB_TOKEN`.

The `credentials` job fails the run before any build when a required secret is missing, and names every missing entry.

## Local checks

```bash
python3 .github/custom/apply.py --platform all
python3 .github/custom/manifest.py --help
bash .github/custom/android_verify.sh          # needs a signed build and ANDROID_HOME
pwsh -File .github/custom/windows_sign.ps1     # needs every WINDOWS_* variable
bash .github/custom/macos_sign.sh keychain     # then sign, package, finalize
```

The pipeline never runs a build locally; these command lines only help to rehearse a single step.

## Known limits

- The Inno Setup uninstaller (`unins000.exe`) is generated on the target machine at install time and carries no
  Authenticode signature.
- The notarization ticket, in `official` mode, is stapled to the DMG; the `.app` inside relies on the notarization
  recorded for the DMG, which is how Apple documents disk image distribution.
- A self-signed certificate expires with the material in `signing/`; regenerate and re-release rather than reusing an
  expired certificate.
- The first real run has to prove the credentials end to end. A dry run builds and gates without creating a tag or a
  release.
