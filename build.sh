#!/bin/bash
# Build WallLocus.app — requires only Xcode Command Line Tools (not full Xcode)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/WallLocus.app"
APP_NAME="WallLocus"
BIN="$APP/Contents/MacOS/$APP_NAME"

FLAGS=(-swift-version 5 -O
       -framework Cocoa -framework AVFoundation
       -framework CoreMedia -framework CoreVideo)

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Sources shared by the app and (later) the screen saver.
# Rendering.swift and SharedConfig.swift are AppKit-free so both targets can link them.
SOURCES=("$DIR/main.swift" "$DIR/L10n.swift" "$DIR/Rendering.swift" \
         "$DIR/SharedConfig.swift" "$DIR/ThumbnailStore.swift")

compile_arch() {
  local arch="$1" out="$2"
  swiftc "${FLAGS[@]}" -target "$arch-apple-macos13.0" -o "$out" "${SOURCES[@]}"
}

echo "==> Compiling $APP_NAME"

# UNIVERSAL=1 ./build.sh  ->  universal binary (Apple silicon + Intel)
# default                 ->  host architecture only
if [ "${UNIVERSAL:-0}" = "1" ]; then
  echo "    (universal: arm64 + x86_64)"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  compile_arch arm64  "$TMP/arm64"
  compile_arch x86_64 "$TMP/x86_64"
  lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$BIN"
else
  compile_arch "$(uname -m)" "$BIN"
fi

cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

if [ -f "$DIR/AppIcon.icns" ]; then
  cp "$DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "    icon embedded"
fi

# Ad-hoc signature. No paid Developer ID is used, so the app is not notarized:
# first launch needs right-click -> Open, or `xattr -dr com.apple.quarantine`.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
  || echo "    (codesign skipped; app still runs locally)"

echo "==> Done: $APP"
echo "    architectures: $(lipo -archs "$BIN" 2>/dev/null || echo unknown)"

# Screen saver target intentionally omitted.
# macOS 26 no longer discovers .saver bundles in ~/Library/Screen Savers/:
# pluginkit only lists ExtensionKit .appex extensions for com.apple.screensaver.
# The renderer in ScreenSaver/ is kept for reference (see SCREENSAVER.md).
