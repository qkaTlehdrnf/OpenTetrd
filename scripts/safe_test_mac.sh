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
    printf '오류: %s\n' "$1" >&2
    exit 1
}

command -v adb >/dev/null 2>&1 || fail "adb가 없습니다. Android platform-tools를 설치하세요."
command -v curl >/dev/null 2>&1 || fail "curl이 없습니다."

DEVICES=$(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
DEVICE_COUNT=$(printf '%s\n' "$DEVICES" | awk 'NF { count++ } END { print count+0 }')
[ "$DEVICE_COUNT" -eq 1 ] || fail "승인된 Android USB 장치가 정확히 1대여야 합니다 (현재 $DEVICE_COUNT대)."
SERIAL=$(printf '%s\n' "$DEVICES" | awk 'NF { print; exit }')

EXISTING=$(adb forward --list | awk -v p="tcp:$ADB_PORT" '$2 == p { print $1 " " $3 }')
if [ -n "$EXISTING" ]; then
    EXISTING_SERIAL=$(printf '%s\n' "$EXISTING" | awk '{print $1; exit}')
    EXISTING_REMOTE=$(printf '%s\n' "$EXISTING" | awk '{print $2; exit}')
    [ "$EXISTING_SERIAL" = "$SERIAL" ] && [ "$EXISTING_REMOTE" = "tcp:$ADB_PORT" ] \
        || fail "tcp:$ADB_PORT의 기존 ADB 매핑을 덮어쓰지 않습니다: $EXISTING"
    printf '기존 ADB 포트 매핑을 그대로 사용합니다.\n'
else
    nc -z 127.0.0.1 "$ADB_PORT" >/dev/null 2>&1 \
        && fail "Mac의 127.0.0.1:$ADB_PORT가 이미 사용 중입니다."
    adb -s "$SERIAL" forward "tcp:$ADB_PORT" "tcp:$ADB_PORT" >/dev/null
    CREATED_FORWARD=1
    printf '임시 ADB 포트 매핑을 만들었습니다 (종료 시 제거).\n'
fi

nc -z 127.0.0.1 "$SOCKS_PORT" >/dev/null 2>&1 \
    && fail "Mac의 127.0.0.1:$SOCKS_PORT가 이미 사용 중입니다."

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
    fail "로컬 SOCKS 프록시가 시작되지 않았습니다."
}

printf '한 개의 테스트 요청만 휴대폰 릴레이로 전송합니다: %s\n' "$TEST_URL"
if curl --fail --silent --show-error --output /dev/null \
        --connect-timeout 10 --max-time 30 \
        --proxy "socks5h://127.0.0.1:$SOCKS_PORT" "$TEST_URL"; then
    printf '성공: 요청이 OpenTetrd 경로를 통과했습니다.\n'
else
    sed -n '1,120p' "$LOG_FILE" >&2
    fail "터널 요청에 실패했습니다. Tetrd는 그대로 실행해 두고 Android 릴레이 상태를 확인하세요."
fi

ROUTE_AFTER=$(route -n get default 2>/dev/null | shasum | awk '{print $1}')
if [ "$ROUTE_BEFORE" != "$ROUTE_AFTER" ]; then
    fail "시험 도중 기본 경로가 외부 요인으로 변경됐습니다. OpenTetrd는 경로를 변경하지 않았지만 상태를 확인하세요."
fi
printf '확인: macOS 기본 경로는 시험 전후 동일합니다. Tetrd 설정은 건드리지 않았습니다.\n'
