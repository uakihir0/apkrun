# Input Design (InputCore + InputRouter + Guest Agent injection)

| Field | Value |
|---|---|
| Status | Design baseline |
| Related | [../01-architecture/decisions/0013-input-via-guest-injection.md](../01-architecture/decisions/0013-input-via-guest-injection.md), [display-and-windowing.md](display-and-windowing.md), [guest-components.md](guest-components.md), [guest-protocol.md](guest-protocol.md), [desktop-integration.md](desktop-integration.md) (clipboard), [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3, §3 |
| Tasks | #024, #025, #071, #030 (routing), #070 (latency), #091 (fuzzing of the injector input) |

---

## 1. Pipeline

```text
wrapper process                                   apkrund                                 guest (apkrun_guestd)
NSEvent ─▶ IOSurfaceLayerView (WindowingCore)
            ├─ pointer / scroll / keys ─▶ InputCore.EventTranslator ─▶ [InputEvent] (display px)
            └─ NSTextInputClient ───────▶ InputCore.TextInputModel  ─▶ ImeTextEvent
                                      InputSink ─XPC sendInput/sendText─▶ InputRouter (actor)
                                                                           ownership, rate limit,
                                                                           coalescing, displayID
                                                                           ─vsock 6101 input stream─▶ InputInjector
                                                                                                      InputManager.injectInputEvent
                                                                                                      (setDisplayId = N)
                                                                                                    ▶ ApkRunIme (InputMethodService)
                                                                                                      InputConnection.commitText …
◀──────────────────── imeStateChanged(EditorState) ◀──────────── editor focus, cursor rect ◀────────── ApkRunIme
```

Rules:

- **No shell command per event** on any product path (FR-IN-06). `adb shell input` is used only once, to validate coordinates in #024 step 1.
- Input is delivered only to the display leased by the sending session (FR-IN-05, §7).
- Every gesture opened in the guest is closed: every touch `DOWN` gets `UP` or `CANCEL`, and every key down gets a key up (§7.3).
- Key codes and text are never logged at `info` or above, only counts (NFR-SEC, [../01-architecture/security-model.md](../01-architecture/security-model.md)).

---

## 2. Event model (InputCore)

```swift
public struct InputTimestamp: Sendable { public var hostNanos: UInt64 }     // mach continuous time of the NSEvent

public enum InputEvent: Sendable, Equatable {
    case touch(TouchEvent)
    case mouse(MouseEvent)
    case scroll(ScrollEvent)
    case key(KeyEvent)
    case longPress(DisplayPoint, InputTimestamp)     // right-click emulation option (§4.3); the agent owns timing
    case cancelAll(InputTimestamp)                   // cancel open gestures and release pressed keys
}

public struct TouchEvent: Sendable, Equatable {
    public enum Phase: Sendable { case down, move, up, cancel }
    public var phase: Phase
    public var pointerID: Int                        // 0 in v1 (single pointer)
    public var position: DisplayPoint                // display pixels, floating point
    public var time: InputTimestamp
}

public struct MouseEvent: Sendable, Equatable {
    public enum Action: Sendable { case hoverEnter, hoverMove, hoverExit, press(MouseButton), release(MouseButton) }
    public var action: Action
    public var position: DisplayPoint
    public var buttons: MouseButtons                 // current button state
    public var time: InputTimestamp
}

public struct ScrollEvent: Sendable, Equatable {
    public var position: DisplayPoint
    public var vertical: Double                      // Android AXIS_VSCROLL units (§4.4)
    public var horizontal: Double                    // Android AXIS_HSCROLL units
    public var time: InputTimestamp
}

public struct KeyEvent: Sendable, Equatable {
    public enum Action: Sendable { case down, up }
    public var action: Action
    public var androidKeyCode: Int32                 // KEYCODE_*
    public var metaState: AndroidMetaState           // META_SHIFT_ON, META_CTRL_ON, META_ALT_ON, META_CAPS_LOCK_ON …
    public var repeatCount: Int32
    public var time: InputTimestamp
}

public enum ImeTextEvent: Sendable, Equatable {
    case commit(String)
    case setComposing(String, selection: Range<Int>)
    case finishComposing
    case key(KeyEvent)                               // editor-mode keys, sent through InputConnection.sendKeyEvent (§5.4)
    case editorAction(Int32)                         // EditorInfo.IME_ACTION_*
    case contextMenuAction(ContextMenuAction)        // .copy, .cut, .paste, .selectAll
}
```

`DisplayPoint` is in the pixel space of the session's display (`ResolvedDisplayMode.pixelSize`, [display-and-windowing.md](display-and-windowing.md) §6). InputCore does not know display IDs. `InputRouter` adds the Android display ID (§7). The wire encoding (`InputBatch`, `ImeCommand`) is defined in [guest-protocol.md](guest-protocol.md).

---

## 3. Coordinate mapping

`CoordinateMapper` (InputCore, pure, T0-tested) is created by `IOSurfaceLayerView` from the current content rect and the pool's pixel size:

```text
contentRect  = view bounds in steady state; the aspect-fit rect of the current frame during live resize
               (display-and-windowing.md §7.1)
x_px = (p.x − contentRect.minX) × pixelWidth  / contentRect.width
y_px = (contentRect.maxY − p.y) × pixelHeight / contentRect.height      // AppKit y-up → Android y-down
```

- Events outside `contentRect` (the letterbox bars during live resize) are dropped when they would start a gesture. During a gesture they are **clamped** to the display edge, so a drag that leaves the window still ends with `UP` at the edge.
- The mapper is replaced atomically on `surfacesReplaced` (new pixel size). A gesture in progress keeps the mapper it started with, and the host sends `CANCEL` for it if the generation changes during the gesture.
- Coordinates are sent as floating point. The agent passes them to `MotionEvent` unchanged (sub-pixel precision matters for scroll and drag velocity).

---

## 4. Source mapping (pointer, scroll)

This section is the "mouse as touch by default, hover and right-click as mouse" rule of ADR-0013 in detail. Per-package overrides live in the package settings under `input.*` ([../03-reference/package-metadata-json.md](../03-reference/package-metadata-json.md)).

### 4.1 Mapping table

| macOS event | Android event (default) | Source / tool | Notes |
|---|---|---|---|
| left `mouseDown` | `ACTION_DOWN` | `SOURCE_TOUCHSCREEN`, `TOOL_TYPE_FINGER`, pointer 0, pressure 1.0 | FR-IN-01 |
| left `mouseDragged` | `ACTION_MOVE` | same | coalesced to one per display refresh when the stream is backed up (§8) |
| left `mouseUp` | `ACTION_UP` | same | |
| `mouseMoved` (no button) | `ACTION_HOVER_MOVE` | `SOURCE_MOUSE`, `TOOL_TYPE_MOUSE` | needs `acceptsMouseMovedEvents`; limited to 120 Hz; off with `input.hover = false` |
| `mouseEntered` / `mouseExited` (tracking area on the content rect) | `ACTION_HOVER_ENTER` / `ACTION_HOVER_EXIT` | `SOURCE_MOUSE` | |
| `rightMouseDown` / `rightMouseUp` | `ACTION_DOWN` + `ACTION_BUTTON_PRESS(BUTTON_SECONDARY)` … `ACTION_BUTTON_RELEASE` + `ACTION_UP` | `SOURCE_MOUSE`, `TOOL_TYPE_MOUSE` | context click; with `input.secondaryClick = longPress`, a touch long-press instead (§4.3) |
| Control + left click | as right click | | Mac convention |
| `otherMouseDown` (middle) | ignored in v1 | | |
| `scrollWheel` | `ACTION_SCROLL` with `AXIS_VSCROLL` / `AXIS_HSCROLL` at the pointer | `SOURCE_MOUSE` | FR-IN-02, §4.4; with `input.scrollMode = touchDrag`, a synthetic finger drag (§4.4) |
| `magnify`, `rotate`, `swipe` (trackpad gestures) | not forwarded in v1 | | FR-IN-09, post-v1 (two synthetic pointers) |
| tablet / pressure events | treated as left mouse | | post-v1 (stylus) |

A mouse click in a window that is not key only activates the window (`acceptsFirstMouse` = false, the Mac default). The next click is delivered.

### 4.2 Touch semantics

- A single pointer (ID 0) in v1. `downTime` is set at `DOWN` and reused for the gesture (the agent tracks it).
- A left-button hold without movement becomes an Android long press naturally, because the `UP` arrives late.
- Double click is two taps. No special handling.
- Losing key focus, closing the window, `surfacesReplaced`, or the session leaving `running` during a gesture sends `CANCEL` (the translator emits `.cancelAll`).
- Whether injected `SOURCE_MOUSE` events make Android draw its own mouse pointer on the display (on top of the Mac cursor) is checked in #024. If it does, the agent hides it for pool displays (pointer icon `TYPE_NULL`, through the hidden `InputManager` pointer-icon API), and if that is not possible, hover is off by default (`input.hover = false`). The result is recorded in [../04-plan/open-questions.md](../04-plan/open-questions.md).

### 4.3 Secondary click

- `mouseSecondary` (default, ADR-0013): real mouse secondary-button events. Views get `onContextClick` / context menus, and web content gets `contextmenu`.
- `longPress`: the agent injects `DOWN`, waits `ViewConfiguration.getLongPressTimeout() + 50 ms`, then `UP`, at the click position. This helps phone apps that only react to long press. It is a per-package option in Settings → App → Input.

### 4.4 Scrolling

Android views scroll by `axis value × ViewConfiguration.getScaled{Vertical,Horizontal}ScrollFactor()`. The factor is 64 dp by default (`config_verticalScrollFactor`). The agent reports it in dp for each display in `DisplayAdded` / `DisplayChanged` ([guest-protocol.md](guest-protocol.md)), and the translator converts:

```text
precise deltas (trackpad, Magic Mouse; hasPreciseScrollingDeltas):
    dp = scrollingDelta (points) / zoom                  // 1 dp = 1 pt at zoom 1 (display-and-windowing.md §6.1)
    AXIS_VSCROLL = + dpY / scrollFactorDp
    AXIS_HSCROLL = − dpX / scrollFactorDp
line deltas (wheel mice):
    AXIS_VSCROLL = + scrollingDeltaY   (lines ≈ notches)
    AXIS_HSCROLL = − scrollingDeltaX
```

- `scrollingDelta` already includes the user's "natural scrolling" preference, so no extra inversion is applied. The signs above are verified by T2 tests in #024 (HelloCompose list: two-finger swipe up must move content up, as in Safari).
- Momentum-phase events (`momentumPhase`) are forwarded as ordinary scroll events. Android does not add its own fling to mouse scroll.
- Events are accumulated per display refresh (at most one `ACTION_SCROLL` per 8 ms), summing the axes.

`touchDrag` mode (per-package option for apps whose custom views ignore `ACTION_SCROLL`): at the start of a precise scroll sequence (`phase == .began`), inject a finger `DOWN` at the pointer, then `MOVE` by the accumulated deltas (in pixels), and `UP` when momentum ends. Android's `VelocityTracker` turns the last moves into a fling. Wheel mice in this mode send short drag gestures per notch (80 dp each).

---

## 5. Keyboard and text

### 5.1 Two paths

| Situation | Path | Why |
|---|---|---|
| An Android **editor is focused** (the APKRun IME reported `editorFocused`) | **Editor mode.** `NSTextInputContext.handleEvent` interprets every key. The results (`insertText`, marked text, `doCommand(by:)`) become `ImeTextEvent`s on the IME channel | Full Unicode, dead keys, and composition (Japanese, Chinese, Korean) handled by the macOS input method (FR-IN-07); ordered with editing keys |
| No editor focused (games, lists, custom views) | **Key mode.** Raw `KeyEvent`s by physical key (§5.2), injected into the display | Apps that read key codes directly |

The wrapper learns the mode from `imeStateChanged(EditorState)` events. apkrund relays them from the IME on the session channel ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3). `EditorState` carries `focused`, `inputType`, `imeOptions`, the selection, the composing range, and the cursor rectangle in display pixels.

