import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import RuntimeAPI
import RuntimeClient
import Testing

@testable import apkrun

#if APKRUN_EMBEDDED_RUNTIME
    import Darwin
#endif

@Test func packageQueryAndRuntimeInfoCommandsParse() async throws {
    let list = try await APKRunCommand.asyncParseAsRoot(["list", "--all", "--json"])
    #expect((list as? ListPackagesCommand)?.all == true)
    #expect((list as? ListPackagesCommand)?.json == true)

    let packageInfo = try await APKRunCommand.asyncParseAsRoot([
        "info", "io.apkrun.fixture.hellotext", "--json",
    ])
    #expect((packageInfo as? PackageInfoCommand)?.package == "io.apkrun.fixture.hellotext")
    #expect((packageInfo as? PackageInfoCommand)?.json == true)

    let overview = try await APKRunCommand.asyncParseAsRoot(["info"])
    #expect((overview as? PackageInfoCommand)?.package == nil)

    let runtimeInfo = try await APKRunCommand.asyncParseAsRoot(["info", "--runtime"])
    #expect((runtimeInfo as? PackageInfoCommand)?.package == nil)
    #expect((runtimeInfo as? PackageInfoCommand)?.runtime == true)
}

#if !APKRUN_EMBEDDED_RUNTIME
    @Test func daemonInstallCommandParsesConfirmationAndJSONFlags() async throws {
        let command = try await APKRunCommand.asyncParseAsRoot([
            "install", "example.apk", "--yes", "--json", "--detach",
        ])

        #expect((command as? InstallCommand)?.files == ["example.apk"])
        #expect((command as? InstallCommand)?.yes == true)
        #expect((command as? InstallCommand)?.json == true)
        #expect((command as? InstallCommand)?.detach == true)
    }

    @Test func operationsCommandsParseListWaitAndCancel() async throws {
        let list = try await APKRunCommand.asyncParseAsRoot(["operations", "list", "--json"])
        #expect((list as? OperationsListCommand)?.json == true)

        let operationID = "41f9ed7b-a123-4ebd-9a61-7a2be9465780"
        let wait = try await APKRunCommand.asyncParseAsRoot([
            "operations", "wait", operationID, "--detach",
        ])
        #expect((wait as? OperationsWaitCommand)?.id == operationID)
        #expect((wait as? OperationsWaitCommand)?.detach == true)

        let cancel = try await APKRunCommand.asyncParseAsRoot([
            "operations", "cancel", operationID, "--json",
        ])
        #expect((cancel as? OperationsCancelCommand)?.id == operationID)
        #expect((cancel as? OperationsCancelCommand)?.json == true)
    }

    @Test func operationPollingWaitsForTerminalSnapshotAndRejectsUnknownResult() async throws {
        let operationID = RuntimeAPI.OperationID()
        let packageID = try #require(RuntimePackageID(rawValue: "com.example.app"))
        let summary = RuntimePackageSummary(
            packageID: packageID,
            displayName: "Example",
            versionCode: 42
        )
        let queue = FakeOperationStatusQueue([
            OperationSnapshot(
                operationID: operationID,
                kind: .install,
                startedAt: Date(timeIntervalSince1970: 1),
                progress: OperationProgress(stage: "startingRuntime")
            ),
            OperationSnapshot(
                operationID: operationID,
                kind: .install,
                startedAt: Date(timeIntervalSince1970: 1),
                result: .succeeded(.package(summary)),
                finishedAt: Date(timeIntervalSince1970: 2)
            ),
        ])

        let finished = try await OperationCommandOutput.waitForTerminalSnapshot(
            operationID: operationID,
            progressToStderr: false,
            pollInterval: .zero,
            query: { id in await queue.next(id) },
            sleep: { _ in }
        )
        #expect(try OperationCommandOutput.installedPackage(from: finished, expectedPackageID: packageID) == summary)

        let unknown = OperationSnapshot(
            operationID: operationID,
            kind: .install,
            startedAt: Date(timeIntervalSince1970: 1),
            result: .unknown,
            finishedAt: Date(timeIntervalSince1970: 2)
        )
        do {
            try OperationCommandOutput.requireSuccess(unknown)
            Issue.record("an unknown operation result unexpectedly counted as success")
        } catch let failure as RuntimeWireError {
            #expect(failure.code == "runtime.operationResultUnknown")
            #expect(ExitCodes.code(for: failure) != ExitCodes.success)
        }
    }

    @Test func missingOperationRemainsNotFoundAndNeverBecomesSuccess() async {
        let missing = RuntimeWireError.runtime(
            "operationNotFound",
            message: "That operation doesn't exist or has expired."
        )
        let failure = await OperationCommandOutput.commandFailure(missing)

        #expect(failure.code == "runtime.operationNotFound")
        #expect(ExitCodes.code(for: failure) == ExitCodes.notFound)
    }

    @Test func unknownOperationOutputAndCancellationDispositionNeverSucceed() throws {
        let operationID = RuntimeAPI.OperationID()
        let unknownOutput = OperationSnapshot(
            operationID: operationID,
            kind: .install,
            startedAt: Date(timeIntervalSince1970: 1),
            result: .succeeded(.unknown),
            finishedAt: Date(timeIntervalSince1970: 2)
        )
        #expect(throws: RuntimeWireError.self) {
            try OperationCommandOutput.requireSuccess(unknownOutput)
        }
        #expect(throws: RuntimeWireError.self) {
            try OperationCommandOutput.checkCancelResult(.unknown)
        }
        #expect(throws: RuntimeWireError.self) {
            try OperationCommandOutput.checkCancelResult(.alreadyFinished(.unknown))
        }
    }

    @Test func operationInstallResultMustContainTheExpectedPackage() async throws {
        let operationID = RuntimeAPI.OperationID()
        let expectedPackageID = try #require(RuntimePackageID(rawValue: "com.example.expected"))
        let otherPackageID = try #require(RuntimePackageID(rawValue: "com.example.other"))
        let summary = RuntimePackageSummary(
            packageID: otherPackageID,
            displayName: "Other",
            versionCode: 7
        )
        let snapshot = OperationSnapshot(
            operationID: operationID,
            kind: .install,
            startedAt: Date(timeIntervalSince1970: 1),
            result: .succeeded(.package(summary)),
            finishedAt: Date(timeIntervalSince1970: 2)
        )

        do {
            _ = try OperationCommandOutput.installedPackage(
                from: snapshot,
                expectedPackageID: expectedPackageID
            )
            Issue.record("an install result for another package unexpectedly counted as success")
        } catch let failure as RuntimeWireError {
            #expect(failure.code == "runtime.operationResultUnknown")
        }
    }

    @Test func operationListSanitizesProgressBeforeTerminalOutput() {
        let operation = OperationSnapshot(
            operationID: RuntimeAPI.OperationID(),
            kind: .install,
            startedAt: Date(timeIntervalSince1970: 1),
            progress: OperationProgress(message: "Installing\u{001B}[2J\nAPK")
        )

        let text = OperationCommandOutput.listText([operation])
        #expect(text.contains("Installing�[2J�APK"))
        #expect(!text.contains("\u{001B}"))
        #expect(!text.contains("\nAPK"))
    }

    @Test func daemonInstallRejectsMoreThanTwentyInputFilesBeforeOpeningThem() {
        let paths = Array(repeating: "not-opened.apk", count: 21)
        do {
            _ = try DaemonInstallSupport.inputFiles(paths)
            Issue.record("more than twenty package files unexpectedly passed validation")
        } catch let failure as CLIFailure {
            guard case .invalidArgument(let argument, let reason) = failure else {
                Issue.record("unexpected CLI failure: \(failure)")
                return
            }
            #expect(argument == "file")
            #expect(reason == "tooMany")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func daemonInstallDowngradePromptExplainsRuntimeRecheck() throws {
        let preview = RuntimeImportPreview(
            ticket: try #require(RuntimeImportTicket(rawValue: "00000000-0000-0000-0000-000000000001")),
            packageID: try #require(RuntimePackageID(rawValue: "com.example.app")),
            displayName: "Example",
            versionCode: 12,
            files: [],
            relation: .downgrade(from: 18)
        )

        let prompt = DaemonInstallSupport.installConfirmationPrompt(for: preview)
        #expect(prompt.contains("version 12, below version 18"))
        #expect(prompt.contains("Recheck Android's current version"))
        #expect(!prompt.contains("debuggable Android"))
    }

    @Test func daemonInstallPreviewShowsFileHashesAndSigningStatus() throws {
        let preview = RuntimeImportPreview(
            ticket: try #require(RuntimeImportTicket(rawValue: "00000000-0000-0000-0000-000000000001")),
            packageID: try #require(RuntimePackageID(rawValue: "com.example.app")),
            displayName: "Example",
            versionCode: 12,
            files: [
                RuntimeArtifactFile(
                    name: "base.apk",
                    size: 120,
                    sha256: try #require(
                        RuntimeSHA256Digest(rawValue: "sha256:\(String(repeating: "a", count: 64))")
                    )
                )
            ],
            relation: .newPackage,
            warnings: [.signingNotChecked]
        )

        let text = DaemonInstallSupport.previewText(preview)
        #expect(text.contains("Files (1, 120 bytes):"))
        #expect(text.contains("base.apk: 120 bytes, sha256:\(String(repeating: "a", count: 64))"))
        #expect(text.contains("Signing: not checked"))
    }

    @Test func daemonInstallRequiresConfirmationForCachedSameSetPreview() throws {
        #expect(DaemonInstallSupport.requiresConfirmation)
        let preview = RuntimeImportPreview(
            ticket: try #require(RuntimeImportTicket(rawValue: "00000000-0000-0000-0000-000000000001")),
            packageID: try #require(RuntimePackageID(rawValue: "com.example.app")),
            displayName: "Example",
            versionCode: 12,
            files: [],
            relation: .sameAsInstalled
        )
        #expect(DaemonInstallSupport.installConfirmationPrompt(for: preview).contains("Reinstall"))
        #expect(
            DaemonInstallSupport.previewText(preview)
                .contains("Relation: same stored APK set (will reinstall)")
        )
    }

    @Test func daemonInstallPreDispatchTimeoutDoesNotClaimInstallMayHaveCompleted() async throws {
        let packageID = try #require(RuntimePackageID(rawValue: "com.example.app"))
        let failure = await DaemonInstallSupport.installFailure(
            RuntimeControlClientError.requestTimedOut(operation: "installImported"),
            packageID: packageID
        )

        #expect(failure.code == "runtime.requestTimedOut")
    }

    @Test func daemonInstallTransportFailureExplainsThatInstallMayHaveCompleted() async throws {
        let packageID = try #require(RuntimePackageID(rawValue: "com.example.app"))
        let operationID = RuntimeAPI.OperationID()
        let failure = await DaemonInstallSupport.installFailure(
            RuntimeControlClientError.operationResultUnknown(operation: "beginInstallImported"),
            packageID: packageID,
            operationID: operationID
        )

        #expect(failure.code == "runtime.operationResultUnknown")
        #expect(failure.message.contains("could not confirm"))
        #expect(failure.remediation?.contains("apkrun operations wait \(operationID.wireValue)") == true)
        #expect(failure.remediation?.contains("apkrun info com.example.app") == true)
        #expect(failure.remediation?.contains("before retrying") == true)
    }
