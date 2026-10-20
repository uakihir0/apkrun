import Foundation
import IOSurface

/// One renderer operation, as the device issued it. A recording replays these calls in order (graphics.md §14).
enum VirGLOperation: Codable, Equatable, Sendable {
    case createContext(id: UInt32, name: String)
    case destroyContext(id: UInt32)
    case attachResource(context: UInt32, resource: UInt32)
    case detachResource(context: UInt32, resource: UInt32)
    case submit(context: UInt32, commands: [UInt8])
    case createResource(VirGLResourceArguments)
    case unrefResource(id: UInt32)
    case transferWrite(VirGLTransfer, data: [UInt8])
    case transferRead(VirGLTransfer, byteCount: Int)
    case createFence(id: UInt32, context: UInt32)
    case reset
}

/// The renderer operations of one session, in order: the input of the replay test.
struct VirGLRecording: Codable, Equatable, Sendable {
    /// The format version of the recording. A reader rejects any other value.
    static let currentVersion = 1

    var version: Int
    var operations: [VirGLOperation]

    init(operations: [VirGLOperation]) {
        version = Self.currentVersion
        self.operations = operations
    }

    /// The recording as JSON.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decodes a recording, and rejects a version that this build does not read.
    static func decoded(from data: Data) throws -> VirGLRecording {
        let recording = try JSONDecoder().decode(VirGLRecording.self, from: data)
        guard recording.version == currentVersion else {
            throw VirGLRecordingFailure.unsupportedVersion(recording.version)
        }
        return recording
    }
}

/// A test-only summary of guest memory observed through a VirGL backing range.
///
/// The observation contains counts only. It never retains or serializes the guest bytes.
public struct VirGLGuestBackingObservation: Equatable, Sendable {
    /// The VirGL resource whose guest backing was observed.
    public let resourceID: UInt32
    /// The number of ranges the guest attached to the resource.
    public let rangeCount: Int
    /// The number of bytes read from the backing ranges.
    public let sampledByteCount: Int
    /// The number of nonzero sampled bytes visible through the host pointers.
    public let nonzeroByteCount: Int
}

/// A failure to read a recording.
public enum VirGLRecordingFailure: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    /// The recording could not be encoded or written to the file at `path`.
    case writeFailed(path: String)
}

