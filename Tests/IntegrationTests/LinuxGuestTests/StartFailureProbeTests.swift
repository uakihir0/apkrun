import Dispatch
import Foundation
import Virtualization
import XCTest

@testable import VirtualMachineCore

final class LinuxGuestStartFailureProbeTests: XCTestCase {
    func testStartFailureProbeRecordsCompletionAndDelegateAgainstPositiveControl() async throws {
        let artifacts = try LinuxGuestHarness.artifactURLs()
        let positiveControl = VZStartFailureProbe()
        try await positiveControl.construct(
            kernelURL: artifacts.kernel,
            initrdURL: artifacts.initrd,
            powerOff: true
        )
        let positiveCompletion = await positiveControl.start()
        let positiveStopped: Bool
        if positiveCompletion == .succeeded {
            positiveStopped = await positiveControl.waitForGuestStop(timeout: .seconds(60))
        } else {
            positiveStopped = false
        }
        let positiveCleanupCompleted = await positiveControl.stopIfRunning()
        let positiveFinalState = await positiveControl.machineState()
        let positiveCallbacks = positiveControl.callbacks
        if positiveCleanupCompleted {
            await positiveControl.release()
        }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-start-failure-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        var preserveTemporaryDirectory = false
        defer {
            if !preserveTemporaryDirectory {
                try? FileManager.default.removeItem(at: temporaryDirectory)
            }
        }

        let kernelCopy = temporaryDirectory.appendingPathComponent("Image")
        try FileManager.default.copyItem(at: artifacts.kernel, to: kernelCopy)

        let failureProbe = VZStartFailureProbe()
        try await failureProbe.construct(
            kernelURL: kernelCopy,
            initrdURL: artifacts.initrd,
            powerOff: true
        )
        try FileManager.default.removeItem(at: kernelCopy)
        let failureCompletion = await failureProbe.start()
        if failureCompletion == .succeeded {
            _ = await failureProbe.waitForGuestStop(timeout: .seconds(60))
        } else {
            await failureProbe.waitForAnyCallback(timeout: .seconds(2))
        }
        let failureCleanupCompleted = await failureProbe.stopIfRunning()
        let failureFinalState = await failureProbe.machineState()
        preserveTemporaryDirectory = !failureCleanupCompleted
        let failureCallbacks = failureProbe.callbacks
        if failureCleanupCompleted {
            await failureProbe.release()
        }

        let report = """
                Positive control:
                start completion: \(positiveCompletion)
            guestDidStop within 60 seconds: \(positiveStopped)
            cleanup reached a terminal state or stop completed: \(positiveCleanupCompleted)
            VM state after cleanup: \(positiveFinalState.rawValue)
            callbacks: \(positiveCallbacks)

            Kernel removed after VZ machine construction:
            start completion: \(failureCompletion)
            cleanup reached a terminal state or stop completed: \(failureCleanupCompleted)
            VM state after cleanup: \(failureFinalState.rawValue)
            callbacks observed in the bounded interval: \(failureCallbacks)
            temporary directory preserved after cleanup failure: \(preserveTemporaryDirectory)
            """
        let attachment = XCTAttachment(string: report)
        attachment.name = "VZ start failure callback probe"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(positiveCompletion, .succeeded, report)
        XCTAssertTrue(positiveStopped, report)
        XCTAssertTrue(positiveCleanupCompleted, report)
        XCTAssertEqual(positiveFinalState, .stopped, report)
        XCTAssertEqual(positiveCallbacks, [.guestDidStop], report)
        XCTAssertEqual(
            failureCompletion,
            .failed(domain: "VZErrorDomain", code: 2),
            report
        )
        XCTAssertTrue(failureCallbacks.isEmpty, report)
        XCTAssertTrue(failureCleanupCompleted, report)
        XCTAssertTrue(failureFinalState.isTerminal, report)
    }
}

private enum VZStartProbeCompletion: Equatable, Sendable, CustomStringConvertible {
    case succeeded
    case failed(domain: String, code: Int)

