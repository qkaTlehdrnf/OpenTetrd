#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
DEST=/sdcard/Download/OpenTetrd

command -v adb >/dev/null 2>&1 || { printf 'adb가 필요합니다.\n' >&2; exit 1; }
COUNT=$(adb devices | awk 'NR > 1 && $2 == "device" { count++ } END { print count+0 }')
[ "$COUNT" -eq 1 ] || { printf '승인된 Android 장치가 정확히 1대여야 합니다.\n' >&2; exit 1; }

adb shell mkdir -p "$DEST"
adb push "$ROOT/opentetrd" "$DEST/"
printf '%s\n' \
    '전송 완료. Termux에서 다음 명령을 실행하세요:' \
    '  termux-setup-storage  # 최초 한 번만' \
    '  pkg install python    # Python이 없을 때만' \
    '  cd ~/storage/downloads/OpenTetrd' \
    '  python -m opentetrd.phone_relay'
