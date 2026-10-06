import DiagnosticsCoreTestSupport
import Foundation
import Testing

@testable import DiagnosticsCore

@Test func logMessageRendersEveryPrivacyModeAndStructuredContext() {
    let operationID = "12345678-90ab-cdef-1234-567890abcdef"
    let message: LogMessage =
        "pkg \( "io.example.app", .public) path \( "/Users/alice/private.apk", .private) digest \( "source.apk", .hashed)"

    #expect(message.publicText.contains("pkg io.example.app"))
    #expect(message.publicText.contains("path <private>"))
    #expect(message.privateText?.contains("/Users/alice/private.apk") == true)
    #expect(message.privateText?.contains("<private>") == false)
    #expect(!String(describing: message).contains("/Users/alice/private.apk"))
    #expect(!String(reflecting: message).contains("/Users/alice/private.apk"))

    let digest = message.publicText.components(separatedBy: "digest ").last ?? ""
    let digestSuffixIsHex = digest.dropFirst().allSatisfy { character in character.isHexDigit }
    #expect(digest.count == 9)
    #expect(digest.first == "#")
    #expect(digestSuffixIsHex)

    let sink = RecordingLogSink()
    let logger = APKLogger(
        category: StoreLogCategory.transaction,
        sink: sink,
        context: LogContext(
            operationID: operationID,
            packageID: "io.example.app",
            displayID: "3",
            sessionID: "session-7"
        )
    )
    logger.error("install failed at \( "/private/staging", .private)", errorCode: "store.installFailed")

    let entry = sink.entries[0]
    #expect(entry.subsystem == .store)
    #expect(entry.category == "transaction")
    #expect(entry.encodedMessage.contains("\u{1F}"))
    #expect(entry.formattedPublicMessage.contains("op=12345678"))
    #expect(entry.formattedPublicMessage.contains("pkg=io.example.app"))
    #expect(entry.formattedPublicMessage.contains("disp=3"))
    #expect(entry.formattedPublicMessage.contains("sess=session-7"))
    #expect(entry.formattedPublicMessage.contains("err=store.installFailed"))
    #expect(entry.formattedPublicMessage.contains("<private>"))
    #expect(!String(describing: entry).contains("/private/staging"))
    #expect(!String(reflecting: entry).contains("/private/staging"))
}

@Test func publicOnlyLogMessageDoesNotUsePrivateSeparator() {
    let message: LogMessage = "started \( "io.example.app", .public)"
    let entry = LogEntry(
        level: .notice,
        subsystem: .cli,
        category: "command",
        publicMessage: message.publicText,
        privateMessage: message.privateText
    )

    #expect(message.privateText == nil)
    #expect(!entry.encodedMessage.contains("\u{1F}"))
}

@Test func logMessageEscapesThePrivateSeparatorInLiteralsAndValues() {
    let message: LogMessage = "literal\u{1F} \( "value\u{1F}secret", .private)"

    #expect(!message.publicText.contains("\u{1F}"))
    #expect(message.publicText.contains("\\u{001F}"))
    #expect(message.privateText?.contains("\u{1F}") == false)
}

@Test func sensitiveDescriptionIsRedacted() {
    let credential = Sensitive("fixture-secret")
    #expect(credential.description == "<redacted>")
    #expect(!String(describing: credential).contains("fixture-secret"))
    #expect(!String(reflecting: credential).contains("fixture-secret"))
}

@Test func logMessageInterpolationBuilderDoesNotReflectPrivateValues() {
    var builder = LogMessage.StringInterpolation(literalCapacity: 16, interpolationCount: 1)
    builder.appendLiteral("token ")
    builder.appendInterpolation("fixture-secret", .private)

    #expect(!String(describing: builder).contains("fixture-secret"))
    #expect(!String(reflecting: builder).contains("fixture-secret"))
}

@Test func loggerDoesNotRenderDisabledMessages() {
    let sink = RecordingLogSink(minimumLevel: .notice)
    let logger = APKLogger(category: CLILogCategory.command, sink: sink)
    let counter = DescriptionCounter()

    logger.debug("value \(counter, .public)")

    #expect(counter.count == 0)
    #expect(sink.entries.isEmpty)
}

@Test func loggerPreservesWarningSeverityAndCatalogCode() {
    let sink = RecordingLogSink(minimumLevel: .warning)
    let logger = APKLogger(category: VMLogCategory.network, sink: sink)

    logger.warning(
        "VM network attachment disconnected",
        errorCode: "vm.networkAttachmentLost"
    )

    let entry = sink.entries.first
    #expect(entry?.level == .warning)
    #expect(entry?.category == VMLogCategory.network.rawValue)
    #expect(entry?.errorCode == "vm.networkAttachmentLost")
}

private final class DescriptionCounter: CustomStringConvertible, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptions = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return descriptions
    }

    var description: String {
        lock.lock()
        descriptions += 1
        lock.unlock()
        return "counted"
    }
}