    var description: String {
        switch self {
        case .succeeded:
            "succeeded"
        case .failed(let domain, let code):
            "failed(\(domain)/\(code))"
        }
    }
}

private enum VZStartProbeCallback: Equatable, Sendable, CustomStringConvertible {
    case guestDidStop
    case didStopWithError(domain: String, code: Int)

    var description: String {
        switch self {
        case .guestDidStop:
            "guestDidStop"
        case .didStopWithError(let domain, let code):
            "didStopWithError(\(domain)/\(code))"
        }
    }
}

private enum VZStartProbeMachineState: String, Equatable, Sendable {
    case released
    case stopped
    case starting
    case running
    case stopping
    case paused
    case error
    case unknown

    var isTerminal: Bool {
        self == .stopped || self == .error || self == .released
    }
}

private final class VZStartProbeDelegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var recordedCallbacks: [VZStartProbeCallback] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var callbacks: [VZStartProbeCallback] {
        lock.withLock { recordedCallbacks }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        dispatchPrecondition(condition: .onQueue(queue))
        lock.withLock {
            recordedCallbacks.append(.guestDidStop)
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        dispatchPrecondition(condition: .onQueue(queue))
        let underlying = error as NSError
        lock.withLock {
            recordedCallbacks.append(
                .didStopWithError(domain: underlying.domain, code: underlying.code)
            )
        }
    }
}

