import Foundation

/// `MoveTaskToDisplay`: moves an Android task to a display (guest-protocol.md §7.1 #16).
public struct GuestMoveTaskToDisplay: GuestOperation {
    /// The decoded result of the operation.
    public typealias Result = GPEmpty
    /// The operation number of guest-protocol.md §7.1.
    public static let number = 16
    /// The task to move.
    public let taskID: Int32
    /// The destination display.
    public let displayID: Int32
    /// Whether the task should move to the back of its stack.
    public let toBack: Bool

    /// Creates the operation.
    public init(taskID: Int32, displayID: Int32, toBack: Bool = false) {
        self.taskID = taskID
        self.displayID = displayID
        self.toBack = toBack
    }

    /// The name that errors report for the operation.
    public var operationName: String { "MoveTaskToDisplay" }
    /// The capability that the operation needs.
    public var capability: GuestCapability { .launch }
    /// The time the agent has to answer.
    public var timeout: Duration { .seconds(5) }

    /// The request that carries the operation.
    public func request() -> GPRequest.OneOf_Op {
        var move = GPMoveTaskToDisplay()
        move.taskID = taskID
        move.displayID = displayID
        move.toBack = toBack
        return .moveTaskToDisplay(move)
    }

    /// Decodes the agent's answer.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .moveTaskToDisplay(let empty) = result { return empty }
        return nil
    }
}

/// `ListTasks`: reads tasks on one display or all displays (guest-protocol.md §7.1 #17).
public struct GuestListTasks: GuestOperation {
    /// The decoded result of the operation.
    public typealias Result = GPTaskList
    /// The operation number of guest-protocol.md §7.1.
    public static let number = 17
    /// The optional display to filter by; nil requests tasks from all displays.
    public let displayID: Int32?

    /// Creates the operation.
    public init(displayID: Int32? = nil) {
        self.displayID = displayID
    }

    /// The name that errors report for the operation.
    public var operationName: String { "ListTasks" }
    /// The capability that the operation needs.
    public var capability: GuestCapability { .launch }
    /// The time the agent has to answer.
    public var timeout: Duration { .seconds(5) }

    /// The request that carries the operation.
    public func request() -> GPRequest.OneOf_Op {
        var list = GPListTasks()
        if let displayID {
            list.displayID = displayID
        }
        return .listTasks(list)
    }

    /// Decodes the agent's answer.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPTaskList? {
        if case .listTasks(let tasks) = result { return tasks }
        return nil
    }
}