#endif

#if !APKRUN_EMBEDDED_RUNTIME
    private actor FakeOperationStatusQueue {
        private var snapshots: [OperationSnapshot]

        init(_ snapshots: [OperationSnapshot]) {
            self.snapshots = snapshots
        }

        func next(_ operationID: RuntimeAPI.OperationID) -> OperationSnapshot {
            guard !snapshots.isEmpty else {
                return OperationSnapshot(
                    operationID: operationID,
                    kind: .install,
                    startedAt: Date(timeIntervalSince1970: 1),
                    result: .unknown,
                    finishedAt: Date(timeIntervalSince1970: 2)
                )
            }
            return snapshots.removeFirst()
        }
    }
#endif

@Test func runtimeRestartCommandParsesConfirmationFlag() async throws {
    let command = try await APKRunCommand.asyncParseAsRoot(["runtime", "restart", "--yes"])
    #expect((command as? RuntimeRestartCommand)?.yes == true)
}

@Test func runtimeResetCommandParses() async throws {
    let command = try await APKRunCommand.asyncParseAsRoot(["runtime", "reset"])
    #expect(command is RuntimeResetCommand)
}

@Test func packageInfoRejectsTheDisplayOptionWithAnActionableCatalogError() async throws {
    let command = try await APKRunCommand.asyncParseAsRoot(["info", "--displays"])
    guard var infoCommand = command as? PackageInfoCommand else {
        Issue.record("info --displays did not parse as PackageInfoCommand")
        return
    }
    do {
        try await infoCommand.run()
        Issue.record("--displays unexpectedly returned without display snapshots")
    } catch let failure as CLIFailure {
        #expect(failure.code == "displayStatusUnavailable")
        #expect(ExitCodes.code(for: failure) == ExitCodes.unavailable)
    }
}

