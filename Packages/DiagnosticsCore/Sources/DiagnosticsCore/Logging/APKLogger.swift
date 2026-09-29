/// A type-safe logger bound to one statically declared category.
public struct APKLogger: Sendable {
    private let subsystem: LogSubsystem
    private let category: String
    private let sink: any LogSink
    private let context: LogContext

    /// Creates a logger for a declared category.
    ///
    /// - Parameters:
    ///   - category: A category whose type declares its owning subsystem.
    ///   - sink: An injected sink, or the production OSLog sink when omitted.
    ///   - context: Public-safe identifiers appended to each entry.
    public init(category: RuntimeLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .runtime, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for a virtual machine category.
    public init(category: VMLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .vm, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for a graphics category.
    public init(category: GraphicsLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .graphics, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for an input category.
    public init(category: InputLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .input, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for an image category.
    public init(category: ImageLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .image, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for a package store category.
    public init(category: StoreLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .store, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for an app update category.
    public init(category: UpdateLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .update, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for a wrapper category.
    public init(category: WrapperLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .wrapper, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for an integration category.
    public init(category: IntegrationLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .integration, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for a maintenance category.
    public init(category: MaintenanceLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .maintenance, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for an app user interface category.
    public init(category: UILogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .ui, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for a menu bar category.
    public init(category: MenuBarLogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .menubar, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for a command-line category.
    public init(category: CLILogCategory, sink: (any LogSink)? = nil, context: LogContext = LogContext()) {
        self.init(subsystem: .cli, category: category.rawValue, sink: sink, context: context)
    }

    /// Creates a logger for a diagnostics category.
    public init(
        category: DiagnosticsLogCategory,
        sink: (any LogSink)? = nil,
        context: LogContext = LogContext()
    ) {
        self.init(subsystem: .diagnostics, category: category.rawValue, sink: sink, context: context)
    }

    private init(
        subsystem: LogSubsystem,
        category: String,
        sink: (any LogSink)?,
        context: LogContext
    ) {
        self.subsystem = subsystem
        self.category = category
        self.sink = sink ?? OSLogSink(subsystem: subsystem, category: category)
        self.context = context
    }

    /// Writes a high-volume diagnostic message.
    public func debug(_ message: @autoclosure () -> LogMessage) {
        write(.debug, message: message)
    }

    /// Writes a state change or operation timing.
    public func info(_ message: @autoclosure () -> LogMessage) {
        write(.info, message: message)
    }

    /// Writes a user-visible outcome.
    public func notice(_ message: @autoclosure () -> LogMessage) {
        write(.notice, message: message)
    }

    /// Writes an operation failure and its qualified error code.
    public func error(_ message: @autoclosure () -> LogMessage, errorCode: String? = nil) {
        write(.error, message: message, errorCode: errorCode)
    }

    /// Writes an invariant violation.
    public func fault(_ message: @autoclosure () -> LogMessage, errorCode: String? = nil) {
        write(.fault, message: message, errorCode: errorCode)
    }

    private func write(
        _ level: LogLevel,
        message: () -> LogMessage,
        errorCode: String? = nil
    ) {
        guard sink.isEnabled(for: level) else { return }
        let renderedMessage = message()
        let entry = LogEntry(
            level: level,
            subsystem: subsystem,
            category: category,
            publicMessage: renderedMessage.publicText,
            privateMessage: renderedMessage.privateText,
            context: contextForCurrentTask,
            errorCode: errorCode
        )
        sink.write(entry)
    }

    private var contextForCurrentTask: LogContext {
        LogContext(
            operationID: OperationContext.currentWireID ?? context.operationID,
            packageID: context.packageID,
            displayID: context.displayID,
            sessionID: context.sessionID
        )
    }
}
