import Foundation
import RuntimeAPI
import Testing

@MainActor
@Test
func menuBarModelListsOnlyRunningSessionsWithPackageNames() async {
    let firstPackage = packageID("io.example.first")
    let secondPackage = packageID("io.example.second")
    let service = MenuBarTestRuntimeService(
        sessions: [
            RuntimeSessionSnapshot(packageID: firstPackage, phase: .running),
            RuntimeSessionSnapshot(packageID: secondPackage, phase: .starting),
        ],
        packages: [
            package(firstPackage, name: "First app"),
            package(secondPackage, name: "Second app"),
        ]
    )
    let model = MenuBarModel(service: service)

    await model.reload()

    #expect(model.isConnected)
    #expect(
        model.snapshot.sessions == [
            MenuBarSession(
                id: firstPackage.rawValue,
                packageID: firstPackage.rawValue,
                displayName: "First app"
            )
        ])
}

@MainActor
@Test
func menuBarModelConfirmsStopWhenASessionIsStarting() async {
    let runningPackageID = packageID("io.example.running")
    let service = MenuBarTestRuntimeService(
        sessions: [RuntimeSessionSnapshot(packageID: runningPackageID, phase: .starting)]
    )
    let model = MenuBarModel(service: service)
    await model.reload()

    #expect(model.snapshot.sessions.isEmpty)
    #expect(model.snapshot.hasOpenSessions)
    await model.requestStopAndroid()

    #expect(model.isShowingStopConfirmation)
    #expect(service.stopCount == 0)

    await model.confirmStopAndroid()

    #expect(!model.isShowingStopConfirmation)
    #expect(service.stopCount == 1)
    #expect(model.snapshot.runtimeStatus?.runtimeState == "stopped")
}

@MainActor
@Test
func menuBarModelStartsAndroidWhenStopped() async {
    let service = MenuBarTestRuntimeService(status: sampleRuntimeStatus("stopped"))
    let model = MenuBarModel(service: service)
    await model.reload()

    await model.startAndroid()

    #expect(service.startCount == 1)
    #expect(model.snapshot.runtimeStatus?.runtimeState == "ready")
}

@MainActor
@Test
func menuBarModelReloadsAfterASessionSnapshotChangedEvent() async {
    let service = MenuBarTestRuntimeService()
    let model = MenuBarModel(service: service)
    await model.start()
    await waitUntil {
        service.subscribedTopics.contains(.sessions)
    }

    let packageID = packageID("io.example.session")
    service.sessions = [RuntimeSessionSnapshot(packageID: packageID, phase: .running)]
    service.emit(.sessions)

    await waitUntil { model.snapshot.sessions.map(\.packageID) == [packageID.rawValue] }
    model.stopListening()
}

@MainActor
@Test
func menuBarModelStopsWithoutConfirmationWhenNoSessionIsOpen() async {
    let service = MenuBarTestRuntimeService()
    let model = MenuBarModel(service: service)
    await model.reload()

    await model.requestStopAndroid()

    #expect(!model.isShowingStopConfirmation)
    #expect(service.stopCount == 1)
    #expect(model.snapshot.runtimeStatus?.runtimeState == "stopped")
}

@MainActor
@Test
func menuBarModelReloadsAfterAnEvent() async {
    let service = MenuBarTestRuntimeService(status: sampleRuntimeStatus("stopped"))
    let model = MenuBarModel(service: service)
    await model.start()
    await waitUntil { service.subscribedTopics.contains(.runtime) }

    service.status = sampleRuntimeStatus("ready")
    service.emit(.runtime)
    await waitUntil { model.snapshot.runtimeStatus?.runtimeState == "ready" }

    #expect(model.isConnected)
    #expect(model.snapshot.runtimeStatus?.runtimeState == "ready")
    model.stopListening()
}

