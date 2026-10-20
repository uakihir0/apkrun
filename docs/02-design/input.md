# Input (InputCore, InputRouter, Guest Agent injection)

Input moves pointer, scroll, keyboard, and text events from the wrapper's window to Android displays, through the Guest Agent. This document covers the pipeline, the event model, coordinate mapping, pointer and scroll mapping, keyboard and text, shortcuts, routing and focus, transport, security, limits, errors, tests, and open items.

---

## 1. Pipeline

```text
wrapper: NSEvent ─▶ IOSurfaceLayerView ─▶ InputCore.EventTranslator ─▶ [InputEvent] (display px)
                                       └▶ NSTextInputClient ─▶ TextInputModel ─▶ ImeTextEvent
         InputSink ─XPC sendInput/sendText─▶ apkrund: InputRouter (ownership, rate limit, coalescing, displayID)
         ─vsock 6101 input stream─▶ guest: InputInjector ─▶ InputManager.injectInputEvent (setDisplayId = N)
                                    ApkRunIme (InputMethodService) ◀─ ImeCommand
         ◀─ imeStateChanged(EditorState) ◀─ editor focus, cursor rect ◀─ ApkRunIme
```

Rules:

- **No shell command per event** on any product path (FR-IN-06). The only `adb shell input` use is the one-off coordinate check `scripts/dev/validate-input-coordinates.sh`.
- Input reaches only the display leased by the sending session (FR-IN-05, §7).
- Every gesture opened in the guest is closed. Each touch `DOWN` gets `UP` or `CANCEL`, and each key down gets a key up (§7.3).
- Key codes and text are never logged at `info` or above, only counts ([security-model.md](../01-architecture/security-model.md)).

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

`DisplayPoint` is in the pixel space of the session's display (`ResolvedDisplayMode.pixelSize`, [display-and-windowing.md](display-and-windowing.md) §6.1). InputCore does not know display IDs. `InputRouter` adds the Android display ID (§7.1). The wire encoding (`InputBatch`, `ImeCommand`) is in [guest-protocol.md](guest-protocol.md).

---

## 3. Coordinate mapping

`IOSurfaceLayerView` creates `CoordinateMapper` (InputCore, pure) from the current content rect and the pool's pixel size:

```text
contentRect  = view bounds in steady state; the aspect-fit rect of the current frame during live resize
               (display-and-windowing.md §7.1)
x_px = (p.x − contentRect.minX) × pixelWidth  / contentRect.width
y_px = (contentRect.maxY − p.y) × pixelHeight / contentRect.height      // AppKit y-up → Android y-down
```

- Events outside `contentRect` (letterbox bars during live resize) are dropped when they would start a gesture. During a gesture they are **clamped** to the display edge, so a drag that leaves the window still ends with `UP` at the edge.
- The mapper is replaced atomically on `surfacesReplaced` and updated on layout changes. A gesture keeps the mapper of its `DOWN` through `UP` or cancellation. A new gesture uses the latest mapper. If the generation changes during an open gesture, the host sends `CANCEL` for it.
- Coordinates are floating point. The agent passes them to `MotionEvent` unchanged.

---

## 4. Source mapping (pointer, scroll)

This section details the mouse-as-touch rule of [ADR-0013](../01-architecture/decisions/0013-input-via-guest-injection.md). Per-package overrides are under `input.*` ([package-metadata-json.md](../03-reference/package-metadata-json.md)).

### 4.1 Mapping table

