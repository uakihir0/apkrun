@preconcurrency import AppKit
import Foundation
import RuntimeAPI

/// Opens a fresh generic launcher process for a package without moving launcher policy into the daemon.
struct WorkspaceOpener: Sendable {
    let appBundleURL: URL
    let launcherBundleURL: URL

    func open(packageID: RuntimePackageID) async throws(RuntimeWireError) {
        guard FileManager.default.fileExists(atPath: launcherBundleURL.path),
            launcherBundleURL.pathExtension == "app"
        else {
            throw Self.launcherUnavailableError
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                Task { @MainActor [launcherBundleURL] in
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.arguments = ["--package", packageID.rawValue]
                    configuration.createsNewApplicationInstance = true
                    NSWorkspace.shared.openApplication(at: launcherBundleURL, configuration: configuration) {
                        _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        } catch {
            throw Self.launcherUnavailableError
        }
    }

    func openForWrapperApproval() async throws(RuntimeWireError) {
        guard FileManager.default.fileExists(atPath: appBundleURL.path),
            appBundleURL.pathExtension == "app"
        else {
            throw Self.launcherUnavailableError
        }

        do {
            try await WorkspaceApprovalOpenGate().perform { [appBundleURL] completion in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = ["--approve"]
                configuration.activates = true
                configuration.createsNewApplicationInstance = false
                NSWorkspace.shared.openApplication(at: appBundleURL, configuration: configuration) {
                    _, error in
                    if let error {
                        completion(.failure(error))
                    } else {
                        completion(.success(()))
                    }
                }
            }
        } catch {
            throw Self.launcherUnavailableError
        }
    }

    private static let launcherUnavailableError = RuntimeWireError.runtime(
        "serviceUnavailable",
        message: "APKRun couldn't open the app launcher.",
        remediation: "Restart APKRun and try again."
    )
}

final class WorkspaceApprovalOpenGate: @unchecked Sendable {
    private enum State {
        case pending
        case started
        case completed
        case cancelled
    }

    private let lock = NSLock()
    private var state = State.pending
    private var continuation: CheckedContinuation<Void, any Error>?

    func perform(
        _ operation:
            @escaping @MainActor @Sendable (
                @escaping @Sendable (Result<Void, any Error>) -> Void
            ) -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard install(continuation) else { return }
                Task { @MainActor [self] in
                    guard begin() else { return }
                    operation { [self] result in
                        complete(result)
                    }
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        lock.lock()
        let isCancelled = state == .cancelled
        if !isCancelled {
            self.continuation = continuation
        }
        lock.unlock()
        if isCancelled {
            continuation.resume(throwing: CancellationError())
            return false
        }
        return true
    }

    private func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending else { return false }
        state = .started
        return true
    }

    private func cancel() {
        lock.lock()
        guard state == .pending || state == .started else {
            lock.unlock()
            return
        }
        state = .cancelled
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func complete(_ result: Result<Void, any Error>) {
        lock.lock()
        guard state == .started else {
            lock.unlock()
            return
        }
        state = .completed
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