@Test func runtimeInfoHumanOutputIncludesAvailableDaemonAndBuildDetails() {
    let status = sampleRuntimeInfoStatus
    let output = RuntimeInfoOutput.human(
        status,
        buildInfo: releaseBuildInfo,
        includeRuntimeDetails: true
    )

    #expect(output.contains("APKRun: 0.1.0 (1)"))
    #expect(output.contains("Background service: running"))
    #expect(output.contains("Android: ready"))
    #expect(output.contains("Image: android-17"))
    #expect(output.contains("Guest Agent: connected"))
    #expect(output.contains("Guest Agent protocol: 1.4"))
}

@Test func runtimeInfoJSONIncludesStableCoreFieldsAndOptionalRuntimeDetails() throws {
    let data = Data(
        try RuntimeInfoOutput.json(
            sampleRuntimeInfoStatus,
            buildInfo: releaseBuildInfo,
            includeRuntimeDetails: false
        ).utf8
    )
    let envelope = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let result = try #require(envelope["result"] as? [String: Any])

    #expect(envelope["schemaVersion"] as? Int == 1)
    #expect((result["buildInfo"] as? [String: Any])?["marketingVersion"] as? String == "0.1.0")
    #expect(result["hostState"] as? String == "running")
    #expect(result["runtimeState"] as? String == "ready")
    #expect(result["imageVersion"] as? String == "android-17")
    #expect(result["runtimeDetails"] == nil)
}