| macOS event | Android event (default) | Source / tool | Notes |
|---|---|---|---|
| left `mouseDown` | `ACTION_DOWN` | `SOURCE_TOUCHSCREEN`, `TOOL_TYPE_FINGER`, pointer 0, pressure 1.0 | FR-IN-01 |
| left `mouseDragged` | `ACTION_MOVE` | same | One per display refresh when the stream is backed up (§8) |
| left `mouseUp` | `ACTION_UP` | same | |
| `mouseMoved` (no button) | `ACTION_HOVER_MOVE` | `SOURCE_MOUSE`, `TOOL_TYPE_MOUSE` | Needs `acceptsMouseMovedEvents`. At most 120 Hz. Off with `input.hover = false`. Nothing is sent while a gesture is open (§4.2) |
| `mouseEntered` / `mouseExited` (tracking area on the content rect) | `ACTION_HOVER_ENTER` / `ACTION_HOVER_EXIT` | `SOURCE_MOUSE` | |
| `rightMouseDown` / `rightMouseUp` | `ACTION_DOWN` + `ACTION_BUTTON_PRESS(BUTTON_SECONDARY)` … `ACTION_BUTTON_RELEASE` + `ACTION_UP` | `SOURCE_MOUSE`, `TOOL_TYPE_MOUSE` | Context click. With `input.secondaryClick = longPress`, a long press instead (§4.3) |
| Control + left click | As right click | | Mac convention |
| `otherMouseDown` (middle) | Ignored in v1 | | |
| `scrollWheel` | `ACTION_SCROLL` with `AXIS_VSCROLL` / `AXIS_HSCROLL` at the pointer | `SOURCE_MOUSE` | FR-IN-02, §4.4. With `input.scrollMode = touchDrag`, a synthetic finger drag |
| `magnify`, `rotate`, `swipe` | Not forwarded in v1 | | FR-IN-09, post-v1 |
| Tablet and pressure events | Treated as left mouse | | Stylus is post-v1 |

A mouse click in a window that is not key only activates the window (`acceptsFirstMouse` = false). The next click is delivered.

### 4.2 Touch semantics

- A single pointer (ID 0) in v1. `downTime` is set at `DOWN` and reused for the gesture.
- A left-button hold without movement becomes an Android long press, because `UP` arrives late.
- Only `leftMouseDragged` moves the touch. A move without a button is hover, which is not sent during a gesture. A stray pointer move during a tap never turns it into a drag.
- A double click is two taps.
- Losing key focus, closing the window, `surfacesReplaced`, or the session leaving `running` during a gesture sends `CANCEL` (the translator emits `.cancelAll`).
- Android may draw its own pointer for injected `SOURCE_MOUSE` events (OQ-31, §14). The agent then hides it on pool displays with pointer icon `TYPE_NULL`, through the hidden `InputManager` pointer-icon API. If that API is refused, hover is off by default (`input.hover = false`, R-18).

### 4.3 Secondary click

- `mouseSecondary` (default): real secondary-button events. Views get `onContextClick` and context menus, and web content gets `contextmenu`.
- `longPress`: the agent injects `DOWN`, waits `ViewConfiguration.getLongPressTimeout() + 50 ms`, then injects `UP` at the click position. It helps phone apps that react only to long press. Settings → App → Input.

### 4.4 Scrolling

Android views scroll by `axis value × ViewConfiguration.getScaled{Vertical,Horizontal}ScrollFactor()`, which is 64 dp by default (`config_verticalScrollFactor`). The agent reports the factor in dp for each display in `DisplayAdded` and `DisplayChanged` ([guest-protocol.md](guest-protocol.md)). The translator converts:

```text
precise deltas (trackpad, Magic Mouse; hasPreciseScrollingDeltas):
    dp = scrollingDelta (points) / zoom                  // 1 dp = 1 pt at zoom 1 (display-and-windowing.md §6.1)
    AXIS_VSCROLL = + dpY / scrollFactorDp
    AXIS_HSCROLL = − dpX / scrollFactorDp
line deltas (wheel mice):
    AXIS_VSCROLL = + scrollingDeltaY   (lines ≈ notches)
    AXIS_HSCROLL = − scrollingDeltaX
```

