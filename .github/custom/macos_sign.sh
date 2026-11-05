#!/usr/bin/env bash
# Code signing, DMG packaging and verification for macOS.
#
#   macos_sign.sh keychain   create the temporary keychain and export the identity
#   macos_sign.sh sign       sign every Mach-O binary in the app, then the bundle
#   macos_sign.sh package    build the DMG and sign it
#   macos_sign.sh finalize   notarize when a Developer ID is configured, then verify
#   macos_sign.sh cleanup    delete the keychain and every temporary credential
#
# SIGNING_MODE selects what is expected:
#   official     a Developer ID Application certificate and an Apple notarization
#   self-signed  this repository's own certificate; notarization is impossible, so
#                macOS reports an unidentified developer on first launch

set -euo pipefail

MODE="${1:-}"
KEYCHAIN="$RUNNER_TEMP/flclash-signing.keychain-db"
P12="$RUNNER_TEMP/flclash-signing.p12"
CERT_PEM="$RUNNER_TEMP/flclash-signing.pem"
TRUST_MARKER="$RUNNER_TEMP/flclash-trusted-cn"
NOTARY_JSON="$RUNNER_TEMP/notary.json"
SYSTEM_KEYCHAIN='/Library/Keychains/System.keychain'

SIGNING_MODE="${SIGNING_MODE:-self-signed}"
if [[ "$SIGNING_MODE" != 'self-signed' && "$SIGNING_MODE" != 'official' ]]; then
  echo "::error::SIGNING_MODE must be self-signed or official, not '$SIGNING_MODE'"
  exit 1
fi

# Apple's timestamp service is not in the picture for a self-signed build, and
# asking for a timestamp would only add a way for the run to fail.
timestamp_flag='--timestamp'
[[ "$SIGNING_MODE" == 'self-signed' ]] && timestamp_flag=''

die() {
  echo "::error::$*"
  exit 1
}

require() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "macos_sign.sh: $name is not set"
}

decode_secret() {
  local name="$1" target="$2"
  printf '%s' "${!name}" |
    python3 -c 'import base64, sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "$target"
}

certificate_cn() {
  openssl x509 -in "$CERT_PEM" -noout -subject -nameopt multiline |
    sed -n 's/^ *commonName *= //p' | head -1
}

case "$MODE" in
  keychain)
    for name in APP_NAME MACOS_CERTIFICATE_P12_BASE64 MACOS_CERTIFICATE_PASSWORD MACOS_KEYCHAIN_PASSWORD; do
      require "$name"
    done

    security create-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 21600 "$KEYCHAIN"
    security unlock-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"
    decode_secret MACOS_CERTIFICATE_P12_BASE64 "$P12"
    security import "$P12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PASSWORD" \
      -T /usr/bin/codesign -T /usr/bin/security > /dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
      -k "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null
    security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

    if [[ "$SIGNING_MODE" == 'self-signed' ]]; then
      openssl pkcs12 -in "$P12" -passin pass:"$MACOS_CERTIFICATE_PASSWORD" -nokeys -clcerts -out "$CERT_PEM"
      # A self-signed certificate is only a usable signing identity once a trust
      # setting names the code signing policy, and that lives in the system store.
      sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "$SYSTEM_KEYCHAIN" "$CERT_PEM"
      cn=$(certificate_cn)
      [[ -n "$cn" ]] || die 'the release certificate has no common name'
      security find-certificate -c "$cn" "$SYSTEM_KEYCHAIN" > /dev/null ||
        die 'the release certificate was not trusted for code signing'
      printf '%s' "$cn" > "$TRUST_MARKER"
      echo "trusted '$cn' for code signing on this run only"
    fi

    security find-identity -v -p codesigning "$KEYCHAIN"
    identity=$(security find-identity -v -p codesigning "$KEYCHAIN" |
      sed -n 's/.*"\([^"]*\)".*/\1/p' | head -1)
    [[ -n "$identity" ]] || die 'the keychain holds no valid code signing identity'

    if [[ "$SIGNING_MODE" == 'official' ]]; then
      require APPLE_TEAM_ID
      [[ "$identity" == 'Developer ID Application: '* ]] ||
        die "official mode needs a Developer ID Application certificate, found '$identity'"
      [[ "$identity" == *"($APPLE_TEAM_ID)"* ]] || die "identity '$identity' does not belong to team $APPLE_TEAM_ID"
    fi

    echo "MACOS_SIGN_IDENTITY=$identity" >> "$GITHUB_ENV"
    echo "signing identity: $identity ($SIGNING_MODE)"
    ;;

  sign)
    for name in APP_NAME MACOS_SIGN_IDENTITY; do require "$name"; done
    APP="$GITHUB_WORKSPACE/build/macos/Build/Products/Release/$APP_NAME.app"
    ENTITLEMENTS="$GITHUB_WORKSPACE/.github/custom/release.entitlements"
    [[ -d "$APP" ]] || die "no application bundle at $APP"
    [[ -f "$ENTITLEMENTS" ]] || die "no entitlements at $ENTITLEMENTS"

    python3 - "$APP" > "$RUNNER_TEMP/macho.txt" <<'PY'
