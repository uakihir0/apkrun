import Foundation

/// Requests runtime sizing and optional diagnostic details through the control endpoint.
public struct RuntimeInfoControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// The optional detail flags for the runtime information snapshot.
    public let request: RuntimeInfoRequest

    /// Creates a runtime-information request.
    public init(header: APIRequestHeader, request: RuntimeInfoRequest = RuntimeInfoRequest()) {
        self.header = header
        self.request = request
    }
}

/// The runtime information snapshot or a typed control-endpoint failure.
public struct RuntimeInfoControlReply: Codable, Equatable, Sendable {
    /// The runtime information snapshot, present on success.
    public let result: RuntimeInfo?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimeInfo) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case error
    }

    /// Decodes exactly one result or error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let result = try container.decodeIfPresent(RuntimeInfo.self, forKey: .result)
        let error = try container.decodeIfPresent(RuntimeWireError.self, forKey: .error)
        guard (result == nil) != (error == nil) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "A runtime-information reply must contain exactly one result or error."
                )
            )
        }
        self.result = result
        self.error = error
    }

    /// Encodes exactly one result or error.
    public func encode(to encoder: any Encoder) throws {
        guard (result == nil) != (error == nil) else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "A runtime-information reply must contain exactly one result or error."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// Requests the current app sessions through the control endpoint.
public struct RuntimeListSessionsControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader

    /// Creates a session-list request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// The session inventory or a typed control-endpoint failure.
public struct RuntimeListSessionsControlReply: Codable, Equatable, Sendable {
    /// The current session summaries, present on success.
    public let result: [SessionSummary]?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: [SessionSummary]) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case error
    }

    /// Decodes exactly one result or error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let result = try container.decodeIfPresent([SessionSummary].self, forKey: .result)
        let error = try container.decodeIfPresent(RuntimeWireError.self, forKey: .error)
        guard (result == nil) != (error == nil) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "A session-list reply must contain exactly one result or error."
                )
            )
        }
        self.result = result
        self.error = error
    }

    /// Encodes exactly one result or error.
    public func encode(to encoder: any Encoder) throws {
        guard (result == nil) != (error == nil) else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "A session-list reply must contain exactly one result or error."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}