- `scrollingDelta` already includes natural scrolling, so no inversion is added. The T2 test checks the signs with HelloCompose's list: a two-finger swipe up moves the content up, as in Safari.
- Momentum-phase events are forwarded as ordinary scroll events. Android adds no fling to mouse scroll.
- Events accumulate per display refresh: at most one `ACTION_SCROLL` per 8 ms, with the axes summed.
- `touchDrag` (per package, for apps whose custom views ignore `ACTION_SCROLL`): at the start of a precise scroll (`phase == .began`), inject a finger `DOWN` at the pointer. `MOVE` by the accumulated deltas in pixels, and `UP` when momentum ends. `VelocityTracker` turns the last moves into a fling. Wheel mice send an 80 dp drag per notch in this mode.

---

## 5. Keyboard and text

### 5.1 Two paths

| Situation | Path | Why |
|---|---|---|
| An Android **editor is focused** (the APKRun IME reported `editorFocused`) | **Editor mode.** `NSTextInputContext.handleEvent` interprets every key. `insertText`, marked text, and `doCommand(by:)` become `ImeTextEvent`s on the IME channel | Full Unicode, dead keys, and composition (Japanese, Chinese, Korean) come from the macOS input method (FR-IN-07). Ordered with editing keys |
| No editor focused (games, lists, custom views) | **Key mode.** Raw `KeyEvent`s by physical key (§5.2) | Apps that read key codes directly |

The wrapper learns the mode from `imeStateChanged(EditorState)`, relayed by apkrund on the session channel ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.3). `EditorState` carries `focused`, `inputType`, `imeOptions`, the selection, the composing range, and the cursor rectangle in display pixels.