Until #071 (M4) there is no IME. Everything uses key mode, and characters come from Android's virtual key character map (US layout). That is the documented limitation of #025 (§10).

### 5.2 Physical key mapping

`KeyCodeMap` (InputCore) is a static table generated from `Packages/InputCore/Resources/keymap-mac-android.csv` (`kVK_*` code, Android `KEYCODE_*`, notes). It covers:

| macOS keys | Android |
|---|---|
| `kVK_ANSI_A`…`Z`, `kVK_ANSI_0`…`9` | `KEYCODE_A`…`Z`, `KEYCODE_0`…`9` |
| punctuation (`Minus`, `Equal`, `LeftBracket`, `RightBracket`, `Backslash`, `Semicolon`, `Quote`, `Comma`, `Period`, `Slash`, `Grave`) | `KEYCODE_MINUS`, `EQUALS`, `LEFT_BRACKET`, `RIGHT_BRACKET`, `BACKSLASH`, `SEMICOLON`, `APOSTROPHE`, `COMMA`, `PERIOD`, `SLASH`, `GRAVE` |
| `Return`, `Tab`, `Space`, `Delete` (backspace), `ForwardDelete` | `ENTER`, `TAB`, `SPACE`, `DEL`, `FORWARD_DEL` |
| arrows, `Home`, `End`, `PageUp`, `PageDown` | `DPAD_LEFT/RIGHT/UP/DOWN`, `MOVE_HOME`, `MOVE_END`, `PAGE_UP`, `PAGE_DOWN` |
| `F1`…`F12` | `F1`…`F12` (only when macOS delivers them to the app) |
| keypad keys | `NUMPAD_*` |
| `Shift`, `Control`, `Option` (left/right) | `SHIFT_LEFT/RIGHT`, `CTRL_LEFT/RIGHT`, `ALT_LEFT/RIGHT` as key events in key mode |
| `CapsLock` | `CAPS_LOCK` plus `META_CAPS_LOCK_ON` |
| JIS `Yen`, `Underscore` | `YEN`, `RO` |
| JIS `Eisu`, `Kana` | not forwarded (they switch the macOS input source) |
| `Escape` | `BACK` (FR-IN-04). `ESCAPE` with `input.escapeKey = escape` |
| `Command` | not forwarded; reserved for host shortcuts (§6). Optional `input.sendCommandKey` maps it to `META_LEFT` for apps that need it |

