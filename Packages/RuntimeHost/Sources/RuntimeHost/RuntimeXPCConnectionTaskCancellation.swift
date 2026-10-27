import Foundation

/// Cancels every active request task when its owning XPC connection is invalidated.
final class RuntimeXPCConnectionTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var handles: [ObjectIdentifier: RuntimeXPCRequestTaskHandle] = [:]

    func makeHandle() -> RuntimeXPCRequestTaskHandle {
        let handle = RuntimeXPCRequestTaskHandle()
        lock.lock()
        let shouldCancel = isCancelled
        if !shouldCancel {
            handles[ObjectIdentifier(handle)] = handle
        }
        lock.unlock()
        if shouldCancel {
            handle.cancel()
        }
        return handle
    }

    func remove(_ handle: RuntimeXPCRequestTaskHandle) {
        lock.lock()
        handles.removeValue(forKey: ObjectIdentifier(handle))
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let outstanding = Array(handles.values)
        handles.removeAll()
        lock.unlock()
        for handle in outstanding {
            handle.cancel()
        }
    }
}

/// Holds one admitted XPC request task and closes the install/cancel race.
final class RuntimeXPCRequestTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false
    private var isFinished = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        guard !isCancelled, !isFinished else {
            let shouldCancel = isCancelled
            lock.unlock()
            if shouldCancel {
                task.cancel()
            }
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }

    func finish() {
        lock.lock()
        isFinished = true
        task = nil
        lock.unlock()
    }
}
