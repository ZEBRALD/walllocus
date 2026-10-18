#!/bin/bash
# Package build/WallLocus.app into a distributable DMG.
# Usage: ./package-dmg.sh [version]
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/WallLocus.app"
VERSION="${1:-$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0.0.0)}"
OUT="$DIR/build/WallLocus-$VERSION.dmg"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run ./build.sh first" >&2
  exit 1
fi

# Staging folder: the app plus a shortcut to /Applications,
# so the mounted DMG behaves like a standard drag-to-install window.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $OUT"
hdiutil create \
  -volname "WallLocus" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  -fs HFS+ \
  "$OUT" >/dev/null

echo "==> Done: $OUT"
echo "    size: $(du -h "$OUT" | cut -f1)"
echo "    sha256: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"