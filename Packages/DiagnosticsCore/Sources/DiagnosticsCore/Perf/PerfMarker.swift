import Foundation

/// A stable lifecycle marker from the diagnostics performance catalogue.
public struct PerfMarker: RawRepresentable, Hashable, Sendable, CaseIterable {
    public let rawValue: String

    static let unknown = PerfMarker(rawValue: "UNKNOWN")

    let subsystem: LogSubsystem

    public init(rawValue: String) {
        self.rawValue = rawValue
        self.subsystem = Self.subsystem(for: rawValue)
    }

    public static let daemonReady = PerfMarker(rawValue: "DAEMON_READY")
    public static let vmStart = PerfMarker(rawValue: "VM_START")
    public static let kernelStart = PerfMarker(rawValue: "KERNEL_START")
    public static let androidInit = PerfMarker(rawValue: "ANDROID_INIT")
    public static let systemServerReady = PerfMarker(rawValue: "SYSTEM_SERVER_READY")
    public static let bootCompleted = PerfMarker(rawValue: "BOOT_COMPLETED")
    public static let agentConnected = PerfMarker(rawValue: "AGENT_CONNECTED")
    public static let runtimeReady = PerfMarker(rawValue: "RUNTIME_READY")
    public static let vmPaused = PerfMarker(rawValue: "VM_PAUSED")
    public static let vmResumed = PerfMarker(rawValue: "VM_RESUMED")
    public static let wrapperProcessStart = PerfMarker(rawValue: "WRAPPER_PROCESS_START")
    public static let appLaunchRequest = PerfMarker(rawValue: "APP_LAUNCH_REQUEST")
    public static let displayAttached = PerfMarker(rawValue: "DISPLAY_ATTACHED")
    public static let activityStarted = PerfMarker(rawValue: "ACTIVITY_STARTED")
    public static let firstFrame = PerfMarker(rawValue: "FIRST_FRAME")
    public static let firstFrameDisplayed = PerfMarker(rawValue: "FIRST_FRAME_DISPLAYED")
    public static let wrapperGenerateStart = PerfMarker(rawValue: "WRAPPER_GENERATE_START")
    public static let wrapperGenerateEnd = PerfMarker(rawValue: "WRAPPER_GENERATE_END")
    public static let wrapperRefreshEnd = PerfMarker(rawValue: "WRAPPER_REFRESH_END")
    public static let wrapperApprovalEnd = PerfMarker(rawValue: "WRAPPER_APPROVAL_END")
    public static let packageImportStart = PerfMarker(rawValue: "PACKAGE_IMPORT_START")
    public static let packageInspected = PerfMarker(rawValue: "PACKAGE_INSPECTED")
    public static let packageInstallStart = PerfMarker(rawValue: "PACKAGE_INSTALL_START")
    public static let packageInstallComplete = PerfMarker(rawValue: "PACKAGE_INSTALL_COMPLETE")
    public static let packageRollbackComplete = PerfMarker(rawValue: "PACKAGE_ROLLBACK_COMPLETE")
    public static let updateCheckStart = PerfMarker(rawValue: "UPDATE_CHECK_START")
    public static let updateCheckEnd = PerfMarker(rawValue: "UPDATE_CHECK_END")
    public static let updateDownloadStart = PerfMarker(rawValue: "UPDATE_DOWNLOAD_START")
    public static let updateDownloadEnd = PerfMarker(rawValue: "UPDATE_DOWNLOAD_END")
    public static let updateInstallStart = PerfMarker(rawValue: "UPDATE_INSTALL_START")
    public static let updateInstallEnd = PerfMarker(rawValue: "UPDATE_INSTALL_END")
    public static let updateHealthEnd = PerfMarker(rawValue: "UPDATE_HEALTH_END")
    public static let updateRollbackEnd = PerfMarker(rawValue: "UPDATE_ROLLBACK_END")
    public static let clipboardPush = PerfMarker(rawValue: "CLIPBOARD_PUSH")
    public static let notificationDelivered = PerfMarker(rawValue: "NOTIFICATION_DELIVERED")
    public static let fileTransfer = PerfMarker(rawValue: "FILE_TRANSFER")
    public static let selfUpdateCheckEnd = PerfMarker(rawValue: "SELF_UPDATE_CHECK_END")
    public static let hostUpdatePrepareStart = PerfMarker(rawValue: "HOST_UPDATE_PREPARE_START")
    public static let hostUpdatePrepared = PerfMarker(rawValue: "HOST_UPDATE_PREPARED")
    public static let hostUpdated = PerfMarker(rawValue: "HOST_UPDATED")
    public static let imageCheckEnd = PerfMarker(rawValue: "IMAGE_CHECK_END")
    public static let imageDownloadStart = PerfMarker(rawValue: "IMAGE_DOWNLOAD_START")
    public static let imageDownloadEnd = PerfMarker(rawValue: "IMAGE_DOWNLOAD_END")
    public static let imageInstallEnd = PerfMarker(rawValue: "IMAGE_INSTALL_END")
    public static let imageMigrationStart = PerfMarker(rawValue: "IMAGE_MIGRATION_START")
    public static let imageMigrationEnd = PerfMarker(rawValue: "IMAGE_MIGRATION_END")
    public static let imageRollbackEnd = PerfMarker(rawValue: "IMAGE_ROLLBACK_END")

