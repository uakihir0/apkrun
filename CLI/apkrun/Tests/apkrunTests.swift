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
        #expect(prompt.contains("installation will be refused"))
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

    @Test func daemonUninstallUncertaintyShowsTheOperationIDAndRecoveryCommand() async throws {
        let packageID = try #require(RuntimePackageID(rawValue: "com.example.app"))
        let operationID = RuntimeAPI.OperationID()
        let failure = await DaemonInstallSupport.uninstallBeginFailure(
            RuntimeControlClientError.operationResultUnknown(operation: "beginUninstallPackage"),
            packageID: packageID,
            operationID: operationID
        )

        #expect(failure.code == "runtime.operationResultUnknown")
        #expect(failure.remediation?.contains("apkrun operations wait \(operationID.wireValue)") == true)
        #expect(failure.remediation?.contains("apkrun info com.example.app") == true)
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

#if !APKRUN_EMBEDDED_RUNTIME
    @Test func setupCommandParsesImageAndConfirmation() async throws {
        let command = try await APKRunCommand.asyncParseAsRoot(["setup", "--image", "/tmp/bundle", "--yes"])
        guard let setup = command as? SetupCommand else {
            Issue.record("setup did not parse as SetupCommand")
            return
        }
        #expect(setup.image == "/tmp/bundle")
        #expect(setup.yes == true)
    }

    @Test func setupCommandDefaultsToFeedImage() async throws {
        let command = try await APKRunCommand.asyncParseAsRoot(["setup"])
        guard let setup = command as? SetupCommand else {
            Issue.record("setup did not parse as SetupCommand")
            return
        }
        #expect(setup.image == nil)
        #expect(setup.yes == false)
    }

    @Test func runtimeResetCommandParsesEraseFlags() async throws {
        let command = try await APKRunCommand.asyncParseAsRoot([
            "runtime", "reset", "--erase", "--no-backup", "--yes",
        ])
        guard let reset = command as? RuntimeResetCommand else {
            Issue.record("runtime reset did not parse as RuntimeResetCommand")
            return
        }
        #expect(reset.erase == true)
        #expect(reset.noBackup == true)
        #expect(reset.yes == true)
    }
#endif

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

@Test func updateHelpMatchesGolden() {
    #expect(UpdateCommand.helpMessage() == golden("help-update.txt"))
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
        #expect(prompt.contains("installation will be refused"))
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

#if !APKRUN_EMBEDDED_RUNTIME
    @Test func wrapCommandParsesPackageOutputReplaceAndJSON() async throws {
        let parsed = try await APKRunCommand.asyncParseAsRoot([
            "wrap", "io.apkrun.fixture.hellotext",
            "--output", "/tmp", "--replace", "--json",
        ])
        let command = try #require(parsed as? WrapCommand)
        #expect(command.package == "io.apkrun.fixture.hellotext")
        #expect(command.output == "/tmp")
        #expect(command.replace == true)
        #expect(command.json == true)
        #expect(command.portable == false)
    }

    @Test func wrapCommandParsesPortable() async throws {
        let parsed = try await APKRunCommand.asyncParseAsRoot([
            "wrap", "app.apk", "--portable", "--updates", "notify",
        ])
        let command = try #require(parsed as? WrapCommand)
        #expect(command.portable == true)
        #expect(command.install == false)
        #expect(command.updates == "notify")
    }

    @Test func wrapSuccessResultPrintsTheBundlePath() {
        #expect(WrapCommandSupport.resultText(helloWrapperInfo()) == golden("wrap-success.txt"))
    }

    @Test func wrapperInfoReturnsTheSucceededWrapper() throws {
        let info = helloWrapperInfo()
        let snapshot = wrapSnapshot(result: .succeeded(.wrapper(info)))
        #expect(
            try WrapCommandSupport.wrapperInfo(
                from: snapshot, expectedPackageID: helloPackageID) == info)
    }

    @Test func wrapperInfoPropagatesPackageNotInstalled() {
        let wireError = RuntimeWireError(
            domain: "wrapper",
            code: "wrapper.packageNotInstalled",
            message: "io.apkrun.fixture.hellotext isn't installed in APKRun.",
            remediation: "Install io.apkrun.fixture.hellotext first. "
                + "apkrun wrap installs it too when you add --install."
        )
        let snapshot = wrapSnapshot(result: .failed(wireError))
        #expect(throws: wireError) {
            try WrapCommandSupport.wrapperInfo(
                from: snapshot, expectedPackageID: helloPackageID)
        }
        #expect(ErrorOutput.render(wireError, json: false) == golden("wrap-package-not-installed.txt"))
    }

    @Test func wrapperInfoPropagatesWrapperExists() {
        let wireError = RuntimeWireError(
            domain: "wrapper",
            code: "wrapper.wrapperExists",
            message:
                "io.apkrun.fixture.hellotext already has a Mac app (HelloText.app).",
            remediation:
                "Use Update Mac App, or run: apkrun wrap io.apkrun.fixture.hellotext --replace"
        )
        let snapshot = wrapSnapshot(result: .failed(wireError))
        #expect(throws: wireError) {
            try WrapCommandSupport.wrapperInfo(
                from: snapshot, expectedPackageID: helloPackageID)
        }
        #expect(ErrorOutput.render(wireError, json: false) == golden("wrap-wrapper-exists.txt"))
    }

    private var helloPackageID: RuntimePackageID {
        RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext")!
    }

    private func helloWrapperInfo() -> WrapperInfo {
        WrapperInfo(
            summary: WrapperSummary(
                packageID: helloPackageID,
                bundleID: "io.apkrun.android.io.apkrun.fixture.hellotext",
                displayName: "HelloText",
                kind: .local,
                bundleURL: URL(fileURLWithPath: "/Applications/HelloText.app"),
                status: WrapperStatus(state: .valid),
                approval: .generated,
                launcherVersion: "1",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            fileName: "HelloText",
            customization: WrapperCustomizationWire(),
            signer: .adHoc,
            cdhash: "0123456789abcdef0123456789abcdef01234567",
            launcherAPI: APIVersion(major: 1, minor: 0),
            formatVersion: 1
        )
    }

    private func wrapSnapshot(result: OperationResult) -> OperationSnapshot {
        OperationSnapshot(
            operationID: OperationID(),
            kind: .wrapperCreate,
            packageID: helloPackageID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            result: result,
            finishedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }
#endif

// MARK: - install update flags (cli.md §4.2)

@Test func installProviderFlagMapsToApkrunAuthority() throws {
    let options = try InstallUpdateOptions.options(
        provider: "direct:https://updates.example.com/app.json",
        updates: nil, update: nil, updateProvider: nil, updateURL: nil)
    #expect(options.authority == .apkrun)
    #expect(options.updateMode == nil)
    #expect(options.provider?.spec == "direct:https://updates.example.com/app.json")
    #expect(options.provider?.bookmark == nil)
}

@Test func installUpdateProviderURLPairMapsToSameSpec() throws {
    let options = try InstallUpdateOptions.options(
        provider: nil, updates: nil, update: nil,
        updateProvider: "direct", updateURL: "https://updates.example.com/app.json")
    #expect(options.authority == .apkrun)
    #expect(options.provider?.spec == "direct:https://updates.example.com/app.json")
}

@Test func installUpdatesNotifyMapsToNotifyOnly() throws {
    let options = try InstallUpdateOptions.options(
        provider: "direct:https://updates.example.com/app.json",
        updates: "notify", update: nil, updateProvider: nil, updateURL: nil)
    #expect(options.authority == .apkrun)
    #expect(options.updateMode == .notifyOnly)
}

@Test func installUpdatesManualLeavesProviderUnused() throws {
    let options = try InstallUpdateOptions.options(
        provider: "direct:https://updates.example.com/app.json",
        updates: nil, update: "manual", updateProvider: nil, updateURL: nil)
    #expect(options.authority == .manual)
    #expect(options.updateMode == .manual)
    #expect(options.provider != nil)
}

@Test func installUpdateAliasConflictsFail() throws {
    #expect(throws: CLIFailure.self) {
        _ = try InstallUpdateOptions.options(
            provider: nil, updates: "notify", update: "manual",
            updateProvider: nil, updateURL: nil)
    }
    #expect(throws: CLIFailure.self) {
        _ = try InstallUpdateOptions.options(
            provider: "direct:https://a.example/m.json", updates: nil, update: nil,
            updateProvider: "direct", updateURL: "https://b.example/m.json")
    }
    #expect(throws: CLIFailure.self) {
        _ = try InstallUpdateOptions.options(
            provider: nil, updates: nil, update: nil,
            updateProvider: "direct", updateURL: nil)
    }
    #expect(throws: CLIFailure.self) {
        _ = try InstallUpdateOptions.options(
            provider: nil, updates: "bogus", update: nil,
            updateProvider: nil, updateURL: nil)
    }
}

