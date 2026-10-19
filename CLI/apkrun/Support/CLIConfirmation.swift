import Darwin
import Foundation

enum CLIConfirmation {
    static func confirm(_ prompt: String, yes: Bool) throws {
        guard !yes else { return }
        guard isatty(STDIN_FILENO) == 1 else {
            throw CLIFailure.confirmationRequired(flag: "--yes")
        }
        FileHandle.standardError.write(Data("\(prompt) Continue? [y/N] ".utf8))
        guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
            throw CLIFailure.declined
        }
    }
}
