import DiagnosticsCore
import Foundation
import GuestProtocol
import RuntimeAPI
import RuntimeCore

extension RuntimeHost {
    /// Starts a `diagnostics` operation (runtime-api.md §4.7, diagnostics.md
    /// §8.1). The client owns `output`; the daemon never opens a user-chosen
    /// path. Progress flows through the operations topic stages
    /// collecting → redacting → writing; cancel truncates the output.
    func createDiagnostics(
        _ request: DiagnosticsRequest,
        output: FileHandle,
        operationID: WireOperationID,
        clientKind: RuntimeClientKind
    ) async throws(RuntimeWireError) -> OperationHandle {
        let requestedID = operationID
        if let existing = trackedOperations[requestedID] {
            return existing.handle
        }
        do {
            try beginLifecycleOperation()
        } catch {
            throw Self.sessionWireError(for: error)
        }

        let handle = OperationHandle(operationID: requestedID, kind: .diagnostics)
        let snapshot = OperationSnapshot(
            operationID: requestedID,
            kind: .diagnostics,
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(
                stage: "collecting",
                message: "Collecting report data…"
            )
        )
        trackedOperations[requestedID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: (try? JSONEncoder().encode(request)) ?? Data(),
            snapshot: snapshot,
            isCancellable: true,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: requestedID)
        let task = Task { [weak self] in
            guard let self else { return }
            if let diagnosticsID = DiagnosticsCore.OperationID(wire: requestedID.wireValue) {
                let context = OperationContext(operationID: diagnosticsID)
                await OperationContext.$current.withValue(context) {
                    await self.runCreateDiagnosticsOperation(
                        request, output: output, operationID: requestedID)
                }
            } else {
                await self.runCreateDiagnosticsOperation(
                    request, output: output, operationID: requestedID)
            }
        }
        trackedOperations[requestedID]?.task = task
        return handle
    }

    /// Runs a `diagnostics` operation to its terminal state.
    private func runCreateDiagnosticsOperation(
        _ request: DiagnosticsRequest,
        output: FileHandle,
        operationID: WireOperationID
    ) async {
        do {
            let options = DiagnosticsOptions(
                includeLogcat: request.includeLogcat,
                deep: request.deep,
                focusPackage: request.focusPackage,
                createdBy: request.createdBy,
                mode: "full")
            let result = try await runDiagnosticsReport(
                options: options,
                to: output,
                operationID: operationID)
            finishOperation(
                operationID,
                result: .succeeded(.diagnostics(
                    DiagnosticsReportInfo(
                        bytes: result.bytes,
                        omitted: result.omitted.map {
                            WireOmittedItem(item: $0.item, reason: $0.reason)
                        },
                        summary: result.summary))))
        } catch is CancellationError {
            // Cancel truncates the output (§8.1): a partial archive never
            // looks like a report.
            try? output.truncate(atOffset: 0)
            finishOperation(operationID, result: .cancelled)
        } catch {
            finishOperation(
                operationID,
                result: .failed(Self.diagnosticsWireError(for: error)))
        }
        try? output.synchronize()
    }

    /// Publishes a progress stage for the report run.
    private func noteDiagnosticsStage(
        _ operationID: WireOperationID, _ phase: DiagnosticsBundleService.Phase
    ) {
        guard var operation = trackedOperations[operationID], operation.snapshot.result == nil else {
            return
        }
        let (stage, message) = {
            switch phase {
            case .collecting: ("collecting", "Collecting report data…")
            case .redacting: ("redacting", "Redacting report data…")
            case .writing: ("writing", "Writing the report…")
            }
        }()
        operation.snapshot = OperationSnapshot(
            operationID: operation.snapshot.operationID,
            parent: operation.snapshot.parent,
            kind: operation.snapshot.kind,
            packageID: operation.snapshot.packageID,
            requestFingerprint: operation.snapshot.requestFingerprint,
            clientKind: operation.snapshot.clientKind,
            startedAt: operation.snapshot.startedAt,
            progress: OperationProgress(stage: stage, message: message)
        )
        trackedOperations[operationID] = operation
        eventHub.publishOperationEvent(
            .progress(operationID, operation.snapshot.progress ?? OperationProgress()),
            operationID: operationID
        )
    }