Meta state: Shift → `META_SHIFT_ON` (+ `LEFT`/`RIGHT`), Control → `META_CTRL_ON`, Option → `META_ALT_ON`, Caps Lock → `META_CAPS_LOCK_ON`. Key repeat (`isARepeat`) increments `repeatCount` on repeated `down` events.

Key codes are positional (US ANSI positions). With a non-US Mac layout, apps in key mode that read `KeyEvent.getUnicodeChar()` see US characters. Editor mode is not affected, because text comes from the macOS input method (§10).

### 5.3 Editor mode: `NSTextInputClient`

`IOSurfaceLayerView` implements `NSTextInputClient`. It keeps a small model of the Android editor (`TextInputModel`: marked text, selection, last cursor rect).

| AppKit call | Sent to the IME |
|---|---|
| `insertText(_:replacementRange:)` | `.commit(text)`. It replaces an active composition, as Android's `commitText` does |
| `setMarkedText(_:selectedRange:replacementRange:)` | `.setComposing(text, selection)` → `InputConnection.setComposingText(text, 1)`, then `setSelection` inside the composition |
| `unmarkText()` | `.finishComposing` |
| `firstRect(forCharacterRange:actualRange:)` | answered locally from the last `EditorState.cursorRect` (display px → window → screen), so the macOS candidate window appears next to the Android cursor. If none is known, the bottom-left of the content rect |
| `hasMarkedText`, `markedRange`, `selectedRange` | answered from `TextInputModel` |
| `attributedSubstring(forProposedRange:)` | `nil` (surrounding text is not mirrored; reconversion unsupported, §10) |
| `doCommand(by:)` | mapped by §5.4 |

