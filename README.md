## Tunnel Controller

[![Build APK](https://github.com/nam348tnh3gp/Tunnel/actions/workflows/build.yml/badge.svg)](https://github.com/nam348tnh3gp/Tunnel/actions/workflows/build.yml)
[![Releases](https://img.shields.io/github/v/release/nam348tnh3gp/Tunnel?label=releases)](https://github.com/nam348tnh3gp/Tunnel/releases)
[![Flutter](https://img.shields.io/badge/flutter-3.22.0-blue?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/dart-%3E%3D3.0.0-blue?logo=dart)](https://dart.dev)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/nam348tnh3gp/Tunnel/blob/main/LICENSE)

A compact Flutter app to run Cloudflare Tunnel (cloudflared) on Android devices. The app supports a temporary "Try" mode and a persistent "Token" mode. Features foreground service support for background operation and state persistence across app restarts. The repository includes a CI pipeline that cross-compiles cloudflared for multiple architectures and packages them into a single APK.

Quick links
- Repository: https://github.com/nam348tnh3gp/Tunnel
- Main app: `lib/main.dart`
- Task handler: `lib/tunnel_task_handler.dart`
- CI workflow: `.github/workflows/build.yml`
- Releases: https://github.com/nam348tnh3gp/Tunnel/releases
- License: `LICENSE` (Apache-2.0)

Table of contents
- [Key features](#key-features)
- [What's new](#whats-new)
- [How it works (overview)](#how-it-works-overview)
- [Prebuilt APK (recommended)](#prebuilt-apk-recommended)
- [Prerequisites](#prerequisites)
- [Build & Run (local)](#build--run-local)
- [Reproduce CI: build cloudflared](#reproduce-ci-build-cloudflared)
- [CI / GitHub Actions](#ci--github-actions)
- [Usage (in-app)](#usage-in-app)
- [Flags & mapping](#flags--mapping)
- [Background Service](#background-service)
- [State Persistence](#state-persistence)
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
- Live logs, automatic detection of trycloudflare public URLs, and basic device performance stats (CPU, temperature via `device_info_ce`).
- Copy logs and public URL from the UI.
- **Foreground service support** — tunnel continues running in background with persistent notification.
- **State persistence** — app remembers tunnel status, logs, and public URL across app restarts.
- **Automatic state recovery** — if the app is killed, it can restore the running tunnel session.

## What's new
- **Foreground Service (v1.0.1)**: Tunnel now runs as a foreground service, allowing continuous operation in the background.
- **State Persistence**: SharedPreferences integration to save and restore tunnel state, logs, and public URLs.
- **Background State Recovery**: App detects if tunnel was running before shutdown and recovers gracefully.
- **Enhanced Notifications**: Live notifications show tunnel status and public URL with quick copy functionality.
- **Improved UI**: Visual status indicators, emoji icons, and better layout for device performance metrics.

## How it works (overview)
- The Flutter UI (see `lib/main.dart`) collects user inputs and launches the native `cloudflared` binary as a subprocess on the device.
- On initialization, the app attempts to get the Android native library directory via a MethodChannel. If `libcloudflared.so` exists in that directory it is used; otherwise `assets/cloudflared` is extracted to app storage.
- The app starts a foreground service via `FlutterForegroundTask` to keep the tunnel alive in the background.
- stdout/stderr are monitored for Try Cloudflare URLs (`https://<id>.trycloudflare.com`), which are shown in the UI when detected.
- App state (logs, URL, PID, running status) is persisted to SharedPreferences after each update.
- On app restart, `_restoreRunningState()` checks if the service is still alive and recovers the UI state accordingly.
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
- Foreground service requires Android 8.0+ for proper background operation.

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
- **Mode Selection**:
  - Try Cloudflared: starts a temporary public URL (no token required).
  - Token: enter your Cloudflare Tunnel token (runs `tunnel run --token <TOKEN>`).
- **Basic Configuration**:
  - Local port (default 8080) — the port your local service is running on.
  - Custom arguments (space-separated) — additional cloudflared CLI flags.
- **Advanced Options**:
  - QUIC on/off — enable/disable QUIC protocol (HTTP/2 fallback available).
  - Post-Quantum on/off — enable post-quantum cryptography.
  - Metrics enabled/disabled — enable/disable tunnel metrics collection.
  - Region — specify a Cloudflare region (e.g., hkg, sin, lax).
  - Edge IP version — choose between Auto, IPv4, or IPv6.
  - Custom hostname — bind tunnel to a custom hostname.
- **Control & Monitoring**:
  - Start/Stop buttons control the tunnel subprocess.
  - Logs are streamed live to the UI.
  - Try URLs are auto-detected and displayed in a copy-friendly card.
  - CPU usage and device temperature are displayed in real-time.
  - Running status indicator shows tunnel state at a glance.

## Flags & mapping
- Disable QUIC → `--protocol http2`
- Enable Post-Quantum → `--post-quantum`
- Disable metrics → `--management-diagnostics=false`
- Region → `--region <value>`
- Edge IP version → `--edge-ip-version <auto|4|6>`
- Hostname → `--hostname <hostname>`
- Custom args → appended as-is to the cloudflared command

## Background Service
The app uses `flutter_foreground_task` to run a foreground service that keeps the tunnel alive even when the app is backgrounded or minimized.

- **Service Initialization**: When you tap "Start", the app launches `FlutterForegroundTask.startService()`.
- **Persistent Notification**: A notification appears with the tunnel status and public URL (if available).
- **Graceful Shutdown**: Tapping "Stop" or closing the app stops the service cleanly.
- **Task Handler**: The background task is managed by `TunnelTaskHandler()` in `lib/tunnel_task_handler.dart`.

**Note**: On Android 8.0+, foreground services require a notification to remain visible. This is intentional to comply with Android policy.

## State Persistence
The app uses `SharedPreferences` to save and restore tunnel state across app restarts.

**Saved state includes**:
- `tunnel_log` — full log output from the tunnel.
- `tunnel_url` — the public URL (for Try mode).
- `tunnel_pid` — process ID of the running tunnel.
- `tunnel_is_running` — boolean flag indicating if tunnel was running.

**Recovery Logic** (`_restoreRunningState()`):
1. On app start, check if foreground service is still running.
2. If service is active and `tunnel_is_running` was true → restore UI state (logs, URL, PID).
3. If service is stopped but `tunnel_is_running` was true → show a warning and reset state.
4. If service is not running → discard saved state and start fresh.

This ensures the app gracefully handles both intentional stops and unexpected process kills.

## Troubleshooting

### Binary not found / permission denied
- Confirm `libcloudflared.so` is in `jniLibs/<abi>` or `assets/cloudflared` exists.
- App runs `chmod 755` after extracting; verify device allows execution.
- Check device logs: `adb logcat | grep Tunnel`

### Architecture mismatch
- Use ABI-compatible build for your device (arm64 vs armeabi-v7a vs x86/x86_64).
- Check device ABI: `adb shell getprop ro.product.cpu.abi`

### No public URL shown
- Inspect logs. App looks for `https://*.trycloudflare.com` pattern.
- Verify token (in Token mode) and network connectivity.
- Ensure the local service is running on the specified port.

### Foreground service not starting
- Verify device has Android 8.0+.
- Check notification permissions in app settings.
- Review logcat for service-related errors.

### State not restored after app crash
- Manual restart clears all recovery state for safety.
- Check `shared_preferences` permissions in `AndroidManifest.xml`.

### Emulators
- Many emulators run x86; ensure matching binaries or use physical device.
- Performance stats may not work on all emulator configurations.

## Security notes
- Tunnel tokens are sensitive — keep them secret and never share them.
- The app executes a native binary; use trusted cloudflared builds from official Cloudflare releases.
- AndroidManifest uses `usesCleartextTraffic="true"` in the generated app to ease testing — review and adjust for production.
- State is persisted locally using `SharedPreferences`; tokens in logs are saved in plaintext on device storage — consider securing this via encryption if needed.
- Foreground service notification may display sensitive information (public URL) — this is user-controlled via the UI.

## Contributing
- File issues or open PRs. When reporting runtime bugs include device model, Android version, and logs.
- Suggested improvements:
  - Secure token storage (encrypt SharedPreferences).
  - Signed release builds and per-ABI APK artifacts.
  - Enhanced log filtering and search functionality.
  - Export logs to file with timestamp.
  - Scheduled tunnel start/stop times.
  - Multiple tunnel profiles/presets.

## License
This project is licensed under the Apache License 2.0 — see `LICENSE`.
