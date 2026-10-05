import DiagnosticsCore
import Foundation

// UNCHECKED-SENDABLE: mutable device state is accessed only from VirtioDeviceModel callbacks on the adapter's serial device queue.
/// A deterministic virtio-rng device used by Linux guest integration tests.
///
/// The VZ adapter calls this model on its per-device serial queue. Its generator
/// restarts from the original seed after every guest or host device reset.
public final class EntropyTestDevice: VirtioDeviceModel, @unchecked Sendable {
    private enum MappingLifecycleEvent: String {
        case reset
        case stop
    }

    /// The guest-visible virtio-rng descriptor.
    public var descriptor: VirtioDeviceDescriptor {
        VirtioDeviceDescriptor(
            name: "test-entropy",
            deviceID: 4,
            pciClass: 0x10,
            pciSubclass: 0,
            queueCount: 1,
            mandatoryFeatures: 0,
            optionalFeatures: 0,
            configurationSpace: Self.configurationSpace(generation: 0)
        )
    }

    private let seed: UInt64
    private let logger: APKLogger
    private let resetObserver: (@Sendable (UInt64) -> Void)?
    private let startObserver: (@Sendable (UInt64) -> Void)?
    private let mappingObserver: (@Sendable (UInt64) -> Void)?
    private let stopObserver: (@Sendable (UInt64) -> Void)?
    private let performsConfigurationProbe: Bool
    private let probesGuestMemoryMapping: Bool
    private let probesPendingElementInvalidation: Bool
    private let pendingElementProbeState = PendingElementProbeState()
    private var generator: SplitMix64Generator
    private var generation: UInt64 = 0
    private var notificationCount = 0
    private var elementCount = 0
    private var writtenByteCount = 0
    private var previousConfigurationUpdater: VirtioDeviceConfigurationUpdater?
    private var contextForNextGenerationProbe: VirtioDeviceContext?
    private var currentContext: VirtioDeviceContext?
    private var didDeferPendingElement = false
    // Probe mode keeps an invalidated token until the next start/stop callback
    // so the test can verify access is rejected in both lifecycle callbacks.
    private var guestMemoryMapping: GuestMemory?
    private var guestMemoryMappingGeneration: UInt64?

    /// Creates a deterministic test entropy device.
    ///
    /// - Parameters:
    ///   - seed: Seed used to create the host's guest-visible byte stream.
    ///   - logger: Logger used for ordered driver, queue, configuration, and reset events.
    ///   - resetObserver: Optional observer called from the device queue after each reset.
    ///   - startObserver: Optional observer called from the device queue after each DRIVER_OK.
    ///   - mappingObserver: Optional observer called after the guest-memory probe mapping is retained.
    ///   - stopObserver: Optional observer called when the model receives its stop callback.
    ///   - performsConfigurationProbe: Whether `DRIVER_OK` runs the same-size and size-mismatch config probes.
    ///   - probesGuestMemoryMapping: Whether to verify mapping invalidation after a guest reset.
    ///   - probesPendingElementInvalidation: Whether to defer and complete one real VZ element during stop.
    public init(
        seed: UInt64,
        logger: APKLogger? = nil,
        resetObserver: (@Sendable (UInt64) -> Void)? = nil,
        startObserver: (@Sendable (UInt64) -> Void)? = nil,
        mappingObserver: (@Sendable (UInt64) -> Void)? = nil,
        stopObserver: (@Sendable (UInt64) -> Void)? = nil,
        performsConfigurationProbe: Bool = true,
        probesGuestMemoryMapping: Bool = false,
        probesPendingElementInvalidation: Bool = false
    ) {
        self.seed = seed
        self.logger = logger ?? APKLogger(category: VMLogCategory.virtio)
        self.resetObserver = resetObserver
        self.startObserver = startObserver
        self.mappingObserver = mappingObserver
        self.stopObserver = stopObserver
        self.performsConfigurationProbe = performsConfigurationProbe
        self.probesGuestMemoryMapping = probesGuestMemoryMapping
        self.probesPendingElementInvalidation = probesPendingElementInvalidation
        generator = SplitMix64Generator(seed: seed)
    }