// UNCHECKED-SENDABLE: every VZ object and retained attachment is accessed only on queue.
private final class VZStartFailureProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.apkrun.vm.queue")
    private let delegateLock = NSLock()
    private var machine: VZVirtualMachine?
    private var configuration: VZVirtualMachineConfiguration?
    private var delegate: VZStartProbeDelegate?
    private var attachmentHandles: [FileHandle] = []

    var callbacks: [VZStartProbeCallback] {
        let delegate = delegateLock.withLock { self.delegate }
        return delegate?.callbacks ?? []
    }

    func construct(kernelURL: URL, initrdURL: URL, powerOff: Bool) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    let configuration = try Self.makeConfiguration(
                        kernelURL: kernelURL,
                        initrdURL: initrdURL,
                        powerOff: powerOff,
                        attachmentHandles: &self.attachmentHandles
                    )
                    try configuration.validate()
                    let machine = VZVirtualMachine(
                        configuration: configuration,
                        queue: self.queue
                    )
                    let delegate = VZStartProbeDelegate(queue: self.queue)
                    machine.delegate = delegate
                    self.configuration = configuration
                    self.machine = machine
                    self.delegateLock.withLock {
                        self.delegate = delegate
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() async -> VZStartProbeCompletion {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<VZStartProbeCompletion, Never>) in
            queue.async {
                guard let machine = self.machine else {
                    continuation.resume(
                        returning: .failed(domain: "APKRunStartProbe", code: 1)
                    )
                    return
                }
                machine.start { result in
                    switch result {
                    case .success:
                        continuation.resume(returning: .succeeded)
                    case .failure(let error):
                        let underlying = error as NSError
                        continuation.resume(
                            returning: .failed(
                                domain: underlying.domain,
                                code: underlying.code
                            )
                        )
                    }
                }
            }
        }
    }

    func waitForGuestStop(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return false }
            if callbacks.contains(.guestDidStop) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return callbacks.contains(.guestDidStop)
    }

    func waitForAnyCallback(timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, callbacks.isEmpty {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func machineState() async -> VZStartProbeMachineState {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<VZStartProbeMachineState, Never>) in
            queue.async {
                guard let machine = self.machine else {
                    continuation.resume(returning: .released)
                    return
                }
                let state: VZStartProbeMachineState
                switch machine.state {
                case .stopped:
                    state = .stopped
                case .starting:
                    state = .starting
                case .running:
                    state = .running
                case .stopping:
                    state = .stopping
                case .paused:
                    state = .paused
                case .error:
                    state = .error
                @unknown default:
                    state = .unknown
                }
                continuation.resume(returning: state)
            }
        }
    }

    func stopIfRunning(timeout: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            let waiter = VZStartProbeStopWaiter(continuation: continuation)
            queue.async {
                guard let machine = self.machine else {
                    waiter.finish(stopped: true)
                    return
                }

                switch machine.state {
                case .stopped, .error:
                    waiter.finish(stopped: true)
                    return
                case .starting, .stopping:
                    waiter.finish(stopped: false)
                    VZStartProbeRetention.shared.retain(self)
                    return
                case .running, .paused:
                    break
                @unknown default:
                    waiter.finish(stopped: false)
                    VZStartProbeRetention.shared.retain(self)
                    return
                }

                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    guard waiter.finish(stopped: false) else { return }
                    VZStartProbeRetention.shared.retain(self)
                }
                waiter.install(timer: timer)
                timer.resume()
                machine.stop { error in
                    let stopped = error == nil
                    guard waiter.finish(stopped: stopped) else {
                        if stopped {
                            self.releaseFrameworkObjectsOnVMQueue()
                            VZStartProbeRetention.shared.release(self)
                        }
                        return
                    }
                    if !stopped {
                        VZStartProbeRetention.shared.retain(self)
                    }
                }
            }
        }
    }

    func release() async {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.releaseFrameworkObjectsOnVMQueue()
                continuation.resume()
            }
        }
    }

    private func releaseFrameworkObjectsOnVMQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        machine?.delegate = nil
        machine = nil
        delegateLock.withLock {
            delegate = nil
        }
        configuration = nil
        attachmentHandles.removeAll()
    }

    private static func makeConfiguration(
        kernelURL: URL,
        initrdURL: URL,
        powerOff: Bool,
        attachmentHandles: inout [FileHandle]
    ) throws -> VZVirtualMachineConfiguration {
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.initialRamdiskURL = initrdURL
        bootLoader.commandLine =
            "console=hvc0 apkrun.test= apkrun.test.poweroff=\(powerOff ? 1 : 0)"

        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = VZGenericMachineIdentifier()

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = bootLoader
        configuration.cpuCount = 2
        configuration.memorySize = 1 * 1_024 * 1_024 * 1_024
        configuration.storageDevices = []
        configuration.networkDevices = []
        configuration.socketDevices = []
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [
            VZVirtioTraditionalMemoryBalloonDeviceConfiguration()
        ]

        let nullDevice = URL(fileURLWithPath: "/dev/null")
        let readingHandle = try FileHandle(forReadingFrom: nullDevice)
        let writingHandle = try FileHandle(forWritingTo: nullDevice)
        attachmentHandles = [readingHandle, writingHandle]
        let attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: readingHandle,
            fileHandleForWriting: writingHandle
        )
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = attachment
        configuration.serialPorts = [serialPort]
        configuration.audioDevices = []
        configuration.graphicsDevices = []
        configuration.keyboards = []
        configuration.pointingDevices = []
        configuration.directorySharingDevices = []
        configuration.usbControllers = []
        return configuration
    }
}

private final class VZStartProbeStopWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timer: DispatchSourceTimer?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func install(timer: DispatchSourceTimer) {
        lock.withLock {
            self.timer = timer
        }
    }

    @discardableResult
    func finish(stopped: Bool) -> Bool {
        let completion: (CheckedContinuation<Bool, Never>, DispatchSourceTimer?)? =
            lock.withLock {
                guard let continuation else { return nil }
                self.continuation = nil
                let timer = self.timer
                self.timer = nil
                return (continuation, timer)
            }
        guard let completion else { return false }
        completion.1?.setEventHandler(handler: nil)
        completion.1?.cancel()
        completion.0.resume(returning: stopped)
        return true
    }
}

private final class VZStartProbeRetention: @unchecked Sendable {
    static let shared = VZStartProbeRetention()

    private let lock = NSLock()
    private var probes: [ObjectIdentifier: VZStartFailureProbe] = [:]

    func retain(_ probe: VZStartFailureProbe) {
        lock.withLock {
            probes[ObjectIdentifier(probe)] = probe
        }
    }

    func release(_ probe: VZStartFailureProbe) {
        _ = lock.withLock {
            probes.removeValue(forKey: ObjectIdentifier(probe))
        }
    }
}
