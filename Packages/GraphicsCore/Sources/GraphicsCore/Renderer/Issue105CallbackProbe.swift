import Darwin
import DiagnosticsCore
import Foundation
import GraphicsBridge

final class Issue105ProbeBudget: @unchecked Sendable {
    static let shared = Issue105ProbeBudget()
    private let lock = NSLock()
    private var count = 0

    func take() -> Bool {
        lock.withLock {
            guard count < 16 else { return false }
            count += 1
            return true
        }
    }
}

final class Issue105CallbackProbe: @unchecked Sendable {
    private struct Active {
        let context: UInt32
        let ordinal: UInt64
        var resource: UInt32?
        var resourceCount = 0
        var dispatchCount = 0
        var ambiguous = false
    }

    private let lock = NSLock()
    private let owner = pthread_self()
    private let enabled: Bool
    private let budget: Issue105ProbeBudget
    private var active: Active?

    init(
        enabled: Bool = ProcessInfo.processInfo.environment["APKRUN_ISSUE_105_FIXTURE_PROBE"] == "1",
        budget: Issue105ProbeBudget = .shared
    ) {
        self.enabled = enabled
        self.budget = budget
    }

    func begin(context: UInt32, diagnostic: VirGLCommandDiagnostic?) {
        guard enabled, pthread_equal(owner, pthread_self()) != 0,
            let diagnostic, diagnostic.command == 519, diagnostic.contextID == context
        else { return }
        lock.withLock {
            if active != nil {
                active?.ambiguous = true
                return
            }
            active = Active(context: context, ordinal: diagnostic.ordinal)
        }
    }

    func record(_ message: UnsafePointer<CChar>, level: Int32) {
        lock.withLock {
            guard active != nil else { return }
            guard pthread_equal(owner, pthread_self()) != 0 else {
                active?.ambiguous = true
                return
            }
            guard level == GB_LOG_ERROR else { return }
            if let match = Self.parseResource(message) {
                active?.resourceCount += 1
                if match.context != active?.context || !(1...512).contains(match.resource) {
                    active?.ambiguous = true
                } else {
                    active?.resource = match.resource
                }
            } else if let context = Self.parseDispatch(message) {
                active?.dispatchCount += 1
                if context != active?.context { active?.ambiguous = true }
            } else {
                var prefix = Cursor(pointer: message)
                if prefix.consume("check_copy_transfer3d_handles:") {
                    active?.ambiguous = true
                } else {
                    prefix = Cursor(pointer: message)
                    if prefix.consume("context ") { active?.ambiguous = true }
                }
            }
        }
    }

    func finish(status: Int32, result: Int32, logger: APKLogger) {
        guard pthread_equal(owner, pthread_self()) != 0 else { return }
        let event: (UInt32, UInt64, UInt32?)? = lock.withLock {
            guard let current = active else { return nil }
            active = nil
            guard status != GB_OK, budget.take() else { return nil }
            let resource = result == 22 && !current.ambiguous && current.resourceCount == 1
                && current.dispatchCount == 1 ? current.resource : nil
            return (current.context, current.ordinal, resource)
        }
        guard let (context, ordinal, resource) = event else { return }
        let resourceField = resource.map(String.init) ?? "unattributed"
        logger.info("issue105_probe context_id=\(context, .public) control_ordinal=\(ordinal, .public) resource_id=\(resourceField, .public)")
    }

    private struct Cursor {
        var pointer: UnsafePointer<CChar>

        mutating func consume(_ literal: StaticString) -> Bool {
            for index in 0..<literal.utf8CodeUnitCount {
                guard pointer.pointee != 0, UInt8(bitPattern: pointer.pointee) == literal.utf8Start[index] else { return false }
                pointer = pointer.advanced(by: 1)
            }
            return true
        }

        mutating func number() -> UInt32? {
            var value: UInt32 = 0
            var digits = 0
            let leadingZero = pointer.pointee == 48
            while pointer.pointee >= 48 && pointer.pointee <= 57 {
                guard digits < 10, !leadingZero || digits == 0 else { return nil }
                let (scaled, overflow1) = value.multipliedReportingOverflow(by: 10)
                let (next, overflow2) = scaled.addingReportingOverflow(UInt32(pointer.pointee - 48))
                guard !overflow1, !overflow2 else { return nil }
                value = next
                digits += 1
                pointer = pointer.advanced(by: 1)
            }
            return digits > 0 ? value : nil
        }

        mutating func skipName() -> Bool {
            var length = 0
            while pointer.pointee != 0 && pointer.pointee != 34 {
                guard pointer.pointee != 10, pointer.pointee != 13, length < 256 else { return false }
                pointer = pointer.advanced(by: 1)
                length += 1
            }
            return consume("\"")
        }

        mutating func end() -> Bool { consume("\n") && pointer.pointee == 0 }
    }

    private static func parseResource(_ message: UnsafePointer<CChar>) -> (context: UInt32, resource: UInt32)? {
        var cursor = Cursor(pointer: message)
        guard cursor.consume("check_copy_transfer3d_handles: context error reported "),
            let context = cursor.number(), context <= Int32.max, cursor.consume(" \""), cursor.skipName(),
            cursor.consume(" Illegal resource "), let resource = cursor.number(), cursor.end()
        else { return nil }
        return (context, resource)
    }

    private static func parseDispatch(_ message: UnsafePointer<CChar>) -> UInt32? {
        var cursor = Cursor(pointer: message)
        guard cursor.consume("context "), let context = cursor.number(), context <= Int32.max,
            cursor.consume(" failed to dispatch COPY_TRANSFER3D: 22"), cursor.end()
        else { return nil }
        return context
    }
}