    public static let allCases: [PerfMarker] = [
        .daemonReady,
        .vmStart,
        .kernelStart,
        .androidInit,
        .systemServerReady,
        .bootCompleted,
        .agentConnected,
        .runtimeReady,
        .vmPaused,
        .vmResumed,
        .wrapperProcessStart,
        .appLaunchRequest,
        .displayAttached,
        .activityStarted,
        .firstFrame,
        .firstFrameDisplayed,
        .wrapperGenerateStart,
        .wrapperGenerateEnd,
        .wrapperRefreshEnd,
        .wrapperApprovalEnd,
        .packageImportStart,
        .packageInspected,
        .packageInstallStart,
        .packageInstallComplete,
        .packageRollbackComplete,
        .updateCheckStart,
        .updateCheckEnd,
        .updateDownloadStart,
        .updateDownloadEnd,
        .updateInstallStart,
        .updateInstallEnd,
        .updateHealthEnd,
        .updateRollbackEnd,
        .clipboardPush,
        .notificationDelivered,
        .fileTransfer,
        .selfUpdateCheckEnd,
        .hostUpdatePrepareStart,
        .hostUpdatePrepared,
        .hostUpdated,
        .imageCheckEnd,
        .imageDownloadStart,
        .imageDownloadEnd,
        .imageInstallEnd,
        .imageMigrationStart,
        .imageMigrationEnd,
        .imageRollbackEnd,
    ]

    public static func == (lhs: PerfMarker, rhs: PerfMarker) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }

    private static func subsystem(for rawValue: String) -> LogSubsystem {
        switch rawValue {
        case "VM_START":
            .vm
        case "WRAPPER_PROCESS_START",
             "APP_LAUNCH_REQUEST",
             "WRAPPER_GENERATE_START",
             "WRAPPER_GENERATE_END",
             "WRAPPER_REFRESH_END",
             "WRAPPER_APPROVAL_END":
            .wrapper
        case "PACKAGE_IMPORT_START",
             "PACKAGE_INSPECTED",
             "PACKAGE_INSTALL_START",
             "PACKAGE_INSTALL_COMPLETE",
             "PACKAGE_ROLLBACK_COMPLETE":
            .store
        case "UPDATE_CHECK_START",
             "UPDATE_CHECK_END",
             "UPDATE_DOWNLOAD_START",
             "UPDATE_DOWNLOAD_END",
             "UPDATE_INSTALL_START",
             "UPDATE_INSTALL_END",
             "UPDATE_HEALTH_END",
             "UPDATE_ROLLBACK_END":
            .update
        case "CLIPBOARD_PUSH", "NOTIFICATION_DELIVERED", "FILE_TRANSFER":
            .integration
        case "SELF_UPDATE_CHECK_END",
             "HOST_UPDATE_PREPARE_START",
             "HOST_UPDATE_PREPARED",
             "HOST_UPDATED",
             "IMAGE_CHECK_END",
             "IMAGE_DOWNLOAD_START",
             "IMAGE_DOWNLOAD_END",
             "IMAGE_INSTALL_END",
             "IMAGE_MIGRATION_START",
             "IMAGE_MIGRATION_END",
             "IMAGE_ROLLBACK_END":
            .maintenance
        case "DAEMON_READY",
             "KERNEL_START",
             "ANDROID_INIT",
             "SYSTEM_SERVER_READY",
             "BOOT_COMPLETED",
             "AGENT_CONNECTED",
             "RUNTIME_READY",
             "VM_PAUSED",
             "VM_RESUMED",
             "DISPLAY_ATTACHED",
             "ACTIVITY_STARTED",
             "FIRST_FRAME",
             "FIRST_FRAME_DISPLAYED":
            .runtime
        default:
            .diagnostics
        }
    }
}
