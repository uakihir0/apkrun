# 0008. Two Kotlin guest agents plus a native vsock bridge

- Status: Accepted
- Date: 2026-09-28
- Related: #033–#036, #072, [../../02-design/guest-components.md](../../02-design/guest-components.md)

## Context

The host needs to launch apps on displays, inject input, manage IME, clipboard, and notifications, and install packages with installer-of-record semantics. These are Android framework APIs (ActivityManager/ActivityOptions, InputManager, InputMethodService, ClipboardManager, NotificationListenerService, PackageInstaller). Android SELinux forbids app and shell domains from using vsock.

Research: scrcpy (Apache-2.0) shows that an `app_process` program started via ADB can inject input on any display (`InputManager.injectInputEvent` + `setDisplayId`, API 29+), read and write the clipboard, and launch on displays using shell's permissions (`INJECT_EVENTS`, `INTERNAL_SYSTEM_WINDOW`, `ACTIVITY_EMBEDDING`, …).

## Decision

- **Guest Agent** (`io.apkrun.guest`, process `apkrun_guestd`, Kotlin): control, launch, input injection, IME service, clipboard, notifications, display events, health.
  - Development: runs scrcpy-style as `app_process` via ADB and is reached through an ADB forward.
  - Custom image: a platform-signed persistent priv-app.
- **Store Agent** (`io.apkrun.store`, Kotlin): a privileged installer app. It is the installer of record and update owner, with PackageInstaller sessions and archive analysis. It is kept separate so its permissions and lifecycle are independent from the always-on control agent.
- **`apkrun_vsockd`** (Rust, small): the only guest component with vsock privileges. It splices host connections to the agents' abstract sockets.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| ADB shell commands only | Slow (process spawn per command), no event streams, no installer-of-record control |
| A single agent for everything | The installer role (update ownership) and the control role have different permissions and failure modes. Splitting reduces blast radius |
| Native C++ agents | Most needed APIs are Java framework APIs. Kotlin is simpler |
| Give the agents vsock directly (custom domain with `unconstrained_vsock_violators`) | Possible, but it puts vsock privilege in large app processes. The bridge keeps the privileged surface tiny |

## Consequences

- There are three guest components to build, sign, and version (a protocol version handshake is mandatory).
- On stock images (M1–M4) there is no Store Agent. Installs use `adb install` / `pm install` as a fallback path (`StoreAgentChannel` has an ADB implementation for development).

## Verification

#034 and #036 acceptance, then G7 (APK v1 → v2 automatic update through the Store Agent with update ownership, #037–#040).