    /// Builds the identity, contributors, and summary context, then runs the
    /// bundle service (diagnostics.md §8.1).
    private func runDiagnosticsReport(
        options: DiagnosticsOptions,
        to output: FileHandle,
        operationID: WireOperationID
    ) async throws -> DiagnosticsBundleResult {
        let paths = self.paths
        let identity = RedactionIdentity(
            preservedPaths: [paths.dataRoot.path, paths.logsRoot.path])

        var contributors: [DiagnosticsContributor] = [
            HostEnvironmentContributor(),
            VersionsContributor(versions: { [weak self] in
                await self?.diagnosticsVersions() ?? [:]
            }),
            ConfigContributor(settingsFile: paths.settingsFile),
            MetricsContributor(snapshot: { nil }),
            HostLogsContributor(mirrorDirectory: paths.logsRoot),
            PerfContributor(
                launchesFile: paths.launchPerformanceFile,
                bootsFile: paths.bootPerformanceFile),
        ]

        // The doctor's check set, shared with `apkrun doctor` (§7.4): the
        // report's health.json is the wire report, health.txt its text form.
        contributors.append(
            HealthContributor { [weak self] deep in
                guard let self,
                    let report = try? await self.healthReport(deep: deep, checks: nil)
                else { return nil }
                guard let json = try? JSONEncoder().encode(report) else { return nil }
                let text = DoctorFormatter.format(
                    rows: report.results.map(Self.diagnosticsDoctorRow),
                    statusLine: report.statusLine)
                return (json: json, text: text)
            })

        // Module-owned sections (§8.2): RuntimeCore owns runtime/ and guest/;
        // the other stores write through closures so no dependency edge is
        // crossed.
        contributors.append(
            ClosureDiagnosticsContributor(name: "runtime") { [weak self] bundle, options in
                try await self?.contributeRuntime(to: bundle, options: options)
            })
        contributors.append(
            ClosureDiagnosticsContributor(
                name: "guest", budget: .seconds(60)
            ) { [weak self] bundle, options in
                try await self?.contributeGuest(to: bundle, options: options)
            })
        contributors.append(
            ClosureDiagnosticsContributor(name: "packages") { [weak self] bundle, options in
                try await self?.contributePackages(to: bundle, options: options)
            })
        contributors.append(
            ClosureDiagnosticsContributor(name: "wrappers") { [weak self] bundle, _ in
                try await self?.contributeWrappers(to: bundle)
            })
        contributors.append(
            ClosureDiagnosticsContributor(name: "integrations") { [weak self] bundle, _ in
                try await self?.contributeIntegrations(to: bundle)
            })
        contributors.append(
            ClosureDiagnosticsContributor(name: "maintenance") { [weak self] bundle, _ in
                try await self?.contributeMaintenance(to: bundle)
            })

        let build = await diagnosticsBuild()
        let service = DiagnosticsBundleService(
            identity: identity, contributors: contributors, build: build)

        let runtimeRunning = await diagnosticsRuntimeRunning()
        let appsLine = await diagnosticsAppsLine()
        let statusLine = runtimeRunning
            ? "APKRun is running."
            : "Android is not running."
        return try await service.run(
            options: options,
            to: output,
            summaryContext: { _ in
                DiagnosticsSummaryContext(
                    statusLine: statusLine,
                    buildLine: build,
                    appsLine: appsLine,
                    guestMissingReason: runtimeRunning ? nil : "Android was not running",
                    operationID: operationID.wireValue)
            },
            onPhase: { [weak self] phase in
                Task { await self?.noteDiagnosticsStage(operationID, phase) }
            },
            isCancelled: { false })
    }

