/// The privacy classification required for each interpolated log value.
public enum LogPrivacy: Sendable {
    /// The value is safe to store in public logs and file mirrors.
    case `public`

    /// The value is hidden by default and is stored only in the private log field.
    case `private`

    /// The value is replaced by a process-local SHA-256 digest.
    case hashed
}

/// A value that must never be interpolated into a log message.
public struct Sensitive<Value: Sendable>: CustomDebugStringConvertible, CustomReflectable, Sendable {
    /// The protected value for the owning subsystem to use.
    public let value: Value

    /// Wraps a value that must never be written to logs.
    public init(_ value: Value) {
        self.value = value
    }

    /// A safe placeholder for UI or debugging descriptions.
    public var description: String { "<redacted>" }

    /// A safe debugging representation without making the value interpolatable.
    public var debugDescription: String { "<redacted>" }

    /// Hides the wrapped value from reflection-based string conversion.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [("value", "<redacted>")],
            displayStyle: .struct,
            ancestorRepresentation: .suppressed
        )
    }
}
