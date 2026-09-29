import Dispatch
import Foundation

enum APKRunDaemon {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

        switch arguments {
        case ["--version"]:
            writeStandardOutput("apkrund \(version) (\(build))")
            return
        case ["--help"], ["-h"]:
            writeStandardOutput("Usage: apkrund [--version | --help]")
            return
        case []:
            break
        default:
            writeStandardError("apkrund: unknown argument\nUsage: apkrund [--version | --help]")
            exit(64)
        }

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let terminationSignals = [SIGTERM, SIGINT].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                exit(EXIT_SUCCESS)
            }
            source.resume()
            return source
        }
        withExtendedLifetime(terminationSignals) {
            dispatchMain()
        }
    }
}

private func writeStandardOutput(_ value: String) {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}

private func writeStandardError(_ value: String) {
    FileHandle.standardError.write(Data((value + "\n").utf8))
}

APKRunDaemon.main()
