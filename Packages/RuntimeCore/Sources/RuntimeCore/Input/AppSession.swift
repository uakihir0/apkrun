import Foundation

/// The identifier of a session (display-and-windowing.md §3.1). The design also has `.system` uses of a display,
/// which come with the display pool (#028). Only app sessions take input, so only `.app` exists here.
public enum SessionID: Sendable, Hashable {
    /// An app session, whose identifier is the session's UUID (runtime-daemon.md §7).
    case app(UUID)
}

/// The states of an app session that the input path tells apart (state-machines.md §3). #026 adds the others, such as
/// `requested` and `ended(SessionEndReason)`, and maps them to these states.
public enum AppSessionState: Sendable, Equatable {
    /// The app is starting, so it takes no input yet.
    case launching
    /// The app is on screen and takes input.
    case running
    /// The window is hidden or minimized. The app still takes input (state-machines.md §3).
    case backgrounded
    /// The session is closing, so it takes no input.
    case closing
    /// The session has ended, so it takes no input.
    case ended

    /// Whether the input path accepts events in this state (runtime-api.md §7.3).
    public var acceptsInput: Bool {
        switch self {
        case .running, .backgrounded: true
        case .launching, .closing, .ended: false
        }
    }
}