The IME reports cursor rectangles through `InputConnection.requestCursorUpdates(CURSOR_UPDATE_MONITOR | CURSOR_UPDATE_IMMEDIATE)` → `onUpdateCursorAnchorInfo` (insertion marker bounds, transformed to display coordinates by the matrix in `CursorAnchorInfo`).

### 5.4 Editor commands

`doCommand(by:)` selectors from `NSStandardKeyBindingResponding` map to key events sent through `InputConnection.sendKeyEvent` (`.key(...)`). Sending them on the IME channel keeps them ordered with committed text.

| Selector | Android |
|---|---|
| `deleteBackward:` / `deleteForward:` | `DEL` / `FORWARD_DEL` (a key event, not `deleteSurroundingText`, so apps that watch `DEL` in empty fields, such as OTP boxes, still work) |
| `deleteWordBackward:` / `deleteWordForward:` | `Ctrl+DEL` / `Ctrl+FORWARD_DEL` |
| `insertNewline:` | if the editor has an action (`imeOptions & IME_MASK_ACTION` not `NONE`/`UNSPECIFIED`, not multi-line, no `IME_FLAG_NO_ENTER_ACTION`) → `.editorAction(action)`; otherwise `ENTER` |
| `insertLineBreak:` (Control+Return), `insertNewlineIgnoringFieldEditor:` (Option+Return) | `ENTER` with `META_SHIFT_ON` (a newline in chat apps that send on Enter) |
| `insertTab:` / `insertBacktab:` | `TAB` / `Shift+TAB` |
| `moveLeft:`, `moveRight:`, `moveUp:`, `moveDown:` (+ `AndModifySelection`) | `DPAD_*` (+ Shift) |
| `moveWordLeft:`, `moveWordRight:` (+ selection) | `Ctrl+DPAD_LEFT/RIGHT` (+ Shift) |
| `moveToBeginningOfLine:`, `moveToEndOfLine:`, `moveToLeftEndOfLine:`, `moveToRightEndOfLine:` (+ selection) | `MOVE_HOME` / `MOVE_END` (+ Shift) |
| `moveToBeginningOfDocument:`, `moveToEndOfDocument:` (+ selection) | `Ctrl+MOVE_HOME` / `Ctrl+MOVE_END` (+ Shift) |
| `pageUp:`, `pageDown:`, `scrollPageUp:`, `scrollPageDown:` | `PAGE_UP` / `PAGE_DOWN` |
| `cancelOperation:` (Esc, ⌘.) | `BACK` when there is no marked text (with marked text the macOS IME consumes Esc itself) |
| others | ignored and counted (`input.ime.unmappedCommand`, debug log of the selector name) |