    /// The `runtime/` section: status, daemon record, graphics, sessions.
    private func contributeRuntime(
        to bundle: DiagnosticsBundleBuilder,
        options: DiagnosticsOptions
    ) async throws {
        var status: [String: Any] = [
            "state": String(describing: runtimeStateSnapshot),
        ]
        let sessions = await listSessions()
        status["sessions"] = sessions.count
        try bundle.addJSON("runtime/status.json", status)

        if let data = try? Data(contentsOf: paths.daemonStateFile) {
            try bundle.add("runtime/daemon.json", data: data)
        } else {
            bundle.omit("runtime/daemon.json", reason: "unavailable")
        }

        if let statistics = await supervisor?.graphicsDeviceStatistics {
            var graphics: [String: Any] = [
                "rendererFailures": statistics.rendererFailures
            ]
            let sessionStats = await sessionGraphicsStatistics(sessionID: nil)
            graphics["sessions"] = sessionStats.map {
                [
                    "packageID": $0.packageID.rawValue,
                    "fps": $0.fps,
                    "droppedFrames": $0.droppedFrames,
                ] as [String: Any]
            }
            try bundle.addJSON("runtime/graphics.json", graphics)
        } else {
            bundle.omit("runtime/graphics.json", reason: "unavailable")
        }
    }

    /// The `guest/` section through operation 73 (§8.3). Missing when the
    /// agent cannot answer — the bundle says why, and Android is never
    /// started for a report.
    private func contributeGuest(
        to bundle: DiagnosticsBundleBuilder,
        options: DiagnosticsOptions
    ) async throws {
        guard let agent = await supervisor?.developmentGuestAgent else {
            bundle.omit("guest/", reason: "guestAgentUnavailable")
            return
        }
        let items: [GPDiagnosticsItem] = [
            .getprop, .logcat, .dumpsysWindow, .dumpsysDisplay, .dumpsysInput,
            .dumpsysActivity, .dumpsysSurfaceflinger, .dumpsysMeminfo,
            .tombstoneList, .agentLog,
        ]
        let collected: [GuestDiagnosticsItem]
        do {
            collected = try await agent.collectDiagnostics(
                items: items, maxBytes: 16 * 1024 * 1024)
        } catch {
            bundle.omit("guest/", reason: "guestAgentUnavailable")
            return
        }
        for item in collected {
            let name: String
            switch item.item {
            case .getprop: name = "guest/getprop.txt"
            case .logcat: name = "guest/logcat.txt"
            case .dumpsysWindow: name = "guest/dumpsys-window.txt"
            case .dumpsysDisplay: name = "guest/dumpsys-display.txt"
            case .dumpsysInput: name = "guest/dumpsys-input.txt"
            case .dumpsysActivity: name = "guest/dumpsys-activity.txt"
            case .dumpsysSurfaceflinger: name = "guest/dumpsys-surfaceflinger.txt"
            case .dumpsysMeminfo: name = "guest/dumpsys-meminfo.txt"
            case .tombstoneList: name = "guest/tombstones.txt"
            case .agentLog: name = "guest/agent.log"
            default: name = "guest/item-\(item.item.rawValue).txt"
            }
            guard item.status == .ok, let payload = item.payload else {
                bundle.omit(
                    name, reason: "collection\(item.status.rawValue.capitalized)")
                continue
            }
            var text = String(decoding: payload, as: UTF8.self)
            if item.item == .logcat {
                text = LogcatFilter.filter(text, includeAll: options.includeLogcat)
            }
            try bundle.add(name, text: text)
        }
    }

    /// The `packages/` section: allowlisted records and the update history.
    private func contributePackages(
        to bundle: DiagnosticsBundleBuilder,
        options: DiagnosticsOptions
    ) async throws {
        do {
            let listed = try await listPackages(RuntimeListPackagesRequest())
            var records: [[String: Any]] = []
            for package in listed.packages {
                records.append(
                    DiagnosticsAllowlists.filterPackageRecord([
                        "packageID": package.packageID.rawValue,
                        "versionName": package.versionName ?? "",
                        "versionCode": "\(package.versionCode)",
                    ]))
            }
            try bundle.addJSON("packages/packages.json", records)
        } catch {
            bundle.omit("packages/packages.json", reason: "unavailable")
        }

        // Update history: journal tail and store state files are already
        // path-reduced JSON lines.
        for (source, destination) in [
            (paths.packageJournalFile, "packages/journal-tail.jsonl"),
            (paths.updatesHistoryFile, "packages/updates.json"),
            (paths.updatesStateFile, "packages/update-state.json"),
        ] {
            guard let data = try? Data(contentsOf: source) else { continue }
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
            let tail = lines.suffix(500).joined(separator: "\n")
            try bundle.add(destination, text: tail + "\n")
        }
    }