Without the APKRun IME (#071), all input uses key mode, and characters come from Android's US virtual key character map (§10).

### 5.2 Physical key mapping

`KeyCodeMap` (InputCore) is a static table generated from `Packages/InputCore/Resources/keymap-mac-android.csv` (`kVK_*` code, Android `KEYCODE_*`, notes):

| macOS keys | Android |
|---|---|
| `kVK_ANSI_A`…`Z`, `kVK_ANSI_0`…`9` | `KEYCODE_A`…`Z`, `KEYCODE_0`…`9` |
| Punctuation: `Minus`, `Equal`, `LeftBracket`, `RightBracket`, `Backslash`, `Semicolon`, `Quote`, `Comma`, `Period`, `Slash`, `Grave` | `KEYCODE_MINUS`, `EQUALS`, `LEFT_BRACKET`, `RIGHT_BRACKET`, `BACKSLASH`, `SEMICOLON`, `APOSTROPHE`, `COMMA`, `PERIOD`, `SLASH`, `GRAVE` |
| `Return`, `Tab`, `Space`, `Delete` (backspace), `ForwardDelete` | `ENTER`, `TAB`, `SPACE`, `DEL`, `FORWARD_DEL` |
| Arrows, `Home`, `End`, `PageUp`, `PageDown` | `DPAD_LEFT/RIGHT/UP/DOWN`, `MOVE_HOME`, `MOVE_END`, `PAGE_UP`, `PAGE_DOWN` |
| `F1`…`F12` | `F1`…`F12` (only when macOS delivers them to the app) |
| Keypad keys | `NUMPAD_*` |
| `Shift`, `Control`, `Option` (left and right) | `SHIFT_LEFT/RIGHT`, `CTRL_LEFT/RIGHT`, `ALT_LEFT/RIGHT` as key events in key mode |
| `CapsLock` | `CAPS_LOCK` plus `META_CAPS_LOCK_ON` |
| JIS `Yen`, `Underscore` | `YEN`, `RO` |
| JIS `Eisu`, `Kana` | Not forwarded (they switch the input source) |
| `Escape` | `BACK` (FR-IN-04). `ESCAPE` with `input.escapeKey = escape` |
| `Command` | Not forwarded; reserved for host shortcuts (§6). Optional `input.sendCommandKey` maps it to `META_LEFT` |

Shift gives `META_SHIFT_ON`, Control gives `META_CTRL_ON`, Option gives `META_ALT_ON`, and Caps Lock gives `META_CAPS_LOCK_ON`. Key repeat (`isARepeat`) increments `repeatCount` on repeated `down` events.

Key codes are positional (US ANSI). With a non-US layout, key-mode apps that read `KeyEvent.getUnicodeChar()` see US characters. Editor mode is not affected (§10).

### 5.3 Editor mode: `NSTextInputClient`

`IOSurfaceLayerView` implements `NSTextInputClient` and keeps a model of the Android editor (`TextInputModel`: marked text, selection, last cursor rect).

| AppKit call | Sent to the IME |
|---|---|
| `insertText(_:replacementRange:)` | `.commit(text)`. It replaces an active composition, as `commitText` does |
| `setMarkedText(_:selectedRange:replacementRange:)` | `.setComposing(text, selection)` → `InputConnection.setComposingText(text, 1)`, then `setSelection` inside the composition |
| `unmarkText()` | `.finishComposing` |
| `firstRect(forCharacterRange:actualRange:)` | Answered from the last `EditorState.cursorRect` (display px → window → screen), so the candidate window appears by the Android cursor. Without a cursor rect, the bottom-left of the content rect |
| `hasMarkedText`, `markedRange`, `selectedRange` | Answered from `TextInputModel` |
| `attributedSubstring(forProposedRange:)` | `nil`. Surrounding text is not mirrored, so reconversion is unsupported (§10) |
| `doCommand(by:)` | Mapped by §5.4 |

The IME reports cursor rectangles through `InputConnection.requestCursorUpdates(CURSOR_UPDATE_MONITOR | CURSOR_UPDATE_IMMEDIATE)` and `onUpdateCursorAnchorInfo`. The insertion marker bounds are transformed to display coordinates with the matrix in `CursorAnchorInfo`.

### 5.4 Editor commands

`doCommand(by:)` selectors from `NSStandardKeyBindingResponding` map to key events sent with `InputConnection.sendKeyEvent` as `.key(...)`. Sending them on the IME channel keeps them ordered with committed text.

| Selector | Android |
|---|---|
| `deleteBackward:` / `deleteForward:` | `DEL` / `FORWARD_DEL`, as key events, not `deleteSurroundingText`. Apps that watch `DEL` in empty fields, such as OTP boxes, still work |
| `deleteWordBackward:` / `deleteWordForward:` | `Ctrl+DEL` / `Ctrl+FORWARD_DEL` |
| `insertNewline:` | If the editor has an action (`imeOptions & IME_MASK_ACTION` is not `NONE` or `UNSPECIFIED`, not multi-line, and no `IME_FLAG_NO_ENTER_ACTION`): `.editorAction(action)`. Otherwise `ENTER` |
| `insertLineBreak:` (Control+Return), `insertNewlineIgnoringFieldEditor:` (Option+Return) | `ENTER` with `META_SHIFT_ON` |
| `insertTab:` / `insertBacktab:` | `TAB` / `Shift+TAB` |
| `moveLeft:`, `moveRight:`, `moveUp:`, `moveDown:` (+ `AndModifySelection`) | `DPAD_*` (+ Shift) |
| `moveWordLeft:`, `moveWordRight:` (+ selection) | `Ctrl+DPAD_LEFT/RIGHT` (+ Shift) |
| `moveToBeginningOfLine:`, `moveToEndOfLine:`, `moveToLeftEndOfLine:`, `moveToRightEndOfLine:` (+ selection) | `MOVE_HOME` / `MOVE_END` (+ Shift) |
| `moveToBeginningOfDocument:`, `moveToEndOfDocument:` (+ selection) | `Ctrl+MOVE_HOME` / `Ctrl+MOVE_END` (+ Shift) |
| `pageUp:`, `pageDown:`, `scrollPageUp:`, `scrollPageDown:` | `PAGE_UP` / `PAGE_DOWN` |
| `cancelOperation:` (Esc, ⌘.) | `BACK` when there is no marked text. With marked text, the macOS IME consumes Esc |
| Others | Ignored and counted (`input.ime.unmappedCommand`); the selector name is logged at debug level |

### 5.5 Password and secure fields

When `EditorState.inputType` is a password variation (`TYPE_TEXT_VARIATION_PASSWORD`, `VISIBLE_PASSWORD`, `WEB_PASSWORD`, or `TYPE_NUMBER_VARIATION_PASSWORD`) and the window is key, the view calls `EnableSecureEventInput()` and sets `inputContext.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]`, as `NSSecureTextField` does. It calls `DisableSecureEventInput()` when focus leaves the field, the window resigns key, or the session ends. A counter balances the calls, and a unit test checks the balance.

### 5.6 The APKRun IME (guest side)

- The IME is built by #071. `io.apkrun.guest/.ime.ApkRunInputMethodService` is an `InputMethodService` with no visible keyboard: `onEvaluateInputViewShown()` returns false, and `onCreateInputView()` returns an empty view. The Mac keyboard and macOS input method are the only text input.
- The Guest Agent enables the IME and selects it as default at start (`Settings.Secure.ENABLED_INPUT_METHODS`, `DEFAULT_INPUT_METHOD`). This needs `WRITE_SECURE_SETTINGS`: the shell has it in development, and the privileged app in the custom image.
- `onStartInput`, `onFinishInput`, `onUpdateSelection`, and `onUpdateCursorAnchorInfo` produce `EditorState` events for the host.
- Host commands run on the IME's main thread against `getCurrentInputConnection()`. A command that arrives with no bound editor is dropped and counted.
- The per-display IME policy is `LOCAL` ([display-and-windowing.md](display-and-windowing.md) §4), so the IME binds to editors on pool displays.
- Channel: in the custom image, the IME runs in the Guest Agent process and shares the input stream (vsock 6101), so ordering holds. In development, the Guest Agent's `app_process` part runs under the shell uid, but the IME must run in the app's own process. The IME therefore listens on the abstract socket `@apkrun-guest-ime`, reached through an ADB forward ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §3.1). Pointer and IME ordering across the two channels is not guaranteed in development.

