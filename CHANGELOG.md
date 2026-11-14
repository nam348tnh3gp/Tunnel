# Changelog

## 1.1.0-beta

### Fixed
- **Token was ignored after the first run**: the saved token always won over the text field, so changing the token had no effect. The field is now the source of truth and is saved on Start.
- **Token leaked into the log and the process list**: it was printed in `Command:` (and persisted/copied with the log) and passed in argv. It now goes through the `TUNNEL_TOKEN` environment variable and anything token-shaped is redacted from the log.
- Closing/rebuilding the page used to kill the tunnel (`dispose` called stop). The process is now owned by an app-lifetime `TunnelRunner`.
- Stop used to wipe the whole log; it now keeps it. A stuck process is SIGKILLed after 5 s.
- Android 14: `FOREGROUND_SERVICE_DATA_SYNC` permission was missing (foreground service would crash on `targetSdk 34`); `POST_NOTIFICATIONS` is now requested at runtime.
- "About" showed a hard-coded version that did not match `pubspec.yaml`; it now reads the real one.
- `Port` fallback mismatch (8000 in UI vs 8080 in code).
- The `Enable Metrics` checkbox actually toggled `--management-diagnostics`; relabelled accordingly.

### Added
- Settings are persisted (mode, port, protocol, region, …); token stored in secure storage with show/hide/forget.
- Auto-restart with exponential backoff (2 s → 60 s, max 8 attempts, resets after a stable 2 min).
- Re-attach to a still-running cloudflared after the app is restarted (PID verified through `/proc`).
- Input validation (port, region, bind IP, `--token` in custom args), quote-aware custom args.
- Pasting a whole `cloudflared ... --token eyJ...` command extracts the token.
- Protocol dropdown (auto / QUIC / HTTP/2), "Open in browser", battery-optimization shortcut, coloured log lines.
- Bounded, throttled log buffer (1500 lines) — no more full-page rebuild per log chunk.
- Unit tests for config/args, token helpers and URL extraction; `analysis_options.yaml`.

### CI
- cloudflared is built from the **latest release tag** (or `cloudflared_ref` input) instead of `master`; Go toolchain from cloudflared's `go.mod`; built binaries cached per tag.
- `flutter analyze` + `flutter test` before the APK build; runs on pull requests too (no version bump/push there).
- `rsync --ignore-existing` so the generated template never overwrites repo files; Kotlin version also patched in `settings.gradle`.
- Actions bumped to v4/v5, concurrency group, APK SHA-256 checksum.

### Removed
- `lib/main.dart.bak.*` backup file, unused `path_provider` dependency.