import os
import sys

root = sys.argv[1]
magics = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
found = []
for base, _, files in os.walk(root):
    for name in files:
        path = os.path.join(base, name)
        try:
            with open(path, 'rb') as handle:
                magic = handle.read(4)
        except OSError:
            continue
        if magic in magics:
            found.append(path)
found.sort(key=lambda path: path.count(os.sep), reverse=True)
print('\n'.join(found))
PY

    count=$(grep -c . "$RUNNER_TEMP/macho.txt" || true)
    (( count > 0 )) || die 'no Mach-O binary was found in the bundle'
    echo "signing $count Mach-O binaries"

    while IFS= read -r binary; do
      [[ -n "$binary" ]] || continue
      codesign --force $timestamp_flag --options runtime --entitlements "$ENTITLEMENTS" \
        --sign "$MACOS_SIGN_IDENTITY" "$binary"
    done < "$RUNNER_TEMP/macho.txt"

    for framework in "$APP"/Contents/Frameworks/*.framework; do
      [[ -d "$framework" ]] || continue
      codesign --force $timestamp_flag --options runtime --sign "$MACOS_SIGN_IDENTITY" "$framework"
    done

    codesign --force $timestamp_flag --options runtime --entitlements "$ENTITLEMENTS" \
      --sign "$MACOS_SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'flags=0x10000(runtime)' ||
      die 'Hardened Runtime is not enabled on the bundle'
    codesign -dv --verbose=4 "$APP" 2>&1 | grep -Fq "Authority=$MACOS_SIGN_IDENTITY" ||
      die 'the bundle is not signed by the expected identity'
    codesign --display --entitlements - "$APP" 2>/dev/null | grep -q 'com.apple.security.network.server' ||
      die 'the release entitlements are missing from the bundle'
    echo 'bundle signed, hardened runtime enabled, entitlements applied'
    ;;

  package)
    for name in APP_NAME MACOS_SIGN_IDENTITY MACOS_ARCH VERSION DIST_DIR; do require "$name"; done
    APP="$GITHUB_WORKSPACE/build/macos/Build/Products/Release/$APP_NAME.app"
    DMG="$DIST_DIR/$APP_NAME-$VERSION-macos-$MACOS_ARCH.dmg"
    [[ -d "$APP" ]] || die "no application bundle at $APP"

    stage="$RUNNER_TEMP/dmg"
    rm -rf "$stage"
    mkdir -p "$stage" "$DIST_DIR"
    cp -R "$APP" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO "$DMG" > /dev/null
    codesign --force $timestamp_flag --sign "$MACOS_SIGN_IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
    echo "dmg signed: $DMG"
    ;;

  finalize)
    for name in APP_NAME MACOS_SIGN_IDENTITY MACOS_ARCH VERSION TAG SOURCE_COMMIT \
      UPSTREAM_COMMIT DIST_DIR; do
      require "$name"
    done
    DMG="$DIST_DIR/$APP_NAME-$VERSION-macos-$MACOS_ARCH.dmg"
    [[ -f "$DMG" ]] || die "no disk image at $DMG"
    codesign --verify --verbose=2 "$DMG"

    status='none'
    submission='none'
    stapled='false'
    if [[ "$SIGNING_MODE" == 'official' ]]; then
      if [[ -n "${APPLE_API_KEY_P8_BASE64:-}" ]]; then
        require APPLE_API_KEY_ID
        require APPLE_API_ISSUER_ID
        decode_secret APPLE_API_KEY_P8_BASE64 "$RUNNER_TEMP/AuthKey.p8"
        auth=(--key "$RUNNER_TEMP/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
      else
        for name in APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID; do require "$name"; done
        auth=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
      fi

      if ! xcrun notarytool submit "$DMG" "${auth[@]}" --wait --output-format json > "$NOTARY_JSON"; then
        cat "$NOTARY_JSON" >&2 || true
        die 'notarytool rejected the submission'
      fi
      status=$(python3 -c "import json;print(json.load(open('$NOTARY_JSON'))['status'])")
      submission=$(python3 -c "import json;print(json.load(open('$NOTARY_JSON'))['id'])")
      if [[ "$status" != 'Accepted' ]]; then
        xcrun notarytool log "$submission" "${auth[@]}" >&2 || true
        die "notarization finished as '$status', not 'Accepted'"
      fi
      echo "notarization accepted: $submission"
      xcrun stapler staple "$DMG"
      xcrun stapler validate "$DMG"
      stapled='true'
    else
      echo '::notice::self-signed build: no notarization, macOS will warn about an unidentified developer'
    fi

    mount="$RUNNER_TEMP/notary-mount"
    mkdir -p "$mount"
    hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$mount" > /dev/null
    codesign --verify --deep --strict --verbose=2 "$mount/$APP_NAME.app"
    if [[ "$SIGNING_MODE" == 'official' ]]; then
      for attempt in 1 2 3; do
        if spctl --assess --type exec --verbose=2 "$mount/$APP_NAME.app"; then
          break
        fi
        [[ "$attempt" == 3 ]] && die 'Gatekeeper rejected the notarized application'
        sleep 20
      done
    fi
    hdiutil detach "$mount" > /dev/null || hdiutil detach "$mount" -force > /dev/null

    jq -n \
      --arg platform macos \
      --arg arch "$MACOS_ARCH" \
      --arg tag "$TAG" \
      --arg version "$VERSION" \
      --arg sourceCommit "$SOURCE_COMMIT" \
      --arg upstreamCommit "$UPSTREAM_COMMIT" \
      --arg identity "$MACOS_SIGN_IDENTITY" \
      --arg signingMode "$SIGNING_MODE" \
      --arg submission "$submission" \
      --arg status "$status" \
      --arg stapled "$stapled" \
      --arg file "$(basename "$DMG")" \
      '{
        platform: $platform,
        arch: $arch,
        tag: $tag,
        version: $version,
        sourceCommit: $sourceCommit,
        upstreamCommit: $upstreamCommit,
        signed: true,
        notarized: ($status == "Accepted"),
        stapled: ($stapled == "true"),
        signingMode: $signingMode,
        selfSigned: ($signingMode == "self-signed"),
        signing: {
          tool: "codesign",
          identity: $identity,
          hardenedRuntime: true,
          entitlements: true,
          selfSigned: ($signingMode == "self-signed")
        },
        notarization: {
          tool: (if $status == "none" then "none" else "notarytool" end),
          status: $status,
          submission: $submission,
          stapled: ($stapled == "true")
        },
        files: [$file]
      }' > "$DIST_DIR/verification-macos-$MACOS_ARCH.json"
    echo "dmg verified ($SIGNING_MODE, notarization: $status)"
    ;;

  cleanup)
    if [[ -f "$TRUST_MARKER" ]]; then
      sudo security delete-certificate -c "$(cat "$TRUST_MARKER")" "$SYSTEM_KEYCHAIN" 2>/dev/null || true
      rm -f "$TRUST_MARKER"
    fi
    security delete-keychain "$KEYCHAIN" 2>/dev/null || true
    rm -f "$P12" "$CERT_PEM" "$RUNNER_TEMP/AuthKey.p8" "$NOTARY_JSON" "$RUNNER_TEMP/macho.txt"
    ;;

  *)
    die "usage: macos_sign.sh {keychain|sign|package|finalize|cleanup}"
    ;;
esac
