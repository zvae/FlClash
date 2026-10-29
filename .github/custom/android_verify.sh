#!/usr/bin/env bash
# Verifies the split APK signatures and identity, then stages them for release.

set -euo pipefail

for name in APP_NAME VERSION TAG APPLICATION_ID SOURCE_COMMIT UPSTREAM_COMMIT DIST_DIR; do
  if [[ -z "${!name:-}" ]]; then
    echo "::error::android_verify.sh: $name is not set"
    exit 1
  fi
done

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$sdk" ]]; then
  echo '::error::ANDROID_HOME and ANDROID_SDK_ROOT are both unset'
  exit 1
fi

build_tools=$(find "$sdk/build-tools" -maxdepth 1 -mindepth 1 -type d | sort -V | tail -1)
apksigner="$build_tools/apksigner"
aapt="$build_tools/aapt"
for tool in "$apksigner" "$aapt"; do
  [[ -x "$tool" ]] || { echo "::error::$tool is missing from the Android SDK"; exit 1; }
done

mapfile -t apks < <(find build/app/outputs/flutter-apk -maxdepth 1 -name '*-release.apk' | sort)
if (( ${#apks[@]} == 0 )); then
  echo '::error::the build produced no release APK'
  exit 1
fi

mkdir -p "$DIST_DIR"
fingerprints=()
staged=()

for apk in "${apks[@]}"; do
  base=$(basename "$apk")
  abi=$(sed -E 's/^app-(.*)-release\.apk$/\1/' <<<"$base")
  [[ "$abi" != "$base" ]] || abi='universal'

  if ! certs=$("$apksigner" verify --print-certs "$apk" 2>&1); then
    echo "::error::$base is not signed with a valid APK signature"
    echo "$certs"
    exit 1
  fi
  dn=$(sed -n 's/^Signer #1 certificate DN: //p' <<<"$certs" | head -1)
  fingerprint=$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' <<<"$certs" | head -1)
  if [[ -z "$dn" || -z "$fingerprint" ]]; then
    echo "::error::$base did not report its signing certificate"
    exit 1
  fi
  if [[ "$dn" == *"Android Debug"* ]]; then
    echo "::error::$base is signed with the Android debug certificate"
    exit 1
  fi
  if [[ -n "${ANDROID_CERT_SHA256:-}" ]]; then
    expected=$(tr -d ':' <<<"$ANDROID_CERT_SHA256" | tr '[:upper:]' '[:lower:]')
    actual=$(tr -d ':' <<<"$fingerprint" | tr '[:upper:]' '[:lower:]')
    if [[ "$actual" != "$expected" ]]; then
      echo "::error::$base is signed by $fingerprint, expected $expected"
      exit 1
    fi
  fi

  badging=$("$aapt" dump badging "$apk" | head -1)
  package=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badging")
  version_name=$(sed -n "s/.* versionName='\([^']*\)'.*/\1/p" <<<"$badging")
  if [[ "$package" != "$APPLICATION_ID" ]]; then
    echo "::error::$base is package '$package', expected '$APPLICATION_ID'"
    exit 1
  fi
  if [[ "$version_name" != "$VERSION" ]]; then
    echo "::error::$base is version '$version_name', expected '$VERSION'"
    exit 1
  fi

  target="$DIST_DIR/$APP_NAME-$VERSION-android-$abi.apk"
  cp "$apk" "$target"
  staged+=("$(basename "$target")")
  fingerprints+=("$abi $dn $fingerprint")
  printf '%s: %s signed by %s (%s)\n' "$base" "$package" "$dn" "$abi"
done

jq -n \
  --arg platform android \
  --arg tag "$TAG" \
  --arg version "$VERSION" \
  --arg sourceCommit "$SOURCE_COMMIT" \
  --arg upstreamCommit "$UPSTREAM_COMMIT" \
  --arg applicationId "$APPLICATION_ID" \
  --arg certificate "$(printf '%s\n' "${fingerprints[@]}" | awk '{print $NF}' | sort -u | paste -sd, -)" \
  --args \
  '{
    platform: $platform,
    tag: $tag,
    version: $version,
    sourceCommit: $sourceCommit,
    upstreamCommit: $upstreamCommit,
    signed: true,
    signing: { tool: "apksigner", applicationId: $applicationId, certificateSha256: $certificate },
    files: $ARGS.positional
  }' "${staged[@]}" > "$DIST_DIR/verification-android.json"

printf 'staged %s APK(s)\n' "${#staged[@]}"
