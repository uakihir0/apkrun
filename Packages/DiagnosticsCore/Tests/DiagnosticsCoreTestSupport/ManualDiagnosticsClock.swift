import DiagnosticsCore
import Foundation

/// A wall clock that tests can advance deterministically.
public final class ManualDiagnosticsClock: DiagnosticsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow: Date

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        storedNow = now
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return storedNow
    }

    public func advance(by duration: TimeInterval) {
        lock.lock()
        storedNow.addTimeInterval(duration)
        lock.unlock()
    }
}
