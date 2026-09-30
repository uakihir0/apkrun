import Foundation

/// The result printed by one requested test-guest check.
public enum TestGuestCheckResult: String, Equatable, Sendable {
    /// The guest reports that the check passed.
    case ok

    /// The guest reports that the check failed.
    case fail
}

/// A complete, recognized record from the test guest's serial output.
public enum TestGuestRecord: Equatable, Sendable {
    /// The guest reached userspace and initialized its test harness.
    case bootOK

    /// The guest completed one requested check.
    case check(name: String, result: TestGuestCheckResult, detail: String)

    /// The guest finished its requested checks.
    case done
}

/// Parses complete `APKRUN-TEST:` lines across arbitrary console read boundaries.
public struct TestGuestLineParser: Sendable {
    private static let prefix = "APKRUN-TEST:"
    private static let maximumLineBytes = 64 * 1_024

    private var lineBytes: [UInt8] = []
    private var isDiscardingOverlongLine = false

    /// Number of lines discarded because they exceeded the bounded line buffer.
    public private(set) var discardedOverlongLineCount = 0

    /// Creates a parser with an empty partial-line buffer.
    public init() {}

    /// Adds console bytes and returns every recognized complete record.
    public mutating func consume(_ data: Data) -> [TestGuestRecord] {
        var records: [TestGuestRecord] = []

        for byte in data {
            if byte == 0x0A {
                if !isDiscardingOverlongLine, let record = parse(lineBytes) {
                    records.append(record)
                }
                lineBytes.removeAll(keepingCapacity: true)
                isDiscardingOverlongLine = false
            } else if !isDiscardingOverlongLine {
                if lineBytes.count == Self.maximumLineBytes,
                    byte == 0x0D
                {
                    // A terminal CR is excluded from the logical line size.
                    lineBytes.append(byte)
                } else if lineBytes.count > Self.maximumLineBytes
                    || lineBytes.count == Self.maximumLineBytes
                {
                    lineBytes.removeAll(keepingCapacity: true)
                    isDiscardingOverlongLine = true
                    discardedOverlongLineCount += 1
                } else {
                    lineBytes.append(byte)
                }
            }
        }

        return records
    }

    /// Parses a final unterminated line at EOF, if one is present.
    public mutating func finish() -> [TestGuestRecord] {
        defer {
            lineBytes.removeAll(keepingCapacity: true)
            isDiscardingOverlongLine = false
        }

        guard !isDiscardingOverlongLine, let record = parse(lineBytes) else {
            return []
        }
        return [record]
    }

    private func parse(_ bytes: [UInt8]) -> TestGuestRecord? {
        var line = bytes
        if line.last == 0x0D {
            line.removeLast()
        }

        let text = String(decoding: line, as: UTF8.self)
        guard let markerRange = text.range(of: Self.prefix) else { return nil }

        // The last kernel message may not end with a newline before /init writes
        // the first test record to hvc0.
        let suffix = text[markerRange.upperBound...]
        guard suffix.first?.isWhitespace == true else { return nil }
        let payload = suffix.trimmingCharacters(in: .whitespaces)
        if payload == "done" {
            return .done
        }

        let fields = payload.split(
            maxSplits: 2,
            omittingEmptySubsequences: true,
            whereSeparator: \.isWhitespace
        )
        guard fields.count >= 2 else { return nil }

        let name = String(fields[0])
        let resultText = String(fields[1])
        if name == "boot" {
            return resultText == "ok" && fields.count == 2 ? .bootOK : nil
        }
        guard let result = TestGuestCheckResult(rawValue: resultText) else {
            return nil
        }

        return .check(
            name: name,
            result: result,
            detail: fields.count == 3 ? String(fields[2]) : ""
        )
    }
}
