#!/bin/bash
# Build a release binary and wrap it in ~/Applications/ClaudeIsland.app
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$HOME/Applications/ClaudeIsland.app"
pkill -x claude-island || true
mkdir -p "$APP/Contents/MacOS"
cp .build/release/claude-island "$APP/Contents/MacOS/claude-island"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.claudeisland.app</string>
  <key>CFBundleExecutable</key><string>claude-island</string>
  <key>CFBundleName</key><string>Claude Island</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Claude Island selects the terminal tab of the session you click.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
