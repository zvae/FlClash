#!/usr/bin/env bash
# Verifies the split APK signatures and identity, then stages them for release.

set -euo pipefail

for name in APP_NAME VERSION TAG APPLICATION_ID SOURCE_COMMIT UPSTREAM_COMMIT DIST_DIR \
  KEY_ALIAS STORE_PASSWORD KEY_PASSWORD; do
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
zipalign="$build_tools/zipalign"
keystore="${KEYSTORE_PATH:-android/app/keystore.jks}"
for tool in "$apksigner" "$aapt" "$zipalign"; do
  [[ -x "$tool" ]] || { echo "::error::$tool is missing from the Android SDK"; exit 1; }
done
[[ -f "$keystore" ]] || { echo "::error::$keystore is missing, the build cannot be re-signed"; exit 1; }

# AGP leaves the v1 (JAR) signature out once minSdk reaches 24, and Honor and
# Huawei installers read the certificate from that signature: a v2-only APK is
# rejected with "this package contains no certificate". Sign all three schemes.
resign_apk() {
  local apk="$1" aligned="$1.aligned" signed="$1.signed"
  "$zipalign" -f -p 4 "$apk" "$aligned"
  "$apksigner" sign --ks "$keystore" --ks-key-alias "$KEY_ALIAS" \
    --ks-pass env:STORE_PASSWORD --key-pass env:KEY_PASSWORD \
    --min-sdk-version 21 --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
    --out "$signed" "$aligned"
  mv "$signed" "$apk"
  rm -f "$aligned"
}

apks=()
while IFS= read -r apk; do
  apks+=("$apk")
done < <(find build/app/outputs/flutter-apk -maxdepth 1 -name '*-release.apk' | sort)
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

  resign_apk "$apk"

  if ! certs=$("$apksigner" verify --print-certs --verbose --min-sdk-version 21 "$apk" 2>&1); then
    echo "::error::$base is not signed with a valid APK signature"
    printf '%s\n' "$certs"
    exit 1
  fi

  if [[ -z "${report_printed:-}" ]]; then
    report_printed=1
    echo "::group::apksigner report for $base"
    printf '%s\n' "$certs" | head -12
    echo "::endgroup::"
  fi

  if grep -q 'Verified using v1 scheme (JAR signing): false' <<<"$certs"; then
    echo "::error::$base has no v1 (JAR) signature; Honor and Huawei installers reject that as 'no certificate'"
    exit 1
  fi

  # apksigner has reworded its report across build-tools releases, so match the
  # labels instead of the whole line and fall back to the JAR signature block.
  dn=$(sed -n 's/.*certificate DN:[[:space:]]*//p' <<<"$certs" | head -1)
  fingerprint=$(sed -n 's/.*certificate SHA-256 digest:[[:space:]]*//p' <<<"$certs" | head -1 | tr -d ':')
  if [[ -z "$fingerprint" ]]; then
    if jarfile_cert=$(keytool -printcert -jarfile "$apk" 2>/dev/null); then
      dn=${dn:-$(sed -n 's/^Owner:[[:space:]]*//p' <<<"$jarfile_cert" | head -1)}
      fingerprint=$(sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' <<<"$jarfile_cert" | head -1 | tr -d ':')
    fi
  fi
  if [[ -z "$fingerprint" ]]; then
    echo "::error::$base did not report its signing certificate"
    "$apksigner" version 2>&1 | head -2
    printf '%s\n' "$certs"
    exit 1
  fi

  if [[ "$dn" == *"Android Debug"* ]]; then
    echo "::error::$base is signed with the Android debug certificate"
    exit 1
  fi
  if [[ -n "${ANDROID_CERT_SHA256:-}" ]]; then
    expected=$(tr -d ':' <<<"$ANDROID_CERT_SHA256" | tr '[:upper:]' '[:lower:]')
    actual=$(tr '[:upper:]' '[:lower:]' <<<"$fingerprint")
    if [[ "$actual" != "$expected" ]]; then
      echo "::error::$base is signed by $fingerprint, expected $expected"
      exit 1
    fi
  elif [[ -z "$dn" ]]; then
    echo "::error::$base reported no signer, and ANDROID_CERT_SHA256 is not set to pin one"
    printf '%s\n' "$certs"
    exit 1
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
