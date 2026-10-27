#!/usr/bin/env bash
# Builds, signs, packages and Sparkle-signs a SourceDeck release
# entirely on this Mac (docs/release.md). Same shape as DKB Clamshell's
# release.sh: local certificate, Hardened Runtime, Sparkle signature.
#   ./scripts/release.sh           # asks for the version
#   ./scripts/release.sh 1.0.1
#
# Signing uses the self-signed "DKB Source Control Local Signing"
# certificate named in Local.xcconfig (scripts/create-signing-cert.sh): a
# folder-access grant for a repository on the Desktop or in Documents is
# keyed on the signing identity, so every release must carry the same one or
# the permission is asked for again. No notarization: first launch
# on another Mac needs System Settings › Privacy & Security › Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="SourceDeckApp"
PROJECT="SourceDeck.xcodeproj"
APP_NAME="SourceDeck"
INFO_PLIST="SourceDeckApp/Info.plist"
# Required: without --account, sign_update silently signs with DKB Monitor's
# default-account key, producing a signature no installed copy accepts.
SPARKLE_ACCOUNT="dkb-source-control"
SPARKLE_VERSION="2.6.4"
# SHA-256 of Sparkle-2.6.4.tar.xz (same pin as the other apps). The tools
# run with access to the signing key, so they are verified before they run.
SPARKLE_SHA256="50612a06038abc931f16011d7903b8326a362c1074dabccb718404ce8e585f0b"
SPARKLE_TOOLS_DIR=".sparkle-tools/$SPARKLE_VERSION"

[ -f Local.xcconfig ] || { echo "Error: Local.xcconfig is missing. Run scripts/create-signing-cert.sh first." >&2; exit 1; }
IDENTITY=$(sed -nE 's/^CODE_SIGN_IDENTITY *= *(.*)$/\1/p' Local.xcconfig | tail -1)
[ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] || {
  echo "Error: Local.xcconfig is ad-hoc. A release must use the local certificate (scripts/create-signing-cert.sh)." >&2
  exit 1
}
command -v create-dmg >/dev/null || { echo "Error: create-dmg not found. Run: brew install create-dmg" >&2; exit 1; }

# Cached per version, verified before anything is extracted (DKB Monitor).
if [ ! -x "$SPARKLE_TOOLS_DIR/bin/sign_update" ]; then
  mkdir -p "$SPARKLE_TOOLS_DIR"
  curl -fsSL -o "$SPARKLE_TOOLS_DIR/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  echo "$SPARKLE_SHA256  $SPARKLE_TOOLS_DIR/sparkle.tar.xz" | shasum -a 256 -c - || {
    echo "Error: Sparkle ${SPARKLE_VERSION} failed checksum verification. Refusing to run its tools." >&2
    rm -f "$SPARKLE_TOOLS_DIR/sparkle.tar.xz"
    exit 1
  }
  tar -xf "$SPARKLE_TOOLS_DIR/sparkle.tar.xz" -C "$SPARKLE_TOOLS_DIR"
fi
# Before anything is built: a DMG signed with a key other than the one in
# Info.plist is rejected by every installed copy, with an error that points
# nowhere near the cause.
PUBLIC_KEY=$("$SPARKLE_TOOLS_DIR/bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p) || {
  echo "Error: no Sparkle key under the \"$SPARKLE_ACCOUNT\" Keychain account. See docs/release.md, One-time setup." >&2
  exit 1
}
[ "$PUBLIC_KEY" = "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST" 2>/dev/null)" ] || {
  echo "Error: SUPublicEDKey in $INFO_PLIST is not the public half of the \"$SPARKLE_ACCOUNT\" key ($PUBLIC_KEY)." >&2
  exit 1
}

# Info.plist is the source of truth for the version; both fields get the
# same MAJOR.MINOR.PATCH.
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
if [ $# -ge 1 ]; then
  VERSION="$1"
else
  SUGGESTED_VERSION=$(awk -F. '{print $1"."$2"."$3+1}' <<< "$CURRENT_VERSION")
  read -rp "Current version is $CURRENT_VERSION. New version (e.g. $SUGGESTED_VERSION) [Enter to keep]: " INPUT
  VERSION="${INPUT:-$CURRENT_VERSION}"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Error: version must be MAJOR.MINOR.PATCH (digits only), got \"$VERSION\"." >&2; exit 1; }
