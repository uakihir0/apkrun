import Foundation

/// A stable lifecycle marker from the diagnostics performance catalogue.
public struct PerfMarker: RawRepresentable, Hashable, Sendable, CaseIterable {
    /// The stable wire name used in diagnostics output.
    public let rawValue: String

    static let unknown = PerfMarker(rawValue: "UNKNOWN")

    let subsystem: LogSubsystem

    /// Creates a marker from its stable wire name.
    public init(rawValue: String) {
        self.rawValue = rawValue
        self.subsystem = Self.subsystem(for: rawValue)
    }

    /// Marks when the APKRun background service becomes ready.
    public static let daemonReady = PerfMarker(rawValue: "DAEMON_READY")
    /// Marks the start of a virtual machine.
    public static let vmStart = PerfMarker(rawValue: "VM_START")
    /// Marks when the guest kernel begins execution.
    public static let kernelStart = PerfMarker(rawValue: "KERNEL_START")
    /// Marks when Android init begins.
    public static let androidInit = PerfMarker(rawValue: "ANDROID_INIT")
    /// Marks when Android's system server becomes ready.
    public static let systemServerReady = PerfMarker(rawValue: "SYSTEM_SERVER_READY")
    /// Marks when Android reports boot completion.
    public static let bootCompleted = PerfMarker(rawValue: "BOOT_COMPLETED")
    /// Marks when a guest agent connects.
    public static let agentConnected = PerfMarker(rawValue: "AGENT_CONNECTED")
    /// Marks when the runtime is ready for clients.
    public static let runtimeReady = PerfMarker(rawValue: "RUNTIME_READY")
    /// Marks when the virtual machine is paused.
    public static let vmPaused = PerfMarker(rawValue: "VM_PAUSED")
    /// Marks when the virtual machine resumes.
    public static let vmResumed = PerfMarker(rawValue: "VM_RESUMED")
    /// Marks when an app wrapper process starts.
    public static let wrapperProcessStart = PerfMarker(rawValue: "WRAPPER_PROCESS_START")
    /// Marks a client request to launch an Android app.
    public static let appLaunchRequest = PerfMarker(rawValue: "APP_LAUNCH_REQUEST")
    /// Marks when a guest display attaches to a host window.
    public static let displayAttached = PerfMarker(rawValue: "DISPLAY_ATTACHED")
    /// Marks when the Android activity starts.
    public static let activityStarted = PerfMarker(rawValue: "ACTIVITY_STARTED")
    /// Marks when Android produces the first frame.
    public static let firstFrame = PerfMarker(rawValue: "FIRST_FRAME")
    /// Marks when the first Android frame appears in the host window.
    public static let firstFrameDisplayed = PerfMarker(rawValue: "FIRST_FRAME_DISPLAYED")
    /// Marks the start of wrapper generation.
    public static let wrapperGenerateStart = PerfMarker(rawValue: "WRAPPER_GENERATE_START")
    /// Marks the completion of wrapper generation.
    public static let wrapperGenerateEnd = PerfMarker(rawValue: "WRAPPER_GENERATE_END")
    /// Marks the completion of a wrapper refresh.
    public static let wrapperRefreshEnd = PerfMarker(rawValue: "WRAPPER_REFRESH_END")
    /// Marks the completion of a wrapper approval operation.
    public static let wrapperApprovalEnd = PerfMarker(rawValue: "WRAPPER_APPROVAL_END")
    /// Marks the start of an APK import.
    public static let packageImportStart = PerfMarker(rawValue: "PACKAGE_IMPORT_START")
    /// Marks completion of APK inspection.
    public static let packageInspected = PerfMarker(rawValue: "PACKAGE_INSPECTED")
    /// Marks the start of package installation.
    public static let packageInstallStart = PerfMarker(rawValue: "PACKAGE_INSTALL_START")
    /// Marks successful completion of package installation.
    public static let packageInstallComplete = PerfMarker(rawValue: "PACKAGE_INSTALL_COMPLETE")
    /// Marks successful completion of a package rollback.
    public static let packageRollbackComplete = PerfMarker(rawValue: "PACKAGE_ROLLBACK_COMPLETE")
    /// Marks the start of an app update check.
    public static let updateCheckStart = PerfMarker(rawValue: "UPDATE_CHECK_START")
    /// Marks completion of an app update check.
    public static let updateCheckEnd = PerfMarker(rawValue: "UPDATE_CHECK_END")
    /// Marks the start of an app update download.
    public static let updateDownloadStart = PerfMarker(rawValue: "UPDATE_DOWNLOAD_START")
    /// Marks completion of an app update download.
    public static let updateDownloadEnd = PerfMarker(rawValue: "UPDATE_DOWNLOAD_END")
    /// Marks the start of an app update installation.
    public static let updateInstallStart = PerfMarker(rawValue: "UPDATE_INSTALL_START")
    /// Marks completion of an app update installation.
    public static let updateInstallEnd = PerfMarker(rawValue: "UPDATE_INSTALL_END")
    /// Marks completion of an app update health check.
    public static let updateHealthEnd = PerfMarker(rawValue: "UPDATE_HEALTH_END")
    /// Marks completion of an app update rollback.
    public static let updateRollbackEnd = PerfMarker(rawValue: "UPDATE_ROLLBACK_END")
    /// Marks a clipboard update sent to Android.
    public static let clipboardPush = PerfMarker(rawValue: "CLIPBOARD_PUSH")
    /// Marks delivery of an Android notification.
    public static let notificationDelivered = PerfMarker(rawValue: "NOTIFICATION_DELIVERED")
    /// Marks a host and guest file transfer.
    public static let fileTransfer = PerfMarker(rawValue: "FILE_TRANSFER")
    /// Marks completion of an APKRun self-update check.
    public static let selfUpdateCheckEnd = PerfMarker(rawValue: "SELF_UPDATE_CHECK_END")
    /// Marks the start of host update preparation.
    public static let hostUpdatePrepareStart = PerfMarker(rawValue: "HOST_UPDATE_PREPARE_START")
    /// Marks completion of host update preparation.
    public static let hostUpdatePrepared = PerfMarker(rawValue: "HOST_UPDATE_PREPARED")
    /// Marks that the host application update has completed.
    public static let hostUpdated = PerfMarker(rawValue: "HOST_UPDATED")
    /// Marks completion of the Android image update check.
    public static let imageCheckEnd = PerfMarker(rawValue: "IMAGE_CHECK_END")
    /// Marks the start of an Android image download.
    public static let imageDownloadStart = PerfMarker(rawValue: "IMAGE_DOWNLOAD_START")
    /// Marks completion of an Android image download.
    public static let imageDownloadEnd = PerfMarker(rawValue: "IMAGE_DOWNLOAD_END")
    /// Marks completion of an Android image installation.
    public static let imageInstallEnd = PerfMarker(rawValue: "IMAGE_INSTALL_END")
    /// Marks the start of Android data migration.
    public static let imageMigrationStart = PerfMarker(rawValue: "IMAGE_MIGRATION_START")
    /// Marks completion of Android data migration.
    public static let imageMigrationEnd = PerfMarker(rawValue: "IMAGE_MIGRATION_END")
    /// Marks completion of an Android image rollback.
    public static let imageRollbackEnd = PerfMarker(rawValue: "IMAGE_ROLLBACK_END")

    /// All stable markers in catalogue order.
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

    /// Compares markers by their stable wire names.
    public static func == (lhs: PerfMarker, rhs: PerfMarker) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    /// Hashes the stable wire name.
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