@Test func runtimeStatusJSONReportsDaemonOwnership() throws {
    let data = Data(try RuntimeStatusOutput.json(sampleRuntimeInfoStatus).utf8)
    let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(envelope["result"] as? [String: Any])

    #expect(envelope["schemaVersion"] as? Int == 1)
    #expect(result["owner"] as? String == "apkrund")
    #expect(result["hostState"] as? String == "running")
    #expect(result["runtimeState"] as? String == "ready")
    #expect(result["crashLoopActive"] as? Bool == false)
    #expect(result["daemonPID"] as? Int32 == 123)
    #expect(result["imageVersion"] as? String == "android-17")
    #expect(result["guestAgentState"] as? String == "connected")
    #expect(result["guestAgentProtocolVersion"] as? String == "1.4")
    #expect(
        Set(result.keys)
            == [
                "owner", "hostState", "runtimeState", "crashLoopActive", "daemonPID",
                "imageVersion", "guestAgentState", "guestAgentProtocolVersion",
            ]
    )
}

@Test func packageQueryHumanOutputStripsTerminalControlCharacters() {
    let unsafe = RuntimePackageSummary(
        packageID: RuntimePackageID(rawValue: "io.example.app")!,
        displayName: "Bad\u{1B}[2J app",
        versionCode: 1,
        state: .broken("bad\nreason"),
        managed: true
    )

    #expect(
        PackageQueryOutput.packageListLine(unsafe)
            == "Bad\u{FFFD}[2J app\tio.example.app\t1\tmanaged\tbroken: bad\u{FFFD}reason")
    #expect(!PackageQueryOutput.packageListLine(unsafe).contains("\n"))
}

private let sampleRuntimeInfoStatus = RuntimeHostStatus(
    hostState: "running",
    runtimeState: "ready",
    bootProgress: nil,
    startupFailureStep: nil,
    startupFailureCode: nil,
    crashLoopActive: false,
    daemonPID: 123,
    imageVersion: "android-17",
    guestAgentState: .connected,
    guestAgentProtocolVersion: "1.4"
)

@Test func launchAndStopCommandsParsePackageArguments() async throws {
    let launch = try await APKRunCommand.asyncParseAsRoot([
        "launch", "io.apkrun.fixture.hellotext", "--json",
    ])
    #expect((launch as? LaunchCommand)?.package == "io.apkrun.fixture.hellotext")
    #expect((launch as? LaunchCommand)?.json == true)

    let stop = try await APKRunCommand.asyncParseAsRoot(["stop", "io.apkrun.fixture.hellotext"])
    #expect((stop as? StopCommand)?.package == "io.apkrun.fixture.hellotext")
}

@Test func runtimeStatusExplainsMissingAndUnapprovedDaemonRegistration() {
    let transportFailure = RuntimeControlClientError.transportFailure(
        domain: "NSCocoaErrorDomain",
        code: 4099
    )
    let missing = RuntimeStatusOutput.failure(
        transportFailure,
        runtimeRegistration: .notRegistered
    )
    #expect(missing.code == "runtime.serviceUnavailable")
    #expect(missing.message == "APKRun's background service is not set up.")
    #expect(missing.remediation == "Open APKRun once, or run: apkrun setup")
    #expect(ExitCodes.code(for: missing) == ExitCodes.unavailable)

    let approval = RuntimeStatusOutput.failure(
        transportFailure,
        runtimeRegistration: .requiresApproval
    )
    #expect(approval.message == "APKRun's background service needs approval.")
    #expect(approval.remediation == "Allow APKRun in System Settings under Login Items.")
    #expect(ExitCodes.code(for: approval) == ExitCodes.unavailable)
}

@Test func runtimeRestartTimeoutSuggestsCheckingBeforeRetrying() {
    let failure = RuntimeStatusOutput.failure(
        RuntimeControlClientError.requestTimedOut(operation: "runtimeRestart")
    )

    #expect(failure.code == "runtime.requestTimedOut")
    #expect(failure.remediation?.contains("apkrun runtime status") == true)
    #expect(failure.remediation?.contains("may still finish") == true)
}

@Test func runtimeCancellationUsesInterruptedExitCode() {
    let failure = RuntimeStatusOutput.failure(
        RuntimeControlClientError.requestCancelled(operation: "runtimeRestart")
    )

    #expect(failure.code == "runtime.cancelled")
    #expect(failure.message == "The operation was cancelled.")
    #expect(ExitCodes.code(for: failure) == ExitCodes.interrupted)
}

private let goldenDirectory = Bundle.module.resourceURL!.appendingPathComponent("Golden")

@Test func versionHumanOutputMatchesGolden() {
    let version = releaseBuildInfo

    #expect(Output.versionHuman(version) == golden("version-human.txt"))
}

@Test func versionJSONOutputMatchesGolden() {
    let version = releaseBuildInfo

    #expect(Output.versionJSON(version) == golden("version-json.txt"))
}

@Test func versionFlagUsesTheInjectedVersion() {
    let version = releaseBuildInfo

    #expect(Output.versionFlag(version) == golden("version-flag.txt"))
}

@Test func versionCommandParsesJSONFlag() throws {
    let command = try VersionCommand.parse(["--json"])

    #expect(command.json)
}

