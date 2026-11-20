#!/usr/bin/env bash
# Generates the self-signed material the release pipeline signs with.
#
#   make-signing-material.sh [--name FlClash] [--org com.follow] [--force]
#
# Writes into .github/custom/signing/ (git-ignored):
#   release.jks                  Android release keystore
#   windows-codesign.pfx         Authenticode certificate + key
#   macos-codesign.p12           code signing certificate + key
#   secrets.env                  every value in plain text
#   set-secrets.sh               ready-to-run `gh secret set` script
#
# Nothing here is publicly trusted: Windows shows an unknown publisher and macOS
# reports an unidentified developer until the certificates are trusted locally.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
out="$root/.github/custom/signing"
name='FlClash'
org='com.follow'
force='false'
validity_days=3650

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --org) org="$2"; shift 2 ;;
    --force) force='true'; shift ;;
    --days) validity_days="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "${CI:-}" ]]; then
  echo 'this script is for a one-time local run, not for CI' >&2
  exit 1
fi

if [[ -d "$out" && "$force" != 'true' ]]; then
  echo "$out already exists; pass --force to replace the signing material" >&2
  exit 1
fi

find_keytool() {
  if command -v keytool > /dev/null 2>&1; then
    command -v keytool
    return
  fi
  local candidates=(
    '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool'
    "$HOME/Library/Java/JavaVirtualMachines"/*/Contents/Home/bin/keytool
    '/usr/lib/jvm'/*/bin/keytool
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] && { echo "$candidate"; return; }
  done
  return 1
}

random_password() {
  openssl rand -hex 16
}

