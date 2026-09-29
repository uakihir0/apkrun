import Foundation
import OSLog

/// Emits lifecycle performance markers and high-frequency signpost intervals.
public enum Perf {
    /// The process-wide marker timeline.
    public static let timeline = PerfTimeline()

    private enum AttributeKind {
        case agent
        case boolean
        case bootKind
        case count
        case duration
        case text
    }

    private static let maximumAttributeCount = 16
    private static let maximumAttributeKeyBytes = 64
    private static let maximumStringValueBytes = 256
    private static let maximumDurationMilliseconds = 604_800_000.0
    private static let maximumCount: Int64 = 1_000_000_000_000_000

    private static let signposters = Dictionary(
        uniqueKeysWithValues: LogSubsystem.allCases.map { subsystem in
            (
                subsystem.rawValue,
                OSSignposter(
                    subsystem: subsystem.rawValue,
                    category: .pointsOfInterest
                )
            )
        }
    )

    /// Emits a signpost event and appends it to the selected in-memory timeline.
    public static func mark(
        _ marker: PerfMarker,
        at time: ContinuousClock.Instant = .now,
        _ attributes: [String: PerfValue] = [:],
        timeline: PerfTimeline = Perf.timeline
    ) {
        let marker = PerfMarker.allCases.contains(marker) ? marker : .unknown
        let event = PerfEvent(
            marker: marker,
            time: time,
            attributes: boundedAttributes(attributes, for: marker),
            operationContext: OperationContext.current
        )
        timeline.append(event)

        let signposter = signposter(for: marker.subsystem)
        let baseFields = baseSignpostFields(for: event).joined(separator: " ")
        let emittedAt = ContinuousClock().now
        let offset = sourceTimeOffsetMilliseconds(from: event.time, to: emittedAt)
        let message = "\(baseFields) sourceTimeOffsetMsAtSample=\(offset)"
        signposter.emitEvent("APKRunPerfMarker", "\(message, privacy: .public)")
    }

    /// Measures an async operation with a signpost interval and no timeline entry.
    public static func interval<Result>(
        _ name: StaticString,
        _ body: () async throws -> Result
    ) async rethrows -> Result {
        let signposter = signposter(for: intervalSubsystem(for: String(describing: name)))
        let state = signposter.beginInterval(name)
        defer {
            signposter.endInterval(name, state)
        }
        return try await body()
    }

    private static func signposter(for subsystem: LogSubsystem) -> OSSignposter {
        signposters[subsystem.rawValue]!
    }

    static func intervalSubsystem(for name: String) -> LogSubsystem {
        if name.hasPrefix("gpu.") {
            .graphics
        } else if name.hasPrefix("input.") {
            .input
        } else {
            .diagnostics
        }
    }

    private static func boundedAttributes(
        _ attributes: [String: PerfValue],
        for marker: PerfMarker
    ) -> [String: PerfValue] {
        guard attributes.count <= maximumAttributeCount else {
            return [:]
        }

        let schema = attributeSchema(for: marker)
        var bounded: [String: PerfValue] = [:]
        for key in attributes.keys.sorted() {
            guard
                key.utf8.count <= maximumAttributeKeyBytes,
                key.utf8.allSatisfy(isAllowedKeyByte),
                let kind = schema[key],
                let value = attributes[key],
                isValid(value, as: kind)
            else {
                continue
            }
            bounded[key] = value
        }
        return bounded
    }

