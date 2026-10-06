import DiagnosticsCore
import Foundation
import Testing

@Test func errorCatalogHasLocalizedEnglishTextAndDeclaredPlaceholders() {
    let expectedCodes = Set(
        [
            "invalidTransition", "startFailed", "stoppedWithError", "pauseFailed",
            "resumeFailed", "stopTimedOut", "vsockConnectFailed", "vsockPortNotListening",
            "vsockConnectTimedOut", "virtualizationUnavailable", "cpuCountOutOfRange",
            "memoryOutOfRange", "memoryExceedsHostCap", "kernelMissing",
            "kernelNotUncompressedImage", "initrdMissing", "initrdTooLarge",
            "commandLineInvalid", "diskMissing", "diskIsAndroidSparse", "duplicateDisk",
            "diskNotReadable", "diskNotWritable", "diskSyncModeTestOnly", "diskIdentifierInvalid",
            "missingSystemConsole", "invalidMACAddress", "machineIdentifierInvalid",
            "customDeviceInvalid", "microphoneUsageDescriptionMissing", "frameworkRejected",
            "configurationInvalid", "networkAttachmentLost", "consoleLogWriteFailed",
        ].map { "vm.\($0)" }
            + [
                "confirmationRequired", "declined", "invalidPackageName", "invalidSourceSpec",
                "invalidArgument", "fileNotAccessible", "developerModeRequired", "logsUnavailable",
                "malformedReply", "versionSkew", "invalidArguments", "devConsoleRequiresTerminal",
            ].map { "cli.\($0)" }
            + [
                "instanceLocked", "instanceLockFailed", "devLinuxTimedOut",
                "devLinuxInvalidOptions", "devLinuxArtifactDirectoryMustBeAbsolute",
                "devLinuxCheckFailed", "devLinuxDidNotFinish",
                "devConsoleGuestFailed", "devConsoleInputFailed",
                "devConsoleOutputDropped", "devConsoleCleanupPending",
            ].map { "runtime.\($0)" }
            + [
                "rendererInitFailed", "rendererOperationFailed", "rendererLost", "libraryMissing",
                "scanoutInvalid",
                "modeUnsupported", "poolAllocationFailed", "configUpdateFailed", "deviceNotReady",
            ].map { "graphics.\($0)" }
    )
    #expect(Set(ErrorCatalog.entries.keys) == expectedCodes)
    #expect(ErrorCatalog.entries.values.allSatisfy { $0.message?["en"] != nil })

    let healthCheckIDs: Set<String> = [
        "vm.state",
        "vm.network",
        "vm.consoleWriter",
        "vm.virtualizationSupported",
    ]
    for entry in ErrorCatalog.entries.values {
        #expect(!healthCheckIDs.contains(entry.code))
        #expect(
            entry.code.hasPrefix("vm.")
                || entry.code.hasPrefix("cli.")
                || entry.code.hasPrefix("runtime.")
                || entry.code.hasPrefix("graphics.")
        )
        for text in entry.message?.values ?? [String: String]().values {
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(entry.parameters.isSuperset(of: placeholders(in: text)))
        }
        for text in entry.remediation?.values ?? [String: String]().values {
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(entry.parameters.isSuperset(of: placeholders(in: text)))
        }
        for variant in entry.variants.values {
            for text in variant.message?.values ?? [String: String]().values {
                #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(entry.parameters.isSuperset(of: placeholders(in: text)))
            }
            for text in variant.remediation?.values ?? [String: String]().values {
                #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(entry.parameters.isSuperset(of: placeholders(in: text)))
            }
        }
    }
}

@Test func configurationListExitUsesEveryItemAndHasSafeFallbacks() {
    #expect(
        ErrorCatalog.cliExit(
            for: CatalogFixtureError.configuration("cpuCountOutOfRange,memoryOutOfRange")
        ) == 70
    )
    #expect(
        ErrorCatalog.cliExit(
            for: CatalogFixtureError.configuration("cpuCountOutOfRange,diskMissing")
        ) == 1
    )
    #expect(ErrorCatalog.cliExit(for: CatalogFixtureError.configuration("unknownFailure")) == 1)
    #expect(ErrorCatalog.cliExit(for: CatalogFixtureError.configuration("")) == 1)
}

