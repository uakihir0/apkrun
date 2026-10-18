import Foundation
import Testing

@testable import RuntimeCore

@Test func placeholderCanBeConstructed() {
    _ = RuntimeCorePlaceholder()
}

@Test(.timeLimit(.minutes(1)))
func consoleTaskDrainCancelsConsumerBeforeJoiningIt() async {
    let stream = AsyncStream.makeStream(of: Data.self)
    let consumer = Task {
        for await _ in stream.stream {}
    }

    let didDrain = await waitForConsoleTaskDrain(consumer, timeout: .milliseconds(10))

    #expect(!didDrain)
}

@Test(.timeLimit(.minutes(1)))
func sessionRegistryReusesLivePackageAndLimitsEmbeddedDisplayToOneSession() async throws {
    let registry = SessionRegistry()

    let first = try await registry.request(packageID: "io.apkrun.fixture.hellotext")
    let repeated = try await registry.request(packageID: "io.apkrun.fixture.hellotext")
    #expect(first.id == repeated.id)
    #expect(first.displayID == 0)

    await #expect(throws: SessionRegistryFailure.displayInUse(packageID: "io.apkrun.fixture.hellotext")) {
        try await registry.request(packageID: "io.apkrun.fixture.hellocompose")
    }
}

@Test(.timeLimit(.minutes(1)))
func sessionRegistryAppliesThePackageStorePackageNameLimits() async {
    let registry = SessionRegistry()
    await #expect(throws: SessionRegistryFailure.invalidPackageIdentifier) {
        try await registry.request(packageID: "com.example._internal")
    }
    let overlongPackageID = "\(String(repeating: "a", count: 254)).b"
    await #expect(throws: SessionRegistryFailure.invalidPackageIdentifier) {
        try await registry.request(packageID: overlongPackageID)
    }
}

@Test(.timeLimit(.minutes(1)))
func sessionRegistryEnforcesLifecycleAndTracksOnlyItsOwnPackageTasks() async throws {
    let registry = SessionRegistry()
    let session = try await registry.request(packageID: "io.apkrun.fixture.hellotext")
    _ = try await registry.transition(session.id, to: .waitingForRuntime)
    _ = try await registry.transition(session.id, to: .acquiringDisplay)
    _ = try await registry.transition(session.id, to: .launching)
    _ = await registry.launchCompleted(packageID: "io.apkrun.fixture.hellotext", taskID: 12)
    _ = try await registry.transition(session.id, to: .running)
    #expect(await registry.taskAppeared(packageID: "io.apkrun.fixture.hellotext", taskID: 12)?.taskIDs == [12])

    #expect(await registry.taskVanished(packageID: "io.apkrun.fixture.hellocompose", taskID: 12) == nil)
    #expect(await registry.session(session.id)?.state == .running)

    let ended = await registry.taskVanished(packageID: "io.apkrun.fixture.hellotext", taskID: 12)
    #expect(ended?.state == .ended(.appExited))
    let relaunched = try await registry.request(packageID: "io.apkrun.fixture.hellotext")
    #expect(relaunched.id != session.id)
}

@Test(.timeLimit(.minutes(1)))
func sessionRegistryEndsATrackedTaskThatExitsBeforeItsFirstFrame() async throws {
    let registry = SessionRegistry()
    let session = try await registry.request(packageID: "io.apkrun.fixture.hellotext")
    _ = try await registry.transition(session.id, to: .waitingForRuntime)
    _ = try await registry.transition(session.id, to: .acquiringDisplay)
    _ = try await registry.transition(session.id, to: .launching)
    _ = await registry.launchCompleted(packageID: "io.apkrun.fixture.hellotext", taskID: 17)
    _ = await registry.taskAppeared(packageID: "io.apkrun.fixture.hellotext", taskID: 17)

    let ended = await registry.taskVanished(packageID: "io.apkrun.fixture.hellotext", taskID: 17)

    #expect(ended?.state == .ended(.appExited))
    #expect(ended?.taskIDs.isEmpty == true)
}

@Test(.timeLimit(.minutes(1)))
func sessionRegistryRejectsSkippedLifecycleTransitionsAndRecordsWindowClose() async throws {
    let registry = SessionRegistry()
    let session = try await registry.request(packageID: "io.apkrun.fixture.hellotext")

    await #expect(throws: SessionRegistryFailure.invalidTransition(from: .requested, to: .running)) {
        try await registry.transition(session.id, to: .running)
    }

    _ = try await registry.transition(session.id, to: .acquiringDisplay)
    _ = try await registry.transition(session.id, to: .launching)
    _ = await registry.launchCompleted(packageID: "io.apkrun.fixture.hellotext", taskID: 12)
    _ = try await registry.transition(session.id, to: .running)
    _ = await registry.taskAppeared(packageID: "io.apkrun.fixture.hellotext", taskID: 12)
    _ = try await registry.transition(session.id, to: .closing)
    let ended = await registry.taskVanished(packageID: "io.apkrun.fixture.hellotext", taskID: 12)
    #expect(ended?.state == .ended(.userClosed))
    #expect(!AppSessionState.ended(.userClosed).acceptsInput)
}
