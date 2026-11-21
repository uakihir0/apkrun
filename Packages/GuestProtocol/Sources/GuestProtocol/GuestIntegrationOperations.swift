import Foundation

/// SetClipboard, guest protocol operation 40 (guest-protocol.md §7.1,
/// desktop-integration.md §4.2). The guest answers `Empty`; the ClipAck the
/// window waits for carries the seq the host coordinator allocated.
public struct GuestSetClipboard: GuestOperation {
    /// The guest acknowledges the write with `Empty`.
    public typealias Result = GPEmpty
    /// The stable guest protocol operation number.
    public static let number = 40

    /// The clip to set on the Android clipboard.
    public let clip: GPClipData

    /// Creates a set-clipboard request.
    public init(clip: GPClipData) {
        self.clip = clip
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "SetClipboard" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .clipboardText }
    /// The per-call timeout; paste waits on the ClipAck for 500 ms (§4.5).
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        .setClipboard(clip)
    }

    /// Extracts the empty acknowledgement.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .setClipboard(let empty) = result { return empty }
        return nil
    }
}

/// ActivateNotification, guest protocol operation 41 (guest-protocol.md §7.5,
/// desktop-integration.md §5.4). Sends the content or action intent on the
/// session's display; `notFound` means the notification has gone.
public struct GuestActivateNotification: GuestOperation {
    /// The guest acknowledges the intent with `Empty`.
    public typealias Result = GPEmpty
    /// The stable guest protocol operation number.
    public static let number = 41

    /// The StatusBarNotification key.
    public let key: String
    /// The action to fire; nil fires the content intent.
    public let actionIndex: Int32?
    /// The launch display.
    public let displayID: Int32

    /// Creates an activate-notification request.
    public init(key: String, actionIndex: Int32?, displayID: Int32) {
        self.key = key
        self.actionIndex = actionIndex
        self.displayID = displayID
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "ActivateNotification" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .notifications }
    /// The per-call timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPActivateNotification()
        request.key = key
        if let actionIndex {
            request.actionIndex = actionIndex
        }
        request.displayID = displayID
        return .activateNotification(request)
    }

    /// Extracts the empty acknowledgement.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .activateNotification(let empty) = result { return empty }
        return nil
    }
}

/// DismissNotification, guest protocol operation 42 (guest-protocol.md §7.5,
/// desktop-integration.md §5.4). Cancels the notification on Android.
public struct GuestDismissNotification: GuestOperation {
    /// The guest acknowledges the cancel with `Empty`.
    public typealias Result = GPEmpty
    /// The stable guest protocol operation number.
    public static let number = 42

    /// The StatusBarNotification key.
    public let key: String

    /// Creates a dismiss-notification request.
    public init(key: String) {
        self.key = key
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "DismissNotification" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .notifications }
    /// The per-call timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPDismissNotification()
        request.key = key
        return .dismissNotification(request)
    }

    /// Extracts the empty acknowledgement.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .dismissNotification(let empty) = result { return empty }
        return nil
    }
}

/// SetNotificationForwarding, guest protocol operation 43 (guest-protocol.md
/// §7.5, desktop-integration.md §5.1). Replaces the forwarding allowlist; the
/// agent re-sends every active forwarded notification with `replay = true`.
public struct GuestSetNotificationForwarding: GuestOperation {
    /// The guest acknowledges the list with `Empty`.
    public typealias Result = GPEmpty
    /// The stable guest protocol operation number.
    public static let number = 43

    /// The packages whose notifications may leave the guest.
    public let packages: [String]

    /// Creates a set-forwarding request.
    public init(packages: [String]) {
        self.packages = packages
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "SetNotificationForwarding" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .notifications }
    /// The per-call timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPSetNotificationForwarding()
        request.packages = packages
        return .setNotificationForwarding(request)
    }

    /// Extracts the empty acknowledgement.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .setNotificationForwarding(let empty) = result { return empty }
        return nil
    }
}

/// SetUrlRedirect, guest protocol operation 44 (guest-protocol.md §7.1,
/// desktop-integration.md §3.2). `enabled` is the global links switch;
/// `excludedPackages` are the packages whose `integrations.links` value keeps
/// links inside Android (`android` or `off`). The agent recomputes its
/// browser-role answer from the push.
public struct GuestSetUrlRedirect: GuestOperation {
    /// The guest acknowledges the set with `Empty`.
    public typealias Result = GPEmpty
    /// The stable guest protocol operation number.
    public static let number = 44

    /// The global `integrations.enabled.links` switch.
    public let enabled: Bool
    /// The packages that keep links inside Android.
    public let excludedPackages: [String]

    /// Creates a set-redirect request.
    public init(enabled: Bool, excludedPackages: [String]) {
        self.enabled = enabled
        self.excludedPackages = excludedPackages
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "SetUrlRedirect" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .url }
    /// The per-call timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPSetUrlRedirect()
        request.enabled = enabled
        request.excludedPackages = excludedPackages
        return .setURLRedirect(request)
    }

    /// Extracts the empty acknowledgement.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .setURLRedirect(let empty) = result { return empty }
        return nil
    }
}

