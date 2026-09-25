#!/bin/sh
# Builds dist/OpenTetrd-macOS-arm64-<version>.dmg whose Finder window shows the app,
# an arrow and an Applications shortcut, so users can drag the app into Applications.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP="$ROOT/dist/OpenTetrd.app"
VOLUME_NAME=OpenTetrd
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/macos/Info.plist")
DMG="$ROOT/dist/OpenTetrd-macOS-arm64-$VERSION.dmg"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/opentetrd-dmg.XXXXXX")
DEVICE=

cleanup() {
    if [ -n "$DEVICE" ]; then
        hdiutil detach "$DEVICE" -quiet -force >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

[ -e "/Volumes/$VOLUME_NAME" ] && {
    printf '오류: /Volumes/%s가 이미 마운트되어 있습니다. 먼저 꺼내세요.\n' "$VOLUME_NAME" >&2
    exit 1
}

"$ROOT/scripts/build_macos.sh"

# Background: 1x and Retina 2x combined into one TIFF that Finder picks from.
swiftc -swift-version 5 -O -framework AppKit "$ROOT/macos/dmg/Background.swift" -o "$WORK/background"
"$WORK/background" "$WORK/background.png" 1
"$WORK/background" "$WORK/background@2x.png" 2

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/OpenTetrd.app"
ln -s /Applications "$STAGE/Applications"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null

hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$STAGE" -fs HFS+ \
    -format UDRW -size 64m "$WORK/rw.dmg"
DEVICE=$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen \
    | awk '/Apple_HFS/ { print $1; exit }')
[ -n "$DEVICE" ] || { printf '오류: 디스크 이미지를 마운트하지 못했습니다.\n' >&2; exit 1; }

# Finder 창 배치. 처음 실행하면 터미널이 Finder 제어 권한을 요청합니다.
if ! osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 840, 548}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "OpenTetrd.app" of container window to {170, 190}
        set position of item "Applications" of container window to {470, 190}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
then
    printf '경고: Finder 창 배치에 실패했습니다. Applications 바로가기만 있는 DMG를 만듭니다.\n' >&2
fi

sync
# Finder can hold the volume for a moment after closing the window.
for _attempt in 1 2 3 4 5; do
    hdiutil detach "$DEVICE" -quiet && { DEVICE=; break; }
    sleep 2
done
[ -z "$DEVICE" ] || { printf '오류: 디스크 이미지를 꺼내지 못했습니다.\n' >&2; exit 1; }
rm -f "$DMG"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
printf 'macOS disk image: %s\n' "$DMG"
shasum -a 256 "$DMG"