if [ "$VERSION" != "$CURRENT_VERSION" ] &&
   [ "$(printf '%s\n%s\n' "$CURRENT_VERSION" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]; then
  echo "Error: $VERSION is lower than the current $CURRENT_VERSION." >&2
  exit 1
fi

echo "==> Testing SourceDeckCore"
(cd SourceDeckCore && swift test)

echo "==> Testing SourceDeckApp"
xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination "platform=macOS" -quiet

# Info.plist is edited in place before the build, so any failure from here
# on would otherwise leave it bumped to a version that never shipped.
INFO_PLIST_BACKUP=$(mktemp)
cp "$INFO_PLIST" "$INFO_PLIST_BACKUP"

# One handler, installed once: `$?` inside a trap is whatever ran last, so
# chaining two traps would have the second read the first's exit code.
on_exit() {
  local status=$?
  if [ -n "${BUILD_DIR:-}" ]; then
    rm -rf "$BUILD_DIR"
  fi
  if [ "$status" -ne 0 ]; then
    echo "==> Failed (exit $status) — restoring $INFO_PLIST" >&2
    cp "$INFO_PLIST_BACKUP" "$INFO_PLIST"
  fi
  rm -f "$INFO_PLIST_BACKUP"
}
trap on_exit EXIT

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$INFO_PLIST"
echo "==> Releasing version $VERSION"

OUT_DIR="release-output/$VERSION"
mkdir -p "$OUT_DIR"
BUILD_DIR=$(mktemp -d)

echo "==> Building (Release, signed with \"$IDENTITY\", universal arm64+x86_64)"
# Without the generic destination xcodebuild builds for this Mac's own
# architecture only and Intel Macs would be left out.
xcodebuild build \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination "generic/platform=macOS" -quiet

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "Error: no app at $APP_PATH — the build produced nothing." >&2; exit 1; }

echo "==> Verifying the built app"
codesign --verify --deep --strict "$APP_PATH" || {
  echo "Error: $APP_PATH failed signature verification." >&2
  exit 1
}
# Into a variable first: `grep -q` closing the pipe early makes codesign
# exit non-zero under pipefail, which read as "no runtime flag".
SIGNATURE=$(codesign -dvv "$APP_PATH" 2>&1)
grep -q 'flags=.*runtime' <<< "$SIGNATURE" || { echo "Error: Hardened Runtime is not set on the Release build." >&2; exit 1; }
grep -q "Authority=$IDENTITY" <<< "$SIGNATURE" || { echo "Error: the app is not signed by \"$IDENTITY\"." >&2; exit 1; }
VERSION_BUILT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
[ "$VERSION_BUILT" = "$VERSION" ] || { echo "Error: the app says $VERSION_BUILT, expected $VERSION." >&2; exit 1; }
ARCHS_BUILT=$(lipo -archs "$APP_PATH/Contents/MacOS/$APP_NAME")
for arch in arm64 x86_64; do
  grep -qw "$arch" <<< "$ARCHS_BUILT" || {
    echo "Error: binary is missing $arch (built: $ARCHS_BUILT). Intel or Apple Silicon Macs would be left out." >&2
    exit 1
  }
done
# Exactly one entitlement: library validation off, so Hardened
# Runtime loads Sparkle.framework, which a self-signed certificate (no Team
# ID) can't make pass that check. No sandbox, and in particular no
# get-task-allow, which Xcode injects into Debug builds.
ENTITLEMENTS=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -oE '<key>[^<]+</key>' | sort | tr -d '\n' || true)
EXPECTED='<key>com.apple.security.cs.disable-library-validation</key>'
[ "$ENTITLEMENTS" = "$EXPECTED" ] || { echo "Error: unexpected entitlements: $ENTITLEMENTS" >&2; exit 1; }
echo "    signature OK, hardened runtime OK, entitlements OK, version $VERSION_BUILT, architectures: $ARCHS_BUILT"

echo "==> Creating DMG"
DMG_PATH="$OUT_DIR/SourceDeck-$VERSION.dmg"
rm -f "$DMG_PATH"
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "$APP_NAME.app" 160 185 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 460 185 \
  "$DMG_PATH" \
  "$APP_PATH"
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256")

echo "==> Signing update with Sparkle"
# -p prints only the raw EdDSA signature — exactly what the admin panel's
# "Sparkle signature" field expects.
"$SPARKLE_TOOLS_DIR/bin/sign_update" -p --account "$SPARKLE_ACCOUNT" "$DMG_PATH" | tee "$DMG_PATH.sig"
[ -s "$DMG_PATH.sig" ] || { echo "Error: sign_update produced an empty signature." >&2; exit 1; }

rm -rf "$OUT_DIR/$APP_NAME.app"
cp -R "$APP_PATH" "$OUT_DIR/"
echo ""
echo "==> Done: $OUT_DIR"
echo "    Installer: $DMG_PATH"
echo "    SHA-256:   $(cut -d' ' -f1 "$DMG_PATH.sha256")"
echo "    Sparkle signature: $DMG_PATH.sig"
echo "Install here with: ./scripts/install-local.sh $VERSION"