@Test func rootParserPreservesVersionSubcommandJSONFlag() async throws {
    let parsed = try await APKRunCommand.asyncParseAsRoot(["version", "--json"])

    #expect((parsed as? VersionCommand)?.json == true)
}

@Test func devLinuxFloodArgumentsUseDefaultAndExplicitLineCounts() throws {
    #expect(
        try DevLinuxFloodArguments.make(tests: ["flood"], lineCount: nil)
            == ["apkrun.test.flood=10000000"]
    )
    #expect(
        try DevLinuxFloodArguments.make(tests: ["flood"], lineCount: 1234)
            == ["apkrun.test.flood=1234"]
    )
    #expect(try DevLinuxFloodArguments.make(tests: ["ports"], lineCount: nil).isEmpty)
}

@Test func devLinuxFloodArgumentsRejectMisuseAndOutOfRangeCounts() {
    do {
        _ = try DevLinuxFloodArguments.make(tests: ["ports"], lineCount: 100)
        Issue.record("flood line count without the flood test unexpectedly succeeded")
    } catch CLIFailure.invalidArgument(let argument, let reason) {
        #expect(argument == "--flood-lines")
        #expect(reason == "requiresFloodTest")
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    do {
        _ = try DevLinuxFloodArguments.make(tests: ["flood"], lineCount: 10_000_001)
        Issue.record("out-of-range flood line count unexpectedly succeeded")
    } catch CLIFailure.invalidArgument(let argument, let reason) {
        #expect(argument == "--flood-lines")
        #expect(reason == "range")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

#if APKRUN_EMBEDDED_RUNTIME
    @Test func runtimeControlCommandsParseStatusStartAndStop() async throws {
        let status = try await APKRunCommand.asyncParseAsRoot(["runtime", "status", "--json"])
        #expect((status as? RuntimeStatusCommand)?.json == true)

        let start = try await APKRunCommand.asyncParseAsRoot(["runtime", "start"])
        #expect(start is RuntimeStartCommand)

        let stop = try await APKRunCommand.asyncParseAsRoot(["runtime", "stop"])
        #expect(stop is RuntimeStopCommand)

    }

    @Test func runtimeStatusExplainsRetryableDaemonShutdown() {
        let error = RuntimeStatusOutput.failure(
            RuntimeControlClientError.endpointRejected(.hostShuttingDown)
        )

        #expect(error.code == "runtime.hostShuttingDown")
        #expect(error.message == "APKRun's background service is stopping.")
        #expect(error.remediation == "Try again in a moment.")
        #expect(ExitCodes.code(for: error) == 75)
    }

    @Test func runtimeStatusUsesCatalogMessagesForDaemonFailures() {
        let startupError = RuntimeStatusOutput.failure(
            RuntimeControlClientError.remoteFailure(
                code: "runtime.hostStartupFailed",
                message: "server fallback"
            )
        )
        #expect(startupError.message == "Part of APKRun's background service couldn't start.")
        #expect(startupError.remediation?.contains("apkrun runtime status") == true)
        #expect(ExitCodes.code(for: startupError) == 69)

        let unavailableError = RuntimeStatusOutput.failure(
            RuntimeControlClientError.transportFailure(domain: "NSCocoaErrorDomain", code: 4099)
        )
        #expect(unavailableError.message == "APKRun's background service isn't running.")
        #expect(unavailableError.remediation == "Open APKRun once, or restart its background service.")
        #expect(ExitCodes.code(for: unavailableError) == 69)

        let unauthorizedError = RuntimeStatusOutput.failure(
            RuntimeControlClientError.invalidClientIdentity
        )
        #expect(unauthorizedError.code == "runtime.notAuthorized")
        #expect(unauthorizedError.message == "This part of APKRun isn't allowed to control the runtime.")
        #expect(ExitCodes.code(for: unauthorizedError) == 5)

        let bootTimeout = RuntimeStatusOutput.failure(
            RuntimeControlClientError.remoteFailure(
                code: "runtime.bootTimedOut",
                message: "Something went wrong in APKRun's background service."
            )
        )
        #expect(bootTimeout.message == "Something went wrong in APKRun's background service.")
        #expect(!bootTimeout.message.contains("{phase}"))
        #expect(bootTimeout.remediation == "Restart Android. If it happens again, create a diagnostics report.")
        #expect(ExitCodes.code(for: bootTimeout) == 1)
    }

    @Test func developmentDisplayCommandsParseAddInEitherOptionOrder() throws {
        #expect(
            try DevDisplaysInputParser.parse("add --size 960x1700 --dpi 320")
                == .add(width: 960, height: 1700, dpi: 320)
        )
        #expect(
            try DevDisplaysInputParser.parse("add --dpi 240 --size 800x1200")
                == .add(width: 800, height: 1200, dpi: 240)
        )
    }

    @Test func developmentDisplayCommandsParseListRemoveHelpAndExit() throws {
        #expect(try DevDisplaysInputParser.parse("list") == .list)
        #expect(try DevDisplaysInputParser.parse("remove 15") == .remove(scanout: 15))
        #expect(try DevDisplaysInputParser.parse("help") == .help)
        #expect(try DevDisplaysInputParser.parse("quit") == .quit)
        #expect(try DevDisplaysInputParser.parse("exit") == .quit)
        #expect(try DevDisplaysInputParser.parse("  ") == .empty)
    }

    @Test func developmentDisplayCommandsRejectMalformedInput() {
        for input in [
            "add",
            "add --size 640x800",
            "add --size 500x800 --dpi 320",
            "add --size 640x800 --dpi 119",
            "add --size 640x800 --dpi 320 --dpi 320",
            "list extra",
            "remove 0",
            "remove 16",
            "remove one",
            "unknown",
        ] {
            #expect(throws: (any Error).self) {
                try DevDisplaysInputParser.parse(input)
            }
        }
    }
