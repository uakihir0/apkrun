# Glossary

Terms are used with exactly these meanings throughout the docs and code. When a new term is introduced in a design doc, add it here.

## Product and components

| Term | Meaning |
|---|---|
| **APKRun** | The product as a whole. Also the project codename. |
| **APKRun.app** | The main GUI application: home screen, add-app flow, per-app settings, store view. Never owns the VM. |
| **APKRunMenuBar** | Menu bar extra (login item) showing runtime status, running apps, updates. |
| **apkrund** | The per-user runtime daemon (LaunchAgent). Sole owner of the VM, DisplayPool, graphics, package store, and update scheduling. |
| **apkrun (CLI)** | Command-line client of `apkrund`. Also hosts `apkrun dev …` development commands that run the VM in-process before `apkrund` exists. |
| **Wrapper** | A generated thin `.app` bundle (e.g. `Discord.app`) that represents one Android package. |
| **APKRunLauncher** | The single executable used by every wrapper. It connects to `apkrund`, opens an app session, owns the NSWindow, presents frames, and forwards input. |
| **Thin wrapper** | The default wrapper form: launcher + `wrapper.json` + icon + Info.plist. No APK, no runtime inside. |
| **Portable wrapper** | A thin wrapper that also carries a bootstrap APK set in `Contents/Resources/bootstrap/`, used only for the first import. |
| **Standalone wrapper** | A wrapper embedding runtime + image + APK. Explicitly not implemented in v1. |
| **Local wrapper** | A wrapper generated on the user's own Mac, ad-hoc / locally signed. |
| **Distribution wrapper** | A wrapper intended for third parties; Developer ID signed, Hardened Runtime, notarized. |
| **Guest Agent / `apkrun_guestd`** | APKRun's control agent inside Android: launch/stop on a display, package query, **input injection** (the only input path for app displays), IME, clipboard, notifications, display lifecycle, health. |
| **Store Agent / `io.apkrun.store`** | Privileged Android app that performs installs/updates/uninstalls through `PackageInstaller`, and is the installer of record (update owner). |
| **APKRun AOSP product** | Our custom Android build (device/product definition inheriting from Cuttlefish arm64). |
| **Runtime image** | A versioned, ready-to-boot bundle (kernel, initrd, disk images, manifest) consumed by the Mac runtime. |

## Architecture

| Term | Meaning |
|---|---|
| **Layer** | One of the four product layers: App Wrapper, Desktop Runtime, Android Runtime, Store & Update. |
| **Module** | A Swift package target under `Packages/` with a single owner boundary (e.g. `VirtualMachineCore`). |
| **VMState** | The state of the virtual machine as seen by `VirtualMachineCore` (stopped, starting, running, paused, stopping, failed). |
| **RuntimeState** | The state of the Android runtime as seen by `RuntimeCore` (stopped, booting, ready, suspended, failed). Derived from VMState + Android readiness + agent connectivity. |
| **App session** | One running wrapper ↔ one Android package ↔ one display ↔ one window. Created on launch, destroyed on close/terminate. |
| **Display / display ID** | An Android display. In APKRun, each pool display is a virtio-gpu scanout that Android sees as a physical display. |
| **Scanout** | A virtio-gpu output (up to 16). The host presents scanout contents. |
| **DisplayPool** | The actor that allocates, attaches, and releases displays. |
| **Primary display** | Android display 0. Normally unused for apps (hidden). |
| **Secondary display** | Any non-primary display. The normal home of an app session. |
| **Window mode** | `secondaryDisplay` (default) or `primaryDisplayCompatibility` (fallback for apps that misbehave on secondary displays). |
| **Warm launch** | Launch while the VM is running and Android is ready. |
| **Cold launch** | Launch while the VM is stopped (boot required). |
| **Frame source / surface pool** | The set of IOSurfaces a display renders into; shared with the wrapper process via XPC. |
| **Operation ID** | A UUID generated per user-visible operation (launch, install, update …) and carried through logs across processes and into the guest. |

## Update system

