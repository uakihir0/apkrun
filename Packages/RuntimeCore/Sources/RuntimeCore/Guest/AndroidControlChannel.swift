import GuestProtocol

/// Android operations used by runtime clients (guest-protocol.md §7.1, §13.1).
///
/// The implementation sends typed GuestProtocol operations over the Guest Agent control connection. ADB remains
/// available for provisioning, package installation, and development diagnostics; it is not a control channel.
public protocol AndroidControlChannel: Sendable {
    /// Launches a package on the requested Android display.
    func launch(package: String, displayID: Int32) async throws(GuestAgentFailure) -> GuestLaunchReport

    /// Finishes every task for a package without force-stopping its process.
    func stopApplication(package: String) async throws(GuestAgentFailure) -> Bool

    /// Force-stops every task and process for a package.
    func forceStopApplication(package: String) async throws(GuestAgentFailure) -> Bool

    /// Moves Android's global task focus to the top task on one display.
    func focusDisplay(displayID: Int32) async throws(GuestAgentFailure)

    /// Moves one Android task to another display.
    func moveTask(taskID: Int32, toDisplay displayID: Int32, toBack: Bool) async throws(GuestAgentFailure)

    /// Lists tasks on one display, or on all displays when `displayID` is `nil`.
    func listTasks(displayID: Int32?) async throws(GuestAgentFailure) -> [GPTaskInfo]

    /// Queries PackageManager for one package. Returns `nil` when the package is not installed.
    func queryPackage(_ package: String) async throws(GuestAgentFailure) -> GPPackageInfo?

    /// Lists installed packages matching the requested filter.
    func listPackages(filter: GPPackageFilter) async throws(GuestAgentFailure) -> [GPPackageSummary]

    /// Reads the health of the Guest Agent and Android system.
    func getHealth() async throws(GuestAgentFailure) -> GPHealth

    /// Requests an orderly Android shutdown.
    func shutdown(reason: String) async throws(GuestAgentFailure)
}

extension AndroidControlChannel {
    /// Returns whether PackageManager reports this package as installed.
    public func isInstalled(_ package: String) async throws(GuestAgentFailure) -> Bool {
        try await queryPackage(package) != nil
    }
}