/// Collects the operations of the renderer engine it wraps. The lock makes it safe to read from another thread.
///
/// The development Linux run attaches one through `VirtioGPUDevice.virgl(recorder:)` and writes the recording with
/// `writeRecording(to:)`, so the `kmscube` stream can be replayed (graphics.md §14, M02-graphics.md #23 step 3).
public final class VirGLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private static let maximumGuestBackingSampleBytes = 4096
    private let observedGuestResourceIDs: Set<UInt32>
    private let recordsOperations: Bool
    private var operations: [VirGLOperation] = []
    private var guestBackingObservations: [UInt32: VirGLGuestBackingObservation] = [:]
    private var attachedGuestBackingResourceIDs = Set<UInt32>()

    /// Creates a recorder.
    ///
    /// - Parameters:
    ///   - observingGuestResourceIDs: Guest resource IDs to sample before their first renderer submission after
    ///     backing is attached. At most 4096 bytes per resource are inspected, and only byte counts are retained.
    ///     Guest bytes are never retained or serialized.
    ///   - recordsOperations: Whether to retain renderer operations for a replay recording.
    public init(
        observingGuestResourceIDs: Set<UInt32> = [],
        recordsOperations: Bool = true
    ) {
        self.observedGuestResourceIDs = observingGuestResourceIDs
        self.recordsOperations = recordsOperations
    }

    /// The operations recorded so far.
    var recording: VirGLRecording {
        VirGLRecording(operations: lock.withLock { operations })
    }

    /// Test-only summaries of guest backing ranges sampled before the first renderer submission after attachment.
    public func guestBackingObservationsForTest() -> [VirGLGuestBackingObservation] {
        lock.withLock {
            guestBackingObservations.values.sorted { $0.resourceID < $1.resourceID }
        }
    }

    /// The latest observation for a configured resource ID if it belongs to the backing currently attached to the
    /// renderer.
    public func guestBackingObservationIfAttachedForTest(
        resourceID: UInt32
    ) -> VirGLGuestBackingObservation? {
        lock.withLock {
            guard attachedGuestBackingResourceIDs.contains(resourceID) else { return nil }
            return guestBackingObservations[resourceID]
        }
    }

    /// Writes the operations recorded so far to `url`, in the replay format of `VirGLRecording` (version 1).
    public func writeRecording(to url: URL) throws(VirGLRecordingFailure) {
        do {
            try recording.encoded().write(to: url, options: .atomic)
        } catch {
            throw VirGLRecordingFailure.writeFailed(path: url.path)
        }
    }

    func record(_ operation: VirGLOperation) {
        guard recordsOperations else { return }
        lock.withLock { operations.append(operation) }
    }

    func observesGuestResource(_ resourceID: UInt32) -> Bool {
        observedGuestResourceIDs.contains(resourceID)
    }

    func guestBackingDidAttach(resourceID: UInt32) {
        lock.withLock {
            _ = guestBackingObservations.removeValue(forKey: resourceID)
            _ = attachedGuestBackingResourceIDs.insert(resourceID)
        }
    }

    func guestBackingDidDetach(resourceID: UInt32) {
        lock.withLock {
            _ = attachedGuestBackingResourceIDs.remove(resourceID)
        }
    }

    func guestBackingsDidReset() {
        lock.withLock {
            attachedGuestBackingResourceIDs.removeAll()
        }
    }

    /// Samples up to 4096 bytes from the live ranges that the renderer receives for an observed resource. This runs
    /// on the render thread, before the renderer is called with commands that may use the same resource.
    @discardableResult
    func observeGuestBacking(
        resourceID: UInt32,
        ranges: [VirGLBackingRange]
    ) -> VirGLGuestBackingObservation? {
        guard observesGuestResource(resourceID), !ranges.isEmpty else { return nil }

        var sampledByteCount = 0
        var nonzeroByteCount = 0
        for range in ranges {
            let bytesToSample = min(range.count, Self.maximumGuestBackingSampleBytes - sampledByteCount)
            guard bytesToSample > 0 else { break }

            let bytes = range.base.assumingMemoryBound(to: UInt8.self)
            for offset in 0..<bytesToSample where bytes[offset] != 0 {
                nonzeroByteCount += 1
            }
            sampledByteCount += bytesToSample
        }

        let observation = VirGLGuestBackingObservation(
            resourceID: resourceID,
            rangeCount: ranges.count,
            sampledByteCount: sampledByteCount,
            nonzeroByteCount: nonzeroByteCount
        )
        lock.withLock {
            guestBackingObservations[resourceID] = observation
        }
        return observation
    }
}

/// An engine that records each state-changing operation, then forwards it.
///
/// Capsets and polls are not recorded, because they change no renderer state. Teardown is not
/// recorded either: a replay starts from a fresh renderer and ends with its own teardown.
final class RecordingVirGLEngine: VirGLEngine {
    private let inner: any VirGLEngine
    private let recorder: VirGLRecorder
    /// Accessed only on the render thread.
    private var attachedGuestBackings: [UInt32: [VirGLBackingRange]] = [:]
    /// Bound the observer to one sample per attached backing.
    private var sampledGuestResources = Set<UInt32>()

