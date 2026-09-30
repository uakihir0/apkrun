import Foundation

/// Holds an in-flight framework operation until its callback completes.
package final class VZOperationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, VZErrorInfo>?
    private var cancellationRequested = false
    private var operationStarted = false

    package init() {}

    package func install(_ continuation: CheckedContinuation<Void, VZErrorInfo>) {
        let wasCancelled = lock.withLock {
            guard !cancellationRequested else { return true }
            self.continuation = continuation
            return false
        }
        if wasCancelled {
            continuation.resume(throwing: Self.cancellationFailure)
        }
    }

    package func complete(_ result: Result<Void, any Error>) {
        let completion = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            operationStarted = false
            return (continuation, cancellationRequested)
        }
        guard let continuation = completion.0 else { return }
        if completion.1 {
            continuation.resume(throwing: Self.cancellationFailure)
            return
        }
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: VZErrorInfo(error as NSError))
        }
    }

    package func complete(_ error: (any Error)? = nil) {
        if let error {
            complete(.failure(error))
        } else {
            complete(.success(()))
        }
    }

    /// Claims the framework call so cancellation cannot release it prematurely.
    package func markStarted() -> Bool {
        lock.withLock {
            guard continuation != nil, !cancellationRequested else { return false }
            operationStarted = true
            return true
        }
    }

    package func cancel() {
        let continuation: CheckedContinuation<Void, VZErrorInfo>? = lock.withLock {
            cancellationRequested = true
            guard !operationStarted else { return nil }
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(throwing: Self.cancellationFailure)
    }

    private static let cancellationFailure = VZErrorInfo(
        domain: NSCocoaErrorDomain,
        code: NSUserCancelledError,
        description: "Virtual machine operation was cancelled."
    )
}

package func withVZOperationCompletion(
    _ begin: @escaping @Sendable (VZOperationCompletion) -> Void
) async throws(VZErrorInfo) {
    let completion = VZOperationCompletion()
    do {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, VZErrorInfo>) in
                completion.install(continuation)
                begin(completion)
            }
        } onCancel: {
            completion.cancel()
        }
    } catch let error as VZErrorInfo {
        throw error
    } catch {
        throw VZErrorInfo(error as NSError)
    }
}