---

## 6. Shortcuts (FR-IN-04, FR-IN-08)

Host shortcuts are handled by the wrapper's menus (`performKeyEquivalent`) and never reach Android. The menus are in [wrapper.md](wrapper.md) §5.6. This table is complete: the launcher adds no other key equivalent.

| Shortcut | Action |
|---|---|
| ⌘Q, ⌘W, ⌘H, ⌥⌘H, ⌘M, ⌘`, ⌃⌘F, ⌘, | Mac app and window commands. ⌘W and ⌘Q end the session ([display-and-windowing.md](display-and-windowing.md) §7.6) |
| ⌘=, ⌘−, ⌘0 | Zoom ([display-and-windowing.md](display-and-windowing.md) §6.1) |
| Esc, ⌘[ | Android `BACK` (FR-IN-04). Esc follows `input.escapeKey` |
| ⌘C / ⌘X / ⌘A | Editor mode: `.contextMenuAction(.copy/.cut/.selectAll)` → `InputConnection.performContextMenuAction(android.R.id.copy …)`. Key mode: `Ctrl+C` / `Ctrl+X` / `Ctrl+A` |
| ⌘V | Editor mode, with clipboard integration on for the package: push the Mac clipboard to Android first ([desktop-integration.md](desktop-integration.md), push-with-ack), then `performContextMenuAction(paste)`. Integration off: `.commit(pasteboard plain text)`, because the user explicitly pasted. Key mode: `Ctrl+V` |
| ⌘Z / ⇧⌘Z | `Ctrl+Z` / `Ctrl+Shift+Z` (through `sendKeyEvent` in editor mode) |
| ⌃ + key | Passed to Android with `META_CTRL_ON` |
| ⌥ + key | Editor mode: interpreted by the macOS input method (for example ⌥E accents). Key mode: `META_ALT_ON` |

---

## 7. Routing and focus (FR-IN-05)

### 7.1 InputRouter (apkrund)

```swift
public actor InputRouter {
    public func route(_ batch: [InputEvent], from session: SessionID) async
    public func routeText(_ event: ImeTextEvent, from session: SessionID) async
    public func focusChanged(_ session: SessionID, focused: Bool) async
    public func sessionEnded(_ session: SessionID) async           // closes open gestures and keys
}
```

- The session comes from the XPC connection, and a wrapper can name only its own session ([process-model-and-ipc.md](../01-architecture/process-model-and-ipc.md) §2.2). The router finds the lease in `DisplayPool` and stamps the Android display ID. Wrappers never send display IDs.
- Events are accepted only while the session is `running` or `backgrounded`. Otherwise they are dropped and counted.
- Rate limits per session: 2000 events/s and 64 KiB of text/s. Excess is dropped with a counter and a rate-limited warning.
- Coalescing applies when the guest stream's send buffer is above 64 KiB: consecutive `MOVE`, hover, and scroll events for the same display merge, and scroll axes add up. `DOWN`, `UP`, `CANCEL`, button, and key events are never dropped or merged.

### 7.2 Focus

- AOSP runs with `config_perDisplayFocusEnabled = false`. An injected key event with a display ID goes to that display's focused window, because `InputDispatcher` uses the event's display ID. The IME follows the globally focused window.
- On `focusChanged(true)`, the router sends `FocusDisplay(displayID)`. The agent moves the session's top task to the front (`IActivityTaskManager.setFocusedTask(taskId)`; the shell and the privileged app hold `MANAGE_ACTIVITY_TASKS`). A touch `DOWN` also moves focus. The explicit call makes keyboard-only focus changes work, such as ⌘` between wrappers.
- Native windows enqueue focus changes on separate queues. The host therefore assigns a shared, increasing generation at each key-focus report, and the router ignores an older late notification. A retry with the current generation is accepted when the agent could not focus a task that had not appeared yet. Task appearance triggers that retry.
- On `focusChanged(false)`, the router sends `.cancelAll` for that session.
- Two-window input and IME routing are open (R-05, §14).

