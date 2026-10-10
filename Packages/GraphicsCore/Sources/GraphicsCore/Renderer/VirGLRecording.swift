import Foundation

/// One renderer operation, as the device issued it. A recording replays these calls in order (graphics.md §12).
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

/// A failure to read a recording.
enum VirGLRecordingFailure: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}

/// Collects the operations of the renderer engine it wraps. The lock makes it safe to read from another thread.
final class VirGLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [VirGLOperation] = []

    /// The operations recorded so far.
    var recording: VirGLRecording {
        VirGLRecording(operations: lock.withLock { operations })
    }

    func record(_ operation: VirGLOperation) {
        lock.withLock { operations.append(operation) }
    }
}

/// An engine that records each state-changing operation, then forwards it.
///
/// Capsets and polls are not recorded, because they change no renderer state. Teardown is not
/// recorded either: a replay starts from a fresh renderer and ends with its own teardown.
final class RecordingVirGLEngine: VirGLEngine {
    private let inner: any VirGLEngine
    private let recorder: VirGLRecorder

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
        recorder.record(.submit(context: context, commands: commands))
        try inner.submit(context: context, commands: commands)
    }

    func createResource(_ arguments: VirGLResourceArguments) throws(GraphicsFailure) {
        recorder.record(.createResource(arguments))
        try inner.createResource(arguments)
    }

    func unrefResource(id: UInt32) {
        recorder.record(.unrefResource(id: id))
        inner.unrefResource(id: id)
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

    func poll() {
        inner.poll()
    }

    func reset() throws(GraphicsFailure) {
        recorder.record(.reset)
        try inner.reset()
    }

    func destroy() throws(GraphicsFailure) {
        try inner.destroy()
    }
}

/// Replays a recording on `engine`, in order, and stops at the first failing call.
///
/// The returned index is the position of the operation that failed, or `nil` when every call succeeded.
func replay(_ recording: VirGLRecording, onto engine: any VirGLEngine) -> (index: Int, failure: GraphicsFailure)? {
    for (index, operation) in recording.operations.enumerated() {
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
            case .unrefResource(let id):
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
            }
        } catch {
            return (index, error)
        }
    }
    return nil
}
