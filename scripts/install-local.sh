#!/usr/bin/env bash
# Copies a built release into /Applications and launches it (DKB Clamshell).
#   ./scripts/install-local.sh            # newest release-output/<version>
#   ./scripts/install-local.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DKB Source Control"
VERSION="${1:-$(ls release-output 2>/dev/null | sort -V | tail -1)}"
[ -n "$VERSION" ] || { echo "Error: no release in release-output/. Run scripts/release.sh first." >&2; exit 1; }
SRC="release-output/$VERSION/$APP_NAME.app"
[ -d "$SRC" ] || { echo "Error: $SRC not found." >&2; exit 1; }

if pgrep -x "$APP_NAME" >/dev/null; then
  echo "==> Quitting the running $APP_NAME"
  osascript -e "tell application \"$APP_NAME\" to quit" || true
  sleep 1
fi
echo "==> Installing $VERSION to /Applications"
rm -rf "/Applications/$APP_NAME.app"
cp -R "$SRC" "/Applications/$APP_NAME.app"
open "/Applications/$APP_NAME.app"
echo "Done."
