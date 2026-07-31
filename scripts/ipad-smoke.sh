#!/bin/bash
# Boots an iPad simulator, installs and launches the iPad app, and captures a
# screenshot. This is the phase's only end-to-end check that the app actually
# runs — every other gate stops at "it compiles".
#
#   ./scripts/ipad-smoke.sh ["iPad Pro 11-inch (M5)"] [/tmp/ipad-smoke.png]
#
# Prints "==> RUNNING" when the process is still alive after launch. Look at
# the screenshot afterwards: a live process proves nothing about what rendered.
set -euo pipefail

# Without this xcrun cannot even find simctl.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DEVICE="${1:-iPad Pro 11-inch (M5)}"
OUT="${2:-/tmp/ipad-smoke.png}"
BUNDLE_ID="ch.ski.video-viewer.ipad"

script_dir=$(cd "$(dirname "$0")" && pwd)
cd "$script_dir/../SkiVideoViewer"

echo "==> building for $DEVICE"
xcodebuild -scheme SkiVideoViewer-iPad \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath .build-ipad build >/dev/null

# -maxdepth first: BSD find warns when it follows a test.
APP=$(find .build-ipad/Build/Products -maxdepth 3 -name "SkiVideoViewer.app" | head -1)
if [ -z "$APP" ]; then echo "no app bundle produced"; exit 1; fi
echo "==> app: $APP"

echo "==> booting"
# Already-booted is not an error here; bootstatus below is the real wait.
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b

echo "==> installing"
xcrun simctl install "$DEVICE" "$APP"

# A stale copy from an earlier run would make the launch below a no-op and the
# screenshot a picture of the previous build.
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true

echo "==> launching"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID"

sleep 4
xcrun simctl io "$DEVICE" screenshot "$OUT"
echo "==> screenshot: $OUT"

# The app must still be running; a launch-then-crash would leave no process.
if xcrun simctl spawn "$DEVICE" launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; then
  echo "==> RUNNING"
else
  echo "==> WARNING: process not found after launch — check the screenshot"
fi
