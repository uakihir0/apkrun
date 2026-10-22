import Foundation
import RuntimeAPI
import RuntimeCore
import XCTest
@testable import RuntimeHost

/// Exercises the idle policy against a running Android VM (#70, runtime-daemon.md §5).
///
/// Runs in the `AndroidIdleSuspend` test-plan configuration and needs the Android bundle and development Guest Agent.
final class IdleSuspendTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-idle-suspend" else {
            throw XCTSkip("Idle suspend checks run in the AndroidIdleSuspend test-plan configuration.")
        }
    }

    /// With no activity assertions, the one-minute deadline pauses the VM and the two-minute deadline stops it.
    func testIdlePolicySuspendsThenStopsTheRuntime() async throws {
        try await RuntimeHostBootSession.withBoot(
            idleSettings: try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 2)
        ) { host, _ in
            let guestAgentReady = await Self.waitUntil(.seconds(15)) {
                await host.status().guestAgentState == .connected
            }
            XCTAssertTrue(guestAgentReady, "the internal ADB connection did not start the Guest Agent")
            let internalADBCountsAsActivity = await host.idleActivityKindsForTesting().contains(.adbClient)
            XCTAssertFalse(
                internalADBCountsAsActivity,
                "the supervisor's internal ADB transport must not count as user activity"
            )

            let idleStartedAt = ContinuousClock.now
            let suspended = await Self.waitUntil(.seconds(95)) {
                await host.status().runtimeState == "suspended"
            }
            XCTAssertTrue(suspended, "the VM did not suspend at the one-minute idle deadline")
            let suspendedAt = ContinuousClock.now
            XCTAssertGreaterThanOrEqual(
                idleStartedAt.duration(to: suspendedAt),
                .seconds(55),
                "the idle suspend deadline fired before one minute of inactivity"
            )
            let stopped = await Self.waitUntil(.seconds(75)) {
                await host.status().runtimeState == "stopped"
            }
            XCTAssertTrue(stopped, "the runtime did not stop at the two-minute idle deadline")
            let stoppedAt = ContinuousClock.now
            XCTAssertGreaterThanOrEqual(
                idleStartedAt.duration(to: stoppedAt),
                .seconds(110),
                "the idle stop deadline fired before two minutes of inactivity"
            )
            XCTAssertLessThan(
                idleStartedAt.duration(to: stoppedAt),
                .seconds(155),
                "the idle stop deadline exceeded its expected scheduling tolerance"
            )
        }
    }

    /// An open adb shell holds an activity assertion beyond the idle suspend deadline.
    func testConnectedADBCommandKeepsRuntimeReadyPastSuspendDeadline() async throws {
        try await RuntimeHostBootSession.withBoot(
            idleSettings: try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 0)
        ) { host, _ in
            let adb = try await Self.connectedClient(host)
            let shellTask = Task {
                try await adb.shell("sleep 65", timeout: .seconds(70))
            }

            let adbActivityStarted = await Self.waitUntil(.seconds(10)) {
                await host.idleActivityKindsForTesting().contains(.adbClient)
            }
            XCTAssertTrue(adbActivityStarted, "the active adb shell did not hold an ADB activity assertion")

            let suspendDeadline = ContinuousClock.now + .seconds(61)
            let stayedReady = await Self.waitUntil(.seconds(75)) {
                guard ContinuousClock.now >= suspendDeadline else { return false }
                return await host.status().runtimeState == "ready"
            }
            XCTAssertTrue(stayedReady, "the runtime suspended while an adb shell command was connected")
            do {
                _ = try await shellTask.value
            } catch {
                XCTFail("the controlled ADB shell did not finish cleanly: \(error)")
            }
        }
    }

    /// A pending PackageStore install holds the runtime through the idle deadline at the guest commit boundary.
    func testPendingInstallKeepsRuntimeReadyPastSuspendDeadline() async throws {
        guard let fixturePath = AndroidTestEnvironment.current()["APKRUN_FIXTURE_APK"],
            !fixturePath.isEmpty,
            FileManager.default.fileExists(atPath: fixturePath)
        else {
            throw XCTSkip("APKRUN_FIXTURE_APK does not name the HelloText fixture.")
        }

        let clock = ManualRuntimeIdleClock()
        let storeMutationGate = RuntimeHostStoreMutationGate()
        try await RuntimeHostBootSession.withBoot(
            idleSettings: try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 0),
            idleClock: clock,
            packageStoreMutationGate: storeMutationGate
        ) { host, _ in
            let apk = URL(fileURLWithPath: fixturePath)
            let file = try FileHandle(forReadingFrom: apk)
            defer { try? file.close() }
            let preview = try await host.importPackage(
                RuntimeImportPackageRequest(
                    files: [RuntimeImportSourceFile(fileIndex: 0, name: apk.lastPathComponent)],
                    origin: .cli
                ),
                files: [file]
            )
            let operationID = RuntimeAPI.OperationID()
            _ = try await host.beginInstallImported(
                RuntimeInstallImportedRequest(ticket: preview.ticket),
                operationID: operationID,
                clientKind: .cli
            )
            defer { Task { await storeMutationGate.release() } }

            let reachedStoreMutation = await Self.waitUntil(.seconds(30)) {
                await storeMutationGate.hasEntered
            }
            XCTAssertTrue(reachedStoreMutation, "PackageInstaller did not reach the controlled mutation boundary")
            let storeActivityHeld = await Self.waitUntil(.seconds(5)) {
                await host.idleActivityKindsForTesting().contains(.storeOperation)
            }
            XCTAssertTrue(storeActivityHeld, "the install did not hold a store activity assertion")

            clock.advanceAwakeTime(by: .seconds(65))
            let leftReadyWhileInstalling = await Self.waitUntil(.seconds(5)) {
                await host.status().runtimeState != "ready"
            }
            XCTAssertFalse(leftReadyWhileInstalling, "the runtime suspended while PackageInstaller was active")

            await storeMutationGate.release()
            let operationFinished = await Self.waitUntil(.seconds(30)) {
                (try? await host.operationStatus(operationID).result) != nil
            }
            XCTAssertTrue(operationFinished, "the controlled PackageInstaller operation did not finish")
            let installResult = try await host.operationStatus(operationID).result
            if case .succeeded(.package) = installResult {
                // The fixture install completed while the idle deadline was held.
            } else {
                XCTFail("Expected HelloText install to succeed, got \(String(describing: installResult))")
            }

            let storeActivityReleased = await Self.waitUntil(.seconds(5)) {
                !(await host.idleActivityKindsForTesting().contains(.storeOperation))
            }
            XCTAssertTrue(storeActivityReleased, "the completed install kept its store activity assertion")

            clock.advanceAwakeTime(by: .seconds(61))
            let suspendedAfterInstall = await Self.waitUntil(.seconds(5)) {
                await host.status().runtimeState == "suspended"
            }
            XCTAssertTrue(suspendedAfterInstall, "the runtime did not resume idle suspension after install completion")
        }
    }

    /// A normal RuntimeHost start request resumes a VM paused by the idle policy.
    func testRuntimeStartRequestResumesSuspendedVM() async throws {
        try await RuntimeHostBootSession.withBoot(
            idleSettings: try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 0)
        ) { host, _ in
            let suspended = await Self.waitUntil(.seconds(95)) {
                await host.status().runtimeState == "suspended"
            }
            XCTAssertTrue(suspended, "the VM did not suspend at the one-minute idle deadline")
            try await host.startRuntime(reason: .user)

            let resumed = await Self.waitUntil(.seconds(5)) {
                await host.status().runtimeState == "ready"
            }
            XCTAssertTrue(resumed, "the runtime start request did not resume Android")
        }
    }

    /// Every idle resume returns to ready within the documented budget and emits a frame for the new HelloText
    /// session's IOSurface.
    func testHelloTextFirstFrameAppearsAfterIdleResumeWithP50Under500Milliseconds() async throws {
        guard let fixturePath = AndroidTestEnvironment.current()["APKRUN_FIXTURE_APK"],
            !fixturePath.isEmpty,
            FileManager.default.fileExists(atPath: fixturePath)
        else {
            throw XCTSkip("APKRUN_FIXTURE_APK does not name the HelloText fixture.")
        }

        let clock = ManualRuntimeIdleClock()
        try await RuntimeHostBootSession.withBoot(
            idleSettings: try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 0),
            idleClock: clock
        ) { host, _ in
            try await Self.installHelloText(at: URL(fileURLWithPath: fixturePath), on: host)
            let storeActivityReleased = await Self.waitUntil(.seconds(5)) {
                !(await host.idleActivityKindsForTesting().contains(.storeOperation))
            }
            XCTAssertTrue(storeActivityReleased, "installing HelloText did not release its store activity assertion")
            guard storeActivityReleased else {
                return
            }
            let packageID = try XCTUnwrap(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
            var resumeDurations: [Double] = []
            resumeDurations.reserveCapacity(20)

            for run in 1...20 {
                clock.advanceAwakeTime(by: .seconds(61))
                let suspended = await Self.waitUntil(.seconds(5)) {
                    await host.status().runtimeState == "suspended"
                }
                XCTAssertTrue(suspended, "run \(run): the VM did not reach the idle-suspended state")
                guard suspended else {
                    break
                }

                let performanceEventCount = await host.performanceEventsForTesting().count
                let launchTask = Task {
                    try await host.launch(RuntimeLaunchRequest(packageID: packageID))
                }
                let ready = await Self.waitUntil(.seconds(5)) {
                    await host.status().runtimeState == "ready"
                }
                XCTAssertTrue(ready, "run \(run): the launch did not resume Android")
                guard ready else {
                    _ = try? await launchTask.value
                    break
                }

                let launch: RuntimeLaunchResult
                do {
                    launch = try await launchTask.value
                } catch {
                    XCTFail("run \(run): HelloText could not open after idle resume: \(error)")
                    break
                }
                XCTAssertEqual(launch.state, .running, "run \(run): HelloText did not reach the running state")

                let newPerformanceEvents = await host.performanceEventsForTesting().dropFirst(performanceEventCount)
                guard let resumed = newPerformanceEvents.first(where: { $0.marker == .vmResumed }),
                    let runtimeReady = newPerformanceEvents.first(where: {
                        $0.marker == .runtimeReady && $0.time >= resumed.time
                    })
                else {
                    XCTFail("run \(run): the performance timeline did not record VM_RESUMED and RUNTIME_READY")
                    break
                }
                resumeDurations.append(Self.seconds(resumed.time.duration(to: runtimeReady.time)))

                await host.beginReadyFrameObservationForTesting(sessionID: launch.sessionID)
                let firstFrameReady = await Self.waitUntil(.seconds(15)) {
                    await host.hasReadyFrameForTesting(sessionID: launch.sessionID)
                }
                XCTAssertTrue(
                    firstFrameReady,
                    "run \(run): HelloText produced no frame after its session reached running"
                )
                guard firstFrameReady else {
                    break
                }

                _ = try await host.terminate(RuntimeTerminateRequest(packageID: packageID))
                let sessionReleased = await Self.waitUntil(.seconds(5)) {
                    !(await host.idleActivityKindsForTesting().contains(.session))
                }
                XCTAssertTrue(sessionReleased, "run \(run): terminating HelloText did not release its session hold")
                guard sessionReleased else {
                    break
                }
            }

            XCTAssertEqual(resumeDurations.count, 20, "all 20 idle-resume launches must reach a first frame")
            let sortedDurations = resumeDurations.sorted()
            if sortedDurations.count == 20 {
                let p50 = (sortedDurations[9] + sortedDurations[10]) / 2
                XCTAssertLessThanOrEqual(
                    p50,
                    0.5,
                    "VM resume to RuntimeHost ready p50 was \(p50 * 1_000) ms; the budget is 500 ms"
                )
            }
        }
    }

    private static func installHelloText(at apk: URL, on host: RuntimeHost) async throws {
        let file = try FileHandle(forReadingFrom: apk)
        defer { try? file.close() }
        let preview = try await host.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: apk.lastPathComponent)],
                origin: .cli
            ),
            files: [file]
        )
        _ = try await host.installImported(RuntimeInstallImportedRequest(ticket: preview.ticket))
    }

    private static func connectedClient(_ host: RuntimeHost) async throws -> AdbClient {
        let boundPort = await host.developmentADBHostPortForTesting()
        let port = try XCTUnwrap(boundPort, "the boot bound no development ADB port")
        let adb = AdbClient(
            executable: try AndroidTestEnvironment.adbExecutable(),
            endpoint: AdbClient.loopbackEndpoint(port: port)
        )
        try await adb.connect(timeout: .seconds(30))
        return adb
    }

    /// Polls a VM state marker without waiting on a fixed-duration sleep.
    private static func waitUntil(_ budget: Duration, condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await condition()
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private final class ManualRuntimeIdleClock: RuntimeIdleClock, @unchecked Sendable {
    private final class Waiter: @unchecked Sendable {
        let id = UUID()
        let deadline: Duration
        var continuation: CheckedContinuation<Void, any Error>?
        var isCancelled = false

        init(deadline: Duration) {
            self.deadline = deadline
        }
    }

    private let lock = NSLock()
    private var instant: Duration = .zero
    private var waiters: [UUID: Waiter] = [:]

    var now: Duration {
        lock.withLock { instant }
    }

    func sleep(until deadline: Duration) async throws {
        let waiter = Waiter(deadline: deadline)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                var result: Result<Void, any Error>?
                lock.lock()
                if waiter.isCancelled {
                    result = .failure(CancellationError())
                } else if instant >= deadline {
                    result = .success(())
                } else {
                    waiter.continuation = continuation
                    waiters[waiter.id] = waiter
                }
                lock.unlock()

                if let result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancel(waiter)
        }
    }

    func advanceAwakeTime(by duration: Duration) {
        lock.lock()
        instant += duration
        let dueWaiters = waiters.values.filter { instant >= $0.deadline }
        for waiter in dueWaiters {
            waiters.removeValue(forKey: waiter.id)
        }
        let continuations = dueWaiters.compactMap { waiter -> CheckedContinuation<Void, any Error>? in
            let continuation = waiter.continuation
            waiter.continuation = nil
            return continuation
        }
        lock.unlock()

        for continuation in continuations {
            continuation.resume()
        }
    }

    private func cancel(_ waiter: Waiter) {
        lock.lock()
        waiter.isCancelled = true
        let continuation = waiter.continuation
        waiter.continuation = nil
        waiters.removeValue(forKey: waiter.id)
        lock.unlock()

        continuation?.resume(throwing: CancellationError())
    }
}
