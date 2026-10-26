/// Sends the host's ordered BCP 47 language preferences to Android (guest-protocol.md §7.1 #46).
public struct GuestSetLocale: GuestOperation {
    /// The response body for a successful operation.
    public typealias Result = GPEmpty
    /// The `Request.op` and `Response.result` field number.
    public static let number = 46

    /// The preferred language tags, in priority order.
    public let languageTags: [String]

    /// Creates an operation for the ordered language tags.
    public init(languageTags: [String]) {
        self.languageTags = languageTags
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "SetLocale" }
    /// The capability required by this operation.
    public var capability: GuestCapability { .locale }
    /// The default request timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the protobuf request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPSetLocale()
        request.bcp47 = languageTags
        return .setLocale(request)
    }

    /// Decodes the matching response body.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .setLocale(let empty) = result { return empty }
        return nil
    }
}

/// Sets Android's time zone by its IANA identifier (guest-protocol.md §7.1 #47).
public struct GuestSetTimeZone: GuestOperation {
    /// The response body for a successful operation.
    public typealias Result = GPEmpty
    /// The `Request.op` and `Response.result` field number.
    public static let number = 47

    /// The IANA time-zone identifier.
    public let identifier: String

    /// Creates an operation for an IANA time-zone identifier.
    public init(identifier: String) {
        self.identifier = identifier
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "SetTimeZone" }
    /// The capability required by this operation.
    public var capability: GuestCapability { .locale }
    /// The default request timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the protobuf request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPSetTimeZone()
        request.tzID = identifier
        return .setTimeZone(request)
    }

    /// Decodes the matching response body.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .setTimeZone(let empty) = result { return empty }
        return nil
    }
}

/// Synchronizes the Android wall clock (guest-protocol.md §7.1 #48).
public struct GuestSyncTime: GuestOperation {
    /// The response body for a successful operation.
    public typealias Result = GPEmpty
    /// The `Request.op` and `Response.result` field number.
    public static let number = 48

    /// The host wall clock as Unix milliseconds.
    public let unixTimeMilliseconds: Int64
    /// The most recently measured guest ping round-trip time.
    public let roundTripMilliseconds: UInt32

    /// Creates an operation for a host time and measured round-trip time.
    public init(unixTimeMilliseconds: Int64, roundTripMilliseconds: UInt32) {
        self.unixTimeMilliseconds = unixTimeMilliseconds
        self.roundTripMilliseconds = roundTripMilliseconds
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "SyncTime" }
    /// The capability required by this operation.
    public var capability: GuestCapability { .locale }
    /// The default request timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the protobuf request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPSyncTime()
        request.unixTimeMs = unixTimeMilliseconds
        request.rttMs = roundTripMilliseconds
        return .syncTime(request)
    }

    /// Decodes the matching response body.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .syncTime(let empty) = result { return empty }
        return nil
    }
}

/// Sets Android's 12/24-hour clock preference (guest-protocol.md §7.1 #49).
public struct GuestSetClockFormat: GuestOperation {
    /// The response body for a successful operation.
    public typealias Result = GPEmpty
    /// The `Request.op` and `Response.result` field number.
    public static let number = 49

    /// The desired clock format.
    public let format: GPClockFormat

    /// Creates an operation for the desired clock format.
    public init(format: GPClockFormat) {
        self.format = format
    }

    /// The operation name used in diagnostics.
    public var operationName: String { "SetClockFormat" }
    /// The capability required by this operation.
    public var capability: GuestCapability { .locale }
    /// The default request timeout.
    public var timeout: Duration { .seconds(5) }

    /// Builds the protobuf request.
    public func request() -> GPRequest.OneOf_Op {
        var request = GPSetClockFormat()
        request.format = format
        return .setClockFormat(request)
    }

    /// Decodes the matching response body.
    public static func decode(_ result: GPResponse.OneOf_Result) -> GPEmpty? {
        if case .setClockFormat(let empty) = result { return empty }
        return nil
    }
}
