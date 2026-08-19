#!/usr/bin/env bash
# =============================================================================
#  build_app.sh — Fast Local Development & Bundle Builder for ClipLocal
# =============================================================================
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
APP_NAME="ClipLocal"
APP_DIR="$DIR/$APP_NAME.app"
DEST_APP="/Applications/$APP_NAME.app"

# 1. Single Source of Truth: Read version from version.json or main.swift
VERSION=$(python3 -c "import json; print(json.load(open('$DIR/version.json'))['version'])" 2>/dev/null || grep -m1 'let appVersion =' "$DIR/main.swift" | cut -d'"' -f2 || echo "1.2.4")
echo "🔖 Building $APP_NAME v$VERSION..."

# 2. Generate updated icons if needed
if [ -f "$DIR/AppIcon.png" ]; then
    mkdir -p "$DIR/AppIcon.iconset"
    sips -z 16 16     "$DIR/AppIcon.png" --out "$DIR/AppIcon.iconset/icon_16x16.png" >/dev/null 2>&1
    sips -z 32 32     "$DIR/AppIcon.png" --out "$DIR/AppIcon.iconset/icon_16x16@2x.png" >/dev/null 2>&1
    sips -z 32 32     "$DIR/AppIcon.png" --out "$DIR/AppIcon.iconset/icon_32x32.png" >/dev/null 2>&1
    sips -z 64 64     "$DIR/AppIcon.png" --out "$DIR/AppIcon.iconset/icon_32x32@2x.png" >/dev/null 2>&1
    sips -z 128 128   "$DIR/AppIcon.png" --out "$DIR/AppIcon.iconset/icon_128x128.png" >/dev/null 2>&1
    sips -z 256 256   "$DIR/AppIcon.png" --out "$DIR/AppIcon.iconset/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "$DIR/AppIcon.png" --out "$DIR/AppIcon.iconset/icon_256x256.png" >/dev/null 2>&1
    sips -z 512 512   "$DIR/AppIcon.png" --out "$DIR/AppIcon.iconset/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "$DIR/AppIcon.png" --out "$DIR/AppIcon.iconset/icon_512x512.png" >/dev/null 2>&1
    sips -z 1024 1024 "$DIR/AppIcon.png" --out "$DIR/AppIcon.iconset/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$DIR/AppIcon.iconset" -o "$DIR/AppIcon.icns" >/dev/null 2>&1 || true
fi

# 3. Assemble .app bundle structure
echo "📦 Assembling .app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

# 4. Copy Icon & Brand Assets
[ -f "$DIR/AppIcon.icns" ] && cp "$DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/"
[ -f "$DIR/AppLogo.png" ]  && cp "$DIR/AppLogo.png"  "$APP_DIR/Contents/Resources/"
[ -f "$DIR/AppIcon.png" ]  && cp "$DIR/AppIcon.png"  "$APP_DIR/Contents/Resources/"
[ -f "$DIR/logo.svg" ]     && cp "$DIR/logo.svg"     "$APP_DIR/Contents/Resources/"

# 5. Write Info.plist
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>com.aoh.cliplocal</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# 6. Compile Swift Binary
echo "🔨 Compiling main.swift with swiftc..."
SWIFT_SDK=$(xcrun --show-sdk-path 2>/dev/null || true)
SWIFT_CACHE="/tmp/.swiftcache_cliplocal"
mkdir -p "$SWIFT_CACHE"
xcrun swiftc -O ${SWIFT_SDK:+-sdk "$SWIFT_SDK"} -module-cache-path "$SWIFT_CACHE" -o "$APP_DIR/Contents/MacOS/$APP_NAME" "$DIR/main.swift" -framework Cocoa

chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# 7. Codesign with designated identifier for permission persistence
echo "🔏 Ad-hoc code signing..."
codesign --force --deep --sign - --requirements '=designated => identifier "com.aoh.cliplocal"' "$APP_DIR" >/dev/null 2>&1 || true

# 8. Install to /Applications
echo "🚀 Installing to $DEST_APP..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST_APP" 2>/dev/null || true
cp -R "$APP_DIR" "$DEST_APP"

# 9. Refresh LaunchServices icon cache
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST_APP" 2>/dev/null || true
touch "$DEST_APP"

# 10. Relaunch
echo "✨ Launching $APP_NAME..."
open "$DEST_APP"
echo "✅ Build & Install Complete!"
