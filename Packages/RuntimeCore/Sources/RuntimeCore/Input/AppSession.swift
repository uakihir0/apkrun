import Foundation

/// The identifier of an app or bounded system display session (display-and-windowing.md §3.1).
public enum SessionID: Sendable, Hashable {
    /// An app session, whose identifier is the session's UUID (runtime-daemon.md §7).
    case app(UUID)
    /// A bounded system operation that temporarily needs a display (#29).
    case system(SystemDisplayUse)
}

/// The states of an app session (state-machines.md §3). The input path accepts events only while the session is
/// running or backgrounded.
public enum AppSessionState: Sendable, Equatable {
    /// A client requested the session.
    case requested
    /// The runtime is booting or resuming.
    case waitingForRuntime
    /// A display is being prepared for the session.
    case acquiringDisplay
    /// The app is starting, so it takes no input yet.
    case launching
    /// The app is on screen and takes input.
    case running
    /// The window is hidden or minimized. The app still takes input (state-machines.md §3).
    case backgrounded
    /// The session is closing, so it takes no input.
    case closing
    /// The session has ended, so it takes no input.
    case ended(SessionEndReason)

    /// Whether the input path accepts events in this state (runtime-api.md §7.3).
    public var acceptsInput: Bool {
        switch self {
        case .running, .backgrounded: true
        case .requested, .waitingForRuntime, .acquiringDisplay, .launching, .closing, .ended: false
        }
    }
}

/// Why an app session ended (state-machines.md §3).
public enum SessionEndReason: Sendable, Equatable {
    /// The user closed the app window.
    case userClosed
    /// Android removed the app's last task.
    case appExited
    /// Android reported that the app process crashed.
    case appCrashed
    /// The Android runtime stopped.
    case runtimeStopped
    /// The package is being updated.
    case updating
    /// APKRun or Android is being updated.
    case runtimeUpdating
    /// The package was uninstalled.
    case packageUninstalled
    /// A typed RuntimeCore failure code for the session.
    case error(SessionFailureCode)
}

/// RuntimeCore failure categories that can end an app session.
public enum SessionFailureCode: String, Sendable, Equatable {
    /// The only display available in the embedded #27 mode is already in use.
    case displayInUse
    /// The app launch did not produce a task before its deadline.
    case launchTimedOut
    /// The Guest Agent could not complete the operation.
    case guestAgentUnavailable
    /// The graphics display disappeared while the app was running.
    case displayLost
    /// A failure that does not have a more specific session category.
    case runtimeFailed
}