    private static func attributeSchema(for marker: PerfMarker) -> [String: AttributeKind] {
        switch marker.rawValue {
        case "DAEMON_READY":
            ["startupMs": .duration, "recoverySteps": .count]
        case "VM_START":
            ["bootKind": .bootKind]
        case "AGENT_CONNECTED":
            ["agent": .agent]
        case "RUNTIME_READY":
            ["bootMs": .duration]
        case "VM_RESUMED":
            ["pausedMs": .duration]
        case "APP_LAUNCH_REQUEST":
            ["xpcDelayMs": .duration]
        case "DISPLAY_ATTACHED":
            ["slot": .count, "displayID": .text, "reused": .boolean]
        case "ACTIVITY_STARTED":
            ["processStarted": .boolean]
        case "WRAPPER_GENERATE_START", "WRAPPER_GENERATE_END", "WRAPPER_REFRESH_END", "WRAPPER_APPROVAL_END":
            ["result": .text, "durationMs": .duration, "kind": .text]
        case "PACKAGE_IMPORT_START", "PACKAGE_INSPECTED", "PACKAGE_INSTALL_START",
             "PACKAGE_INSTALL_COMPLETE", "PACKAGE_ROLLBACK_COMPLETE":
            ["bytes": .count, "splits": .count, "status": .text]
        case "UPDATE_CHECK_START", "UPDATE_CHECK_END", "UPDATE_DOWNLOAD_START",
             "UPDATE_DOWNLOAD_END", "UPDATE_INSTALL_START", "UPDATE_INSTALL_END",
             "UPDATE_HEALTH_END", "UPDATE_ROLLBACK_END":
            ["provider": .text, "result": .text, "bytes": .count]
        case "CLIPBOARD_PUSH", "NOTIFICATION_DELIVERED", "FILE_TRANSFER":
            ["durationMs": .duration, "bytes": .count]
        case "SELF_UPDATE_CHECK_END", "HOST_UPDATE_PREPARE_START", "HOST_UPDATE_PREPARED", "HOST_UPDATED":
            ["result": .text, "fromBuild": .text, "toBuild": .text, "durationMs": .duration]
        case "IMAGE_CHECK_END", "IMAGE_DOWNLOAD_START", "IMAGE_DOWNLOAD_END", "IMAGE_INSTALL_END",
             "IMAGE_MIGRATION_START", "IMAGE_MIGRATION_END", "IMAGE_ROLLBACK_END":
            ["imageVersion": .text, "result": .text, "bytes": .count, "durationMs": .duration]
        default:
            [:]
        }
    }

    private static func isValid(_ value: PerfValue, as kind: AttributeKind) -> Bool {
        switch (kind, value) {
        case let (.duration, .integer(value)):
            value >= 0 && Double(value) <= maximumDurationMilliseconds
        case let (.duration, .double(value)):
            value.isFinite && value >= 0 && value <= maximumDurationMilliseconds
        case let (.count, .integer(value)):
            value >= 0 && value <= maximumCount
        case (.boolean, .boolean):
            true
        case let (.bootKind, .string(value)):
            ["cold", "firstBoot", "migration"].contains(value)
                && value.utf8.count <= maximumStringValueBytes
        case let (.agent, .string(value)):
            ["guest", "store"].contains(value)
                && value.utf8.count <= maximumStringValueBytes
        case let (.text, .string(value)):
            value.utf8.count <= maximumStringValueBytes
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        default:
            false
        }
    }

    private static func isAllowedKeyByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 95, 97...122:
            true
        default:
            false
        }
    }

    static func signpostFields(for event: PerfEvent) -> String {
        let baseFields = baseSignpostFields(for: event).joined(separator: " ")
        let emittedAt = ContinuousClock().now
        return signpostFields(for: event, baseFields: baseFields, emittedAt: emittedAt)
    }

    static func signpostFields(
        for event: PerfEvent,
        emittedAt: ContinuousClock.Instant
    ) -> String {
        let baseFields = baseSignpostFields(for: event).joined(separator: " ")
        return signpostFields(for: event, baseFields: baseFields, emittedAt: emittedAt)
    }

    private static func signpostFields(
        for event: PerfEvent,
        baseFields: String,
        emittedAt: ContinuousClock.Instant
    ) -> String {
        let offset = sourceTimeOffsetMilliseconds(from: event.time, to: emittedAt)
        return "\(baseFields) sourceTimeOffsetMsAtSample=\(offset)"
    }

    private static func baseSignpostFields(for event: PerfEvent) -> [String] {
        let markerName = PerfMarker.allCases.contains(event.marker) ? event.marker.rawValue : "UNKNOWN"
        var fields = ["marker=\(markerName)"]

        if let context = event.operationContext {
            fields.append("op=\(context.operationID.short)")
            if let parent = context.parent {
                fields.append("parent=\(parent.short)")
            }
        }

        for (key, value) in boundedAttributes(event.attributes, for: event.marker).sorted(by: { $0.key < $1.key }) {
            guard let publicValue = publicSignpostValue(for: key, value: value) else {
                continue
            }
            fields.append("\(key)=\(publicValue)")
        }
        return fields
    }

    private static func publicSignpostValue(for key: String, value: PerfValue) -> String? {
        switch value {
        case let .string(value):
            switch (key, value) {
            case ("agent", "guest"), ("agent", "store"),
                 ("bootKind", "cold"), ("bootKind", "firstBoot"), ("bootKind", "migration"):
                String(reflecting: value)
            default:
                nil
            }
        case .integer, .double, .boolean:
            value.signpostValue
        }
    }

    private static func sourceTimeOffsetMilliseconds(
        from sourceTime: ContinuousClock.Instant,
        to emittedAt: ContinuousClock.Instant
    ) -> Double {
        let components = sourceTime.duration(to: emittedAt).components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }
}