@MainActor
@Test
func menuBarModelRetriesSnapshotAfterResyncFailure() async {
    let service = MenuBarTestRuntimeService(status: sampleRuntimeStatus("ready"))
    let model = MenuBarModel(
        service: service,
        snapshotRetryInitialDelay: .milliseconds(1)
    )
    await model.start()
    await waitUntil {
        model.isConnected
            && service.subscribedTopics == Set([.runtime, .sessions, .updates, .health])
    }

    let priorReadCount = service.runtimeStatusReadCount
    service.failNextRuntimeStatusRead = true
    service.status = sampleRuntimeStatus("stopped")
    service.emit(.runtime)

    await waitUntil {
        model.isConnected
            && model.snapshot.runtimeStatus?.runtimeState == "stopped"
            && service.runtimeStatusReadCount >= priorReadCount + 2
    }

    #expect(service.runtimeStatusReadCount == priorReadCount + 2)
    model.stopListening()
}

@MainActor
private final class MenuBarTestRuntimeService: MenuBarRuntimeService {
    var status: RuntimeHostStatus
    var sessions: [RuntimeSessionSnapshot]
    var packages: RuntimePackageListResult
    var failNextRuntimeStatusRead = false
    private(set) var runtimeStatusReadCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var subscribedTopics: Set<EventTopic> = []
    private var continuations: [EventTopic: AsyncStream<EventEnvelope>.Continuation] = [:]

    init(
        status: RuntimeHostStatus = sampleRuntimeStatus("ready"),
        sessions: [RuntimeSessionSnapshot] = [],
        packages: [RuntimePackageSummary] = []
    ) {
        self.status = status
        self.sessions = sessions
        self.packages = RuntimePackageListResult(packages: packages, source: .liveAndroid)
    }

    func runtimeStatus() async throws -> RuntimeHostStatus {
        runtimeStatusReadCount += 1
        if failNextRuntimeStatusRead {
            failNextRuntimeStatusRead = false
            throw TestServiceError.unavailable
        }
        return status
    }

    func listSessions() async throws -> [RuntimeSessionSnapshot] {
        sessions
    }

    func listPackages() async throws -> RuntimePackageListResult {
        packages
    }

    func startRuntime() async throws -> RuntimeHostStatus {
        startCount += 1
        status = sampleRuntimeStatus("ready")
        return status
    }

    func stopRuntime() async throws -> RuntimeHostStatus {
        stopCount += 1
        status = sampleRuntimeStatus("stopped")
        return status
    }

    func launch(packageID: RuntimePackageID) async throws {}

    func subscribe(to topic: EventTopic) async throws -> AsyncStream<EventEnvelope> {
        AsyncStream { continuation in
            subscribedTopics.insert(topic)
            continuations[topic] = continuation
        }
    }

    func emit(_ topic: EventTopic) {
        continuations[topic]?.yield(
            EventEnvelope(
                topic: topic,
                seq: 1,
                time: Date(),
                payload: .resyncRequired(topic)
            )
        )
    }
}

private enum TestServiceError: Error {
    case unavailable
}

private func package(_ packageID: RuntimePackageID, name: String) -> RuntimePackageSummary {
    RuntimePackageSummary(
        packageID: packageID,
        displayName: name,
        versionCode: nil
    )
}

private func packageID(_ rawValue: String) -> RuntimePackageID {
    guard let packageID = RuntimePackageID(rawValue: rawValue) else {
        Issue.record("Invalid package ID in test fixture: \(rawValue)")
        return RuntimePackageID(rawValue: "io.example.invalid")!
    }
    return packageID
}

private func sampleRuntimeStatus(_ runtimeState: String) -> RuntimeHostStatus {
    RuntimeHostStatus(
        hostState: "running",
        runtimeState: runtimeState,
        bootProgress: nil,
        startupFailureStep: nil,
        startupFailureCode: nil,
        crashLoopActive: false,
        daemonPID: 1,
        imageVersion: nil
    )
}

@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while clock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Condition was not satisfied.", sourceLocation: sourceLocation)
}