@Test func updatePolicyParsesDirectProviderSpec() async throws {
    let command = try await APKRunCommand.asyncParseAsRoot(
        [
            "update", "policy", "com.example.app", "--mode", "automatic",
            "--provider", "direct:https://updates.example.com/app.json",
        ])
    let policy = try #require(command as? UpdatePolicyCommand)
    #expect(policy.provider == "direct:https://updates.example.com/app.json")
}

#if !APKRUN_EMBEDDED_RUNTIME
    @Test func installParsesDirectProviderAndAliasFlags() async throws {
        let plain = try await APKRunCommand.asyncParseAsRoot(
            [
                "install", "app.apk", "--provider",
                "direct:https://updates.example.com/app.json",
            ])
        let aliased = try await APKRunCommand.asyncParseAsRoot(
            [
                "install", "app.apk", "--update-provider", "direct",
                "--update-url", "https://updates.example.com/app.json",
                "--updates", "notify",
            ])
        #expect(
            (plain as? InstallCommand)?.provider
                == "direct:https://updates.example.com/app.json")
        #expect((aliased as? InstallCommand)?.updateProvider == "direct")
        #expect(
            (aliased as? InstallCommand)?.updateURL
                == "https://updates.example.com/app.json")
        #expect((aliased as? InstallCommand)?.updates == "notify")
    }
