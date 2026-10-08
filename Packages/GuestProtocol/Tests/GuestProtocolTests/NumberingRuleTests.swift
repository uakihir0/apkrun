import Foundation
import Testing

/// The numbering rule of guest-protocol.md §4.1, checked against the schema source.
///
/// The rule is a property of the .proto text: each operation in `Request.op` has a result in
/// `Response.result` with the same number and the same field name. The paired GuestOperation
/// types belong to RuntimeCore (#072), so this test checks the schema side only.
private struct OneOfField {
    let type: String
    let name: String
    let number: Int
}

private enum Schema {
    /// The directory of the .proto files, found from the location of this source file.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // GuestProtocolTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // GuestProtocol
        .appendingPathComponent("proto/apkrun/guest/v1", isDirectory: true)

    static func load() throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".proto") }
            .sorted()
        return try names.map { try String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
    }

    /// The names of all messages in the schema.
    static func messageNames(in files: [String]) -> Set<String> {
        var names = Set<String>()
        for file in files {
            for line in file.split(separator: "\n") {
                if let match = line.firstMatch(of: /^message (\w+) \{/) {
                    names.insert(String(match.1))
                }
            }
        }
        return names
    }

    /// The fields of the `oneof <name>` block inside `message <message>`.
    static func oneOf(_ name: String, inMessage message: String, in files: [String]) throws -> [OneOfField] {
        for file in files {
            guard let messageBody = block(in: file, startingWith: "message \(message) {") else {
                continue
            }
            guard let oneOfBody = block(in: messageBody, startingWith: "oneof \(name) {") else {
                throw SchemaError.missing("oneof \(name) in \(message)")
            }
            return fields(in: oneOfBody)
        }
        throw SchemaError.missing("message \(message)")
    }

    /// The text between `header` (which ends in `{`) and its matching closing brace.
    static func block(in text: String, startingWith header: String) -> String? {
        guard let start = text.range(of: header) else {
            return nil
        }
        var depth = 1
        var body = ""
        for character in text[start.upperBound...] {
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return body
                }
            }
            body.append(character)
        }
        return nil
    }

    static func fields(in body: String) -> [OneOfField] {
        body.split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: /^\s*(?:repeated\s+)?(\S+)\s+(\w+)\s*=\s*(\d+)\s*;/),
                let number = Int(match.3)
            else {
                return nil
            }
            return OneOfField(type: String(match.1), name: String(match.2), number: number)
        }
    }
}

private enum SchemaError: Error {
    case missing(String)
}

/// The number ranges of guest-protocol.md §4.1, for Request.op.
private let operationRanges: [ClosedRange<Int>] = [10...39, 40...59, 60...69, 70...79, 100...139]

@Test func everyRequestOperationHasAResultWithTheSameNumberAndName() throws {
    let files = try Schema.load()
    let operations = try Schema.oneOf("op", inMessage: "Request", in: files)
    let results = try Schema.oneOf("result", inMessage: "Response", in: files)
    let resultsByNumber = Dictionary(results.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })

    // guest-protocol.md §7.1 has 29 operations (10–21, 40–53, 70, 72, 73), §7.5 has 10 (60–69),
    // and §11.1 has 11 (100–110).
    #expect(operations.count == 50)
    for operation in operations {
        #expect(
            resultsByNumber[operation.number]?.name == operation.name,
            "\(operation.name) = \(operation.number) has no result with the same number and name")
    }
    // Every result is an operation, apart from `error = 1`.
    #expect(results.filter { $0.number != 1 }.count == operations.count)
}

@Test func operationNumbersAreUniqueAndInTheirRanges() throws {
    let operations = try Schema.oneOf("op", inMessage: "Request", in: try Schema.load())
    #expect(Set(operations.map(\.number)).count == operations.count)
    for operation in operations {
        #expect(
            operationRanges.contains { $0.contains(operation.number) },
            "\(operation.name) = \(operation.number) is outside the ranges of §4.1")
    }
}

@Test func operationNumber71IsReservedOnRequestAndResponseAndNotUsed() throws {
    let files = try Schema.load()
    let operations = try Schema.oneOf("op", inMessage: "Request", in: files)
    let results = try Schema.oneOf("result", inMessage: "Response", in: files)
    #expect(!operations.contains { $0.number == 71 })
    #expect(!results.contains { $0.number == 71 })

    let schema = files.joined(separator: "\n")
    for message in ["Request", "Response"] {
        let body = try #require(Schema.block(in: schema, startingWith: "message \(message) {"))
        #expect(body.contains("reserved 71;"), "message \(message) does not reserve 71")
    }
}

@Test func everyEventNumberIsUniqueAndInItsRange() throws {
    let events = try Schema.oneOf("kind", inMessage: "Event", in: try Schema.load())
    #expect(Set(events.map(\.number)).count == events.count)
    for event in events {
        let inRange =
            (10...22).contains(event.number) || (40...45).contains(event.number)
            || (100...102).contains(event.number)
        #expect(inRange, "\(event.name) = \(event.number) is outside the event ranges of §8.1 and §11.2")
    }
}

@Test func everyOperationAndPayloadTypeIsDefinedInTheSchema() throws {
    let files = try Schema.load()
    let defined = Schema.messageNames(in: files)
    let request = try Schema.oneOf("op", inMessage: "Request", in: files)
    let response = try Schema.oneOf("result", inMessage: "Response", in: files)
    let event = try Schema.oneOf("kind", inMessage: "Event", in: files)
    for field in request + response + event where field.number != 1 {
        #expect(defined.contains(field.type), "\(field.type) for \(field.name) is not defined")
    }
}
