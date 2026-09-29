# 0005. One Android display per macOS window

- Status: Accepted
- Date: 2026-09-28
- Related: #028–#030, #067, R-04, [../../02-design/display-and-windowing.md](../../02-design/display-and-windowing.md)

## Context

To make each Android app feel like a separate Mac app (own window, Dock icon, Cmd+Tab entry), each app must render to its own surface that the host can present in its own window. Android supports multiple displays. Activities can be launched on a specific display (`ActivityOptions.setLaunchDisplayId`, `am start --display`). Cuttlefish supports multiple virtio-gpu scanouts, displays added and removed at runtime (crosvm `gpu add-displays`), and a DRM display finder in the ranchu HWC.

## Decision

Each app session gets its own **Android display backed by a virtio-gpu scanout** (up to 16). The app is launched on that display, and its scanout is presented in the wrapper's window. Display 0 stays hidden. A pool (`DisplayPool`) enables and disables scanouts on demand. Two window modes exist:

- `secondaryDisplay` (default): an app on its own pool display.
- `primaryDisplayCompatibility`: the app runs on display 0. Only one such session can exist at a time. This is the fallback for apps that misbehave on secondary displays.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| One big display, crop per app (freeform windows) | The host cannot know window bounds reliably, apps overlap, input routing is hard, and Android's desktop mode is not available for arm64 Cuttlefish |
| Android virtual displays (`DisplayManager.createVirtualDisplay`) rendering into a guest Surface | Getting frames to the host would need encoding or readback (scrcpy-style), which breaks the zero-readback requirement |
| One VM per app | Memory and boot cost are prohibitive |

## Consequences

- There are at most 15 concurrent app windows plus display 0 (the virtio-gpu limit). The DisplayPool reports exhaustion clearly.
- Some apps assume display 0 (e.g. use `getDefaultDisplay()` for metrics). Window mode fallback plus the compatibility DB (#090) handle these.
- Android's system decorations and IME on secondary displays need configuration (`force_desktop_mode_on_external_displays` / `should_show_system_decorations`, IME policy). This is settled in #029 and in the custom product (#035).
- Resize means a scanout mode change: a new EDID and display info → Android reconfiguration (#067).

## Verification

G5 (two APKs run in two Mac windows with independent input, #030) and the #029 findings report.
