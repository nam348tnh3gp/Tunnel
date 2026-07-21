# Tunnel Controller

[![CI](https://github.com/nam348tnh3gp/Tunnel/actions/workflows/build.yml/badge.svg)](https://github.com/nam348tnh3gp/Tunnel/actions/workflows/build.yml)
[![Flutter](https://img.shields.io/badge/flutter-3.22.0-blue?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/dart-%3E%3D3.0.0-blue?logo=dart)](https://dart.dev)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/nam348tnh3gp/Tunnel/blob/main/LICENSE)

A lightweight Flutter app that runs Cloudflare Tunnel (cloudflared) on Android devices. The app can run in a temporary "Try" mode or as a persistent tunnel using a Cloudflare tunnel token. The repository contains a CI workflow that cross-compiles cloudflared for multiple Android ABIs and builds the release APK.

Quick links
- Source: https://github.com/nam348tnh3gp/Tunnel
- Main app: `lib/main.dart`
- CI workflow: `.github/workflows/build.yml`
- License: `LICENSE` (Apache-2.0)
- Releases: https://github.com/nam348tnh3gp/Tunnel/releases

Table of contents
- [Features](#features)
- [How it works (high level)](#how-it-works-high-level)
- [Prebuilt APKs (recommended)](#prebuilt-apks-recommended)
- [Prerequisites](#prerequisites)
- [Build & Run locally](#build--run-locally)
- [Reproducing CI: building cloudflared](#reproducing-ci-building-cloudflared)
- [CI / GitHub Actions](#ci--github-actions)
- [Usage (in-app)](#usage-in-app)
- [Advanced options & flags mapping](#advanced-options--flags-mapping)
- [Troubleshooting](#troubleshooting)
- [Security & privacy notes](#security--privacy-notes)
- [Contributing](#contributing)
- [License](#license)

Features
- Simple GUI to start/stop Cloudflare Tunnel on Android.
- Two modes:
  - Try mode: obtains a temporary public URL (Try Cloudflare) mapping to a local port.
  - Token mode: runs `tunnel run --token <TOKEN>` for persistent tunnels.
- Multi-ABI support: CI builds cloudflared for arm64, arm, x86_64, x86 and packages into jniLibs and assets.
- Binary fallback: if native library is not present, app extracts `assets/cloudflared` to app documents and executes it.
- Streamed logs, automatic detection of Try Cloudflare public URL, basic device performance stats via `device_info_ce`.
- Copyable logs and public URL from the UI.

How it works (high level)
- The Flutter UI (lib/main.dart) manages user inputs and launches the native cloudflared binary as a subprocess on the device.
- On init the app tries to read the Android native library directory using a MethodChannel implemented in the Android activity (MainActivity created by the CI script). If `libcloudflared.so` exists there, it uses that binary; otherwise it extracts `assets/cloudflared` into app storage and marks it executable.
- When the tunnel starts, stdout/stderr are monitored for Try Cloudflare URLs (regex matching `https://<id>.trycloudflare.com`) and displayed to the user.
- CI builds cloudflared for different GOARCH/NDK targets, copies them into `android/app/src/main/jniLibs/<abi>/libcloudflared.so`, and also copies the arm64 build to `assets/cloudflared` as a fallback.

Prebuilt APKs (recommended)
- Prebuilt APKs are provided in the repository Releases. There is a release artifact named `tunnel-apk.zip` which contains a single APK built to support all supported architectures (aarch32, aarch64, x86, x86_64).
- This ZIP file is the fastest way to get the app on your device:
  1. Download `tunnel-apk.zip` from the Releases page.
  2. Unzip to extract `tunnel.apk` (or similarly named file).
  3. Install on your Android device:
     - Enable "Install unknown apps" for your installer (browser or file manager), or use adb:
       adb install -r path/to/tunnel.apk
- Notes:
  - The provided APK is an unsigned/unsigned-by-default build from CI (verify with the release asset). For distribution to users, consider signing the APK.
  - Verify the APK architecture compatibility on older/rare devices — the bundled APK is intended to support all common ABIs but device firmware variations can affect runtime.

Prerequisites
- Flutter (3.22.0 recommended — workflow uses this)
- Java JDK 17
- Android SDK + Android NDK (r26c used in CI)
- (Optional) Go toolchain to build cloudflared locally
- An Android device or emulator (note: emulators might require ABI compatibility or qemu setup)

Build & Run locally
1. Clone the repository
   git clone https://github.com/nam348tnh3gp/Tunnel.git
   cd Tunnel

2. Install Flutter and verify:
   flutter --version

3. Install Android SDK/NDK and connect a device or start an emulator.

4. Get dependencies:
   flutter pub get

5. (Optional) Provide `cloudflared` binary:
   - For production on device, either:
     - Place ABI-specific shared libs at:
       android/app/src/main/jniLibs/arm64-v8a/libcloudflared.so
       android/app/src/main/jniLibs/armeabi-v7a/libcloudflared.so
       android/app/src/main/jniLibs/x86_64/libcloudflared.so
       android/app/src/main/jniLibs/x86/libcloudflared.so
     - Or place a runnable binary in `assets/cloudflared` (the app will extract to app documents at runtime).

6. Run debug on device:
   flutter run

7. Build release APK:
   flutter build apk --release
   The APK will be available at:
   build/app/outputs/flutter-apk/app-release.apk
   (The repository's CI produces APK artifacts too; prefer Releases if available.)

Reproducing CI: building cloudflared (summary of steps from workflow)
- CI clones upstream cloudflared and builds per-ABI using the Android NDK toolchains and Go:
  export GOOS=android
  export GOARCH=<arm64|arm|amd64|386>
  export CGO_ENABLED=1
  export CC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/<clang-target>"
  export CXX="...clang++"
  go build -ldflags='-s -w' -o cloudflared ./cmd/cloudflared
- After each build the binary is copied and renamed to `libcloudflared.so` inside an `output/<abi>/` directory.
- The CI then scaffolds a Flutter project, copies the app sources, injects the jniLibs and the arm64 binary into `assets/cloudflared` as a fallback, and builds the APK.

CI / GitHub Actions
- Workflow: `.github/workflows/build.yml`
- Steps:
  1. Setup Java (Zulu, JDK 17) and Flutter (3.22.0).
  2. Download and unpack Android NDK r26c; set ANDROID_NDK_HOME and PATH.
  3. Clone cloudflared and compile for multiple Android ABIs using CGO and NDK clang.
  4. Create a Flutter project (`flutter create ... tunnel_app`), copy sources, inject native libs into `jniLibs` and `assets`, then run `flutter build apk --release`.
  5. Upload APK artifacts.
- Triggers: push to `main` or `master`, and manual dispatch.

Usage (in-app)
- Choose Mode:
  - Try Cloudflared: no token, enter local port (defaults to 8080). Starts tunnel and exposes a trycloudflare public URL.
  - Token: paste your Cloudflare Tunnel token, the app runs `tunnel run --token <TOKEN>`.
- Optional settings:
  - Local port
  - Custom arguments (space-separated)
  - QUIC toggle
  - Post-Quantum toggle
  - Enable/disable metrics
  - Region (e.g., hkg, sin, lax)
  - Edge IP version (auto / 4 / 6)
  - Custom hostname
- Start: tap Start; logs appear and public URL (if any) is shown and copyable.
- Stop: tap Stop to terminate the subprocess.

Advanced options & flags mapping
- QUIC checkbox: when enabled default QUIC is used; unchecking adds `--protocol http2`.
- Post-Quantum checkbox: adds `--post-quantum`.
- Metrics toggle: when disabled adds `--management-diagnostics=false`.
- Region: `--region <value>`
- Edge IP version: `--edge-ip-version <auto|4|6>`
- Custom hostname: `--hostname <hostname>`
- Custom args: appended raw to the argument list.

Troubleshooting
- Binary not found / permission denied:
  - Ensure `libcloudflared.so` exists in the correct `jniLibs/<abi>/` folder or `assets/cloudflared` is packaged.
  - The app attempts to `chmod 755` the binary. If the device prevents execution, verify ABI and Android security policies.
- Architecture mismatch:
  - Use an ABI-compatible cloudflared binary. arm64 devices need arm64-v8a (`aarch64`) builds.
- No public URL detected:
  - Check logs for errors. The app searches stdout/stderr for `https://*.trycloudflare.com`.
  - If running Token mode, verify token validity and network access.
- Running on emulators:
  - Some emulators are x86; ensure you have x86/x86_64 binaries or use a physical device.

Security & privacy notes
- Tunnel tokens are sensitive — do not share them.
- The app executes a native binary; ensure you trust the cloudflared build.
- The AndroidManifest in the generated app uses `usesCleartextTraffic="true"` to ease local testing; consider changing this for release builds.

Contributing
- Issues, bug reports and PRs are welcome.
- Suggested improvements:
  - Persist user settings (tokens, last-used port).
  - More robust detection of public URLs and richer log parsing.
  - Automated per-ABI release artifacts and signed APKs.
- Please fork, create a branch, and open a PR. Describe device/Android version when reporting runtime bugs.

License
- This repository includes an `LICENSE` file: Apache License 2.0.
- See `LICENSE` for full terms.
