import DiagnosticsCore
import Dispatch
import Foundation
import VirtioDeviceCore
import Virtualization

/// Builds and operates Virtualization.framework VMs on one private serial queue.
package struct VZVirtualMachineDriverFactory: VirtualMachineDriverFactory {
    private let queue: VMQueue

    package init(queue: VMQueue) {
        self.queue = queue
    }

    package func makeDriver(
        for definition: VMDefinition,
        consoleChannels: [ConsoleChannel]
    ) async throws(VZErrorInfo) -> any VirtualMachineDriver {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<any VirtualMachineDriver, VZErrorInfo>) in
            queue.dispatchQueue.async {
                assertOnVMQueue(queue)
                var attachedChannels: [ConsoleChannel] = []
                do {
                    var attachments: [VZSerialPortAttachment] = []
                    for channel in consoleChannels {
                        attachments.append(try channel.makeAttachment())
                        attachedChannels.append(channel)
                    }
                    let buildResult = try VZConfigurationBuilder.build(
                        definition,
                        consolePortAttachments: attachments
                    )
                    let configuration = buildResult.configuration
                    try configuration.validate()

                    let stream = AsyncStream.makeStream(
                        of: VirtualMachineEvent.self,
                        bufferingPolicy: .unbounded
                    )
                    let machine = VZVirtualMachine(
                        configuration: configuration,
                        queue: queue.dispatchQueue
                    )
                    let delegate = VZVirtualMachineEventDelegate(
                        queue: queue,
                        continuation: stream.continuation
                    )
                    let driver = VZVirtualMachineDriver(
                        machine: machine,
                        socketDevice: machine.socketDevices.first as? VZVirtioSocketDevice,
                        delegate: delegate,
                        queue: queue,
                        consoleChannels: consoleChannels,
                        customDeviceAdapters: buildResult.customDeviceAdapters,
                        events: stream.stream,
                        eventContinuation: stream.continuation
                    )
                    machine.delegate = delegate
                    continuation.resume(returning: driver)
                } catch {
                    for channel in attachedChannels {
                        channel.detachAttachment()
                    }
                    continuation.resume(throwing: VZErrorInfo(error as NSError))
                }
            }
        }
    }
}

