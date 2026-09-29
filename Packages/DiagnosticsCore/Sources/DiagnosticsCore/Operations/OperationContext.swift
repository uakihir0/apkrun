import Foundation

/// Task-local correlation context for work performed on behalf of an operation.
public struct OperationContext: Equatable, Sendable {
    /// The task-local context active in the current asynchronous flow.
    @TaskLocal public static var current: OperationContext?

    /// The identifier of this operation.
    public let operationID: OperationID

    /// The identifier of the operation that started this sub-operation.
    public let parent: OperationID?

    /// Creates an operation context with an optional parent operation.
    public init(operationID: OperationID, parent: OperationID? = nil) {
        self.operationID = operationID
        self.parent = parent
    }

    /// The current operation ID in the string form used by XPC and the guest protocol.
    public static var currentWireID: String? {
        current?.operationID.wireValue
    }

    /// Runs synchronous work under a new operation identifier.
    public static func withNew<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        try $current.withValue(OperationContext(operationID: OperationID()), operation: operation)
    }

    /// Runs asynchronous work under a new operation identifier.
    public static func withNew<Result>(
        _ operation: nonisolated(nonsending) () async throws -> Result
    ) async rethrows -> Result {
        try await $current.withValue(OperationContext(operationID: OperationID()), operation: operation)
    }

    /// Runs synchronous sub-operation work with a new ID whose parent is the current operation.
    public static func withChild<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let context = OperationContext(operationID: OperationID(), parent: current?.operationID)
        return try $current.withValue(context, operation: operation)
    }

    /// Runs asynchronous sub-operation work with a new ID whose parent is the current operation.
    public static func withChild<Result>(
        _ operation: nonisolated(nonsending) () async throws -> Result
    ) async rethrows -> Result {
        let context = OperationContext(operationID: OperationID(), parent: current?.operationID)
        return try await $current.withValue(context, operation: operation)
    }
}