### 7.3 Gesture and key integrity

The agent tracks per display the open touch gesture (`downTime`, last position), pressed mouse buttons, and pressed keys. It synthesizes `CANCEL`, button releases, and key ups when it receives `.cancelAll`, when the input stream disconnects, or when the target display is removed. This prevents stuck keys and half-open gestures.

---

## 8. Transport and latency (NFR-PERF-03)

- **Wrapper → apkrund:** `sendInput([InputEvent])` is batched per run-loop turn. The first event after idle is sent at once. `sendText` is unbatched and in order.
- **apkrund → guest:** a dedicated input stream (vsock 6101, or its ADB forward in development) carries `InputBatch{ display_id, events[], host_send_nanos }` and `ImeCommand`. Each frame is written at once, with no Nagle delay.
- **Guest injection:** `InputManager.getInstance().injectInputEvent(event, INJECT_INPUT_EVENT_MODE_ASYNC)` after `setDisplayId`, a hidden API reached by reflection, as scrcpy does. `eventTime` = `SystemClock.uptimeMillis()` at injection. Spacing inside a batch is kept by offsetting from the batch's first host timestamp.
- **Budget** (NSEvent received → injected, p95 ≤ 16 ms):

| Segment | Budget (p95) | Measured by |
|---|---|---|
| NSEvent → XPC send (wrapper) | 2 ms | signpost `input.translate` |
| XPC → router → vsock write (apkrund) | 2 ms | signpost `input.route` |
| vsock → agent read | 2 ms | `InputAck` round trip |
| agent read → `injectInputEvent` returned | 4 ms | agent timing |
| Margin | 6 ms | |

