import Foundation

enum DevLinuxFloodArguments {
    static let defaultLineCount = 10_000_000
    static let maximumLineCount = 10_000_000

    static func make(tests: [String], lineCount: Int?) throws -> [String] {
        let requestsFlood = tests.contains("flood")
        guard requestsFlood || lineCount == nil else {
            throw CLIFailure.invalidArgument(
                argument: "--flood-lines",
                reason: "requiresFloodTest"
            )
        }
        guard requestsFlood else { return [] }

        let count = lineCount ?? defaultLineCount
        guard (1...maximumLineCount).contains(count) else {
            throw CLIFailure.invalidArgument(
                argument: "--flood-lines",
                reason: "range"
            )
        }
        return ["apkrun.test.flood=\(count)"]
    }
}