| Term | Meaning |
|---|---|
| **Update type A / B / C / D** | A = Android application update, B = APKRun runtime update, C = Android guest image update, D = wrapper metadata update. Never mixed. |
| **Update authority** | Who owns automatic updates of a package: `apkrun`, `googlePlay`, `external`, `manual`. Exactly one per package. |
| **Update mode** | Per-package preference `update.mode`: `automatic` or `notifyOnly`. It applies while the authority is `apkrun`. "Manual" in the UI and the CLI is the authority `manual`, not a mode. |
| **Update provider** | Where update candidates come from: `local`, `direct`, `fdroid`, `github`. Independent from authority. Google Play is an authority (`googlePlay`, post-v1 #097), not a provider: APKRun never downloads from it. |
| **Update candidate** | A newer version announced by a provider, not yet verified. |
| **Package artifact** | A single APK or a split set (base + splits) on disk. |
| **Staged artifact** | A downloaded and verified artifact waiting for a safe moment to install. |
| **Gentle update** | Installing only when the app is not in use (Android `InstallConstraints` + host session tracking). |
| **Update ownership** | Android 14+ mechanism (`setRequestUpdateOwnership`) that prevents other installers from silently updating a package. |
| **Health check** | Post-install verification: version confirmed → launch → process exists → first frame. |
| **Binary rollback** | Reinstalling the previous artifact set. App data migrations are not reverted. |
| **Canonical metadata** | Package metadata as reported by Android PackageManager (as opposed to host-side preview parsing). |

## Graphics

| Term | Meaning |
|---|---|
| **virtio-gpu** | Standard virtio GPU device (virtio device ID 16). |
| **VirGL** | Guest Mesa driver that serializes OpenGL (ES) into virtio-gpu 3D commands. |
| **virglrenderer** | Host library that executes VirGL command streams. |
| **ANGLE** | Implementation of EGL/GLES on top of Metal (used as virglrenderer's GL backend on macOS). |
| **Venus / gfxstream** | Future Vulkan paths (Phase 21). |
| **Readback** | Copying GPU contents to CPU memory. Forbidden on the normal frame path. |
| **Zero-copy scanout** | Presenting guest scanout content without any copy. Stretch goal; v1 allows at most one GPU-side blit per frame. |

## Android

| Term | Meaning |
|---|---|
| **Cuttlefish** | AOSP's virtual device (normally run with crosvm). We reuse its images and configuration but boot them with Virtualization.framework. |
| **Reference boot** | A boot of the same Cuttlefish build under the official `launch_cvd`/crosvm on Linux, used to capture the ground-truth kernel cmdline, bootconfig, devices, and properties. |
| **bootconfig** | Android 12+ mechanism that carries `androidboot.*` parameters in a trailer appended to the initrd. |
| **Dynamic partitions / super** | Logical partitions (system, vendor, product, …) inside `super.img`. |
| **Split APK** | An app delivered as `base.apk` plus configuration splits (ABI, density, language). |
| **Reference boot capture** | The recorded `/proc/cmdline`, `/proc/bootconfig`, `getprop`, device list, and partition map from a reference boot. It is the ground truth that the VZ boot must reproduce (#064). |
| **Direct kernel boot** | Booting the Android kernel with `VZLinuxBootLoader` (kernel + initrd + cmdline) and no bootloader. APKRun does the work that U-Boot does for Cuttlefish: slot selection, bootconfig, AVB properties ([../01-architecture/decisions/0015-direct-kernel-boot.md](../01-architecture/decisions/0015-direct-kernel-boot.md)). |
| **vsock bridge / `apkrun_vsockd`** | Small native guest daemon in its own SELinux domain. It accepts host vsock connections and forwards them to the agents' local sockets. Android SELinux does not let app or shell domains use `AF_VSOCK`. |
| **Installer of record** | The package recorded by PackageManager as having installed an app. |

## Process

| Term | Meaning |
|---|---|
| **Gate (G1–G9)** | A technical checkpoint that must pass before later work is considered validated. |
| **Milestone (M0–M12)** | A group of tasks. |
| **Task (#NNN)** | A unit of work that becomes one GitHub issue and normally one PR. |
| **Spike** | A time-boxed investigation whose deliverable is knowledge (a document), not production code. |
| **DoD** | Definition of Done. |
| **ADR** | Architecture Decision Record. |
