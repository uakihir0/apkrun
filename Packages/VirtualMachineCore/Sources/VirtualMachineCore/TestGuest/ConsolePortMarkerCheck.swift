import Foundation

/// The `APKRUN-PORT-<i>` marker check of the Linux test guest's port test (vm.md §6.2, android-image.md §7.1).
///
/// The host sends `APKRUN-PORT-<i>` to console port `i` after the guest announces the port. The guest reads
/// `/dev/hvc<i>` and prints `APKRUN-TEST: port-<i> ok APKRUN-PORT-<i>` when that marker arrives. Port 0 is the
/// system console, which carries the records themselves, so it takes no marker.
public enum ConsolePortMarkerCheck {
    /// One marked port whose check did not pass.
    public enum Failure: Equatable, Sendable, CustomStringConvertible {
        /// The guest printed no `port-<i>` record.
        case missing(port: Int)

        /// The guest printed `count` records for the port, where one is expected.
        case repeated(port: Int, count: Int)

        /// The guest printed `port-<i> fail`.
        case failed(port: Int, detail: String)

        /// The guest printed `port-<i> ok` with a detail other than the marker sent to port `i`.
        case wrongMarker(port: Int, detail: String)

        /// A one-line description for a test failure message.
        public var description: String {
            switch self {
            case .missing(let port):
                return "port-\(port) was not reported"
            case .repeated(let port, let count):
                return "port-\(port) was reported \(count) times"
            case .failed(let port, let detail):
                return "port-\(port) failed: \(detail)"
            case .wrongMarker(let port, let detail):
                return "port-\(port) reported \(detail), not \(ConsolePortMarkerCheck.marker(forPort: port))"
            }
        }
    }

    /// The marker the host sends to attachment port `index`.
    public static func marker(forPort index: Int) -> String {
        "APKRUN-PORT-\(index)"
    }

    /// The check name the guest prints for attachment port `index`.
    public static func checkName(forPort index: Int) -> String {
        "port-\(index)"
    }

    /// The attachment indices of `plan` that take a marker: every port except the system console at index 0.
    public static func markedPorts(in plan: [ConsolePortDefinition]) -> [Int] {
        Array(plan.indices.dropFirst())
    }

    /// The failures over `records`, one for each marked port of `plan` that does not pass.
    ///
    /// A marked port passes only when exactly one `port-<i>` record is `ok` and carries `APKRUN-PORT-<i>`. A
    /// missing, repeated, failed, or mislabelled record fails the check. An empty result means every marked port
    /// received its own marker.
    public static func failures(in records: [TestGuestRecord], plan: [ConsolePortDefinition]) -> [Failure] {
        var failures: [Failure] = []
        for index in markedPorts(in: plan) {
            let name = checkName(forPort: index)
            let reports: [(result: TestGuestCheckResult, detail: String)] = records.compactMap { record in
                guard case .check(let recordName, let result, let detail) = record, recordName == name else {
                    return nil
                }
                return (result, detail)
            }
            guard let report = reports.first else {
                failures.append(.missing(port: index))
                continue
            }
            guard reports.count == 1 else {
                failures.append(.repeated(port: index, count: reports.count))
                continue
            }
            if report.result == .fail {
                failures.append(.failed(port: index, detail: report.detail))
            } else if report.detail != marker(forPort: index) {
                failures.append(.wrongMarker(port: index, detail: report.detail))
            }
        }
        return failures
    }
}
