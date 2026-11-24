#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/build/HEAVN Keep Awake.app"

if ! xcrun --find swiftc >/dev/null 2>&1; then
    printf '%s\n' 'Install the Xcode command-line tools first: xcode-select --install' >&2
    exit 1
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"

xcrun swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macosx13.0" \
    "$ROOT/Sources/HEAVNMenu.swift" \
    -framework AppKit -framework CoreBluetooth \
    -o "$APP/Contents/MacOS/HEAVNKeepAwake"

codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '\nBuilt %s\n' "$APP"
