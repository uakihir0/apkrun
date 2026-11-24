import AppKit
import Carbon.HIToolbox
import InputCore

/// Balances `EnableSecureEventInput` and `DisableSecureEventInput` for password fields
/// (input.md §5.5). The calls come in pairs; the counter keeps them paired across focus changes,
/// state reports that repeat, and the session end.
@MainActor
final class SecureInputController {
    /// The enable calls minus the disable calls. Always 0 or 1.
    private(set) var depth = 0
    /// How often enable ran; a test checks `enables == disables` at the end (input.md §5.5).
    private(set) var enables = 0
    /// How often disable ran.
    private(set) var disables = 0
    /// Whether the allowed input source was narrowed to the Roman one.
    private(set) var romanOnly = false

    private let enable: () -> Void
    private let disable: () -> Void

    /// Creates a controller. The Carbon calls are injectable so the unit test counts the balance
    /// without changing the process's real input security.
    init(
        enable: @escaping () -> Void = { EnableSecureEventInput() },
        disable: @escaping () -> Void = { DisableSecureEventInput() }
    ) {
        self.enable = enable
        self.disable = disable
    }

    /// Whether secure input is held.
    var isActive: Bool {
        depth > 0
    }

    /// Applies the wanted state: secure while a password field is focused and the window is key
    /// (input.md §5.5).
    func update(_ wanted: Bool, inputContext: NSTextInputContext?) {
        if wanted, depth == 0 {
            depth = 1
            enables += 1
            romanOnly = true
            inputContext?.allowedInputSourceLocales = [NSAllRomanInputSourcesLocaleIdentifier]
            enable()
        } else if !wanted, depth > 0 {
            depth = 0
            disables += 1
            romanOnly = false
            inputContext?.allowedInputSourceLocales = nil
            disable()
        }
    }
}
