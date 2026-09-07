#!/bin/bash
# Builds StayAwake.app from source. Output: build/StayAwake.app
# Requires Xcode Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")/.."

APP=build/StayAwake.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Bundled so the app can offer passwordless lid mode from inside the menu.
cp scripts/install-sudoers.sh "$APP/Contents/Resources/"

swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$APP/Contents/MacOS/StayAwake" \
    Sources/main.swift

# Ad-hoc signature. Locally built apps do not get the quarantine flag, so
# Gatekeeper lets them run without a paid Developer ID.
codesign --force --deep --sign - "$APP"
echo "Built $APP"