    /// Fills the initial guest-visible configuration and begins lifecycle accounting.
    public func deviceDidStart(
        context: VirtioDeviceContext,
        negotiatedFeatures: UInt64
    ) {
        if let staleContext = contextForNextGenerationProbe {
            contextForNextGenerationProbe = nil
            if performsConfigurationProbe {
                verifyStaleContext(staleContext, against: context)
            }
        }
        currentContext = context
        startObserver?(generation)
        notificationCount = 0
        elementCount = 0
        writtenByteCount = 0
        logger.info(
            "entropy-test DRIVER_OK generation=\(generation, .public) features=\(negotiatedFeatures, .public)"
        )
        let configurationUpdater = context.configurationUpdater
        if let previousConfigurationUpdater {
            let logger = self.logger
            let generation = self.generation
            Task {
                do {
                    try await previousConfigurationUpdater.updateConfigurationSpace(
                        Self.configurationSpace(generation: generation)
                    )
                    logger.error("entropy-test stale configuration updater was accepted")
                } catch let failure as VirtioFailure {
                    if case .notReady = failure {
                        logger.info(
                            "entropy-test stale configuration updater rejected generation=\(generation, .public)"
                        )
                    } else {
                        logger.error("entropy-test stale configuration updater probe failed")
                    }
                } catch {
                    logger.error("entropy-test stale configuration updater probe failed")
                }
            }
        }
        self.previousConfigurationUpdater = configurationUpdater
        if probesGuestMemoryMapping {
            do {
                let range = GuestPhysicalRange(address: 0x7000_0000, length: 4_096)
                let mapping = try context.mapGuestMemory(range)
                _ = try mapping.copyBytes(at: 0, count: 0)
                guestMemoryMapping = mapping
                guestMemoryMappingGeneration = generation
                logger.info("entropy-test guest memory mapping ok")
                mappingObserver?(generation)
            } catch {
                logger.error("entropy-test guest memory mapping failed")
            }
        }
        guard performsConfigurationProbe else { return }
        let generation = self.generation
        let configuration = Self.configurationSpace(generation: generation)
        let logger = self.logger
        Task {
            do {
                async let firstUpdate: Void =
                    configurationUpdater.updateConfigurationSpace(configuration)
                async let secondUpdate: Void =
                    configurationUpdater.updateConfigurationSpace(
                        Self.configurationSpace(generation: generation &+ 1)
                    )
                try await firstUpdate
                try await secondUpdate
                logger.info("entropy-test same-size configuration update ok")
                logger.info("entropy-test serialized configuration updates ok")
            } catch {
                logger.error("entropy-test same-size configuration updates failed")
            }

            do {
                try await configurationUpdater.updateConfigurationSpace(
                    Data(repeating: 0, count: 4)
                )
                logger.error("entropy-test configuration size mismatch was accepted")
            } catch let failure as VirtioFailure {
                if case .configSizeMismatch(let expected, let actual) = failure {
                    logger.info(
                        "entropy-test configuration size mismatch rejected expected=\(expected, .public) actual=\(actual, .public)"
                    )
                } else {
                    logger.error("entropy-test configuration size probe failed")
                }
            } catch {
                logger.error("entropy-test configuration size probe failed")
            }
        }
    }

    /// Fills writable elements from the deterministic byte stream.
    public func queueNotified(index: Int, context: VirtioDeviceContext) {
        let queue: any VirtioQueue
        do {
            queue = try context.queue(index)
        } catch {
            logger.error("entropy-test queue notification arrived before the device was ready")
            return
        }

        var elements = 0
        var bytesWritten = 0
        var deferredPendingElement = false
        queue.drain { element in
            elements += 1
            let requestedCount = min(element.writableByteCount, 1 * 1_024 * 1_024)
            if requestedCount > 0 {
                var bytes: [UInt8] = []
                bytes.reserveCapacity(requestedCount)
                for _ in 0..<requestedCount {
                    bytes.append(generator.nextByte())
                }
                do {
                    try bytes.withUnsafeBytes { buffer in
                        try element.write(buffer)
                    }
                    bytesWritten += bytes.count
                } catch {
                    logger.error("entropy-test could not fill a virtqueue element")
                }
            }
            if probesPendingElementInvalidation, !didDeferPendingElement {
                didDeferPendingElement = true
                deferredPendingElement = true
                let pending = element.deferCompletion()
                let completionToken = pending.makeCompletionToken()
                let generation = self.generation
                logger.info(
                    "entropy-test pending element deferred generation=\(generation, .public)"
                )
                let logger = self.logger
                let probeState = self.pendingElementProbeState
                Task {
                    [completionToken] in
                    try? await Task.sleep(for: .seconds(3))
                    let completedAfterStop = probeState.didStop
                    completionToken.complete()
                    if completedAfterStop {
                        logger.info("entropy-test pending completion attempted after stop callback")
                    } else {
                        logger.error("entropy-test pending completion preceded stop callback")
                    }
                }
            } else {
                element.complete()
            }
        }

        notificationCount += 1
        elementCount += elements
        writtenByteCount += bytesWritten
        logger.debug(
            "entropy-test queue notification generation=\(generation, .public) queue=\(index, .public) elements=\(elements, .public) bytes=\(bytesWritten, .public)"
        )
        if notificationCount == 1 || notificationCount.isMultiple(of: 64) {
            logger.info(
                "entropy-test notification summary generation=\(generation, .public) notifications=\(notificationCount, .public) elements=\(elementCount, .public) bytes=\(writtenByteCount, .public)"
            )
        }
        if deferredPendingElement {
            logger.info("entropy-test pending element probe armed")
        }
    }