/// ResolveUrl, guest protocol operation 50 (guest-protocol.md §7.1,
/// desktop-integration.md §7.2). Answers one `OpenUrlOnHost` event: the host
/// opened it (`openedOnHost`), Android should open the kept intent
/// (`openInGuest`), or the link is dropped (`drop`).
public struct GuestResolveUrl: GuestOperation {
    /// The guest acknowledges the answer with `Empty`.
    public typealias Result = GPEmpty
    /// The stable guest protocol operation number.
    public static let number = 50

    /// The `OpenUrlOnHost.request_id` being answered.
    public let requestID: UInt64
    /// What the host did with the link.
    public let action: GPUrlAction

    /// Creates a resolve-url request.
    public init(requestID: UInt64, action: GPUrlAction) {
        self.requestID = requestID
        self.action = action
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "ResolveUrl" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .url }
    /// The per-call timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPResolveUrl()
        request.requestID = requestID
        request.action = action
        return .resolveURL(request)
    }

    /// Extracts the empty acknowledgement.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .resolveURL(let empty) = result { return empty }
        return nil
    }
}

/// ImportFiles, guest protocol operation 45 (guest-protocol.md §7.4,
/// desktop-integration.md §6.2). Delivers the dropped files the bulk
/// transfers carried: each `FileRef.transfer_id` names a completed
/// host-allocated `.file` transfer.
public struct GuestImportFiles: GuestOperation {
    /// The guest answers with `ImportResult`.
    public typealias Result = GPImportResult
    /// The stable guest protocol operation number.
    public static let number = 45

    /// The package that receives the share intents.
    public let package: String
    /// The display the drop landed on.
    public let displayID: Int32
    /// The announced transfers, one per dropped file.
    public let files: [GPFileRef]

    /// Creates an import-files request.
    public init(package: String, displayID: Int32, files: [GPFileRef]) {
        self.package = package
        self.displayID = displayID
        self.files = files
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "ImportFiles" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .files }
    /// The per-call timeout; share resolution can take a moment.
    public var timeout: Duration { .seconds(10) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPImportFiles()
        request.target = .shareToPackage
        request.package = package
        request.displayID = displayID
        request.files = files
        return .importFiles(request)
    }

    /// Extracts the import result.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPImportResult? {
        if case .importFiles(let result) = result { return result }
        return nil
    }
}

/// ResolveExport, guest protocol operation 51 (guest-protocol.md §7.5,
/// desktop-integration.md §6.3). Answers one `ExportFileOffered` event:
/// accept replies `ExportStart` carrying the transfer ID the agent then
/// streams on the bulk channel; decline carries no transfer.
public struct GuestResolveExport: GuestOperation {
    /// The guest answers with `ExportStart`.
    public typealias Result = GPExportStart
    /// The stable guest protocol operation number.
    public static let number = 51

    /// The `ExportFileOffered.offer_id` being answered.
    public let offerID: UInt64
    /// The user's answer.
    public let decision: GPExportDecision

    /// Creates a resolve-export request.
    public init(offerID: UInt64, decision: GPExportDecision) {
        self.offerID = offerID
        self.decision = decision
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "ResolveExport" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .files }
    /// The per-call timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPResolveExport()
        request.offerID = offerID
        request.decision = decision
        return .resolveExport(request)
    }

    /// Extracts the export start.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPExportStart? {
        if case .resolveExport(let start) = result { return start }
        return nil
    }
}

/// SetSharedFolderAccess, guest protocol operation 52
/// (guest-protocol.md §7.5, desktop-integration.md §6.4). Pushes the
/// per-package access map the `MacFilesProvider` enforces.
public struct GuestSetSharedFolderAccess: GuestOperation {
    /// The guest acknowledges with `Empty`.
    public typealias Result = GPEmpty
    /// The stable guest protocol operation number.
    public static let number = 52

    /// The current roots (the provider validates root IDs against them).
    public let roots: [GPSharedRoot]
    /// Package → access (`readOnly` or `readWrite`); absent entries get
    /// SecurityException in the provider.
    public let access: [String: String]

    /// Creates a set-access request.
    public init(roots: [GPSharedRoot], access: [String: String]) {
        self.roots = roots
        self.access = access
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "SetSharedFolderAccess" }
    /// The Guest Agent capability required for this operation.
    public var capability: GuestCapability { .filesShared }
    /// The per-call timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the versioned wire request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPSetSharedFolderAccess()
        request.roots = roots
        request.access = access.map { package, level in
            var entry = GPPackageAccess()
            entry.package = package
            entry.access = level == "readWrite" ? .readWrite : .readOnly
            return entry
        }
        return .setSharedFolderAccess(request)
    }

    /// Extracts the empty acknowledgement.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .setSharedFolderAccess(let empty) = result { return empty }
        return nil
    }
}