#endif

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

// MARK: - wrap import/install table (wrapper.md §12.2)

#if !APKRUN_EMBEDDED_RUNTIME
    @Test func wrapFilePlanCoversTheImportTable() throws {
        // §12.2 rows: installable relations ask or honor --install; the
        // installed package is wrapped without reinstalling the file.
        #expect(
            WrapCommandSupport.filePlan(relation: .newPackage, install: false) == .confirmInstall)
        #expect(
            WrapCommandSupport.filePlan(relation: .newPackage, install: true) == .installAndWrap)
        #expect(
            WrapCommandSupport.filePlan(relation: .unknown, install: false) == .confirmInstall)
        #expect(
            WrapCommandSupport.filePlan(relation: .sameAsInstalled, install: false)
                == .wrapInstalled(.sameVersion))
        #expect(
            WrapCommandSupport.filePlan(relation: .sameAsInstalled, install: true)
                == .wrapInstalled(.sameVersion))
        #expect(
            WrapCommandSupport.filePlan(relation: .update(from: 1), install: false)
                == .wrapInstalled(.newerFile))
        #expect(
            WrapCommandSupport.filePlan(relation: .update(from: 1), install: true)
                == .installAndWrap)
        #expect(
            WrapCommandSupport.filePlan(relation: .downgrade(from: 2), install: false)
                == .wrapInstalled(.olderFile))
        #expect(
            WrapCommandSupport.filePlan(relation: .downgrade(from: 2), install: true)
                == .installAndWrap)
        #expect(
            WrapCommandSupport.filePlan(relation: .otherSigner, install: false)
                == .wrapInstalled(.otherSigner))
        #expect(
            WrapCommandSupport.filePlan(relation: .otherSigner, install: true)
                == .installAndWrap)
    }

    @Test func wrapParsesAliasAndWindowFlags() async throws {
        let command =
            try await APKRunCommand.asyncParseAsRoot(
                [
                    "wrap", "com.example.app",
                    "--update", "auto", "--window-size", "800x600", "--resizable",
                ]) as? WrapCommand
        let parsed = try #require(command)
        #expect(parsed.update == "auto")
        #expect(parsed.windowSize == "800x600")
        #expect(parsed.resizable)
    }

    @Test func wrapUpdateAliasMapsToAutomatic() throws {
        // update-system.md §2.4: without a provider the authority stays
        // manual and the automatic mode sits unused.
        let options = try InstallUpdateOptions.options(
            provider: nil, updates: nil, update: "auto",
            updateProvider: nil, updateURL: nil)
        #expect(options.authority == .manual)
        #expect(options.updateMode == .automatic)
    }

    @Test func wrapperSubcommandsParse() async throws {
        let verify = try await APKRunCommand.asyncParseAsRoot(
            ["wrapper", "verify", "/Applications/App.app", "--deep", "--json"])
        #expect(verify is WrapperVerifyCommand)
        let info = try await APKRunCommand.asyncParseAsRoot(
            ["wrapper", "info", "com.example.app", "--json"])
        #expect(info is WrapperInfoCommand)
    }

    @Test func installParsesWrapFlags() async throws {
        let command =
            try await APKRunCommand.asyncParseAsRoot(
                ["install", "app.apk", "--wrap", "--output", "/tmp/apps"]) as? InstallCommand
        let parsed = try #require(command)
        #expect(parsed.wrap)
        #expect(parsed.output == "/tmp/apps")
    }

    @Test func wrapperSubcommandsParseListRefreshRemove() async throws {
        #expect(
            try await APKRunCommand.asyncParseAsRoot(["wrapper", "list", "--json"])
                is WrapperListCommand)
        #expect(
            try await APKRunCommand.asyncParseAsRoot(
                ["wrapper", "refresh", "com.example.app", "--name", "New", "--launcher-only"])
                is WrapperRefreshCommand)
        #expect(
            try await APKRunCommand.asyncParseAsRoot(["wrapper", "refresh", "--all"])
                is WrapperRefreshCommand)
        #expect(
            try await APKRunCommand.asyncParseAsRoot(
                ["wrapper", "remove", "com.example.app", "--trash", "--yes"])
                is WrapperRemoveCommand)
    }

    @Test func wrapGoldenListAndBatchTexts() throws {
        let entries = [
            WrapperListEntryWire(
                summary: helloWrapperInfo().summary, state: .valid, refreshReasons: []),
            WrapperListEntryWire(
                summary: WrapperSummary(
                    packageID: RuntimePackageID(rawValue: "com.example.other")!,
                    bundleID: "io.apkrun.android.com.example.other",
                    displayName: "Other",
                    kind: .local,
                    bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
                    status: WrapperStatus(state: .missing),
                    approval: .generated,
                    launcherVersion: "1",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                state: .missing,
                refreshReasons: []
            ),
        ]
        #expect(WrapCommandSupport.listText(entries) == golden("wrapper-list.txt"))
        let batch = WrapperBatchResult(
            refreshed: [RuntimePackageID(rawValue: "com.example.one")!],
            skippedRunning: [RuntimePackageID(rawValue: "com.example.busy")!],
            failed: [
                WrapperBatchFailure(
                    packageID: RuntimePackageID(rawValue: "com.example.broken")!,
                    error: .runtime(
                        "internalError",
                        message: "APKRun's background service failed."))
            ]
        )
        #expect(WrapCommandSupport.batchText(batch) == golden("wrapper-batch.txt"))
    }

    @Test func wrapGoldenVerificationAndInfoTexts() throws {
        let verification = WrapperVerification(
            bundleURL: URL(fileURLWithPath: "/Applications/HelloText.app"),
            bundleID: "io.apkrun.android.io.apkrun.fixture.hellotext",
            packageID: "io.apkrun.fixture.hellotext",
            kind: .local,
            registered: true,
            cdhash: "0123456789abcdef0123456789abcdef01234567"
        )
        #expect(
            WrapCommandSupport.verificationText(verification)
                == golden("wrap-verify-valid.txt"))
        #expect(
            WrapCommandSupport.infoText(helloWrapperInfo()) == golden("wrap-info.txt"))
        let broken = WrapperVerification(
            bundleURL: URL(fileURLWithPath: "/Applications/HelloText.app"),
            bundleID: "io.apkrun.android.io.apkrun.fixture.hellotext",
            packageID: "io.apkrun.fixture.hellotext",
            registered: true,
            problems: [.signatureInvalid, .bundleIDMismatch]
        )
        #expect(
            WrapCommandSupport.verificationText(broken)
                == golden("wrap-verify-problems.txt"))
    }
