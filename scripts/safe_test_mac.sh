#!/bin/sh
# Tests one explicit curl request. It never changes routes, DNS, firewall, or macOS proxies.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_URL=${1:-https://connectivitycheck.gstatic.com/generate_204}
ADB_PORT=8787
SOCKS_PORT=1088
CREATED_FORWARD=0
PROXY_PID=
LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/opentetrd.XXXXXX")

cleanup() {
    if [ -n "$PROXY_PID" ]; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
    fi
    if [ "$CREATED_FORWARD" -eq 1 ]; then
        adb forward --remove "tcp:$ADB_PORT" >/dev/null 2>&1 || true
    fi
    rm -f "$LOG_FILE"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

command -v adb >/dev/null 2>&1 || fail "adb not found. Install the Android platform-tools."
command -v curl >/dev/null 2>&1 || fail "curl not found."

DEVICES=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
DEVICE_COUNT=$(printf '%s\n' "$DEVICES" | awk 'NF { count++ } END { print count+0 }')
[ "$DEVICE_COUNT" -eq 1 ] || fail "Exactly one authorized Android USB device is required (found $DEVICE_COUNT)."
SERIAL=$(printf '%s\n' "$DEVICES" | awk 'NF { print; exit }')

EXISTING=$(adb forward --list | awk -v p="tcp:$ADB_PORT" '$2 == p { print $1 " " $3 }')
if [ -n "$EXISTING" ]; then
    EXISTING_SERIAL=$(printf '%s\n' "$EXISTING" | awk '{print $1; exit}')
    EXISTING_REMOTE=$(printf '%s\n' "$EXISTING" | awk '{print $2; exit}')
    [ "$EXISTING_SERIAL" = "$SERIAL" ] && [ "$EXISTING_REMOTE" = "tcp:$ADB_PORT" ] \
        || fail "Refusing to overwrite an existing ADB mapping for tcp:$ADB_PORT: $EXISTING"
    printf 'Reusing the existing ADB port mapping.\n'
else
    nc -z 127.0.0.1 "$ADB_PORT" >/dev/null 2>&1 \
        && fail "127.0.0.1:$ADB_PORT is already in use on this Mac."
    adb -s "$SERIAL" forward "tcp:$ADB_PORT" "tcp:$ADB_PORT" >/dev/null
    CREATED_FORWARD=1
    printf 'Created a temporary ADB port mapping (removed on exit).\n'
fi

nc -z 127.0.0.1 "$SOCKS_PORT" >/dev/null 2>&1 \
    && fail "127.0.0.1:$SOCKS_PORT is already in use on this Mac."

ROUTE_BEFORE=$(route -n get default 2>/dev/null | shasum | awk '{print $1}')
cd "$ROOT"
python3 -m opentetrd.desktop --listen-port "$SOCKS_PORT" --relay-port "$ADB_PORT" >"$LOG_FILE" 2>&1 &
PROXY_PID=$!

READY=0
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if nc -z 127.0.0.1 "$SOCKS_PORT" >/dev/null 2>&1; then
        READY=1
        break
    fi
    sleep 0.1
done
[ "$READY" -eq 1 ] || {
    sed -n '1,120p' "$LOG_FILE" >&2
    fail "The local SOCKS proxy did not start."
}

printf 'Sending exactly one test request through the phone relay: %s\n' "$TEST_URL"
if curl --fail --silent --show-error --output /dev/null \
        --connect-timeout 10 --max-time 30 \
        --proxy "socks5h://127.0.0.1:$SOCKS_PORT" "$TEST_URL"; then
    printf 'Success: the request travelled through the OpenTetrd path.\n'
else
    sed -n '1,120p' "$LOG_FILE" >&2
    fail "The tunnelled request failed. Leave Tetrd running and check the Android relay."
fi

ROUTE_AFTER=$(route -n get default 2>/dev/null | shasum | awk '{print $1}')
if [ "$ROUTE_BEFORE" != "$ROUTE_AFTER" ]; then
    fail "The default route changed during the test due to an external factor. OpenTetrd did not change it, but check your network state."
fi
printf 'Verified: the macOS default route is unchanged, and Tetrd settings were left alone.\n'
