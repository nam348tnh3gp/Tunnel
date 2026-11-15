<div align="center">

<img src="https://gor-mez8.onrender.com/render.gif?text=TUNNEL+CONTROLLER&effect=glitch&font=monobold&w=700&h=120&size=64&c1=ff2e88&bg=transparent&fps=15&dur=3&seed=7" alt="TUNNEL CONTROLLER" />

<img src="https://gor-mez8.onrender.com/render.gif?text=Cloudflare+Tunnel+on+Android&effect=type&font=mono&w=700&h=50&size=26&c1=d6d3d1&bg=transparent&fps=15&dur=2.5&seed=7" alt="Cloudflare Tunnel on Android" />

[![Build APK](https://github.com/nam348tnh3gp/Tunnel/actions/workflows/build.yml/badge.svg)](https://github.com/nam348tnh3gp/Tunnel/actions/workflows/build.yml)
[![Releases](https://img.shields.io/github/v/release/nam348tnh3gp/Tunnel?label=releases&include_prereleases)](https://github.com/nam348tnh3gp/Tunnel/releases)
[![Flutter](https://img.shields.io/badge/flutter-3.22.0-blue?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/dart-%3E%3D3.0.0-blue?logo=dart)](https://dart.dev)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/nam348tnh3gp/Tunnel/blob/main/LICENSE)

</div>

A compact Flutter app that runs Cloudflare Tunnel (`cloudflared`) on Android. It supports a temporary **Quick** mode and a persistent **Token** mode, keeps the tunnel alive in the background with a foreground service, remembers your settings, and restarts the tunnel automatically if it drops. The repository's CI cross-compiles `cloudflared` for every Android ABI and bundles it into the APK.

**Quick links:** [Repository](https://github.com/nam348tnh3gp/Tunnel) · [Releases](https://github.com/nam348tnh3gp/Tunnel/releases) · [Changelog](CHANGELOG.md) · [CI workflow](.github/workflows/build.yml) · License: Apache-2.0

## Table of contents
- [Key features](#key-features)
- [What's new in 1.0.0+2](#whats-new-in-100)
- [Download](#download)
- [Usage](#usage)
- [Flags & mapping](#flags--mapping)
- [How it works](#how-it-works)
- [Project layout](#project-layout)
- [Build & run locally](#build--run-locally)
- [CI & releases](#ci--releases)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [Contributing](#contributing)
- [License](#license)

## Key features
- Start / stop a Cloudflare Tunnel from a simple UI.
- **Two modes**
  - **Quick (try)** — temporary public `https://<id>.trycloudflare.com` URL pointing at a local port.
  - **Token** — `cloudflared tunnel run` with your tunnel token for a persistent tunnel.
- **Foreground service + WakeLock** — keeps running with the screen off or the app minimised.
- **Auto-restart** — exponential backoff (2 s → 60 s, up to 8 attempts, counter resets after a stable 2 minutes).
- **Settings remembered** across launches; the token is stored encrypted (`flutter_secure_storage`) with show / hide / forget.
- **Re-attach after app restart** — if cloudflared is still alive, Stop keeps working (PID verified through `/proc`).
- Public URL auto-detected for both Quick and Token mode, with *Open in browser* and *Copy*.
- Colour-coded live log (bounded to 1500 lines), copy / clear, CPU and temperature readout.
- Input validation and quote-aware additional arguments.
- Multi-ABI: `arm64-v8a`, `armeabi-v7a`, `x86_64`, `x86` binaries are built in CI and shipped as `libcloudflared.so`.

## What's new in 1.0.0+2
- 🔒 The token is passed through the `TUNNEL_TOKEN` environment variable, never on the command line, and token-shaped text is redacted from the log.
- 🐛 Changing the token now takes effect (the old saved token used to win over the text field).
- 🐛 Leaving the screen no longer stops the tunnel; Stop keeps the log and force-kills a stuck process after 5 s.
- 🐛 Android 14 foreground-service permission added; notification permission is requested at runtime.
- ✨ Persisted settings, auto-restart, protocol selector (Auto / QUIC / HTTP/2), battery-optimisation shortcut.
- 🧪 Unit tests, `flutter analyze` in CI, and automated GitHub Releases on tags.

Full details: [CHANGELOG.md](CHANGELOG.md).

<div align="center">
<img src="https://gor-mez8.onrender.com/render.gif?text=DOWNLOAD&effect=type&font=monobold&w=700&h=60&size=36&c1=ff2e88&bg=transparent&fps=15&dur=1.5&seed=7" alt="DOWNLOAD" />
</div>

## Download
Grab the latest APK from the [Releases](https://github.com/nam348tnh3gp/Tunnel/releases) page. Each release contains:

| File | For |
| --- | --- |
| `tunnel-controller-<tag>-arm64-v8a.apk` | Most modern phones (64-bit ARM) |
| `tunnel-controller-<tag>-armeabi-v7a.apk` | Older 32-bit ARM devices |
| `tunnel-controller-<tag>-x86_64.apk` | x86_64 devices / emulators |
| `tunnel-controller-<tag>-universal.apk` | All of the above in one (larger) file |
| `SHA256SUMS.txt` | Checksums for verification |

Check your device ABI with `adb shell getprop ro.product.cpu.abi`.

Install:
```
adb install -r tunnel-controller-<tag>-arm64-v8a.apk
```
or enable "Install unknown apps" and open the APK from a file manager. Verify the download with `sha256sum -c SHA256SUMS.txt`.

**Requirements:** Android 5.0 (API 21) or newer. Android 13+ will ask for notification permission (needed for the foreground-service notification).

<div align="center">
<img src="https://gor-mez8.onrender.com/render.gif?text=USAGE&effect=wave&font=monobold&w=700&h=60&size=36&c1=ff2e88&bg=transparent&fps=15&dur=2&seed=7" alt="USAGE" />
</div>

## Usage
1. **Choose a mode**
   - *Token*: paste your tunnel token. You can also paste the whole `cloudflared ... --token eyJ...` command; the token is extracted for you.
   - *Quick (try)*: enter the local port your service listens on.
2. (Optional) open **Advanced Options** and adjust protocol, region, etc.
3. Tap **Start**. The status card shows the state (`Starting…`, `Running`, `Reconnecting…`), the PID, and the public URL once detected.
4. Tap **Stop** to shut the tunnel down (SIGTERM, then SIGKILL after 5 s).

Settings cannot be edited while the tunnel is running. The menu (⋮) has *About*, the list of supported arguments, a shortcut to disable battery optimisation, and the disclaimer.

**Advanced options**

| Option | Notes |
| --- | --- |
| Protocol | Auto (default), QUIC, or HTTP/2 |
| Auto-restart on failure | Backoff 2 s → 60 s, max 8 attempts |
| Post-Quantum | Enables post-quantum secure tunnel |
| Management diagnostics | On by default; turn off to disable diagnostic routes |
| Overwrite DNS | Overwrite existing DNS records |
| Region / Edge IP version / Edge bind address / Label | Passed straight to cloudflared |
| Additional arguments | Space-separated, quotes supported. `--token` is rejected here — use the token field |

## Flags & mapping
| UI | cloudflared |
| --- | --- |
| Token mode | `tunnel run` + `TUNNEL_TOKEN` env var |
| Quick mode | `tunnel --url http://localhost:<port>` |
| Protocol QUIC / HTTP/2 | `--protocol quic` / `--protocol http2` (Auto adds nothing) |
| Post-Quantum | `--post-quantum` |
| Diagnostics off | `--management-diagnostics=false` |
| Overwrite DNS | `--overwrite-dns` |
| Region | `--region <value>` |
| Edge IP version | `--edge-ip-version <4\|6>` |
| Edge bind address | `--edge-bind-address <ip>` |
| Label | `--label <text>` |
| Additional arguments | appended as-is |

## How it works
- On start, the app asks Android (via a `MethodChannel`) for its native library directory and runs `libcloudflared.so` from there as a subprocess. No binary is extracted at runtime.
- `TunnelRunner` owns the process for the lifetime of the app, so closing or rebuilding the screen never kills the tunnel.
- A foreground service (`flutter_foreground_task`) plus WakeLock keeps the process alive in the background; the notification shows the public URL once known.
- stdout and stderr are read line by line, redacted for secrets, shown in the log, and scanned for the public URL (`*.trycloudflare.com` in Quick mode, the ingress hostname in Token mode).
- If cloudflared exits unexpectedly and auto-restart is on, it is relaunched with exponential backoff.
- Run state (PID, URL) and the last 300 log lines are persisted. After an app restart, if the foreground service is still running and the PID still belongs to cloudflared, the UI re-attaches (live output is unavailable until the next start; Stop still works).

## Project layout
```
lib/
  main.dart                    app entry, foreground-task setup, theme
  tunnel_task_handler.dart     foreground service isolate (WakeLock)
  models/tunnel_config.dart    settings model, argument builder, validation, token helpers
  services/
    tunnel_runner.dart         process lifecycle, restart/backoff, re-attach
    settings_store.dart        SharedPreferences + secure storage
    log_buffer.dart            bounded, throttled log
    url_extractor.dart         public URL detection
    system_monitor.dart        CPU / temperature
  ui/tunnel_page.dart          the screen
  constants/arguments.dart     supported-arguments reference
test/                          unit tests for config/args, token helpers, URL extraction
```

## Build & run locally
Prerequisites: Flutter 3.22.0, JDK 17, Android SDK. The Android project is generated by CI (`flutter create`) and is not committed, so a local run needs the same scaffolding and the `libcloudflared.so` files.

```
git clone https://github.com/nam348tnh3gp/Tunnel.git
cd Tunnel
flutter pub get
flutter analyze
flutter test        # unit tests run without an Android project
```

To run on a device, generate the Android project (`flutter create .`), then place the binaries in:
```
android/app/src/main/jniLibs/arm64-v8a/libcloudflared.so
android/app/src/main/jniLibs/armeabi-v7a/libcloudflared.so
android/app/src/main/jniLibs/x86_64/libcloudflared.so
android/app/src/main/jniLibs/x86/libcloudflared.so
```
and copy the manifest permissions, `MainActivity.kt` (the `getNativeLibraryDir` channel) and Gradle settings from `.github/workflows/build.yml`. The simplest route is to let CI build it.

## CI & releases
See [`.github/workflows/build.yml`](.github/workflows/build.yml). It runs on pushes to `main`/`master`, pull requests, `v*` tags and manual dispatch.

1. Resolve the latest official `cloudflared` release tag (override with the `cloudflared_ref` input) and use cached binaries when available.
2. Otherwise build cloudflared for arm64, armv7, x86_64 and x86 with the Android NDK r26c (Go version taken from cloudflared's `go.mod`).
3. Generate the Flutter project, add the Android manifest / Gradle config, inject `jniLibs`.
4. `flutter analyze` and `flutter test`, then `flutter build apk --release`.
5. Upload the APK and its SHA-256 as an artifact. On `main` the version code is bumped and committed (`[skip ci]`).

**Publishing a release:** make sure `version:` in `pubspec.yaml` matches, then
```
git tag v1.1.0-beta
git push origin v1.1.0-beta
```
CI builds per-ABI and universal APKs, writes `SHA256SUMS.txt`, and creates the GitHub Release from `RELEASE_NOTES.md`. Tags containing `-` are marked pre-release.

Signing uses repository secrets: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_PASSWORD`, `KEY_ALIAS`.

## Troubleshooting

**Binary not found** — the About dialog shows the native directory. `libcloudflared.so` must be present for your ABI; use a matching APK. Logs: `adb logcat | grep -i tunnel`.

**Tunnel stops in the background** — tap ⋮ → *Disable battery optimization*, allow notifications, and keep the foreground notification visible. Some vendor ROMs also need "autostart"/"no restrictions" in their battery settings.

**No public URL shown** — Quick mode prints a `trycloudflare.com` URL; Token mode shows the first hostname from your tunnel's ingress configuration. Check the log for errors, the token, and network connectivity, and make sure your local service is running on the chosen port.

**`WRN ... ping_group_range`** — Android does not let cloudflared use ICMP ping; it only affects the ICMP proxy, HTTP tunnelling works normally.

**`ERR Connection terminated` when stopping** — expected during graceful shutdown.

**Keeps reconnecting** — check the token is valid and not revoked, try *Protocol → HTTP/2* on networks that block UDP/QUIC, or turn *Auto-restart* off to see the first error.

**Emulators** — use an `x86_64` build or a physical device; CPU/temperature readout may be unavailable.

<div align="center">
<img src="https://gor-mez8.onrender.com/render.gif?text=SECURITY&effect=flicker&font=monobold&w=700&h=60&size=36&c1=ff2e88&bg=transparent&fps=15&dur=2&seed=7" alt="SECURITY" />
</div>

## Security notes
- Tunnel tokens are secrets. The token is stored encrypted with `flutter_secure_storage`, passed to cloudflared through an environment variable (not visible in `ps`), and redacted from the log. Use the trash icon next to the field to forget it.
- Logs are saved locally (last 300 lines) and can include hostnames and IPs; clear them before sharing.
- The foreground notification displays the public URL while the tunnel runs.
- The generated manifest sets `usesCleartextTraffic="true"` so you can reach local `http://` services; review it for production.
- The app executes a native binary built by CI from an official cloudflared release tag; verify downloads with `SHA256SUMS.txt`.
- This is an unofficial client. Use at your own risk; Cloudflare Tunnel is a service provided by Cloudflare Inc.

## Contributing
Issues and PRs are welcome. When reporting a runtime bug, include the device model, Android version, ABI and the (redacted) log. Ideas:
- Multiple tunnel profiles / presets
- Export log to file
- Scheduled start / stop
- Per-ABI size optimisation

## License
Apache License 2.0 — see [`LICENSE`](LICENSE).