#endif

// MARK: - #80 `apkrun settings`

struct SettingsCommandTests {
    private func entries() -> [PackageSettingWire] {
        [
            PackageSettingWire(
                key: "window.defaultWidth", value: "1080", source: "default",
                appliesLive: false, stored: nil, allowed: nil),
            PackageSettingWire(
                key: "window.resizable", value: "true", source: "recommended",
                appliesLive: true, stored: nil, allowed: ["true", "false"]),
            PackageSettingWire(
                key: "window.zoom", value: "1.00", source: "user",
                appliesLive: true, stored: "1.00", allowed: nil),
        ]
    }

    /// cli.md §4.2: `settings list` shows the effective value and source.
    @Test func settingsListGolden() {
        #expect(
            SettingsCommand.SettingsCommandSupport.listText(entries())
                == golden("settings-list.txt"))
    }

    /// cli.md §4.2: an unknown key exits 4 (`store.unknownSetting`).
    @Test func settingsUnknownKeyExitCode() {
        let failure = SettingsCommand.unknownSetting("window.bogus")
        #expect(failure.code == "store.unknownSetting")
        #expect(ExitCodes.code(for: failure) == 4)
    }

    /// cli.md §4.2: an invalid value exits 64 (`store.invalidSettingValue`).
    @Test func settingsInvalidValueExitCode() {
        let failure = RuntimeWireError(
            domain: "store", code: "store.invalidSettingValue",
            message: "window.zoom must be one of 0.75–2.0",
            parameters: ["key": "window.zoom", "allowed": "0.75–2.0"])
        #expect(ExitCodes.code(for: failure) == 64)
    }

    /// cli.md §4.2: an unmanaged package exits 4 (`store.packageNotFound`).
    @Test func settingsPackageNotFoundExitCode() {
        let failure = RuntimeWireError(
            domain: "store", code: "store.packageNotFound",
            message: "APKRun doesn't manage an app named com.nope.")
        #expect(ExitCodes.code(for: failure) == 4)
    }
}