    init(wrapping inner: any VirGLEngine, recorder: VirGLRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func capsetInfo(id: UInt32) throws(GraphicsFailure) -> GraphicsCapsetInfo {
        try inner.capsetInfo(id: id)
    }

    func fillCapset(id: UInt32, version: UInt32, into buffer: inout [UInt8]) throws(GraphicsFailure) {
        try inner.fillCapset(id: id, version: version, into: &buffer)
    }

    func createContext(id: UInt32, name: String) throws(GraphicsFailure) {
        recorder.record(.createContext(id: id, name: name))
        try inner.createContext(id: id, name: name)
    }

    func destroyContext(id: UInt32) throws(GraphicsFailure) {
        recorder.record(.destroyContext(id: id))
        try inner.destroyContext(id: id)
    }

    func attachResource(context: UInt32, resource: UInt32) throws(GraphicsFailure) {
        recorder.record(.attachResource(context: context, resource: resource))
        try inner.attachResource(context: context, resource: resource)
    }

    func detachResource(context: UInt32, resource: UInt32) throws(GraphicsFailure) {
        recorder.record(.detachResource(context: context, resource: resource))
        try inner.detachResource(context: context, resource: resource)
    }

    func submit(context: UInt32, commands: [UInt8]) throws(GraphicsFailure) {
        for (resourceID, ranges) in attachedGuestBackings
        where recorder.observesGuestResource(resourceID) && !sampledGuestResources.contains(resourceID) {
            if recorder.observeGuestBacking(resourceID: resourceID, ranges: ranges) != nil {
                sampledGuestResources.insert(resourceID)
            }
        }
        recorder.record(.submit(context: context, commands: commands))
        try inner.submit(context: context, commands: commands)
    }

    func createResource(_ arguments: VirGLResourceArguments) throws(GraphicsFailure) {
        recorder.record(.createResource(arguments))
        try inner.createResource(arguments)
    }

    func unrefResource(id: UInt32) {
        recorder.record(.unrefResource(id: id))
        attachedGuestBackings.removeValue(forKey: id)
        sampledGuestResources.remove(id)
        recorder.guestBackingDidDetach(resourceID: id)
        inner.unrefResource(id: id)
    }

    /// Backing is forwarded but not recorded. The pages belong to the guest, and the recording does not hold them.
    /// A replay supplies its own pages (IR-845).
    func attachBacking(resource: UInt32, ranges: [VirGLBackingRange]) throws(GraphicsFailure) {
        try inner.attachBacking(resource: resource, ranges: ranges)
        if recorder.observesGuestResource(resource) {
            attachedGuestBackings[resource] = ranges
            recorder.guestBackingDidAttach(resourceID: resource)
        }
    }

    func detachBacking(resource: UInt32) {
        attachedGuestBackings.removeValue(forKey: resource)
        sampledGuestResources.remove(resource)
        recorder.guestBackingDidDetach(resourceID: resource)
        inner.detachBacking(resource: resource)
    }

    func transferWrite(_ transfer: VirGLTransfer, data: inout [UInt8]) throws(GraphicsFailure) {
        recorder.record(.transferWrite(transfer, data: data))
        try inner.transferWrite(transfer, data: &data)
    }

    func transferRead(_ transfer: VirGLTransfer, into data: inout [UInt8]) throws(GraphicsFailure) {
        recorder.record(.transferRead(transfer, byteCount: data.count))
        try inner.transferRead(transfer, into: &data)
    }

    func createFence(id: UInt32, context: UInt32) throws(GraphicsFailure) {
        recorder.record(.createFence(id: id, context: context))
        try inner.createFence(id: id, context: context)
    }

    // Presentation changes no state that the replay restores, so it is forwarded and not recorded (graphics.md §14).
    func createPresentTarget(
        surface: IOSurface,
        width: UInt32,
        height: UInt32
    ) throws(GraphicsFailure) -> any PresentTarget {
        try inner.createPresentTarget(surface: surface, width: width, height: height)
    }

    func destroyPresentTarget(_ target: any PresentTarget) {
        inner.destroyPresentTarget(target)
    }

    func presentBlit(
        resource: UInt32,
        sourceRect: VirtioGPURect,
        into target: any PresentTarget
    ) throws(GraphicsFailure) -> any PresentFence {
        try inner.presentBlit(resource: resource, sourceRect: sourceRect, into: target)
    }

    func poll() {
        inner.poll()
    }

    func reset() throws(GraphicsFailure) {
        recorder.record(.reset)
        try inner.reset()
        attachedGuestBackings.removeAll()
        sampledGuestResources.removeAll()
        recorder.guestBackingsDidReset()
    }

    func destroy() throws(GraphicsFailure) {
        try inner.destroy()
        attachedGuestBackings.removeAll()
        sampledGuestResources.removeAll()
        recorder.guestBackingsDidReset()
    }
}

/// The result of a replay: how many operations ran, and each failing one with its position in the recording.
struct VirGLReplayOutcome {
    /// The operations that the replay ran. It equals the recording's count when the replay reached the end.
    let attempted: Int
    /// The failing operations, in order.
    let failures: [(index: Int, failure: GraphicsFailure)]
}

/// Replays a recording on `engine`, in order. Like the device, it goes on after a failing call: the device counts the
/// failure and still answers the guest (IR-460), so a stream with rejected calls replays the same way (IR-811).
///
/// The failures are returned, not counted in the device's counters, so a replay leaves the renderer failure count alone.
///
/// With `suppliesBacking`, each resource that the replay creates gets zeroed guest pages of its size, as the guest
/// attaches them. The recording holds no backing, and the renderer reads an in-stream transfer from its backing
/// (IR-831), so the replay supplies it (IR-845). The pages hold no guest data, so the replay checks the renderer's
/// calls, not the pixels.
func replay(
    _ recording: VirGLRecording,
    onto engine: any VirGLEngine,
    suppliesBacking: Bool = false
) -> VirGLReplayOutcome {
    var failures: [(index: Int, failure: GraphicsFailure)] = []
    var attempted = 0
    let backing = ReplayBacking()
    for (index, operation) in recording.operations.enumerated() {
        attempted += 1
        do throws(GraphicsFailure) {
            switch operation {
            case .createContext(let id, let name):
                try engine.createContext(id: id, name: name)
            case .destroyContext(let id):
                try engine.destroyContext(id: id)
            case .attachResource(let context, let resource):
                try engine.attachResource(context: context, resource: resource)
            case .detachResource(let context, let resource):
                try engine.detachResource(context: context, resource: resource)
            case .submit(let context, let commands):
                try engine.submit(context: context, commands: commands)
            case .createResource(let arguments):
                try engine.createResource(arguments)
                if suppliesBacking {
                    try backing.attach(arguments, to: engine)
                }
            case .unrefResource(let id):
                // The renderer releases the pages when the resource goes, so the replay releases them first.
                backing.release(resource: id, from: engine)
                engine.unrefResource(id: id)
            case .transferWrite(let transfer, var data):
                try engine.transferWrite(transfer, data: &data)
            case .transferRead(let transfer, let byteCount):
                var data = [UInt8](repeating: 0, count: byteCount)
                try engine.transferRead(transfer, into: &data)
            case .createFence(let id, let context):
                try engine.createFence(id: id, context: context)
            case .reset:
                try engine.reset()
                backing.forgetAll()
            }
        } catch {
            failures.append((index, error))
        }
    }
    backing.releaseAll(from: engine)
    return VirGLReplayOutcome(attempted: attempted, failures: failures)
}

/// The zeroed guest pages that a replay gives the resources it creates, of the size the resource table counts them.
/// The replay owns the pages. It releases each one in the renderer before it frees the pages (IR-845).
private final class ReplayBacking {
    private var pages: [UInt32: VirGLBackingRange] = [:]