    /// Records that the framework is pausing the device.
    public func deviceWillPause() {
        logger.info("entropy-test device pause")
    }

    /// Records that the framework resumed the device.
    public func deviceWillResume() {
        logger.info("entropy-test device resume")
    }

    /// Restarts the seeded stream and records invalidation after a device reset.
    public func deviceWillReset() {
        contextForNextGenerationProbe = currentContext
        verifyGuestMemoryMappingInvalidated(event: .reset)
        generation &+= 1
        generator = SplitMix64Generator(seed: seed)
        notificationCount = 0
        elementCount = 0
        writtenByteCount = 0
        logger.info("entropy-test device reset generation=\(generation, .public)")
        resetObserver?(generation)
    }

    /// Checks retained probe mappings and records the final device counters.
    public func deviceWillStop() {
        stopObserver?(generation)
        pendingElementProbeState.recordStop()
        verifyGuestMemoryMappingInvalidated(event: .stop)
        currentContext = nil
        contextForNextGenerationProbe = nil
        logger.info(
            "entropy-test device stop generation=\(generation, .public) notifications=\(notificationCount, .public) elements=\(elementCount, .public) bytes=\(writtenByteCount, .public)"
        )
    }

    private func verifyGuestMemoryMappingInvalidated(event: MappingLifecycleEvent) {
        guard probesGuestMemoryMapping, let mapping = guestMemoryMapping else { return }
        guard let mappingGeneration = guestMemoryMappingGeneration else { return }
        defer {
            if event == .stop {
                guestMemoryMapping = nil
                guestMemoryMappingGeneration = nil
            }
        }
        do {
            _ = try mapping.copyBytes(at: 0, count: 0)
            logger.error(
                "entropy-test guest memory mapping remained valid on \(event.rawValue, .public)"
            )
        } catch let failure {
            if case .guestMemoryInvalidated = failure {
                if event == .reset {
                    logger.info(
                        "entropy-test guest memory mapping invalidated on reset generation=\(mappingGeneration, .public)"
                    )
                } else {
                    logger.info(
                        "entropy-test guest memory mapping rejected access during stop mappingGeneration=\(mappingGeneration, .public)"
                    )
                }
            } else {
                logger.error(
                    "entropy-test guest memory mapping check failed on \(event.rawValue, .public)"
                )
            }
        }
    }

    private func verifyStaleContext(
        _ staleContext: VirtioDeviceContext,
        against currentContext: VirtioDeviceContext
    ) {
        let rejectedQueue: Bool
        do {
            _ = try staleContext.queue(0)
            rejectedQueue = false
        } catch .notReady {
            rejectedQueue = true
        } catch {
            rejectedQueue = false
        }
        let rejectedFeatures: Bool
        do {
            _ = try staleContext.negotiatedFeatures
            rejectedFeatures = false
        } catch .notReady {
            rejectedFeatures = true
        } catch {
            rejectedFeatures = false
        }
        let rejectedMemory: Bool
        do {
            _ = try staleContext.mapGuestMemory(
                GuestPhysicalRange(address: 0x7000_0000, length: 4)
            )
            rejectedMemory = false
        } catch .notReady {
            rejectedMemory = true
        } catch {
            rejectedMemory = false
        }

        staleContext.requestReset(reason: "stale-generation regression probe")
        let updater = currentContext.configurationUpdater
        let currentGeneration = generation
        let configuration = Self.configurationSpace(generation: currentGeneration)
        let logger = self.logger
        if rejectedQueue, rejectedFeatures, rejectedMemory {
            logger.info(
                "entropy-test stale context queue/features/memory rejected generation=\(currentGeneration, .public)"
            )
        } else {
            logger.error("entropy-test stale context operation was accepted")
        }
        Task {
            do {
                try await updater.updateConfigurationSpace(configuration)
                logger.info(
                    "entropy-test stale context reset ignored generation=\(currentGeneration, .public)"
                )
            } catch {
                logger.error("entropy-test stale context reset affected the current generation")
            }
        }
    }

    private static func configurationSpace(generation: UInt64) -> Data {
        var littleEndianGeneration = generation.littleEndian
        return withUnsafeBytes(of: &littleEndianGeneration) { Data($0) }
    }
}

private final class PendingElementProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDidStop = false

    var didStop: Bool {
        lock.withLock { storedDidStop }
    }

    func recordStop() {
        lock.withLock {
            storedDidStop = true
        }
    }
}

private struct SplitMix64Generator {
    private var state: UInt64
    private var currentWord: UInt64 = 0
    private var remainingBytes = 0

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextByte() -> UInt8 {
        if remainingBytes == 0 {
            currentWord = nextWord()
            remainingBytes = MemoryLayout<UInt64>.size
        }
        let byte = UInt8(truncatingIfNeeded: currentWord)
        currentWord >>= 8
        remainingBytes -= 1
        return byte
    }

    private mutating func nextWord() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