    /// The `wrappers/` section: registry paths reduced to the last
    /// component (§8.2). Bookmarks never leave the daemon's memory.
    private func contributeWrappers(to bundle: DiagnosticsBundleBuilder) async throws {
        guard let data = try? Data(contentsOf: paths.wrapperRegistryFile),
            var text = String(data: data, encoding: .utf8)
        else { return }
        text = text.replacingOccurrences(
            of: #""bookmark"\s*:\s*"[^"]*""#, with: "\"bookmark\": null",
            options: .regularExpression)
        try bundle.add("wrappers/registry.json", text: text)
    }

    /// The `integrations/` section: per-package capability booleans.
    private func contributeIntegrations(to bundle: DiagnosticsBundleBuilder) async throws {
        var status: [String: Any] = [:]
        if let listed = try? await listPackages(RuntimeListPackagesRequest()) {
            for package in listed.packages {
                if let entry = try? await integrationStatus(packageID: package.packageID) {
                    let data = try JSONEncoder().encode(entry)
                    if var object = try JSONSerialization.jsonObject(with: data)
                        as? [String: Any] {
                        object.removeValue(forKey: "packageID")
                        status[package.packageID.rawValue] = object
                    }
                }
            }
        }
        if status.isEmpty {
            bundle.omit("integrations/status.json", reason: "unavailable")
        } else {
            try bundle.addJSON("integrations/status.json", status)
        }
    }

    /// The `maintenance/` section: host state and self-update status.
    private func contributeMaintenance(to bundle: DiagnosticsBundleBuilder) async throws {
        if let data = try? Data(contentsOf: paths.maintenanceStateFile) {
            try bundle.add("maintenance/state.json", data: data)
        } else {
            bundle.omit("maintenance/state.json", reason: "unavailable")
        }
        if let data = try? Data(contentsOf: paths.imageUpdateStateFile) {
            try bundle.add("maintenance/image-update-state.json", data: data)
        }
    }

    /// The manifest's `build` string.
    private func diagnosticsBuild() async -> String {
        let daemon = await daemonBuildNumber ?? "unknown"
        return "1.0 (\(daemon))"
    }

    /// The versions map of `host/versions.json`.
    private func diagnosticsVersions() async -> [String: String] {
        let daemon = await daemonBuildNumber ?? "unknown"
        return [
            "apkrund": "1.0 (\(daemon))",
            "cli": "1.0 (\(daemon))",
            "apiLevel": "\(APIVersion.current.major).\(APIVersion.current.minor)",
        ]
    }

    /// Whether Android is running, for the summary's guest line.
    private func diagnosticsRuntimeRunning() -> Bool {
        switch runtimeStateSnapshot {
        case .stopped, .failed: false
        default: supervisor != nil
        }
    }

    /// The summary's apps line from the package store.
    private func diagnosticsAppsLine() async -> String? {
        guard let listed = try? await listPackages(RuntimeListPackagesRequest()) else {
            return nil
        }
        let names = listed.packages.map { $0.packageID.rawValue }.sorted()
        if names.isEmpty { return "Apps: none installed" }
        return "Apps: \(names.count) installed — \(names.joined(separator: ", "))"
    }

    /// The report failure as a wire error.
    static func diagnosticsWireError(for error: Error) -> RuntimeWireError {
        if error is DiagnosticsBundleWriter.Failure {
            return RuntimeWireError(
                domain: "diagnostics",
                code: "diagnostics.writeFailed",
                message: "\(error)")
        }
        return RuntimeWireError(
            domain: "diagnostics",
            code: "diagnostics.failed",
            message: "\(error)")
    }

    /// Maps a wire health result onto a formatter row for `health.txt`.
    static func diagnosticsDoctorRow(_ result: WireHealthResult) -> DoctorRow {
        DoctorRow(
            id: result.id,
            group: result.group,
            state: result.state,
            title: result.title.fallback,
            detail: result.detail,
            error: result.error,
            remediation: result.error.flatMap {
                ErrorCatalog.entry(for: $0)?.remediation?["en"]
            },
            fixAvailable: result.fixAvailable
        )
    }
}