#endif

@Test func builtInOutputRequestsAreLimitedToSupportedCompletionShells() {
    #expect(APKRunCommand.isBuiltInOutputRequest(["--help"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["-help"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["--version"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["help", "version"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["--generate-completion-script", "zsh"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["--generate-completion-script=bash"]))
    #expect(
        !APKRunCommand.isBuiltInOutputRequest([
            "--generate-completion-script",
            "unsupported-shell",
        ]))
    #expect(!APKRunCommand.isBuiltInOutputRequest(["--generate-completion-script=unsupported-shell"]))
    #expect(
        !APKRunCommand.isBuiltInOutputRequest([
            "--help",
            "--generate-completion-script",
            "unsupported-shell",
        ]))
    #expect(!APKRunCommand.isBuiltInOutputRequest(["invalid-command", "help"]))
    #expect(!APKRunCommand.isBuiltInOutputRequest(["--", "--help"]))
    #expect(
        !APKRunCommand.isBuiltInOutputRequest([
            "--generate-completion-script",
            "help",
        ]))
    #expect(APKRunCommand.usesJSONErrorOutput(["--json", "--bogus"]))
    #expect(!APKRunCommand.usesJSONErrorOutput(["--", "--json"]))
}

@Test func versionCommandRendersInjectedVersion() {
    let version = releaseBuildInfo
    var command = VersionCommand(versionInformation: version)
    command.json = false
    #expect(command.renderedOutput == golden("version-human.txt"))

    command.json = true
    #expect(command.renderedOutput == golden("version-json.txt"))
}

@Test func versionCommandWritesOneNoticeToTheCLICommandSubsystem() throws {
    let sink = RecordingLogSink()
    let logger = APKLogger(category: .command, sink: sink)
    VersionCommand.recordInvocation(using: logger)

    #expect(sink.entries.count == 1)
    #expect(sink.entries.first?.level == .notice)
    #expect(sink.entries.first?.subsystem == .cli)
    #expect(sink.entries.first?.category == "command")
}

@Test func logsCommandWritesNormalizedJSONEntriesFromTheInjectedRunner() async throws {
    let timestamp = ISO8601DateFormatter().string(from: .now)
    let line =
        #"{"timestamp":"\#(timestamp)","messageType":"Info","eventMessage":"ready","subsystem":"io.apkrun.cli","category":"command"}"#
    let runner = FakeLogCommandRunner(results: [
        LogCommandResult(exitCode: 0, standardOutput: Data(line.utf8))
    ])
    let paths = APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory)
    let output = CLIOutputRecorder()
    try await LogsCommand.execute(
        follow: false,
        since: "5m",
        subsystem: "io.apkrun.cli",
        level: .info,
        json: true,
        reader: LogReader(paths: paths, runner: runner),
        output: output.append
    )

    #expect(output.lines.count == 1)
    #expect(output.lines.first?.toStandardError == false)
    #expect(output.lines.first?.text.contains(#""message":"ready""#) == true)
    let arguments = await runner.recordedArguments()
    #expect(arguments.first?.first == "show")
}

@Test func logsCommandRejectsInvalidFiltersWithCatalogExitCode64() async throws {
    let runner = FakeLogCommandRunner(results: [])
    let paths = APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory)
    let output = CLIOutputRecorder()
    do {
        try await LogsCommand.execute(
            follow: false,
            since: "5m --predicate true",
            subsystem: nil,
            level: nil,
            json: false,
            reader: LogReader(paths: paths, runner: runner),
            output: output.append
        )
        Issue.record("invalid duration unexpectedly succeeded")
    } catch let failure as CLIFailure {
        #expect(failure.code == "invalidArgument")
        #expect(ExitCodes.code(for: failure) == 64)
    }
    #expect(output.lines.isEmpty)
}

@Test func logsCommandRejectsSubsystemOutsideAPKRunNamespace() async throws {
    let runner = FakeLogCommandRunner(results: [])
    let paths = APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory)
    let output = CLIOutputRecorder()
    do {
        try await LogsCommand.execute(
            follow: false,
            since: "5m",
            subsystem: #"io.apkrun.cli" OR true"#,
            level: nil,
            json: false,
            reader: LogReader(paths: paths, runner: runner),
            output: output.append
        )
        Issue.record("invalid subsystem unexpectedly succeeded")
    } catch let failure as CLIFailure {
        #expect(failure.code == "invalidArgument")
        #expect(ExitCodes.code(for: failure) == 64)
    }

    #expect(await runner.recordedArguments().isEmpty)
    #expect(output.lines.isEmpty)
}