@Test func errorPresenterRendersHumanJSONGUIAndPathFreeCopyDetails() throws {
    let operationID = try #require(
        OperationID(wire: "123e4567-e89b-42d3-a456-426614174000")
    )
    let buildInfo = BuildInfo(
        infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
        ]
    )
    let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
    let presenter = ErrorPresenter(
        locale: Locale(identifier: "en"),
        operationID: operationID,
        buildInfo: buildInfo,
        imageVersion: "2026.10.0-arm64",
        timestamp: timestamp
    )
    let invalidArgument = CatalogCLIFixtureError.invalidArgument(
        argument: "--since",
        reason: "duration"
    )

    #expect(
        presenter.cli(invalidArgument) == """
            error: The value of --since isn't valid (duration).
            hint: Run the command with --help to see the allowed values.
            code: cli.invalidArgument (operation 123e4567)
            """
    )

    let wrapped = CatalogOuterError.wrapped(
        CatalogCLIFixtureError.invalidArgument(argument: "--since", reason: "duration")
    )
    let json = try #require(
        JSONSerialization.jsonObject(with: Data(presenter.json(wrapped).utf8)) as? [String: Any]
    )
    let error = try #require(json["error"] as? [String: Any])
    let cause = try #require(error["cause"] as? [String: Any])
    #expect(error["code"] as? String == "runtime.internal")
    #expect(error["message"] as? String == "The value of --since isn't valid (duration).")
    #expect(error["operationID"] as? String == operationID.wireValue)
    #expect(cause["code"] as? String == "cli.invalidArgument")
    #expect(cause["message"] as? String == "The value of --since isn't valid (duration).")

    let fileError = CatalogCLIFixtureError.fileNotAccessible(
        file: "/private/tmp/APKRun/customer-data.apk",
        reason: "notFound",
        underlying: UnderlyingError(domain: "NSPOSIXErrorDomain", code: 2)
    )
    let details = presenter.copyDetails(fileError)
    #expect(details.contains("cli.fileNotAccessible"))
    #expect(details.contains("underlying NSPOSIXErrorDomain 2"))
    #expect(!details.contains("customer-data.apk"))
    #expect(!details.contains("/private"))
    #expect(!details.contains("customer-data.apk/"))

    let gui = presenter.gui(fileError)
    #expect(gui.title == "customer-data.apk doesn't exist.")
    #expect(gui.body == "Check the path.")
    #expect(gui.action == .none)
    #expect(gui.copyDetails == details)
}

@Test func errorPresenterListsConfigurationItemsAndMarksWarnings() {
    let presenter = ErrorPresenter(locale: Locale(identifier: "en"))
    let listOutput = presenter.cli(
        CatalogFixtureError.configuration("kernelMissing,diskMissing")
    )
    let guiOutput = presenter.gui(
        CatalogFixtureError.configuration("kernelMissing,diskMissing")
    )
    #expect(guiOutput.hints.map(\.code) == ["vm.kernelMissing", "vm.diskMissing"])
    #expect(
        guiOutput.hints.map(\.message) == [
            "Files that Android needs are missing, or APKRun can't read or write them.",
            "Files that Android needs are missing, or APKRun can't read or write them.",
        ])
    let hintCount =
        listOutput
        .split(separator: "\n")
        .filter { $0.hasPrefix("hint:") }
        .count
    #expect(hintCount == 3)
    #expect(listOutput.contains("hint: vm.kernelMissing:"))
    #expect(listOutput.contains("hint: vm.diskMissing:"))

    let jsonOutput = presenter.json(
        CatalogFixtureError.configuration("kernelMissing,diskMissing")
    )
    let json = try? JSONSerialization.jsonObject(with: Data(jsonOutput.utf8)) as? [String: Any]
    let errorObject = json?["error"] as? [String: Any]
    let hints = errorObject?["hints"] as? [[String: String]]
    #expect(hints?.map { $0["code"] } == ["vm.kernelMissing", "vm.diskMissing"])

    let warning = presenter.cli(
        CatalogCLIFixtureError.versionSkew(version: "1.0", found: "1.1")
    )
    #expect(warning.hasPrefix("warning:"))
    #expect(warning.contains("code: cli.versionSkew"))
}

