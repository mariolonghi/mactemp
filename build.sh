#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# The Command Line Tools SDK on this machine is too old to build against, so
# prefer the full Xcode toolchain when it is installed.
if [ -d /Applications/Xcode.app ]; then
	export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

APP="MacTemp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

xcrun swiftc -swift-version 5 -O \
	-target arm64-apple-macos12.0 \
	-framework Cocoa \
	main.swift -o "$APP/Contents/MacOS/MacTemp"

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