### 5.5 Password and secure fields

When `EditorState.inputType` is a password variation (`TYPE_TEXT_VARIATION_PASSWORD`, `VISIBLE_PASSWORD`, `WEB_PASSWORD`, `TYPE_NUMBER_VARIATION_PASSWORD`) and the window is key, the view calls `EnableSecureEventInput()` and sets `inputContext.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]`, as `NSSecureTextField` does. It calls `DisableSecureEventInput()` when focus leaves the field, the window resigns key, or the session ends. The calls are balanced by a counter, and a unit test checks the balance.

### 5.6 The APKRun IME (guest side, #071)

- `io.apkrun.guest/.ime.ApkRunInputMethodService`, an `InputMethodService` with no visible keyboard: `onEvaluateInputViewShown()` returns false, and `onCreateInputView()` returns an empty view. The Mac keyboard and the macOS input method are the only text input.
- The Guest Agent enables it and selects it as the default IME at start (`Settings.Secure.ENABLED_INPUT_METHODS` / `DEFAULT_INPUT_METHOD`, which needs `WRITE_SECURE_SETTINGS`: available to the shell uid in development and granted to the priv-app in the custom image).
- `onStartInput` / `onFinishInput` / `onUpdateSelection` / `onUpdateCursorAnchorInfo` → `EditorState` events to the host.
- Commands from the host run on the IME's main thread against `getCurrentInputConnection()`. A command that arrives while no editor is bound is dropped and counted.
- Display: the per-display IME policy is `LOCAL` ([display-and-windowing.md](display-and-windowing.md) §4), so the IME binds to editors on pool displays.
- Channel: in the custom image the IME service runs in the Guest Agent process, and IME commands share the input stream (vsock 6101) with pointer events, so ordering is preserved. In development (stock image) the Guest Agent's `app_process` part runs under the shell uid, but the IME must run in the app's own process. The IME therefore listens on its own abstract socket `@apkrun-guest-ime`, reached through an ADB forward (the pattern Chrome's DevTools socket uses). The row is listed in [../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1. Pointer/IME ordering across the two channels is not guaranteed in development.

---

## 6. Shortcuts (FR-IN-04, FR-IN-08)

Host shortcuts are handled by the wrapper's menus (`performKeyEquivalent`) and never reach Android. The menus themselves are in [wrapper.md](wrapper.md) §5.6. This table is the complete list: the launcher adds no other key equivalent.

| Shortcut | Action |
|---|---|
| ⌘Q, ⌘W, ⌘H, ⌥⌘H, ⌘M, ⌘`, ⌃⌘F, ⌘, | Mac app and window commands (⌘W and ⌘Q end the session; [display-and-windowing.md](display-and-windowing.md) §7.6) |
| ⌘=, ⌘−, ⌘0 | Zoom ([display-and-windowing.md](display-and-windowing.md) §6.1) |
| Esc, ⌘[ | Android `BACK` (FR-IN-04). Esc follows `input.escapeKey` |
| ⌘C / ⌘X / ⌘A | editor mode: `.contextMenuAction(.copy/.cut/.selectAll)` → `InputConnection.performContextMenuAction(android.R.id.copy …)`. Key mode: `Ctrl+C` / `Ctrl+X` / `Ctrl+A` key events |
| ⌘V | editor mode, clipboard integration on for the package: push the Mac clipboard to Android first ([desktop-integration.md](desktop-integration.md), push-with-ack), then `performContextMenuAction(paste)`. Integration off (or before #053): `.commit(pasteboard plain text)`, because the user explicitly pasted. Key mode: `Ctrl+V` |
| ⌘Z / ⇧⌘Z | `Ctrl+Z` / `Ctrl+Shift+Z` key events (through `sendKeyEvent` in editor mode) |
| ⌃ + key | passed to Android with `META_CTRL_ON` (Android app shortcuts) |
| ⌥ + key | editor mode: interpreted by the macOS input method (for example ⌥E accents); key mode: `META_ALT_ON` |

---

## 7. Routing and focus (FR-IN-05, #030)

### 7.1 InputRouter (apkrund)

```swift
public actor InputRouter {
    public func route(_ batch: [InputEvent], from session: SessionID) async
    public func routeText(_ event: ImeTextEvent, from session: SessionID) async
    public func focusChanged(_ session: SessionID, focused: Bool) async
    public func sessionEnded(_ session: SessionID) async           // closes open gestures and keys
}
```

- The session is known from the XPC connection. A wrapper connection can only name its own session ([../01-architecture/process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2). The router looks up the lease in `DisplayPool` and stamps the Android display ID. Wrappers never send display IDs.
- Events are accepted only while the session is `running` or `backgrounded`. Otherwise they are dropped and counted.
- Rate limits per session: 2000 events/s and 64 KiB of text/s. Excess is dropped with a counter and a rate-limited warning.
- Coalescing when the guest stream's send buffer is above 64 KiB: consecutive `MOVE`, hover, and scroll events for the same display merge (scroll axes add up). `DOWN`, `UP`, `CANCEL`, button, and key events are never dropped or merged.

### 7.2 Focus

- AOSP runs with per-display focus disabled (`config_perDisplayFocusEnabled = false`). Injected key events with a display ID go to the focused window of that display (`InputDispatcher` uses the event's display ID when it is set). The IME, however, follows the globally focused window.
- Therefore, on `focusChanged(true)` the router sends `FocusDisplay(displayID)` to the Guest Agent. The agent moves the session's top task to the front (`IActivityTaskManager.setFocusedTask(taskId)`; shell and the priv-app hold `MANAGE_ACTIVITY_TASKS`). A touch `DOWN` on a display also moves focus to it in Android. The explicit call makes keyboard-only focus changes (⌘` between wrappers) work.
- On `focusChanged(false)` the router sends `.cancelAll` for that session.
- R-05 (input and IME on secondary displays) is verified in #030 and #071: typing goes only to the key window's app, and the IME binds to the editor on the correct display.

