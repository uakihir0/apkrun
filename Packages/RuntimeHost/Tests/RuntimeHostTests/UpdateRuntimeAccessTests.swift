import APKStoreCore
import Foundation
import RuntimeAPI
import Testing
import RuntimeCore
import UpdateCore

@testable import RuntimeHost

/// A fake `RuntimeSessionService` + `PackageMutationSessionHandling` for the
/// §7.5 runtime-access T1 checks (fake sessions, no VM).
private actor FakeSessionHandling: RuntimeSessionService, PackageMutationSessionHandling {
    var liveSessions: Set<String> = []
    var backgroundTasks: Set<String> = []
    var lastEndAt: [String: ContinuousClock.Instant] = [:]
    var endedForUpdate: [String] = []
    var reopened: [String] = []
    private var observers: [@Sendable (RuntimePackageID, PackageSessionActivity) -> Void] = []

    /// An observer marker for tests: `runtimeEvents` subscribes lazily.
    var observerCount: Int { observers.count }

    func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        liveSessions.insert(request.packageID.rawValue)
        emit(request.packageID, .started)
        return RuntimeLaunchResult(
            sessionID: UUID(), packageID: request.packageID, state: .running)
    }

    func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError)
        -> RuntimeTerminateResult
    {
        liveSessions.remove(request.packageID.rawValue)
        lastEndAt[request.packageID.rawValue] = .now
        emit(request.packageID, .ended)
        return RuntimeTerminateResult(packageID: request.packageID, hadSession: true)
    }

    func hasActiveSession(packageID: RuntimePackageID) -> Bool {
        liveSessions.contains(packageID.rawValue)
    }

    func hasBackgroundActivity(packageID: RuntimePackageID) -> Bool {
        backgroundTasks.contains(packageID.rawValue)
    }

    func markBackgroundTask(_ packageID: String, active: Bool) {
        if active {
            backgroundTasks.insert(packageID)
        } else if backgroundTasks.remove(packageID) != nil,
            let wireID = RuntimePackageID(rawValue: packageID)
        {
            emit(wireID, .taskEnded)
        }
    }

    func endSessionForPackageUninstall(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) {}

    func lastSessionEnd(packageID: RuntimePackageID) -> ContinuousClock.Instant? {
        lastEndAt[packageID.rawValue]
    }

    func endSessionForUpdate(packageID: RuntimePackageID, reason: SessionEndReason) {
        endedForUpdate.append(packageID.rawValue)
        liveSessions.remove(packageID.rawValue)
        lastEndAt[packageID.rawValue] = .now
        emit(packageID, .ended)
    }

    func reopenPackageSession(packageID: RuntimePackageID) async throws {
        reopened.append(packageID.rawValue)
        liveSessions.insert(packageID.rawValue)
        emit(packageID, .started)
    }

    func observeSessionActivity(
        _ observer: @escaping @Sendable (RuntimePackageID, PackageSessionActivity) -> Void
    ) {
        observers.append(observer)
    }

    private func emit(_ packageID: RuntimePackageID, _ activity: PackageSessionActivity) {
        for observer in observers {
            observer(packageID, activity)
        }
    }
}

private func hostWithFakeSessions() async -> (RuntimeHost, FakeSessionHandling) {
    let host = RuntimeHost()
    let fake = FakeSessionHandling()
    await host.installHeadlessSessionServiceForTesting(fake)
    return (host, fake)
}

@Test(.timeLimit(.minutes(1)))
func updateRuntimeAccessReportsStoppedWithoutSupervisor() async throws {
    let (host, _) = await hostWithFakeSessions()
    let access = await host.updateRuntimeAccess()
    #expect(await access.runtimeState == .stopped)
    // GU5 never blocks when Android cannot be asked (§7.1 hint).
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    #expect(await access.androidAllowsGentleInstall(package))
}

@Test(.timeLimit(.minutes(1)))
func hasActiveUseCoversSessionAndBackgroundTask() async throws {
    let (host, fake) = await hostWithFakeSessions()
    let access = await host.updateRuntimeAccess()
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let wireID = try #require(RuntimePackageID(rawValue: package.rawValue))

    #expect(await !access.hasActiveUse(package))

    _ = try await fake.launch(RuntimeLaunchRequest(packageID: wireID))
    #expect(await access.hasActiveUse(package))  // GU2

    _ = try await fake.terminate(RuntimeTerminateRequest(packageID: wireID))
    #expect(await !access.hasActiveUse(package))

    await fake.markBackgroundTask(package.rawValue, active: true)
    #expect(await access.hasActiveUse(package))  // GU3
}

@Test(.timeLimit(.minutes(1)))
func lastSessionEndAndUpdateSessionOps() async throws {
    let (host, fake) = await hostWithFakeSessions()
    let access = await host.updateRuntimeAccess()
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let wireID = try #require(RuntimePackageID(rawValue: package.rawValue))

    #expect(await access.lastSessionEnd(package) == nil)
    _ = try await fake.launch(RuntimeLaunchRequest(packageID: wireID))
    _ = try await fake.terminate(RuntimeTerminateRequest(packageID: wireID))
    #expect(await access.lastSessionEnd(package) != nil)

    _ = try await fake.launch(RuntimeLaunchRequest(packageID: wireID))
    await access.endSessions(for: package, reason: .updating)
    #expect(await fake.endedForUpdate == [package.rawValue])

    await access.reopen(package)
    #expect(await fake.reopened == [package.rawValue])
}

@Test(.timeLimit(.minutes(1)))
func runtimeEventsCarrySessionAndTaskActivity() async throws {
    let (host, fake) = await hostWithFakeSessions()
    let access = await host.updateRuntimeAccess()
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let wireID = try #require(RuntimePackageID(rawValue: package.rawValue))

    var iterator = access.runtimeEvents.makeAsyncIterator()
    // The stream subscribes to the session service asynchronously; wait for
    // the observer marker before emitting, never a fixed sleep.
    while await fake.observerCount == 0 {
        await Task.yield()
    }

    _ = try await fake.launch(RuntimeLaunchRequest(packageID: wireID))
    let started = await iterator.next()
    _ = try await fake.terminate(RuntimeTerminateRequest(packageID: wireID))
    let ended = await iterator.next()
    await fake.markBackgroundTask(package.rawValue, active: true)
    await fake.markBackgroundTask(package.rawValue, active: false)
    let taskEnded = await iterator.next()

    #expect(started == .sessionStarted(package))
    #expect(ended == .sessionEnded(package))
    #expect(taskEnded == .taskEnded(package))
}
