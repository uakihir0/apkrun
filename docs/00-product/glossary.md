# Glossary

These terms have exactly these meanings in the documents and the code. A design document that introduces a new term adds it here.

## Product and components

| Term | Meaning |
|---|---|
| **APKRun** | The product as a whole. Also the project codename. |
| **APKRun.app** | The main GUI application: home, add-app flow, per-app settings, store view. It never owns the VM. |
| **APKRunMenuBar** | Menu bar extra (login item) showing runtime status, running apps, and updates. |
| **apkrund** | The per-user runtime daemon (LaunchAgent). The only owner of the VM, DisplayPool, graphics, package store, and update scheduling. |
| **apkrun (CLI)** | Command-line client of `apkrund`. Also hosts `apkrun dev …`, which runs the VM in-process before `apkrund` exists. |
| **Wrapper** | A generated thin `.app` bundle (for example `Discord.app`) that represents one Android package. |
| **APKRunLauncher** | The single executable every wrapper uses. It connects to `apkrund`, opens an app session, owns the NSWindow, presents frames, and forwards input. |
| **Thin wrapper** | The default wrapper form: launcher, `wrapper.json`, icon, Info.plist. No APK and no runtime inside. |
| **Portable wrapper** | A thin wrapper that also carries a bootstrap APK set in `Contents/Resources/bootstrap/`, used only for the first import. |
| **Standalone wrapper** | A wrapper that embeds runtime, image, and APK. Not implemented in v1. |
| **Local wrapper** | A wrapper generated on the user's Mac, ad-hoc or locally signed. |
| **Distribution wrapper** | A wrapper for third parties: Developer ID signed, Hardened Runtime, notarized. |
| **Guest Agent / `apkrun_guestd`** | Control agent inside Android: display launch and stop, package query, **input injection** (the only input path for app displays), IME, clipboard, notifications, display lifecycle, health. |
| **Store Agent / `io.apkrun.store`** | Privileged Android app that installs, updates, and uninstalls through `PackageInstaller`. It is the installer of record and the update owner. |
| **APKRun AOSP product** | The custom Android build: a device and product definition that inherits from Cuttlefish arm64. |
| **Composed image** | The development custom image: the stock Cuttlefish build with the APKRun product files added on the Mac (ADR-0019). Never published. |
| **Runtime image** | A versioned, ready-to-boot bundle (kernel, initrd, disk images, manifest) that the Mac runtime consumes. |

## Architecture

| Term | Meaning |
|---|---|
| **Layer** | One of the four product layers: App Wrapper, Desktop Runtime, Android Runtime, Store and Update. |
| **Module** | A Swift package target under `Packages/` with a single owner boundary (for example `VirtualMachineCore`). |
| **VMState** | The VM state as seen by `VirtualMachineCore`: stopped, starting, running, paused, stopping, failed. |
| **RuntimeState** | The Android runtime state as seen by `RuntimeCore`: stopped, booting, ready, suspended, failed. Derived from VMState, Android readiness, and agent connectivity. |
| **App session** | One running wrapper, one Android package, one display, and one window. Created on launch, destroyed on close or terminate. |
| **Display / display ID** | An Android display. Each pool display is a virtio-gpu scanout that Android sees as a physical display. |
| **Scanout** | A virtio-gpu output (up to 16). The host presents its contents. |
| **DisplayPool** | The actor that allocates, attaches, and releases displays. |
| **Primary display** | Android display 0. Normally hidden and unused for apps. |
| **Secondary display** | Any non-primary display. The normal home of an app session. |
| **Window mode** | `secondaryDisplay` (default) or `primaryDisplayCompatibility` (fallback for apps that misbehave on secondary displays). |
| **Warm launch** | Launch while the VM runs and Android is ready. |
| **Cold launch** | Launch while the VM is stopped, so a boot is required. |
| **Frame source / surface pool** | The IOSurfaces a display renders into, shared with the wrapper process over XPC. |
| **Operation ID** | A UUID generated for each user-visible operation. It is carried through logs across processes and into the guest. |

## Update system

