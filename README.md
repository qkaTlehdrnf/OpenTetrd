# OpenTetrd 0.1

## Downloads

| Platform | Installer | Requirements |
| --- | --- | --- |
| Android | **[Download APK](https://github.com/qkaTlehdrnf/OpenTetrd/releases/download/v0.1.0/OpenTetrd-Android-0.1.0-debug.apk)** | Android 8.0 / API 26 or newer |
| macOS | **[Download macOS app](https://github.com/qkaTlehdrnf/OpenTetrd/releases/download/v0.1.0/OpenTetrd-macOS-arm64-0.1.0.zip)** | Apple Silicon, macOS 13 or newer |

[See all releases and SHA-256 checksums](https://github.com/qkaTlehdrnf/OpenTetrd/releases/tag/v0.1.0)

> `v0.1.0` is an early preview. The macOS app is not notarized, so after unzipping you may
> need to Control-click the app and choose **Open**.

A safety-first prototype for sending selected requests over your phone's internet connection
*without* turning Tetrd off. An Android relay opens the destination TCP connection, and a SOCKS5
proxy on the Mac reaches that relay through ADB port forwarding over USB.

```text
curl/browser (explicit SOCKS) -> 127.0.0.1:1088
    -> adb forward (USB) -> Android 127.0.0.1:8787
    -> the phone's default internet -> destination
```

## Safety boundaries

- Never stops the Tetrd process or changes its settings.
- Never changes the macOS default route, DNS, firewall, system proxy, or network service order.
- Both listeners bind to loopback only by default.
- `safe_test_mac.sh` never overwrites an existing ADB mapping or a port already in use.
- On exit, only the ADB mappings and desktop processes the script itself created are cleaned up.

This version supports **TCP CONNECT over SOCKS5 only**. UDP, ICMP, IPv6 path validation,
automatic reconnection, a system-wide transparent tunnel, and reverse tethering (sending the PC's
internet to Android) are all out of scope for now. It is therefore not a full replacement for the
commercial Tetrd — it is an MVP that validates the core path without putting your current
connection at risk.

## 1. Virtual-server test

Runs without the external internet and without a real Android device. The test starts a virtual
internet HTTP server, a virtual phone relay, and the desktop SOCKS server on separate ephemeral
loopback ports and verifies the whole path.

```sh
./scripts/run_virtual_lab.sh
```

On success the suite finishes with `OK`.

## 2-A. Using the native Android app

Open this repository's `android/` folder in Android Studio and build the debug APK, or build from
the command line with JDK 17, the Android SDK, and Gradle 8.9 installed.

```sh
./scripts/build_android.sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```

The built APK lands at `android/app/build/outputs/apk/debug/app-debug.apk`.

Open OpenTetrd on the phone and tap **Start relay**. You also need to approve USB debugging.
The relay listens only on `127.0.0.1:8787` on the phone, so it is never exposed directly to
Wi-Fi or the cellular network.

> The relay runs as a `dataSync` foreground service. On Android 14 and newer the system caps
> `dataSync` foreground services at roughly six hours per day, after which it stops the service.
> Tap **Start relay** again if that happens.

## 2-B. Using Termux without building an APK

If the phone has Termux and Python 3, you can copy the sources over USB instead.

```sh
./scripts/push_termux_relay.sh
```

Run the commands the script prints to start the relay in Termux. Depending on the phone's file
access settings you need to approve `termux-setup-storage` once.

## 3. A limited test on this Mac

**Leave Tetrd running.** With the Android relay started and USB debugging approved:

```sh
./scripts/safe_test_mac.sh
```

You can also point it at a single HTTPS URL of your choice instead of the default.

```sh
./scripts/safe_test_mac.sh https://example.com/
```

The test passes `socks5h://127.0.0.1:1088` to exactly one `curl` request. It never configures a
system proxy regardless of the outcome, and the processes and ADB forwards it created are cleaned
up by a `trap`.

### macOS GUI app

You can manage start, test, and stop from a native app instead of the command line.

```sh
./scripts/build_macos.sh
open dist/OpenTetrd.app
```

Tap `Start relay` in the phone app first, then click `Start OpenTetrd` and `Test connection` in
the Mac app. The Mac app likewise never changes system network settings; it only opens an
explicit SOCKS server.

To test a single app manually, run the following in three terminals.

```sh
adb forward tcp:8787 tcp:8787
python3 -m opentetrd.desktop --verbose
curl --proxy socks5h://127.0.0.1:1088 https://example.com/
```

After a manual test, remove only the mapping you created yourself.

```sh
adb forward --remove tcp:8787
```

### Installing the Python components

```sh
pip install .
```

This provides the `opentetrd-desktop` and `opentetrd-phone` commands, which are equivalent to
`python3 -m opentetrd.desktop` and `python3 -m opentetrd.phone_relay`.

## Layout and threat model

- `opentetrd/desktop.py`: an unauthenticated SOCKS5 CONNECT server, restricted to Mac loopback by default.
- `opentetrd/phone_relay.py`: the relay used for Termux and for the virtual lab.
- `android/`: an Android foreground service implementing the same `OTR1` protocol.
- `tests/test_virtual_lab.py`: proves via the response body that real bytes crossed all three servers.

A computer you have approved for ADB debugging holds strong access to the phone. Approve only
computers you own, and never connect to a shared machine. This prototype has no encryption and no
mutual authentication, but the channel is confined at both ends to loopback and a USB ADB
connection you approved.

Two further limits worth knowing:

- The relay places no restrictions on the destination, so it can also reach the phone's own
  loopback and its local network. Anyone who can reach the relay already has ADB access to the
  device, but keep this in mind before running the desktop proxy with `--allow-lan`.
- The SOCKS5 listener has no authentication. Leave it on loopback unless you fully trust every
  host on the network you expose it to.

## Design rationale

Tetrd's public description covers bidirectional USB internet sharing between phone and PC as its
product scope. Building true system-wide reverse tethering on Android requires a `VpnService` TUN
interface and tunnel socket protection. This repository is deliberately designed to validate the
explicit-proxy path first, without touching those system paths, so that the Tetrd-dependent
connection you are currently relying on stays intact.

- Tetrd product page: https://play.google.com/store/apps/details?id=com.robskie.tether
- Android VPN documentation: https://developer.android.com/develop/connectivity/vpn
