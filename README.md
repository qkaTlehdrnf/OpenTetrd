# OpenTetrd 0.1

## 다운로드

| 플랫폼 | 설치 파일 | 지원 환경 |
| --- | --- | --- |
| Android | **[APK 다운로드](https://github.com/qkaTlehdrnf/OpenTetrd/releases/download/v0.1.0/OpenTetrd-Android-0.1.0-debug.apk)** | Android 8.0 / API 26 이상 |
| macOS | **[macOS 앱 다운로드](https://github.com/qkaTlehdrnf/OpenTetrd/releases/download/v0.1.0/OpenTetrd-macOS-arm64-0.1.0.zip)** | Apple Silicon, macOS 13 이상 |

[전체 릴리스와 SHA-256 체크섬 보기](https://github.com/qkaTlehdrnf/OpenTetrd/releases/tag/v0.1.0)

> 현재 `v0.1.0`은 초기 시험판입니다. macOS 앱은 공증되지 않았으므로 압축 해제 후 앱을 Control-클릭하고 **열기**를 선택해야 할 수 있습니다.

Tetrd를 끄지 않은 채 별도의 요청만 휴대폰 인터넷으로 보내 시험하는 안전 우선 프로토타입입니다.
Android 릴레이가 목적지 TCP 연결을 만들고, Mac의 SOCKS5 프록시가 그 연결을 USB의 ADB 포트 포워딩으로 사용합니다.

```text
curl/브라우저(명시적 SOCKS) -> 127.0.0.1:1088
    -> adb forward(USB) -> Android 127.0.0.1:8787
    -> 휴대폰의 기본 인터넷 -> 목적지
```

## 안전 경계

- Tetrd 프로세스를 중지하거나 설정을 바꾸지 않습니다.
- macOS 기본 경로, DNS, 방화벽, 시스템 프록시와 네트워크 서비스 우선순위를 변경하지 않습니다.
- 두 리스너 모두 기본적으로 루프백에만 바인딩합니다.
- `safe_test_mac.sh`는 기존 ADB 매핑과 사용 중인 포트를 덮어쓰지 않습니다.
- 스크립트가 만든 ADB 매핑과 데스크톱 프로세스만 종료 시 정리합니다.

현재 버전은 **TCP CONNECT 기반 SOCKS5만** 지원합니다. UDP, ICMP, IPv6 경로 검증, 자동 재연결,
시스템 전체 투명 터널, 그리고 PC 인터넷을 Android로 보내는 reverse tethering은 아직 지원하지 않습니다.
따라서 상용 Tetrd의 완전한 대체물이 아니라, 현재 연결을 위험에 빠뜨리지 않고 핵심 경로를 검증하는 MVP입니다.

## 1. 가상 서버 시험

외부 인터넷과 실제 Android를 쓰지 않습니다. 테스트 안에서 가상 인터넷 HTTP 서버, 가상 휴대폰 릴레이,
데스크톱 SOCKS 서버를 각각 임시 루프백 포트에 띄워 전체 경로를 검증합니다.

```sh
./scripts/run_virtual_lab.sh
```

성공 시 3개 테스트가 `OK`로 끝납니다.

## 2-A. Android 네이티브 앱 사용

이 저장소의 `android/`를 Android Studio에서 열고 debug APK를 빌드합니다. 또는 JDK 17, Android SDK와
Gradle 8.9가 설치된 환경에서 실행합니다. 이 Mac에는 명령줄 빌드 도구와 Gradle wrapper가 준비되어 있습니다.

```sh
./scripts/build_android.sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

현재 생성된 APK는 `android/app/build/outputs/apk/debug/app-debug.apk`입니다.

휴대폰에서 OpenTetrd를 열고 **릴레이 시작**을 누릅니다. USB 디버깅 승인도 필요합니다.
릴레이는 Android의 `127.0.0.1:8787`에서만 대기하므로 Wi-Fi나 이동통신망에 직접 노출되지 않습니다.

## 2-B. APK 빌드 없이 Termux에서 사용

휴대폰에 Termux와 Python 3이 있다면 소스를 USB로 복사할 수 있습니다.

```sh
./scripts/push_termux_relay.sh
```

스크립트가 출력하는 명령을 Termux에서 실행해 릴레이를 시작합니다. Android의 파일 접근 권한 설정에 따라
`termux-setup-storage` 승인이 한 번 필요합니다.

## 3. 현재 Mac에서 제한 시험

Tetrd는 **계속 켜 둡니다**. Android 릴레이가 실행 중이고 USB 디버깅이 승인된 상태에서:

```sh
./scripts/safe_test_mac.sh
```

기본 URL 대신 원하는 HTTPS URL 한 개를 지정할 수도 있습니다.

```sh
./scripts/safe_test_mac.sh https://example.com/
```

이 시험은 `curl` 한 요청에만 `socks5h://127.0.0.1:1088`을 명시합니다. 성공 여부와 무관하게 시스템
프록시는 설정하지 않으며, 스크립트가 만든 프로세스와 ADB 포워딩은 `trap`으로 정리됩니다.

### macOS GUI 앱

명령줄 대신 네이티브 앱에서 시작·시험·중지를 관리할 수 있습니다.

```sh
./scripts/build_macos.sh
open dist/OpenTetrd.app
```

휴대폰 앱에서 먼저 `릴레이 시작`을 누른 다음 Mac 앱에서 `OpenTetrd 시작`, `연결 시험` 순서로 누릅니다.
Mac 앱도 시스템 네트워크 설정은 변경하지 않으며 명시적 SOCKS 서버만 엽니다.

수동으로 특정 앱만 시험하려면 세 터미널에서 다음을 실행합니다.

```sh
adb forward tcp:8787 tcp:8787
python3 -m opentetrd.desktop --verbose
curl --proxy socks5h://127.0.0.1:1088 https://example.com/
```

수동 시험 후에는 자신이 만든 매핑만 제거합니다.

```sh
adb forward --remove tcp:8787
```

## 구조와 위협 모델

- `opentetrd/desktop.py`: 인증 없는 SOCKS5 CONNECT 서버. 기본값으로 Mac 루프백만 허용합니다.
- `opentetrd/phone_relay.py`: Termux/가상 실험용 릴레이입니다.
- `android/`: 같은 `OTR1` 프로토콜을 구현한 Android foreground service입니다.
- `tests/test_virtual_lab.py`: 실제 바이트가 세 서버를 통과했음을 응답 본문으로 증명합니다.

ADB 디버깅을 승인한 컴퓨터는 휴대폰에 강한 접근 권한을 가집니다. 소유한 컴퓨터에서만 승인하고,
공용 컴퓨터에는 연결하지 마세요. 이 프로토타입에는 암호화나 상호 인증이 없지만 통신 채널은 양쪽 모두
루프백과 사용자가 승인한 USB ADB 연결로 제한됩니다.

## 설계 근거

Tetrd의 공개 설명은 휴대폰과 PC 사이의 양방향 USB 인터넷 공유를 제품 범위로 밝힙니다.
Android에서 진정한 시스템 전체 reverse tethering을 만들려면 `VpnService`의 TUN 인터페이스와
터널 소켓 보호를 구현해야 합니다. 이 저장소는 현재 Tetrd 의존 연결을 보존하기 위해 해당 시스템 경로를
건드리지 않고, 먼저 명시적 프록시 경로를 검증하도록 설계했습니다.

- Tetrd 제품 설명: https://play.google.com/store/apps/details?id=com.robskie.tether
- Android VPN 개발 문서: https://developer.android.com/develop/connectivity/vpn
