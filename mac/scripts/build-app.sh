#!/bin/bash
# Builds "Download My Messages.app" into mac/build/.
# Requires the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Download My Messages"
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BIN=".build/apple/Products/Release/DownloadMyMessages"
    echo "Built a universal binary (Apple Silicon + Intel)."
else
    echo "Universal build needs full Xcode; building for this Mac only."
    swift build -c release
    BIN=".build/release/DownloadMyMessages"
fi

APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DownloadMyMessages"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature. Friends will need to right-click > Open the first time.
codesign --force --deep --sign - "$APP"

(cd build && rm -f "${APP_NAME}.zip" && ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}.zip")
echo "Done: mac/$APP (and mac/build/${APP_NAME}.zip for sharing)"