### 7.3 Gesture and key integrity

The agent tracks per display: the open touch gesture (`downTime`, last position), pressed mouse buttons, and pressed keys. It synthesizes `CANCEL`, button releases, and key ups when:

- it receives `.cancelAll`;
- the input stream disconnects (host crash or reconnect);
- the target display is removed.

This avoids stuck keys and half-open gestures in Android.

---

## 8. Transport and latency (NFR-PERF-03)

- **Wrapper → apkrund:** `sendInput([InputEvent])` is batched per run-loop turn. The first event after idle is sent immediately. `sendText` is sent unbatched, in order.
- **apkrund → guest:** a dedicated input stream (vsock 6101, or its ADB forward in development) carrying `InputBatch{ display_id, events[], host_send_nanos }` and `ImeCommand`, with `TCP_NODELAY`-like behavior (each frame is written immediately; no Nagle on vsock).
- **Guest injection:** `InputManager.getInstance().injectInputEvent(event, INJECT_INPUT_EVENT_MODE_ASYNC)` after `setDisplayId` (a hidden API reached by reflection, as scrcpy does). `eventTime` = `SystemClock.uptimeMillis()` at injection. Relative spacing inside a batch is preserved by offsetting from the batch's first host timestamp.
- **Budget** (NSEvent received → injected, p95 ≤ 16 ms):

| Segment | Budget (p95) | Measured by |
|---|---|---|
| NSEvent → XPC send (wrapper) | 2 ms | signpost `input.translate` |
| XPC → router → vsock write (apkrund) | 2 ms | signpost `input.route` |
| vsock → agent read | 2 ms | `InputAck` round trip (below) |
| agent read → `injectInputEvent` returned | 4 ms | agent timing |
| Margin | 6 ms | |

- **Measurement:** every 32nd batch carries `ack_requested`. The agent answers `InputAck{ batch_seq, receive_to_inject_micros }`, and the host combines it with its own timestamps and the stream round-trip time for #070. There is no clock synchronization between host and guest. Only durations measured on one side are used.

---

## 9. Security