- **Measurement:** every 32nd batch carries `ack_requested`. The agent answers `InputAck{ batch_seq, receive_to_inject_micros }`, and the host combines it with its own timestamps and the stream round trip for [diagnostics.md](diagnostics.md) §9.3. Host and guest clocks are not synchronized, so only durations measured on one side are used.

---

## 9. Security

- Guest-bound input is generated only from `NSEvent`s in the wrapper's key window, or from APKRun's test harness in development builds.
- The agent validates each batch: the display exists, coordinates are finite and within ±2 × display size, key codes are in the `KEYCODE_*` range, and text is valid UTF-8 up to 4 KiB per command. Violations are dropped and counted. The injector's decoder is a fuzz target (#091).
- Injection needs `INJECT_EVENTS`. The shell has it in development, and the priv-app is platform-signed in the custom image.
- No logging of key codes, text, or pointer positions at `info` or above. Debug logging of input requires a development build.

---

## 10. Unsupported and limited behavior

| Behavior | Status |
|---|---|
| Composition without the APKRun IME (#071) | Not supported. Only ASCII from the US key character map can be typed, and dead keys produce wrong characters |
| Reconversion (select committed text and convert again) | Not supported. `attributedSubstring` returns nil |
| Clause highlighting inside composition | Android shows one underline for the whole composing text. The macOS candidate window still shows clauses |
| Android IMEs (Gboard and others), soft keyboard, handwriting | Not used. The macOS input method is the only text input |
| Dictation, emoji & symbols viewer (⌃⌘Space) | Work through `insertText` and marked text (#071) |
| Non-US layouts in key mode | Positional key codes (US character map). Editor mode is correct |
| Multi-touch, pinch, rotate | Post-v1 (FR-IN-09) |
| Stylus pressure and tilt, game controllers | Post-v1 |
| Android pointer icons (I-beam, hand) | Post-v1 ([display-and-windowing.md](display-and-windowing.md) §7.7) |
| File drag and drop into apps | A drop arrives as a share to the app, or a save to Downloads, not as an Android `DragEvent` at the drop position ([desktop-integration.md](desktop-integration.md) §6.2). #082 |

---

## 11. Errors and logging

- Input errors are not user-facing. They are counters in the diagnostics snapshot: `input.dropped.rate`, `input.dropped.notRunning`, `input.dropped.invalid`, `input.dropped.channel` (events the input stream could not carry), `input.ime.unmappedCommand`, and `input.coalesced`. The health warning `agent.input.disconnected` reports a down agent input stream.
- The `input.dropped.*` counters count what the injector sees refused. For ASYNC injection (§8), that is the refusal at the queue. An event that the framework accepts and then does not deliver is not counted, because the call returns before delivery.
- Logging: `io.apkrun.input`, categories `translate` (wrapper), `route` (apkrund), and `ime` (both). Guest input lines use the logcat tag `ApkRunGuest` ([guest-components.md](guest-components.md) §9).
- The `input.route` signpost wraps `InputRouter.route`. There is no `input.translate` signpost: the window path is synchronous, and `Perf.interval` is asynchronous ([diagnostics.md](diagnostics.md) §4).
- `InputRouter` keeps the counters. `apkrun dev boot` prints them when it stops, with the agent's `adb shell` command count. The input path starts no shell command, so the two counts are equal.
- ACK event time: when `input.ack_trace.v1` is negotiated, and a batch requests both an ACK and its event time, `InputAck` carries the Android uptime `eventTime` of the last accepted `MotionEvent`. The field is optional and needs protocol minor version 1.1 ([guest-protocol.md](guest-protocol.md)). Android uptime is never subtracted from host timestamps.
- The diagnostic trace (#103) is opt-in and runs only in the `AndroidInputTrace` test plan. It records raw AppKit receipts, translated events, routed events, guest ACKs, Android touch dispatch, and fixture clicks, with history bounded at 2,048 receipts and 256 route and ACK records. Each layer reports discarded records. Its ACK cadence and fixture listener perturb timing, so the product-cadence test runs with capture off. A missing ACK field or an unmatched fixture record is a trace failure, not proof of delivery.

---

## 13. Tests

- **T0**, `Packages/InputCore/Tests/InputCoreTests/`: `CoordinateMapper` (steady state, letterbox, clamping, generation change); `EventTranslator` (every row of §4.1, scroll conversion and signs, hover rate limit, letterbox press drop, clamped drag at all four edges); `KeyCodeMap` (unique rows, every `KEYCODE_*` exists); `KeyTranslator` (meta state, repeat).
- **T0**, `Packages/WindowingCore/Tests/WindowingCoreTests/` (`PointerMappingTests`, `PointerEventAdapterTests`, `KeyEventAdapterTests`): adapters from window events to `InputEvent`s.
- **T0**, `Packages/RuntimeCore/Tests/RuntimeCoreTests/`: `InputRouterTests` (ownership, state gating, rate limits, coalescing: `DOWN`, `UP`, and keys are never merged); `GuestInputEncodingTests` and `GuestInputConnectionTests`.
- **T0 (#071)**: `TextInputModel`, editor command mapping (§5.4), and the balance of secure input.
- **T1**, `Guest/guestd/src/test/kotlin/io/apkrun/guest/daemon/`: `InputInjectorTest` (`MotionEvent` and `KeyEvent` construction, injection) and `InputValidatorTest` (batch validation, §9).
- **T1 (#091)**: fuzzing of the agent's `InputBatch` decoder.
- **T2**, `Tests/IntegrationTests/AndroidInputTests/AndroidInputTests.swift`: HelloText clicks (100 of 100 registered, counted by `APKRUN-FIXTURE: click <n>` lines), the right-click context menu, typing and key navigation, HelloCompose scroll signs, and the letterbox and clamping cases on display 0. The same file holds `AndroidInputTraceJoinTests`, which joins trace records without a device. Two-window routing and IME composition are not yet in the suite.
- **T3**, nightly on the reference Mac: the `input-latency` scenario ([diagnostics.md](diagnostics.md) §9.3). It sends 1,000 synthetic clicks and 1,000 key presses at 20 Hz and requires p95 ≤ 16 ms (§8) ([test-strategy.md](../04-plan/test-strategy.md) §7.1).

---

## 14. Open items

- Does Android draw its own pointer for injected `SOURCE_MOUSE` events on pool displays (OQ-31, §4.2)? #029 checks it.
- Injection with a display ID uses the hidden `setDisplayId`, reached by reflection (R-18, §8). It is checked on the stock image (#072, #034), and again on each new Android base ([guest-components.md](guest-components.md) §13).
- Physical trackpad and wheel scroll direction. The synthetic tests check the signs. Physical input is manual check C01-2 ([test-strategy.md](../04-plan/test-strategy.md) §8).
- Input and IME on secondary displays (R-05, §7.2). Fallbacks: `primaryDisplayCompatibility` for affected apps, and the `FALLBACK_DISPLAY` IME policy. #030 and #071 check it.
- Dictation and the emoji viewer through `insertText` and marked text (§10). #071 checks them.
- The counters are not in diagnostics snapshots yet, and the `agent.input.disconnected` warning is not implemented (§11, #024). `input.ime.unmappedCommand` needs the IME (#071).
- NSEvent → injected latency, p95 ≤ 16 ms (§8, NFR-PERF-03). #070 measures it on the reference Mac, which OQ-02 selects. Working default: the lowest-tier lab Mac (M1, 16 GB).