@Test func logsCommandReportsUnavailableWhenNeitherSourceCanBeRead() async throws {
    let runner = FakeLogCommandRunner(results: [LogCommandResult(exitCode: 1)])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("APKRun-LogsUnavailable-\(UUID().uuidString)", isDirectory: true)
    let paths = APKRunPaths(homeDirectory: directory)
    let output = CLIOutputRecorder()
    do {
        try await LogsCommand.execute(
            follow: false,
            since: "5m",
            subsystem: nil,
            level: nil,
            json: false,
            reader: LogReader(paths: paths, runner: runner),
            output: output.append
        )
        Issue.record("unavailable logs unexpectedly succeeded")
    } catch let failure as CLIFailure {
        #expect(failure.code == "logsUnavailable")
        #expect(ExitCodes.code(for: failure) == 1)
    }
}

@Test func logsCommandNotesReadableMirrorFallbackOnStandardError() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("APKRun-LogsMirror-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = APKRunPaths(homeDirectory: directory)
    try FileManager.default.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
    let timestamp = ISO8601DateFormatter().string(from: .now)
    try "\(timestamp) notice io.apkrun.cli/command fallback"
        .write(to: paths.daemonLogFile, atomically: true, encoding: .utf8)
    let output = CLIOutputRecorder()

    try await LogsCommand.execute(
        follow: false,
        since: "5m",
        subsystem: nil,
        level: nil,
        json: false,
        reader: LogReader(
            paths: paths,
            runner: FakeLogCommandRunner(results: [LogCommandResult(exitCode: 1)])
        ),
        output: output.append
    )

    #expect(
        output.lines.contains {
            $0.toStandardError && $0.text == "note: including available APKRun file mirrors."
        })
    #expect(output.lines.contains { !$0.toStandardError && $0.text.contains(" fallback") })
}

@Test func rootHelpMatchesGolden() {
    #if APKRUN_EMBEDDED_RUNTIME
        #expect(APKRunCommand.helpMessage() == golden("help-embedded-runtime.txt"))
    #else
        #expect(APKRunCommand.helpMessage() == golden("help.txt"))
    #endif
}

#if APKRUN_EMBEDDED_RUNTIME
    @Test func developmentLaunchOnlyStartsTheWindowForAnActualLaunch() {
        #expect(DisplayWindowSession.request(in: ["dev", "launch", "HelloText.apk"]) == .launch)
        #expect(DisplayWindowSession.request(in: ["dev", "launch", "--no-window", "HelloText.apk"]) == nil)
        #expect(DisplayWindowSession.request(in: ["help", "launch"]) == nil)
        #expect(DisplayWindowSession.request(in: ["dev", "launch", "--help"]) == nil)
        #expect(DisplayWindowSession.request(in: ["dev", "boot", "--window", "--help"]) == nil)
        #expect(DisplayWindowSession.request(in: ["dev", "boot", "--guest-dir", "launch"]) == nil)
        #expect(DisplayWindowSession.request(in: ["dev", "launch", "--guest-dir", "boot"]) == .launch)
        #expect(
            DisplayWindowSession.request(in: ["dev", "boot", "--window", "--guest-dir", "launch"]) == .boot
        )
    }
#endif

private final class CLIOutputRecorder: @unchecked Sendable {
    struct Line: Equatable {
        let text: String
        let toStandardError: Bool
    }

    private let lock = NSLock()
    private var storedLines: [Line] = []

    var lines: [Line] {
        lock.lock()
        defer { lock.unlock() }
        return storedLines
    }

    func append(_ text: String, _ toStandardError: Bool) {
        lock.lock()
        storedLines.append(Line(text: text, toStandardError: toStandardError))
        lock.unlock()
    }
}

@Test func catalogUsageErrorUsesThreeLinesAndExit64() {
    let error = CLIFailure.invalidArguments

    #expect(
        ErrorOutput.render(error, json: false) == """
            error: The command arguments aren't valid.
            hint: Run the command with --help to see the allowed values.
            code: cli.invalidArguments
            """
    )
    #expect(ExitCodes.code(for: error) == 64)
}

@Test func catalogJSONErrorGoesToTheJSONPresenter() throws {
    let error = CLIFailure.invalidPackageName(package: "not a package")
    let output = try #require(
        JSONSerialization.jsonObject(with: Data(ErrorOutput.render(error, json: true).utf8))
            as? [String: Any]
    )
    let details = try #require(output["error"] as? [String: Any])

    #expect(details["code"] as? String == "cli.invalidPackageName")
    #expect(details["message"] as? String == "not a package isn't a valid Android package name.")
    #expect(ExitCodes.code(for: error) == 64)
}

