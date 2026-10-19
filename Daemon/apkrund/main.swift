import Darwin
import DiagnosticsCore
import Dispatch
import Foundation
import RuntimeHost

await APKRunDaemon.main()

enum APKRunDaemon {
    private static let idleExitGracePeriod: Duration = .seconds(120)

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let buildInfo = BuildInfo.current

        switch arguments {
        case ["--version"]:
            writeStandardOutput("apkrund \(buildInfo.marketingVersion) (\(buildInfo.buildNumber))")
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

        let host = RuntimeHost(buildInfo: buildInfo)
        let termination = DaemonTerminationCoordinator(host: host)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let terminationSources = [SIGTERM, SIGINT].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                Task {
                    guard await termination.shutdown() else { return }
                    exit(EXIT_SUCCESS)
                }
            }
            source.resume()
            return source
        }

        do {
            try await host.start()
        } catch RuntimeHostError.runtimeFailure(.instanceLocked(owner: .apkrund)) {
            // Launchd can race with the existing daemon after a quick logout/login.
            return
        } catch {
            writeStandardError("apkrund: startup failed: \(String(describing: error))")
            await host.shutdown()
            if termination.wasRequested {
                withExtendedLifetime((host, termination, terminationSources)) {
                    dispatchMain()
                }
            }
            // A persistent bundle/configuration failure is not a process crash. Exiting
            // successfully prevents KeepAlive.SuccessfulExit=false from restart-looping;
            // a later Mach-service request or StartInterval will try again.
            exit(EXIT_SUCCESS)
        }

        guard !termination.wasRequested else {
            withExtendedLifetime((host, termination, terminationSources)) {
                dispatchMain()
            }
        }

        guard let appBundleURL = containingAppBundle() else {
            writeStandardError("apkrund: couldn't locate the containing APKRun.app bundle")
            await host.shutdown()
            if termination.wasRequested {
                withExtendedLifetime((host, termination, terminationSources)) {
                    dispatchMain()
                }
            }
            exit(EXIT_SUCCESS)
        }

        let server: RuntimeXPCServer
        do {
            server = try RuntimeXPCServer(
                host: host,
                appBundleURL: appBundleURL,
                buildInfo: buildInfo
            )
            termination.install(server: server)
            guard !termination.wasRequested else {
                withExtendedLifetime((host, server, termination, terminationSources)) {
                    dispatchMain()
                }
            }
            try server.start()
            await host.markDaemonReady()
        } catch {
            writeStandardError("apkrund: couldn't start the control endpoint: \(String(describing: error))")
            await host.shutdown()
            if termination.wasRequested {
                withExtendedLifetime((host, termination, terminationSources)) {
                    dispatchMain()
                }
            }
            // launchd retries when the service is requested again; avoid an automatic
            // KeepAlive loop for a deterministic signature or bundle-layout problem.
            exit(EXIT_SUCCESS)
        }

        let idleMonitor = Task.detached {
            while true {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard await host.canExitWhenIdle(),
                    server.invalidateIfIdle(for: idleExitGracePeriod)
                else {
                    continue
                }
                await host.shutdown()
                exit(EXIT_SUCCESS)
            }
        }
        withExtendedLifetime((host, server, termination, terminationSources, idleMonitor)) {
            dispatchMain()
        }
    }

    private static func containingAppBundle() -> URL? {
        let executable =
            Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        var candidate = executable.deletingLastPathComponent()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}

private final class DaemonTerminationCoordinator: @unchecked Sendable {
    private let host: RuntimeHost
    private let lock = NSLock()
    private var server: RuntimeXPCServer?
    private var requested = false

    init(host: RuntimeHost) {
        self.host = host
    }

    var wasRequested: Bool {
        lock.withLock { requested }
    }

    func install(server: RuntimeXPCServer) {
        let stopAccepting = lock.withLock {
            self.server = server
            return requested
        }
        if stopAccepting {
            server.stopAcceptingNewConnections()
        }
    }

    func shutdown() async -> Bool {
        let (shouldShutdown, currentServer) = lock.withLock {
            guard !requested else { return (false, Optional<RuntimeXPCServer>.none) }
            requested = true
            return (true, server)
        }
        guard shouldShutdown else {
            return false
        }

        currentServer?.stopAcceptingNewConnections()
        await host.shutdown()

        let installedServer = lock.withLock { server }
        if let installedServer {
            installedServer.stopAcceptingNewConnections()
            await installedServer.waitForPendingRequestsToDrain()
            installedServer.invalidate()
        }
        return true
    }
}

private func writeStandardOutput(_ value: String) {
    FileHandle.standardOutput.write(Data((value + "\n").utf8))
}

private func writeStandardError(_ value: String) {
    FileHandle.standardError.write(Data((value + "\n").utf8))
}