    /// Attaches zeroed pages to the resource that `arguments` creates. A format that the table does not accept gets none.
    func attach(_ arguments: VirGLResourceArguments, to engine: any VirGLEngine) throws(GraphicsFailure) {
        guard let count = Self.byteCount(arguments), count > 0, let base = calloc(count, 1) else { return }
        guard let range = VirGLBackingRange(UnsafeMutableRawBufferPointer(start: base, count: count)) else {
            free(base)
            return
        }
        do throws(GraphicsFailure) {
            try engine.attachBacking(resource: arguments.resourceID, ranges: [range])
        } catch {
            free(base)
            throw error
        }
        pages[arguments.resourceID] = range
    }

    /// Releases the pages of `resource` in the renderer, then frees them. A resource without pages is left alone.
    func release(resource: UInt32, from engine: any VirGLEngine) {
        guard let range = pages.removeValue(forKey: resource) else { return }
        engine.detachBacking(resource: resource)
        free(range.base)
    }

    /// Frees the pages after a reset, which has already released them in the renderer.
    func forgetAll() {
        for range in pages.values {
            free(range.base)
        }
        pages.removeAll()
    }

    /// Releases every remaining backing at the end of a replay, while the renderer still runs.
    func releaseAll(from engine: any VirGLEngine) {
        for resource in Array(pages.keys) {
            release(resource: resource, from: engine)
        }
    }

    /// The bytes of a resource at level 0, counted as `ResourceTable` counts them, or `nil` for a format it refuses.
    private static func byteCount(_ arguments: VirGLResourceArguments) -> Int? {
        guard let layout = ResourceTable.layout(format: arguments.format) else { return nil }
        if arguments.target == 0 {
            return Int(arguments.width) * Int(layout.bytesPerBlock)
        }
        guard
            let bytes = try? ResourceTable.textureBytes(
                width: arguments.width,
                height: arguments.height,
                depth: arguments.depth,
                arraySize: arguments.arraySize,
                layout: layout
            )
        else {
            return nil
        }
        return Int(exactly: bytes)
    }
}