#if APKRUN_EMBEDDED_RUNTIME
    @Test func packageImportRejectsNonRegularInputBeforeOpeningIt() throws {
        let fifo = FileManager.default.temporaryDirectory
            .appendingPathComponent("APKRun-PackageInput-\(UUID().uuidString)")
        let result = fifo.path.withCString { Darwin.mkfifo($0, mode_t(0o600)) }
        #expect(result == 0)
        defer { try? FileManager.default.removeItem(at: fifo) }

        do {
            _ = try PackageCommandSupport.inputFiles([fifo.path])
            Issue.record("named pipe unexpectedly passed APK file validation")
        } catch let failure as CLIFailure {
            guard case .invalidArgument(let argument, let reason) = failure else {
                Issue.record("unexpected CLI failure: \(failure)")
                return
            }
            #expect(argument == "file")
            #expect(reason == "notRegularFile")
        }
    }

    @Test func packageDisplayNamesReplaceTerminalAndBidiControls() {
        let unsafeName = "Bad\u{001B}[2J\nName\u{202E}"

        #expect(PackageCommandSupport.safeTerminalText(unsafeName) == "Bad�[2J�Name�")
        #expect(PackageCommandSupport.safeTerminalText("👨‍👩‍👧‍👦") == "👨‍👩‍👧‍👦")
    }

    @Test func packageListTextIncludesStateAndSanitizesTheLabel() throws {
        let packageID = try #require(RuntimePackageID(rawValue: "com.example.app"))
        let summary = RuntimePackageSummary(
            packageID: packageID,
            displayName: "App\nName",
            versionCode: 42,
            state: .uninstalledKeepingData
        )

        #expect(
            PackageQueryOutput.packageListLine(summary)
                == "App�Name\tcom.example.app\t42\tmanaged\tuninstalled, data kept"
        )
    }

    @Test func sameSetPreviewAsksBeforeReinstalling() throws {
        let ticket = try #require(
            RuntimeImportTicket(rawValue: "00000000-0000-0000-0000-000000000001")
        )
        let packageID = try #require(RuntimePackageID(rawValue: "com.example.app"))
        let preview = RuntimeImportPreview(
            ticket: ticket,
            packageID: packageID,
            displayName: "Example\u{001B}[2J",
            versionCode: 42,
            files: [],
            relation: .sameAsInstalled
        )

        #expect(
            PackageCommandSupport.installConfirmationPrompt(for: preview)
                == "Reinstall Example�[2J (com.example.app) using the selected APK files?"
        )
    }

    @Test func packageCommandDowngradePromptExplainsRuntimeRecheck() throws {
        let preview = RuntimeImportPreview(
            ticket: try #require(
                RuntimeImportTicket(rawValue: "00000000-0000-0000-0000-000000000001")
            ),
            packageID: try #require(RuntimePackageID(rawValue: "com.example.app")),
            displayName: "Example",
            versionCode: 12,
            files: [],
            relation: .downgrade(from: 18)
        )

        let prompt = PackageCommandSupport.installConfirmationPrompt(for: preview)
        #expect(prompt.contains("version 12, below version 18"))
        #expect(prompt.contains("Recheck Android's current version"))
        #expect(!prompt.contains("debuggable Android"))
    }
#endif

@Test func invalidSourceSpecDoesNotExposeTheSuppliedURL() throws {
    let suppliedSpec = "https://user:credential@example.invalid/private/path?token=private-token"
    let error = CLIFailure.invalidSourceSpec(argument: suppliedSpec)
    let humanOutput = ErrorOutput.render(error, json: false)
    let jsonOutput = ErrorOutput.render(error, json: true)

    #expect(humanOutput.contains("This update source isn't valid."))
    #expect(jsonOutput.contains("This update source isn't valid."))
    #expect(!humanOutput.contains(suppliedSpec))
    #expect(!jsonOutput.contains(suppliedSpec))
    #expect(!humanOutput.contains("credential"))
    #expect(!jsonOutput.contains("credential"))
    #expect(!humanOutput.contains("private-token"))
    #expect(!jsonOutput.contains("private-token"))
    #expect(ErrorCatalog.entry(for: "cli.invalidSourceSpec")?.parameters.isEmpty == true)
}

@Test func cliExitTableMatchesGeneratedCatalog() {
    for entry in ErrorCatalog.entries.values where entry.code.hasPrefix("cli.") {
        guard case .code(let expected) = entry.cliExit else {
            Issue.record("CLI entry \(entry.code) must have a fixed exit code.")
            continue
        }
        #expect(ExitCodes.code(for: entry.code) == expected)
    }
}

private func golden(_ name: String) -> String {
    let contents = try! String(
        contentsOf: goldenDirectory.appendingPathComponent(name), encoding: .utf8)
    return contents.trimmingCharacters(in: .newlines)
}

private let releaseBuildInfo = BuildInfo(
    infoDictionary: [
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "APKRunBuildIdentity": "release",
        "APKRunGitCommit": "abcdef0",
        "APKRunConfiguration": "Release",
        "APKRunEmbeddedRuntime": false,
    ]
)
