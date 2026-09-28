# 0013. Input via guest-side injection

- Status: Accepted
- Date: 2026-09-28
- Related: #024, #025, #071, #072, R-05, [../../02-design/input.md](../../02-design/input.md)

## Context

Each app window needs pointer, touch, keyboard, scroll, and IME input delivered to *its* Android display. Options:

1. **Host virtio-input devices:** the standard device for Linux guests. Research shows it is **impossible** on the macOS 27 custom virtio API. virtio-input requires the guest to write `select`/`subsel` into the device config space and the device to answer by updating config. VZ provides no config-write callback.
2. **VZ built-in USB HID** (`VZUSBScreenCoordinatePointingDeviceConfiguration`, `VZUSBKeyboardConfiguration`): these are tied to the VZ view/primary display. They have no per-display association and need a `VZVirtualMachineView`.
3. **Guest-side injection:** an agent calls `InputManager.injectInputEvent` with `setDisplayId` (API 29+). This is how scrcpy works.
4. Cuttlefish's own approach, vhost-user virtio-input served by `cf_vhost_user_input`, is not available in VZ.

## Decision

All app input is **injected in the guest by the Guest Agent**. The host (InputCore) translates `NSEvent` into `InputEvent`s in display pixel coordinates. The InputRouter checks display ownership and sends them on a dedicated GuestProtocol input stream. The agent injects `MotionEvent`/`KeyEvent` for the target display. Text input goes through an APKRun IME service (`InputMethodService`) using `commitText`/`setComposingText`, which gives full Unicode and composition support. Key injection alone would not.

## Alternatives considered

See the options above. A guest `uinput` virtual device (RiftVM's approach) was considered too. It needs a native component with `/dev/uinput` access and still needs display association via IDC files, so it adds nothing over `injectInputEvent` for our per-display model.

## Consequences

- Input depends on the Guest Agent being up. Before M5 it runs via ADB (`app_process`), so dev builds need ADB.
- Latency: XPC + vsock + agent add a few milliseconds. The budget is NSEvent received → injected into the guest, p95 ≤ 16 ms (NFR-PERF-03).
- Injected events carry `SOURCE_TOUCHSCREEN`/`SOURCE_MOUSE`/`SOURCE_KEYBOARD` as chosen per mapping (mouse as touch by default, hover and right-click as mouse; [../../02-design/input.md](../../02-design/input.md) §4).
- #072 is scheduled before #024. The GuestProtocol basics (#033) are pulled forward accordingly ([../../04-plan/traceability.md](../../04-plan/traceability.md) §3).

## Verification

G4 input part (tap, scroll, type, #024–#026) and G5 (independent input to two displays, #030).
