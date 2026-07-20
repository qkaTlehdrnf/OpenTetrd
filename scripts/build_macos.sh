#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP="$ROOT/dist/OpenTetrd.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -parse-as-library -O \
    -target arm64-apple-macos13.0 \
    -framework AppKit \
    "$ROOT/macos/OpenTetrdMac.swift" \
    -o "$APP/Contents/MacOS/OpenTetrd"
cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
printf 'macOS app: %s\n' "$APP"
