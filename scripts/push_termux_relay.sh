#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DEST=/sdcard/Download/OpenTetrd

command -v adb >/dev/null 2>&1 || { printf 'adb is required.\n' >&2; exit 1; }
COUNT=$(adb devices | awk 'NR > 1 && $2 == "device" { count++ } END { print count+0 }')
[ "$COUNT" -eq 1 ] || { printf 'Exactly one authorized Android device is required.\n' >&2; exit 1; }

adb shell mkdir -p "$DEST"
adb push "$ROOT/opentetrd" "$DEST/"
printf '%s\n' \
    'Copied. Run these commands in Termux:' \
    '  termux-setup-storage  # first time only' \
    '  pkg install python    # only if Python is missing' \
    '  cd ~/storage/downloads/OpenTetrd' \
    '  python -m opentetrd.phone_relay'
