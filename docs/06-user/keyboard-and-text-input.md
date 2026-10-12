# Keyboard and text input

This page describes how the Mac keyboard reaches an Android app in an APKRun window. It covers key mode, which is the only
keyboard path before the APKRun input method (#071). The design is in [input.md](../02-design/input.md) §5 and §6.

## Key mode

Key mode sends each key you press to the Android app as a key event, with the modifier keys held at that moment.

- Typing works in a text field. Letters, digits, and punctuation are typed as the US keyboard produces them.
- Keys are sent by their position on an ANSI keyboard. On another layout, the character an app receives can differ from the
  one printed on your keycap.
- Shift, Control, Option, and Caps Lock act as they do on an Android keyboard. Shift and Control keep their side (left or
  right).
- Holding a key repeats it in the app, as on Android.
- Backspace, Delete, Enter, Tab, the arrow keys, Home, End, Page Up, Page Down, and F1 to F12 are sent as their Android keys.

## Back

- Escape sends Android's Back key, so Escape closes a screen and returns to the previous one.
- ⌘[ also sends Back.
- The Escape behavior can be set to send Escape itself with the `input.escapeKey` setting. The setting is not yet read from
  the settings store, so Escape sends Back for now.

## Shortcuts

Shortcuts that use Command are translated to the Control shortcuts that Android apps expect.

| Mac shortcut | Sent to Android |
|---|---|
| ⌘C, ⌘X, ⌘V, ⌘A, ⌘Z | Control with the same key (Ctrl+C, Ctrl+X, Ctrl+V, Ctrl+A, Ctrl+Z) |
| ⇧⌘Z | Control and Shift with Z (Ctrl+Shift+Z) |
| ⌃ with a key | the key, with Control held |
| ⌥ with a key | the key, with Alt held |
| ⌘[ | Back |

Other Command shortcuts are not sent to Android. ⌘Q, ⌘W, ⌘H, ⌘M, ⌘`, ⌘,, ⌘=, ⌘−, and ⌘0 keep their Mac meaning.

Pasting Mac text into an Android app is not supported in key mode. ⌘V pastes the Android clipboard. Clipboard sharing between
the Mac and Android is #053.

## Not supported before the input method (#071)

These limits apply to key mode. The APKRun input method (#071) changes the first three.

| Behavior | Status |
|---|---|
| Composing text with an input method, such as Japanese, Chinese, or Korean | not supported. Only the characters of the US key map can be typed. Dead keys produce the wrong characters |
| Converting text you already typed (reconversion) | not supported |
| Underline and clause highlighting while composing | not supported. The Mac candidate window still shows the clauses |
| Android's own keyboards, the soft keyboard, and handwriting | not used. The Mac keyboard and its input methods are the only text input |
| Dictation and the emoji and symbols viewer (⌃⌘Space) | not supported until #071 |
| Non-US layouts | keys are sent by position, so the characters follow the US layout |
| Command shortcuts other than the ones above | not sent to Android |
| Pasting Mac text | not supported until #071 and #053 |