| Term | Meaning |
|---|---|
| **Update type A / B / C / D** | A: Android application. B: APKRun runtime. C: Android guest image. D: wrapper metadata. Never mixed. |
| **Update authority** | Who owns automatic updates of a package: `apkrun`, `googlePlay`, `external`, or `manual`. Exactly one per package. |
| **Update mode** | Per-package preference `update.mode`: `automatic` or `notifyOnly`. It applies while the authority is `apkrun`. "Manual" in the UI and the CLI is the authority `manual`, not a mode. |
| **Update provider** | Where candidates come from: `local`, `direct`, `fdroid`, or `github`. Independent of the authority. Google Play is an authority (`googlePlay`, post-v1 #98), not a provider. APKRun never downloads from it. |
| **Update candidate** | A newer version announced by a provider and not yet verified. |
| **Package artifact** | A single APK, or a split set (base plus splits), on disk. |
| **Staged artifact** | A downloaded and verified artifact that waits for a safe moment to install. |
| **Gentle update** | An install that runs only while the app is not in use (Android `InstallConstraints` and host session tracking). |
| **Update ownership** | The Android 14+ mechanism (`setRequestUpdateOwnership`) that stops other installers from updating a package silently. |
| **Health check** | Post-install verification: version confirmed, launch, process exists, first frame. |
| **Binary rollback** | Reinstalling the previous artifact set. App data migrations are not reverted. |
| **Canonical metadata** | Package metadata as reported by the Android PackageManager, not host-side preview parsing. |

## Graphics

| Term | Meaning |
|---|---|
| **virtio-gpu** | The standard virtio GPU device (virtio device ID 16). |
| **VirGL** | The guest Mesa driver that serializes OpenGL ES into virtio-gpu 3D commands. |
| **virglrenderer** | The host library that executes VirGL command streams. |
| **ANGLE** | An implementation of EGL and GLES on Metal. It is virglrenderer's GL backend on macOS. |
| **Venus / gfxstream** | Future Vulkan paths (post-v1 #97). |
| **Readback** | Copying GPU contents to CPU memory. Forbidden on the normal frame path. |
| **Zero-copy scanout** | Presenting guest scanout content without any copy. A stretch goal. v1 allows at most one GPU-side blit per frame. |

## Android

| Term | Meaning |
|---|---|
| **Cuttlefish** | AOSP's virtual device, normally run with crosvm. APKRun reuses its images and configuration and boots them with Virtualization.framework. |
| **Reference boot** | A boot of the same Cuttlefish build under the official `launch_cvd` or crosvm on Linux. It is the ground truth for the VZ boot. |
| **Reference boot capture** | The `/proc/cmdline`, `/proc/bootconfig`, `getprop` output, device list, and partition map of a reference boot. The VZ boot must reproduce it (#65). |
| **bootconfig** | The Android 12+ mechanism that carries `androidboot.*` parameters in a trailer appended to the initrd. |
| **Dynamic partitions / super** | Logical partitions (system, vendor, product, and others) inside `super.img`. |
| **Split APK** | An app delivered as `base.apk` plus configuration splits (ABI, density, language). |
| **Direct kernel boot** | Booting the Android kernel with `VZLinuxBootLoader` and no bootloader. APKRun prepares the slot, bootconfig, and AVB properties that U-Boot would provide ([0015-direct-kernel-boot.md](../01-architecture/decisions/0015-direct-kernel-boot.md)). |
| **vsock bridge / `apkrun_vsockd`** | A small native guest daemon in its own SELinux domain. It forwards host vsock connections to the agents' local sockets. Android SELinux does not let app or shell domains use `AF_VSOCK`. |
| **Installer of record** | The installer that PackageManager records as having installed an app. |

## Process

| Term | Meaning |
|---|---|
| **Gate (G1–G9)** | A technical checkpoint that must pass before later work counts as validated. |
| **Milestone (M0–M12)** | A group of tasks. |
| **Task (#NNN)** | A unit of work that becomes one GitHub issue and normally one pull request. |
| **Spike** | A time-boxed investigation whose deliverable is knowledge (a document), not production code. |
| **DoD** | Definition of Done. |
| **ADR** | Architecture Decision Record. |
