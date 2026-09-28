# APKRun

**Turn Android apps into Mac apps.**

APKRun runs Android ARM64 apps on Apple silicon Macs as ordinary Mac apps. Each app gets its own `.app` in `/Applications`, its own Dock icon and windows, and automatic updates. Android runs out of sight in a shared, lightweight virtual machine. APKRun is not an emulator, and the user never sees Android itself.

```bash
apkrun wrap Discord.apk --install
# → /Applications/Discord.app
```

The generated `.app` is a thin launcher that never changes. The APK, the app's data, and its updates live in APKRun's store, so the app updates itself while the wrapper stays signed and untouched.

## Status

The documentation baseline is complete. There is no code yet. Implementation starts with task #001 in milestone M0 ([docs/04-plan/roadmap.md](docs/04-plan/roadmap.md)).

| Milestone | Version | Result |
|---|---|---|
| M0–M2, part of M3 | v0.1 | An Android app in a Mac window (GPU-accelerated, mouse and keyboard) |
| rest of M3, M4 | v0.2 | Several apps in several windows; a resident runtime (`apkrund`) |
| M5, M6 | v0.3 | The package store and automatic updates |
| M7 | v0.4 | APK → Mac app wrappers; first public demo |
| M8–M11 | v0.5 | Real update sources, desktop integration, runtime maintenance, diagnostics |
| M12 | v1.0 | Release |

## Requirements

- An Apple silicon Mac (M1 or later) with macOS 27 or later.
- Development also needs Xcode, and for the custom Android image a Linux build machine ([docs/05-development/environment-setup.md](docs/05-development/environment-setup.md)).

## How it works

```text
Hello.app (thin wrapper: launcher + icon + wrapper.json)
   │ XPC
   ▼
apkrund (LaunchAgent) ── package store, updates, DisplayPool, graphics, input
   │ Virtualization.framework: virtio-gpu, virtio-vsock, virtio-blk, virtio-net
   ▼
Android ARM64 guest (AOSP Cuttlefish based)
   one Android display per Mac window; Guest Agent and Store Agent
```

- **Graphics:** Android GLES → Mesa VirGL → virtio-gpu → virglrenderer → ANGLE → Metal, with no CPU readback.
- **Windows:** each Mac window shows its own Android virtual display.
- **Updates:** each app has one update authority (APKRun, Google Play, external, or manual) and a provider (local, direct URL, F-Droid, GitHub). Updates install only when the app is not in use, and roll back if the new version fails its health check.

The details are in [docs/01-architecture/overview.md](docs/01-architecture/overview.md).

## Documentation

- [docs/README.md](docs/README.md) is the map of the documentation and its conventions.
- [AGENTS.md](AGENTS.md) holds the rules for everyone who implements APKRun, humans and AI coding agents.
- [docs/04-plan/issues/README.md](docs/04-plan/issues/README.md) lists every implementation task, #001–#097.

## Repository layout

The planned layout is in [docs/01-architecture/modules.md](docs/01-architecture/modules.md) §1. The top-level directories are `Apps/`, `Daemon/`, `CLI/`, `Packages/` (Swift modules), `Guest/` (Android-side code and the AOSP product), `Images/`, `ThirdParty/`, `Tests/`, `Experiments/`, `scripts/`, and `docs/`. The maintained specification is in `docs/`.

## License

To be decided before the first public release (OQ-40 in [docs/04-plan/open-questions.md](docs/04-plan/open-questions.md)). The constraints from the components, including GPL/LGPL parts and redistributing Android images, are in [docs/05-development/legal-and-licensing.md](docs/05-development/legal-and-licensing.md).
