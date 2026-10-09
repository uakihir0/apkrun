/// The closed set of unified logging subsystems used by APKRun.
public enum LogSubsystem: String, CaseIterable, Sendable {
    /// Runtime daemon lifecycle and service operations.
    case runtime = "io.apkrun.runtime"

    /// Virtual machine lifecycle and device operations.
    case vm = "io.apkrun.vm"

    /// Graphics device and renderer operations.
    case graphics = "io.apkrun.graphics"

    /// Host input translation and routing.
    case input = "io.apkrun.input"

    /// Runtime image installation and verification.
    case image = "io.apkrun.image"

    /// Android package store operations.
    case store = "io.apkrun.store"

    /// Android app update operations.
    case update = "io.apkrun.update"

    /// Mac wrapper generation and lifecycle.
    case wrapper = "io.apkrun.wrapper"

    /// Host and guest desktop integrations.
    case integration = "io.apkrun.integration"

    /// APKRun and Android image maintenance.
    case maintenance = "io.apkrun.maintenance"

    /// Main APKRun application UI.
    case ui = "io.apkrun.ui"

    /// Menu bar application.
    case menubar = "io.apkrun.menubar"

    /// Command line client.
    case cli = "io.apkrun.cli"

    /// Shared diagnostics services.
    case diagnostics = "io.apkrun.diagnostics"
}

/// Categories for `io.apkrun.runtime`.
public enum RuntimeLogCategory: String, CaseIterable, Sendable {
    /// Service startup and host requirements.
    case host

    /// Runtime supervision.
    case supervisor

    /// Guest agent lifecycle.
    case agents

    /// Idle shutdown and suspend.
    case idle

    /// Host sleep and wake.
    case power

    /// Android app sessions.
    case sessions

    /// Display allocation.
    case display

    /// XPC service traffic.
    case xpc

    /// The developer's ADB client and its boot signals (development builds, #015).
    case adb

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.runtime
}

/// Categories for `io.apkrun.vm`.
public enum VMLogCategory: String, CaseIterable, Sendable {
    /// VM lifecycle.
    case lifecycle

    /// VM configuration.
    case config

    /// Serial console.
    case console

    /// Virtio socket connections.
    case vsock

    /// VM networking.
    case network

    /// Virtio devices.
    case virtio

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.vm
}

/// Categories for `io.apkrun.graphics`.
public enum GraphicsLogCategory: String, CaseIterable, Sendable {
    /// Virtual GPU device.
    case device

    /// Renderer initialization and health.
    case renderer

    /// Frame presentation.
    case present

    /// Graphics statistics.
    case stats

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.graphics
}

/// Categories for `io.apkrun.input`.
public enum InputLogCategory: String, CaseIterable, Sendable {
    /// Input event translation.
    case translate

    /// Input routing.
    case route

    /// Input method editor traffic.
    case ime

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.input
}

/// Categories for `io.apkrun.image`.
public enum ImageLogCategory: String, CaseIterable, Sendable {
    /// Image store operations.
    case store

    /// Image installation.
    case install

    /// Image integrity verification.
    case verify

    /// Runtime image instances.
    case instance

    /// Android image boot.
    case boot

    /// Image migration.
    case migration

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.image
}

/// Categories for `io.apkrun.store`.
public enum StoreLogCategory: String, CaseIterable, Sendable {
    /// Package import.
    case `import`

    /// Package transactions.
    case transaction

    /// Package update channels.
    case channel

    /// Reconciliation with Android.
    case reconcile

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.store
}

/// Categories for `io.apkrun.update`.
public enum UpdateLogCategory: String, CaseIterable, Sendable {
    /// Update scheduling.
    case scheduler

    /// Update source providers.
    case provider

    /// Candidate validation.
    case validate

    /// APK installation.
    case install

    /// Post-install health checks.
    case health

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.update
}

/// Categories for `io.apkrun.wrapper`.
public enum WrapperLogCategory: String, CaseIterable, Sendable {
    /// Wrapper generation.
    case generate

    /// Local code signing.
    case sign

    /// Icon conversion.
    case icon

    /// Wrapper registry.
    case registry

    /// Wrapper approval.
    case approval

    /// Wrapper refresh and lifecycle.
    case lifecycle

    /// Launcher startup.
    case launcher

    /// Wrapper window operations.
    case window

    /// App integration adapters.
    case integration

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.wrapper
}

/// Categories for `io.apkrun.integration`.
public enum IntegrationLogCategory: String, CaseIterable, Sendable {
    /// Clipboard integration.
    case clipboard

    /// Notification integration.
    case notifications

    /// Link forwarding.
    case links

    /// File transfer.
    case files

    /// Audio and microphone integration.
    case audio

    /// Locale synchronization.
    case locale

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.integration
}

/// Categories for `io.apkrun.maintenance`.
public enum MaintenanceLogCategory: String, CaseIterable, Sendable {
    /// APKRun self-update.
    case selfUpdate

    /// Android image update.
    case imageUpdate

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.maintenance
}

/// Categories for `io.apkrun.ui`.
public enum UILogCategory: String, CaseIterable, Sendable {
    /// Main application UI.
    case app

    /// First-run setup.
    case onboarding

    /// User operations.
    case operations

    /// Authorization prompts.
    case approval

    /// Settings UI.
    case settings

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.ui
}

/// Categories for `io.apkrun.menubar`.
public enum MenuBarLogCategory: String, CaseIterable, Sendable {
    /// Menu bar status.
    case status

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.menubar
}

/// Categories for `io.apkrun.cli`.
public enum CLILogCategory: String, CaseIterable, Sendable {
    /// CLI command lifecycle.
    case command

    /// Runtime client requests.
    case client

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.cli
}

/// Categories for `io.apkrun.diagnostics`.
public enum DiagnosticsLogCategory: String, CaseIterable, Sendable {
    /// Health checks.
    case health

    /// Diagnostics bundle creation.
    case bundle

    /// Performance markers.
    case perf

    /// Redaction.
    case redaction

    /// The owning logging subsystem.
    public static let subsystem = LogSubsystem.diagnostics
}
