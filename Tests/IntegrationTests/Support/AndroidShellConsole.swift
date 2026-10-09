import Foundation
import RuntimeCore

/// The Android serial shell (hvc1, developer mode) for the T2 Android tests (#013).
///
/// It wraps the product's `AndroidSerialShell`, the channel `RuntimeSupervisor` uses to confirm
/// `sys.boot_completed`, so the checks run on the product path. Root commands run as `su 0`, as
/// the reference capture does (`Images/tools/reference/guest-capture.txt`).
struct AndroidShellConsole {
    /// A command that exited with a non-zero status, or whose output was not what the check needs.
    struct CheckFailure: Error, CustomStringConvertible {
        let command: String
        let detail: String

        var description: String {
            "shell command `\(command)` failed: \(detail)"
        }
    }

    let shell: AndroidSerialShell

    /// Runs `command` and returns its reply without judging the exit status.
    func run(_ command: String, root: Bool = false, timeout: Duration = .seconds(60)) async throws
        -> AndroidSerialShell.Reply
    {
        let line = root ? "su 0 \(command)" : command
        do {
            return try await shell.run(line, timeout: timeout)
        } catch {
            throw CheckFailure(command: line, detail: "the serial shell did not answer (\(error))")
        }
    }

    /// Runs `command`, requires exit status 0, and returns its output.
    func output(_ command: String, root: Bool = false, timeout: Duration = .seconds(60)) async throws -> String {
        let reply = try await run(command, root: root, timeout: timeout)
        guard reply.status == 0 else {
            throw CheckFailure(command: command, detail: "exit status \(reply.status)")
        }
        return reply.output
    }
}