@Test func errorPresenterInheritsCauseRemediationAndEscapesTerminalControls() {
    let presenter = ErrorPresenter(locale: Locale(identifier: "en"))
    let wrapped = CatalogDeclinedOuterError(innerError: CatalogFixtureError.startFailed)
    let rendered = presenter.gui(wrapped)
    #expect(rendered.title == "Nothing was changed.")
    #expect(rendered.body == "Try again. If it fails again, create a diagnostics report.")
    #expect(rendered.action == .retry)

    let injected = presenter.cli(
        CatalogCLIFixtureError.invalidPackageName(
            package: "bad\nerror: spoof\u{1B}[2J"
        )
    )
    let lines = injected.split(separator: "\n")
    #expect(lines.count == 3)
    #expect(lines[0].contains(#"bad\u{A}error: spoof\u{1B}"#))
}

@Test func errorParameterCodableRoundTripsEveryPayloadKind() throws {
    let parameters: [ErrorParameter] = [
        .text("public text"),
        .bytes(1_234_567),
        .count(42),
        .duration(.milliseconds(1_250)),
        .fileName("sample.apk"),
    ]
    let encoded = try JSONEncoder().encode(parameters)
    let decoded = try JSONDecoder().decode([ErrorParameter].self, from: encoded)
    #expect(decoded == parameters)

    let unsafeFileName = try JSONEncoder().encode(
        ErrorParameter.fileName("/private/tmp/customer-data.apk")
    )
    let serializedName = String(decoding: unsafeFileName, as: UTF8.self)
    #expect(!serializedName.contains("/private"))
    #expect(serializedName.contains("customer-data.apk"))
    #expect(try JSONDecoder().decode(ErrorParameter.self, from: unsafeFileName) == .fileName("customer-data.apk"))
}

private func placeholders(in text: String) -> Set<String> {
    guard let expression = try? NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9]*)\}"#) else {
        return []
    }
    let source = text as NSString
    return Set(
        expression.matches(in: text, range: NSRange(location: 0, length: source.length))
            .compactMap { match in
                guard match.numberOfRanges == 2 else { return nil }
                return source.substring(with: match.range(at: 1))
            }
    )
}

private indirect enum CatalogFixtureError: APKRunError {
    case startFailed
    case configuration(String)

    static var domain: ErrorDomain {
        .vm
    }

    var code: String {
        switch self {
        case .startFailed:
            "startFailed"
        case .configuration:
            "configurationInvalid"
        }
    }

    var parameters: [String: ErrorParameter] {
        switch self {
        case .configuration(let items):
            ["items": .text(items)]
        case .startFailed:
            [:]
        }
    }

}

private enum CatalogCLIFixtureError: APKRunError {
    case invalidArgument(argument: String, reason: String)
    case invalidPackageName(package: String)
    case fileNotAccessible(file: String, reason: String, underlying: UnderlyingError?)
    case versionSkew(version: String, found: String)

    static var domain: ErrorDomain { .cli }

    var code: String {
        switch self {
        case .invalidArgument:
            "invalidArgument"
        case .invalidPackageName:
            "invalidPackageName"
        case .fileNotAccessible:
            "fileNotAccessible"
        case .versionSkew:
            "versionSkew"
        }
    }

    var parameters: [String: ErrorParameter] {
        switch self {
        case .invalidArgument(let argument, let reason):
            ["argument": .text(argument), "reason": .text(reason)]
        case .invalidPackageName(let package):
            ["package": .text(package)]
        case .fileNotAccessible(let file, let reason, _):
            ["file": .fileName(file), "reason": .text(reason)]
        case .versionSkew(let version, let found):
            ["version": .text(version), "found": .text(found)]
        }
    }

    var underlying: UnderlyingError? {
        guard case .fileNotAccessible(_, _, let underlying) = self else { return nil }
        return underlying
    }
}

private struct CatalogOuterError: APKRunError {
    let innerError: any APKRunError

    static var domain: ErrorDomain { .runtime }

    var code: String { "internal" }

    var cause: (any APKRunError)? { innerError }
}

private struct CatalogDeclinedOuterError: APKRunError {
    let innerError: any APKRunError

    static var domain: ErrorDomain { .cli }
    var code: String { "declined" }
    var cause: (any APKRunError)? { innerError }
}

extension CatalogOuterError {
    fileprivate static func wrapped(_ cause: any APKRunError) -> CatalogOuterError {
        CatalogOuterError(innerError: cause)
    }
}
