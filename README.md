## Tunnel Controller

[![Build APK](https://github.com/nam348tnh3gp/Tunnel/actions/workflows/build.yml/badge.svg)](https://github.com/nam348tnh3gp/Tunnel/actions/workflows/build.yml)
[![Releases](https://img.shields.io/github/v/release/nam348tnh3gp/Tunnel?label=releases)](https://github.com/nam348tnh3gp/Tunnel/releases)
[![Flutter](https://img.shields.io/badge/flutter-3.22.0-blue?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/dart-%3E%3D3.0.0-blue?logo=dart)](https://dart.dev)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/nam348tnh3gp/Tunnel/blob/main/LICENSE)

A compact Flutter app to run Cloudflare Tunnel (cloudflared) on Android devices. The app supports a temporary "Try" mode and a persistent "Token" mode. The repository includes a CI pipeline that cross-compiles cloudflared for multiple Android ABIs and builds a universal APK.

Quick links
- Repository: https://github.com/nam348tnh3gp/Tunnel
- Main app: `lib/main.dart`
- CI workflow: `.github/workflows/build.yml`
- Releases: https://github.com/nam348tnh3gp/Tunnel/releases
- License: `LICENSE` (Apache-2.0)

Table of contents
- [Key features](#key-features)
- [How it works (overview)](#how-it-works-overview)
- [Prebuilt APK (recommended)](#prebuilt-apk-recommended)
- [Prerequisites](#prerequisites)
- [Build & Run (local)](#build--run-local)
- [Reproduce CI: build cloudflared](#reproduce-ci-build-cloudflared)
- [CI / GitHub Actions](#ci--github-actions)
- [Usage (in-app)](#usage-in-app)
- [Flags & mapping](#flags--mapping)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Contributing](#contributing)
- [License](#license)

## Key features
- Simple UI to start/stop Cloudflare Tunnel on Android devices.
- Two operation modes:
  - Try mode — creates a temporary public URL pointing to a local port.
  - Token mode — runs `tunnel run --token <TOKEN>` for persistent tunnels.
- Multi-ABI support: CI builds cloudflared for arm64, armeabi-v7a, x86_64, x86 and packages them into `jniLibs` and `assets`.
- Fallback binary: if native lib not found, the app extracts `assets/cloudflared` to app storage and executes it.
- Live logs, automatic detection of trycloudflare public URLs, and basic device performance stats (via `device_info_ce`).
- Copy logs and public URL from the UI.

## How it works (overview)
- The Flutter UI (see `lib/main.dart`) collects user inputs and launches the native `cloudflared` binary as a subprocess on the device.
- On initialization, the app attempts to get the Android native library directory via a MethodChannel. If `libcloudflared.so` exists in that directory it is used; otherwise `assets/cloudflared` is extracted and used as fallback.
- stdout/stderr are monitored for Try Cloudflare URLs (`https://<id>.trycloudflare.com`), which are shown in the UI when detected.
- The CI workflow cross-compiles cloudflared for each target ABI, injects the shared libraries into a generated Flutter app, and builds APK(s).

## Prebuilt APK (recommended)
We provide prebuilt artifacts in Releases. Download the latest release and you will find an archive named `tunnel-apk.zip` which contains a single APK built to support all common ABIs (aarch32, aarch64, x86, x86_64).

Installation steps:
1. Go to the Releases page: https://github.com/nam348tnh3gp/Tunnel/releases
2. Download `tunnel-apk.zip`
3. Unzip to extract the APK (e.g. `tunnel.apk`)
4. Install:
   - Via adb:
     ```
     adb install -r path/to/tunnel.apk
     ```
   - Or enable "Install unknown apps" on your device and open the APK with a file manager.

Notes:
- The APK from CI may be unsigned or not Play-signed. For production distribution sign the APK with your key.
- The bundled APK aims to include all ABIs, but some devices/firmwares might require a specific ABI build — test on your target device.

## Prerequisites (for building locally)
- Flutter (workflow tested with 3.22.0)
- Java JDK 17
- Android SDK and Android NDK (CI uses r26c)
- Optional: Go toolchain (if you want to build cloudflared locally)
- Physical Android device or emulator (emulator ABI must match binary)

## Build & Run (local)
1. Clone:
   ```
   git clone https://github.com/nam348tnh3gp/Tunnel.git
   cd Tunnel
   ```
2. Install dependencies:
   ```
   flutter pub get
   ```
3. (Optional) Provide native binaries:
   - Place ABI-specific shared libs in:
     ```
     android/app/src/main/jniLibs/arm64-v8a/libcloudflared.so
     android/app/src/main/jniLibs/armeabi-v7a/libcloudflared.so
     android/app/src/main/jniLibs/x86_64/libcloudflared.so
     android/app/src/main/jniLibs/x86/libcloudflared.so
     ```
   - Or place a runnable binary in `assets/cloudflared` (app will extract at runtime).
4. Run on device:
   ```
   flutter run
   ```
5. Build release APK:
   ```
   flutter build apk --release
   ```
   Output: `build/app/outputs/flutter-apk/app-release.apk`

## Reproduce CI: build cloudflared (summary)
CI clones https://github.com/cloudflare/cloudflared and builds per-ABI using CGO + Android NDK clang. Example steps used in CI:
```bash
export GOOS=android
export GOARCH=<arm64|arm|amd64|386>
export CGO_ENABLED=1
export CC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/<clang-target>"
export CXX="...clang++"
go build -ldflags='-s -w' -o cloudflared ./cmd/cloudflared
# then copy to output/<abi>/libcloudflared.so
```
CI then creates a Flutter project, copies sources, injects `jniLibs/<abi>/libcloudflared.so`, copies arm64 into `assets/cloudflared`, and builds the APK.

## CI / GitHub Actions
See `.github/workflows/build.yml`. High-level steps:
1. Setup Java (Zulu JDK 17) and Flutter (3.22.0).
2. Download Android NDK r26c; set `ANDROID_NDK_HOME`.
3. Clone and cross-compile cloudflared for multiple ABIs.
4. Scaffold Flutter project, inject native libs and assets, then `flutter build apk --release`.
5. Upload APK artifacts.
Triggers: push to `main`/`master`, manual dispatch.

## Usage (in-app)
- Mode:
  - Try Cloudflared: starts a temporary public URL (no token).
  - Token: enter Cloudflare Tunnel token (runs `tunnel run --token <TOKEN>`).
- Common fields:
  - Local port (default 8080)
  - Custom arguments (space-separated)
  - QUIC on/off
  - Post-Quantum on/off
  - Metrics enabled/disabled
  - Region, Edge IP version, Custom hostname
- Start/Stop buttons control the native subprocess. Logs are streamed to the UI and Try URLs are auto-detected and shown.

## Flags & mapping
- Disable QUIC → `--protocol http2`
- Enable Post-Quantum → `--post-quantum`
- Disable metrics → `--management-diagnostics=false`
- Region → `--region <value>`
- Edge IP version → `--edge-ip-version <auto|4|6>`
- Hostname → `--hostname <hostname>`
- Custom args → appended as-is

## Troubleshooting
- Binary not found / permission denied:
  - Confirm `libcloudflared.so` is in `jniLibs/<abi>` or `assets/cloudflared` exists.
  - App runs `chmod 755` after extracting; verify device allows execution.
- Architecture mismatch:
  - Use ABI-compatible build for your device (arm64 vs armeabi-v7a vs x86/x86_64).
- No public URL shown:
  - Inspect logs. App looks for `https://*.trycloudflare.com`.
  - Verify token (in Token mode) and network connectivity.
- Emulators:
  - Many emulators run x86; ensure matching binaries or use physical device.

## Security notes
- Tunnel tokens are sensitive — keep them secret.
- The app executes a native binary; use trusted cloudflared builds.
- AndroidManifest uses `usesCleartextTraffic="true"` in the generated app to ease testing — review for production.

## Contributing
- File issues or open PRs. When reporting runtime bugs include device model, Android version and logs.
- Suggested improvements:
  - Persist settings securely (tokens).
  - Signed release builds and per-ABI artifacts.
  - Better log parsing and UX for errors.

## License
This project is licensed under the Apache License 2.0 — see `LICENSE`.