- Guest-bound input is generated only from `NSEvent`s in the wrapper's key window, or from APKRun's own test harness in development builds.
- The agent validates each batch: the display exists, coordinates are finite and within ±2 × display size, key codes are in the `KEYCODE_*` range, and text is valid UTF-8 up to 4 KiB per command. Violations are dropped and counted. The injector's decoder is a fuzz target (#091).
- Injection needs `INJECT_EVENTS`. Shell has it in development. The priv-app is platform-signed in the custom image.
- No logging of key codes, text, or pointer positions at `info` or above. Debug logging of input requires a development build.

---

## 10. Unsupported and limited behavior

This is the list #025 asks for ("Document unsupported IME behavior").

| Behavior | Status |
|---|---|
| IME composition before #071 (builds up to M3) | not supported. Only characters from the US key character map (ASCII) can be typed; dead keys produce wrong characters |
| Reconversion (select committed text and convert again) | not supported. `attributedSubstring` returns nil |
| Clause highlighting inside composition | Android shows one underline for the whole composing text. The macOS candidate window still shows clauses |
| Android IMEs (Gboard and others), soft keyboard, handwriting | not used. The macOS input method is the only text input |
| Dictation, emoji & symbols viewer (⌃⌘Space) | work through `insertText` / marked text (checked in #071) |
| Non-US layouts in key mode | positional key codes (US character map); editor mode is correct |
| Multi-touch, pinch, rotate | post-v1 (FR-IN-09) |
| Stylus pressure and tilt | post-v1 |
| Game controllers | post-v1 |
| Android pointer icons (I-beam, hand) | post-v1 ([display-and-windowing.md](display-and-windowing.md) §7.7) |
| File drag & drop into apps | #082. A drop arrives as a share to the app (or a save to Downloads), not as an Android `DragEvent` at the drop position ([desktop-integration.md](desktop-integration.md) §6.2) |

---

## 11. Errors and logging

- Input errors are not user-facing. They are counters in the diagnostics snapshot (`input.dropped.rate`, `input.dropped.notRunning`, `input.dropped.invalid`, `input.ime.unmappedCommand`, `input.coalesced`) and health warnings when the agent's input stream is down (`agent.input.disconnected`).
- Logging: `io.apkrun.input`, categories `translate` (wrapper), `route` (apkrund), and `ime` (both). Guest: logcat tag `ApkRunInput`.

---

## 12. Implementation steps

### #024 Pointer input (M3)

1. Validate coordinates with ADB: `adb shell input -d 0 tap <x> <y>` at points computed by `CoordinateMapper` from window clicks. This is a one-off script in `scripts/dev/validate-input-coordinates.sh`.
2. InputCore: `InputEvent` model, `CoordinateMapper`, `EventTranslator` for mouse, hover, and scroll (§3, §4). T0 tests use synthesized `NSEvent`s (`NSEvent.mouseEvent(with:…)`, `CGEvent`-created scroll events).
3. Guest Agent `InputInjector` on the input stream (the agent bootstrap comes from #072): `MotionEvent` construction, `setDisplayId`, async injection, gesture integrity (§7.3), and `InputAck`.
4. `InputRouter` for one session on display 0 (embedded mode).
5. Acceptance: 100 of 100 clicks on the HelloText button are registered (HelloText logs `APKRUN-FIXTURE: click <n>`; [../04-plan/test-strategy.md](../04-plan/test-strategy.md)). Also: dragging scrolls HelloCompose's list, trackpad and wheel scrolling move it in the expected direction, and a right-click opens HelloText's context menu.

### #025 Keyboard input (M3)

1. `KeyCodeMap` from the CSV, with a T0 test that every table row is unique and every `KEYCODE_*` exists (checked against a list generated from the Android SDK `KeyEvent` constants).
2. Key mode (§5.2): key down/up, modifiers, repeat, Esc and ⌘[ → `BACK`, ⌃ shortcuts, and ⌘C/X/V/A/Z mapped to Ctrl combinations.
3. Write down the unsupported IME behavior (§10) in the user documentation stub `docs/06-user/keyboard-and-text-input.md`. #071 replaces the limitation there with the IME behavior.
4. Acceptance: typing `Hello, APKRun 123!` into HelloText's field produces exactly that text. Backspace, Enter, and the arrow keys work, and Esc navigates back.

### #071 IME (M4)

1. `ApkRunInputMethodService`, editor state events, commands (§5.6). Development channel `@apkrun-guest-ime`. In the custom image (M5) the IME shares the process and the input stream.
2. `NSTextInputClient` in `IOSurfaceLayerView`, `TextInputModel`, editor/key mode switching (§5.1), and editor commands (§5.4).
3. The paste policy (§6) and secure input for password fields (§5.5).
4. Acceptance: with the macOS Japanese input method, typing "にほんご" and converting gives "日本語" in HelloText's field and in a HelloCompose `TextField`. The candidate window is next to the Android cursor. Emoji from the character viewer are inserted. ⌘V pastes Mac text. In a password field, secure input is on (checked with `IsSecureEventInputEnabled()` in the UI test) and the input source is Roman. FR-IN-07 and FR-IN-08 are satisfied.

### #030 Routing (M3)

Implement focus handling (§7.2) and multi-session routing in `InputRouter`. Acceptance is in [display-and-windowing.md](display-and-windowing.md) §12 (#030).

---

## 13. Tests

| Tier | Test | Task |
|---|---|---|
| T0 | `CoordinateMapper`: steady state, letterbox, clamping, generation change | #024, #067 |
| T0 | `EventTranslator`: every row of §4.1 with synthesized events; scroll conversion and signs; hover rate limit | #024 |
| T0 | `KeyCodeMap` table checks; key mode meta state; repeat | #025 |
| T0 | `TextInputModel` and editor command mapping (§5.4); secure input balance | #071 |
| T0 | `InputRouter`: ownership, state gating, rate limits, coalescing rules (never merge `DOWN`/`UP`/keys) | #024, #030 |
| T1 | Guest Agent injector unit tests (JVM, MotionEvent/KeyEvent construction) | #024, #025 |
| T1 | Fuzzing of the agent's `InputBatch` decoder | #091 |
| T2 | HelloText clicks, typing, back; HelloCompose scroll; IME composition in both fixtures; two-window routing | #024, #025, #071, #030 |
| T3 | Latency run: the `input-latency` harness scenario ([diagnostics.md](diagnostics.md) §9.3), 1,000 synthetic clicks and 1,000 key presses at 20 Hz, p95 ≤ 16 ms per §8, nightly on the reference Mac ([../04-plan/test-strategy.md](../04-plan/test-strategy.md) §7.1) | #070 |

---

## 14. Open items

| Item | Plan |
|---|---|
| Does Android draw its own mouse pointer for injected `SOURCE_MOUSE` events (§4.2, OQ-31) | #024 checks it on display 0, and #029 repeats the check on a pool display. If it does, the agent hides it on pool displays with pointer icon `TYPE_NULL`. If that API is refused, `input.hover = false` becomes the default (R-18) |
| Injection with a display ID uses the hidden `setDisplayId`, reached by reflection (§8, R-18) | #072 and #034 check it on the stock image, and #058 again for each new Android base ([guest-components.md](guest-components.md) §13) |
| The scroll signs for trackpads and wheel mice (§4.4) | the T2 tests of #024 check them with HelloCompose's list |
| Input and IME on secondary displays (§7.2, R-05) | #024, #030 (independent input to two displays), and #071 (typing goes to the focused display). Fallback: `primaryDisplayCompatibility` for the affected apps, and the `FALLBACK_DISPLAY` IME policy |
| Dictation and the emoji & symbols viewer through `insertText` and marked text (§10) | #071 checks them |
| The latency budget, NSEvent → injected p95 ≤ 16 ms (§8, NFR-PERF-03) | #070 measures it on the reference Mac. Which Mac that is, is OQ-02, due before #070 (working default: the lowest-tier lab Mac, M1 with 16 GB) |

---

## 15. Verification log

Filled in by the tasks. Each entry records the date, the macOS build, the image build (or the test Linux guest), and the result.

| Question | Task | Result |
|---|---|---|
| Coordinates: `adb shell input -d 0 tap` at points computed by `CoordinateMapper` | #024 | pending (§3, §12) |
| Android's own pointer for injected `SOURCE_MOUSE` events, and hiding it on pool displays (OQ-31) | #024 (display 0), #029 (pool displays) | pending (§4.2) |
| Scroll signs: a two-finger swipe up moves HelloCompose's content up; wheel direction | #024 | pending (§4.4) |
| 100 of 100 clicks on the HelloText button are registered; a right-click opens the context menu | #024 | pending (§12) |
| Typing `Hello, APKRun 123!` into HelloText; Backspace, Enter, the arrow keys, and Esc | #025 | pending (§5.2) |
| IME: "にほんご" converts to "日本語" in both fixtures; the candidate window position; emoji viewer and dictation; secure input in password fields | #071 | pending (§5, §10) |
| Two-window routing: typing goes only to the key window's app, and the IME binds to the editor on the correct display (R-05) | #030, #071 | pending (§7.2) |
| Latency, NSEvent → injected: p95 per segment and in total on the reference Mac (OQ-02) | #070 | pending (§8) |
