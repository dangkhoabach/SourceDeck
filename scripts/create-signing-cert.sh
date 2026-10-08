#!/usr/bin/env bash
# Creates the self-signed code-signing certificate every local build of DKB
# Source Control is signed with, and points Local.xcconfig at it.
#
# Why (plan §3.2 D1): there is no Apple Developer Program for this app, so the
# alternative is ad-hoc signing, whose identity is the code hash and therefore
# changes on every build. A self-signed certificate gives each build the same
# designated requirement, so anything keyed on the app's identity — a TCC
# Files and Folders grant for a repository under ~/Desktop or ~/Documents, in
# particular, which git child processes inherit from the app — stays valid
# across builds. Nothing about this touches Gatekeeper: the app is built and
# installed on this Mac, never downloaded.
#
# Idempotent: re-running with the certificate already present only rewrites
# Local.xcconfig. `security add-trusted-cert` may show one macOS password
# dialog the first time.
set -euo pipefail

NAME="DKB Source Control Local Signing"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists — skipping creation."
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  # codeSigning EKU is what lets `codesign` accept the certificate at all.
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$NAME" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout pass:dkbsourcecontrol -out "$TMP/identity.p12"
  # -T /usr/bin/codesign: let codesign use the private key without a prompt
  # on every build.
  security import "$TMP/identity.p12" -k "$KEYCHAIN" -P dkbsourcecontrol -T /usr/bin/codesign >/dev/null
  # User-domain trust for code signing only; without it codesign rejects the
  # self-signed chain.
  security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
  echo "Created identity \"$NAME\" (valid 10 years)."
fi

printf 'CODE_SIGN_IDENTITY = %s\n' "$NAME" > "$ROOT/Local.xcconfig"
echo "Local.xcconfig now uses \"$NAME\"."
