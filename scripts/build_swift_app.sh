#!/usr/bin/env bash
set -euo pipefail

# Build signed macOS .app for OpenGranola (Swift)
# Usage:
#   ./scripts/build_swift_app.sh
#
# For CI / explicit identity:
#   CODESIGN_IDENTITY="Developer ID Application: ..." ./scripts/build_swift_app.sh
#
# For notarization:
#   APPLE_ID="name@example.com"
#   APPLE_TEAM_ID="TEAMID123"
#   APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
SWIFT_DIR="$ROOT_DIR/OpenGranola"
APP_NAME="OpenGranola"
BUNDLE_ID="com.opengranola.app"

echo "=== Building $APP_NAME (Swift) ==="

# Build release binary
cd "$SWIFT_DIR"
swift build -c release 2>&1
BINARY_PATH=".build/release/OpenGranola"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH"
  exit 1
fi

echo "Binary built: $BINARY_PATH"

# Create .app bundle
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"

# Copy binary
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/OpenGranola"

# Copy Info.plist
cp "$SWIFT_DIR/Sources/OpenGranola/Info.plist" "$APP_DIR/Contents/Info.plist"

# Copy app icon
ICON_PATH="$SWIFT_DIR/Sources/OpenGranola/Assets/AppIcon.icns"
if [[ -f "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$APP_DIR/Contents/Resources/AppIcon.icns"
  echo "App icon copied"
fi

# Copy Sparkle framework
SPARKLE_ARTIFACT_DIR="$SWIFT_DIR/.build/artifacts/sparkle"
SPARKLE_FW=$(find "$SPARKLE_ARTIFACT_DIR" -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [[ -n "$SPARKLE_FW" ]]; then
  cp -R "$SPARKLE_FW" "$APP_DIR/Contents/Frameworks/"
  echo "Sparkle.framework copied"
else
  echo "Warning: Sparkle.framework not found in build artifacts"
fi

# Add PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "App bundle created: $APP_DIR"

# Auto-detect signing identity if not set
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
  fi
fi

# Sign the app
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  ENTITLEMENTS="$SWIFT_DIR/Sources/OpenGranola/OpenGranola.entitlements"
  echo "Signing with: $CODESIGN_IDENTITY"

  # Sign Sparkle XPC services and framework first (inside-out)
  SPARKLE_FW_BUNDLE="$APP_DIR/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE_FW_BUNDLE" ]]; then
    # Sign XPC services
    for xpc in "$SPARKLE_FW_BUNDLE"/XPCServices/*.xpc; do
      if [[ -d "$xpc" ]]; then
        codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$xpc"
      fi
    done

    # Sign Autoupdate helper
    AUTOUPDATE="$SPARKLE_FW_BUNDLE/Versions/B/Autoupdate"
    if [[ -f "$AUTOUPDATE" ]]; then
      codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$AUTOUPDATE"
    fi

    # Sign the framework itself
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" --timestamp "$SPARKLE_FW_BUNDLE"
  fi

  # Sign the main app bundle
  codesign --force --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_DIR"

  echo "Code signing complete"
  codesign -vvv "$APP_DIR"
else
  echo "Warning: No signing identity found. App will be unsigned."
fi

# Install to /Applications
cp -R "$APP_DIR" /Applications/
echo "Installed to /Applications/$APP_NAME.app"

echo "=== Build complete ==="