keytool_bin=$(find_keytool) || {
  echo 'keytool was not found; install a JDK or Android Studio first' >&2
  exit 1
}
command -v openssl > /dev/null 2>&1 || { echo 'openssl was not found' >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

android_alias="${name//[^A-Za-z0-9]/}Release"
android_password=$(random_password)
windows_password=$(random_password)
macos_password=$(random_password)
keychain_password=$(random_password)
windows_subject="${name} Self-Signed"
macos_subject="${name} Self-Signed"

echo "generating the Android keystore"
"$keytool_bin" -genkeypair \
  -keystore "$out/release.jks" \
  -storetype PKCS12 \
  -alias "$android_alias" \
  -keyalg RSA \
  -keysize 4096 \
  -validity 36500 \
  -storepass "$android_password" \
  -keypass "$android_password" \
  -dname "CN=${name}, OU=Release, O=${org}, C=CN" > /dev/null

extensions="$out/extensions.cnf"
cat > "$extensions" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = codesign

[dn]
CN = ${name} Self-Signed
O = ${org}
C = CN

[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF

generate_certificate() {
  local label="$1" key="$2" crt="$3" p12="$4" password="$5"
  echo "generating the ${label} certificate"
  openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days "$validity_days" \
    -keyout "$key" -out "$crt" -config "$extensions" -extensions codesign \
    -subj "/CN=${name} Self-Signed/O=${org}/C=CN" > /dev/null 2>&1
  # The macOS keychain refuses the modern default (AES-256 with a SHA-256 MAC),
  # so ask for the 3DES/SHA-1 shape both platforms read, and fall back only when
  # this openssl has no such options.
  if ! openssl pkcs12 -export -inkey "$key" -in "$crt" -out "$p12" \
      -name "${name} Self-Signed" -passout "pass:${password}" \
      -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES > /dev/null 2>&1; then
    rm -f "$p12"
    openssl pkcs12 -export -inkey "$key" -in "$crt" -out "$p12" \
      -name "${name} Self-Signed" -passout "pass:${password}" > /dev/null 2>&1
  fi
}

generate_certificate 'Windows' "$out/windows.key" "$out/windows.crt" \
  "$out/windows-codesign.pfx" "$windows_password"
generate_certificate 'macOS' "$out/macos.key" "$out/macos.crt" \
  "$out/macos-codesign.p12" "$macos_password"

openssl pkcs12 -in "$out/windows-codesign.pfx" -passin "pass:${windows_password}" -noout
openssl pkcs12 -in "$out/macos-codesign.p12" -passin "pass:${macos_password}" -noout
echo 'both certificate containers open'

if [[ "$(uname -s)" == 'Darwin' ]]; then
  probe="$(mktemp -d)/probe.keychain-db"
  security create-keychain -p probe "$probe"
  security unlock-keychain -p probe "$probe"
  if security import "$out/macos-codesign.p12" -k "$probe" -P "$macos_password" > "$out/import.log" 2>&1; then
    echo 'the macOS keychain imports the p12'
  else
    cat "$out/import.log" >&2
    security delete-keychain "$probe" 2>/dev/null || true
    echo 'the generated p12 cannot be imported by the macOS keychain; install a recent OpenSSL and rerun' >&2
    exit 1
  fi
  security delete-keychain "$probe" 2>/dev/null || true
  rm -f "$out/import.log"
fi

android_fingerprint=$("$keytool_bin" -list -v -keystore "$out/release.jks" \
  -storepass "$android_password" -alias "$android_alias" |
  sed -n 's/^[[:space:]]*SHA256: //p' | head -1 | tr -d ':')

openssl base64 -A -in "$out/release.jks" > "$out/keystore.b64"
openssl base64 -A -in "$out/windows-codesign.pfx" > "$out/windows-codesign.b64"
openssl base64 -A -in "$out/macos-codesign.p12" > "$out/macos-codesign.b64"

cat > "$out/secrets.env" <<EOF
KEY_ALIAS=${android_alias}
STORE_PASSWORD=${android_password}
KEY_PASSWORD=${android_password}
ANDROID_CERT_SHA256=${android_fingerprint}
WINDOWS_CERTIFICATE_PASSWORD=${windows_password}
WINDOWS_SIGNER_SUBJECT=${windows_subject}
MACOS_CERTIFICATE_PASSWORD=${macos_password}
MACOS_KEYCHAIN_PASSWORD=${keychain_password}
EOF

repository=''
if command -v gh > /dev/null 2>&1; then
  repository=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
fi
[[ -n "$repository" ]] || repository=$(git -C "$root" config --get remote.origin.url 2>/dev/null |
  sed -E 's#.*github\.com[:/](.*)\.git$#\1#; s#.*github\.com[:/]([^/]+/[^/]+)$#\1#' || true)

cat > "$out/set-secrets.sh" <<EOF
#!/usr/bin/env bash
# Writes every release secret into the repository named here or below.
set -euo pipefail
cd "\$(dirname "\${BASH_SOURCE[0]}")"
REPO="\${REPO:-${repository}}"
if [[ -z "\$REPO" ]]; then
  REPO=\$(gh repo view --json nameWithOwner -q .nameWithOwner)
fi

set_secret() { gh secret set "\$1" --repo "\$REPO" --body "\$2"; }

set_secret KEY_ALIAS '${android_alias}'
set_secret STORE_PASSWORD '${android_password}'
set_secret KEY_PASSWORD '${android_password}'
set_secret ANDROID_CERT_SHA256 '${android_fingerprint}'
set_secret WINDOWS_CERTIFICATE_PASSWORD '${windows_password}'
set_secret WINDOWS_SIGNER_SUBJECT '${windows_subject}'
set_secret MACOS_CERTIFICATE_PASSWORD '${macos_password}'
set_secret MACOS_KEYCHAIN_PASSWORD '${keychain_password}'

gh secret set KEYSTORE --repo "\$REPO" < keystore.b64
gh secret set WINDOWS_CERTIFICATE_PFX_BASE64 --repo "\$REPO" < windows-codesign.b64
gh secret set MACOS_CERTIFICATE_P12_BASE64 --repo "\$REPO" < macos-codesign.b64

echo "secrets written to \$REPO"
EOF
chmod +x "$out/set-secrets.sh"

cat <<EOF

done. material written to ${out}

  Android  alias ${android_alias}, SHA-256 ${android_fingerprint}
  Windows  ${windows_subject}
  macOS    ${macos_subject}
  valid    ${validity_days} days

next:
  1. run ${out}/set-secrets.sh
     (or read secrets.env and add the values under Settings, Secrets, Actions)
  2. keep ${out} private: signing/ is git-ignored, never commit it
  3. Actions, release, Run workflow, dry_run first

anyone installing these builds still sees an unknown publisher on Windows and an
unidentified developer on macOS; see .github/custom/README.md.
EOF