/// Owns a VZVirtualMachine and serializes every framework access.
// UNCHECKED-SENDABLE: queue serializes all VZ object access; machine and delegate are cleared on that queue by release().
package final class VZVirtualMachineDriver: VirtualMachineDriver, @unchecked Sendable {
    private var machine: VZVirtualMachine?
    private var socketDevice: VZVirtioSocketDevice?
    private var delegate: VZVirtualMachineEventDelegate?
    private let queue: VMQueue
    private let eventContinuation: AsyncStream<VirtualMachineEvent>.Continuation
    private let consoleChannels: [ConsoleChannel]
    private var customDeviceAdapters: [VZCustomVirtioDeviceAdapter]
    private var attachmentsAreActive = true
    private var startupEvents: [VirtualMachineEvent] = []

    /// The delegate event stream.
    package let events: AsyncStream<VirtualMachineEvent>

    fileprivate init(
        machine: VZVirtualMachine,
        socketDevice: VZVirtioSocketDevice?,
        delegate: VZVirtualMachineEventDelegate,
        queue: VMQueue,
        consoleChannels: [ConsoleChannel],
        customDeviceAdapters: [VZCustomVirtioDeviceAdapter],
        events: AsyncStream<VirtualMachineEvent>,
        eventContinuation: AsyncStream<VirtualMachineEvent>.Continuation
    ) {
        self.machine = machine
        self.socketDevice = socketDevice
        self.delegate = delegate
        self.queue = queue
        self.consoleChannels = consoleChannels
        self.customDeviceAdapters = customDeviceAdapters
        self.events = events
        self.eventContinuation = eventContinuation
    }

    package func start() async throws(VZErrorInfo) -> [VirtualMachineEvent] {
        try await withVZOperationCompletion { completion in
            let queue = self.queue
            queue.dispatchQueue.async {
                assertOnVMQueue(queue)
                guard completion.markStarted() else { return }
                self.startupEvents.removeAll()
                self.delegate?.beginStart()
                self.requireMachine().start { result in
                    assertOnVMQueue(queue)
                    switch result {
                    case .success:
                        self.startupEvents = self.delegate?.finishStart() ?? []
                    case .failure:
                        self.delegate?.discardStart()
                        self.startupEvents.removeAll()
                    }
                    completion.complete(result)
                }
            }
        }
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<[VirtualMachineEvent], Never>) in
            queue.dispatchQueue.async {
                assertOnVMQueue(self.queue)
                let events = self.startupEvents
                self.startupEvents.removeAll()
                continuation.resume(returning: events)
            }
        }
    }

    package func stop() async throws(VZErrorInfo) {
        try await withVZOperationCompletion { completion in
            let queue = self.queue
            queue.dispatchQueue.async {
                assertOnVMQueue(queue)
                guard completion.markStarted() else { return }
                self.requireMachine().stop { error in
                    assertOnVMQueue(queue)
                    completion.complete(error)
                }
            }
        }
    }

    package func requestStop() async throws(VZErrorInfo) {
        try await withVZOperationCompletion { completion in
            let queue = self.queue
            queue.dispatchQueue.async {
                assertOnVMQueue(queue)
                guard completion.markStarted() else { return }
                do {
                    try self.requireMachine().requestStop()
                    completion.complete()
                } catch {
                    completion.complete(error)
                }
            }
        }
    }

    package func pause() async throws(VZErrorInfo) {
        try await withVZOperationCompletion { completion in
            let queue = self.queue
            queue.dispatchQueue.async {
                assertOnVMQueue(queue)
                guard completion.markStarted() else { return }
                self.requireMachine().pause { result in
                    assertOnVMQueue(queue)
                    completion.complete(result)
                }
            }
        }
    }

    package func resume() async throws(VZErrorInfo) {
        try await withVZOperationCompletion { completion in
            let queue = self.queue
            queue.dispatchQueue.async {
                assertOnVMQueue(queue)
                guard completion.markStarted() else { return }
                self.requireMachine().resume { result in
                    assertOnVMQueue(queue)
                    completion.complete(result)
                }
            }
        }
    }

    package func connect(
        toPort port: UInt32,
        completion:
            @escaping @Sendable (
                Result<VsockConnection, VirtualMachineDriverConnectFailure>
            ) -> Void
    ) {
        let vmQueue = queue
        vmQueue.dispatchQueue.async {
            assertOnVMQueue(vmQueue)
            guard let socketDevice = self.socketDevice else {
                completion(.failure(.vsockDeviceUnavailable))
                return
            }

            socketDevice.connect(toPort: port) { result in
                assertOnVMQueue(vmQueue)
                switch result {
                case .success(let connection):
                    completion(
                        .success(
                            VsockConnection(
                                virtualizationConnection: connection,
                                queue: vmQueue
                            )
                        )
                    )
                case .failure(let error):
                    completion(.failure(.virtualization(VZErrorInfo(error as NSError))))
                }
            }
        }
    }

    package func release() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.dispatchQueue.async {
                assertOnVMQueue(self.queue)
                self.machine?.delegate = nil
                self.socketDevice = nil
                for adapter in self.customDeviceAdapters {
                    adapter.prepareForRelease()
                }
                self.machine = nil
                self.delegate = nil
                self.startupEvents.removeAll()
                self.customDeviceAdapters.removeAll(keepingCapacity: false)
                if self.attachmentsAreActive {
                    for channel in self.consoleChannels {
                        channel.detachAttachment()
                    }
                    self.attachmentsAreActive = false
                }
                self.eventContinuation.finish()
                continuation.resume()
            }
        }
    }

    private func requireMachine() -> VZVirtualMachine {
        guard let machine else {
            assertionFailure("The VZ driver was used after its framework objects were released.")
            preconditionFailure("The VZ driver was used after its framework objects were released.")
        }
        return machine
    }

}

// UNCHECKED-SENDABLE: the VM queue serializes delegate callbacks; the continuation and queue are Sendable values.
package final class VZVirtualMachineEventDelegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let queue: VMQueue
    private let continuation: AsyncStream<VirtualMachineEvent>.Continuation
    private var startupEventBuffer = VMStartupEventBuffer()

    package init(
        queue: VMQueue,
        continuation: AsyncStream<VirtualMachineEvent>.Continuation
    ) {
        self.queue = queue
        self.continuation = continuation
    }

    package func beginStart() {
        assertOnVMQueue(queue)
        startupEventBuffer.begin()
    }

    package func finishStart() -> [VirtualMachineEvent] {
        assertOnVMQueue(queue)
        return startupEventBuffer.finish()
    }

    package func discardStart() {
        assertOnVMQueue(queue)
        startupEventBuffer.discard()
    }

    package func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        assertOnVMQueue(queue)
        publish(.guestDidStop)
    }

    package func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        assertOnVMQueue(queue)
        publish(.didStopWithError(VZErrorInfo(error as NSError)))
    }

    package func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        assertOnVMQueue(queue)
        publish(.networkAttachmentDisconnected(VZErrorInfo(error as NSError)))
    }

    package func publish(_ event: VirtualMachineEvent) {
        assertOnVMQueue(queue)
        if !startupEventBuffer.append(event) {
            continuation.yield(event)
        }
    }
}

private func assertOnVMQueue(_ queue: VMQueue) {
    #if DEBUG
        dispatchPrecondition(condition: .onQueue(queue.dispatchQueue))
    #endif
}
