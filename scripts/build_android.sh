#!/bin/sh
set -eu
cd "$(dirname "$0")/../android"

# Homebrew's JDK is keg-only, so macOS /usr/bin/java does not discover it.
if [ -z "${JAVA_HOME:-}" ] && [ -d /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ]; then
    JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
    export JAVA_HOME
fi

if [ -z "${ANDROID_HOME:-}" ] && [ -d /opt/homebrew/share/android-commandlinetools ]; then
    ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
    export ANDROID_HOME
fi

if [ -x ./gradlew ]; then
    ./gradlew assembleDebug
    printf 'APK: %s\n' "$(pwd)/app/build/outputs/apk/debug/app-debug.apk"
    exit 0
fi
if command -v gradle >/dev/null 2>&1; then
    gradle assembleDebug
    printf 'APK: %s\n' "$(pwd)/app/build/outputs/apk/debug/app-debug.apk"
    exit 0
fi

cat >&2 <<'EOF'
Android 빌드 도구가 없습니다.
Android Studio에서 android/ 폴더를 열어 Build > Build APK(s)를 실행하거나
Gradle 8.9를 설치한 뒤 이 스크립트를 다시 실행하세요.
EOF
exit 2
