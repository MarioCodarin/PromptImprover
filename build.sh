#!/bin/zsh
# Builds a release binary with SwiftPM and wraps it into PromptImprover.app (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
# The prompts are the product. If the rubric maths, the parsers or the linter gate regress, the build stops.
.build/release/PromptImprover --selftest
APP="PromptImprover.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PromptImprover "$APP/Contents/MacOS/"
# Render the SwiftUI logo into the app icon (same view the app shows in-app).
ICONSET=".build/AppIcon.iconset"
rm -rf "$ICONSET"
.build/release/PromptImprover --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Prompt Improver</string>
  <key>CFBundleDisplayName</key><string>Prompt Improver</string>
  <key>CFBundleIdentifier</key><string>local.PromptImprover</string>
  <key>CFBundleExecutable</key><string>PromptImprover</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"

# ./build.sh --install  → copy to /Applications (recommended, so "Open at login" points at a stable path)
if [[ "${1:-}" == "--install" ]]; then
  pkill -x PromptImprover 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "Installed /Applications/$APP"
fi
