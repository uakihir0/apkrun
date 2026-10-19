import Foundation
import RuntimeAPI

/// Dispatches package-session requests to the window that owns that package in an embedded multi-window run (#030).
///
/// Each child service owns one session and display lease; this actor keeps the RuntimeAPI surface singular while the
/// Guest Agent, DisplayPool, SessionRegistry, and input stream are shared by the boot.
public actor EmbeddedMultiSessionService: RuntimeSessionService {
    private var sessions: [String: EmbeddedRuntimeService]

    /// Creates a dispatcher for the packages opened by one `apkrun dev launch` command.
    public init(sessions: [String: EmbeddedRuntimeService]) {
        self.sessions = sessions
    }

    /// Updates or adds the service for one package.
    public func setSession(_ session: EmbeddedRuntimeService, for packageID: String) {
        sessions[packageID] = session
    }

    /// Attaches the same Guest Agent control plane to each window session.
    func attachGuestAgent(_ guestAgent: any EmbeddedSessionGuestAgent) async {
        for session in sessions.values {
            await session.attachGuestAgent(guestAgent)
        }
    }

    /// Starts the session owned by the requested package.
    public func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        guard let session = sessions[request.packageID.rawValue] else {
            throw Self.sessionUnavailable(request.packageID.rawValue)
        }
        return try await session.launch(request)
    }

    /// Ends only the session and app window that own the requested package.
    public func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        guard let session = sessions[request.packageID.rawValue] else {
            throw Self.sessionUnavailable(request.packageID.rawValue)
        }
        return try await session.terminate(request)
    }

    private static func sessionUnavailable(_ packageID: String) -> RuntimeWireError {
        .runtime(
            "sessionNotFound",
            message: "No open app window owns \(packageID).",
            remediation: "Open the app with `apkrun dev launch`, then retry."
        )
    }
}
