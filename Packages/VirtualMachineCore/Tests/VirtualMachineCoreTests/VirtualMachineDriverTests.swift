import Foundation
import Testing
import VirtualMachineCore
import VirtualMachineCoreTestSupport

@Test func fakeVirtualMachineDriverRunsEveryOperationAndReturnsScriptedResults() async {
    let scriptedError = VZErrorInfo(domain: "VZErrorDomain", code: 71, description: "private")
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(
            start: .failure(scriptedError),
            stop: .success(()),
            requestStop: .success(()),
            pause: .success(()),
            resume: .success(())
        )
    )

    do {
        try await driver.start()
        Issue.record("The scripted start should fail.")
    } catch let error {
        #expect(error == scriptedError)
    }
    do {
        try await driver.stop()
        try await driver.requestStop()
        try await driver.pause()
        try await driver.resume()
        await driver.release()
    } catch {
        Issue.record("Unexpected scripted operation failure: \(error)")
    }

    #expect(
        driver.operations == [
            .start,
            .stop,
            .requestStop,
            .pause,
            .resume,
            .release,
        ]
    )
}

@Test func fakeVirtualMachineDriverEmitsEveryDelegateEventInOrder() async {
    let driver = FakeVirtualMachineDriver()
    var iterator = driver.events.makeAsyncIterator()
    let failure = VZErrorInfo(domain: "VZErrorDomain", code: 72, description: "private")
    let events: [VirtualMachineEvent] = [
        .guestDidStop,
        .didStopWithError(failure),
        .networkAttachmentDisconnected(failure),
    ]

    for event in events {
        driver.emit(event)
    }
    driver.finishEvents()

    for expected in events {
        let actual = await iterator.next()
        #expect(actual == expected)
    }
    #expect(await iterator.next() == nil)
}

@Test func fakeVirtualMachineDriverCanHoldStopUntilReleased() async {
    let gate = FakeVirtualMachineDriverGate()
    let completion = DriverOperationCompletionProbe()
    let driver = FakeVirtualMachineDriver(
        script: FakeVirtualMachineDriverScript(stopGate: gate)
    )
    let stopTask = Task {
        do {
            try await driver.stop()
        } catch {
            Issue.record("Unexpected scripted stop failure: \(error)")
        }
        await completion.markCompleted()
    }

    await gate.waitUntilEntered()
    #expect(driver.operations == [.stop])
    #expect(await gate.isOperationPending)
    #expect(await !completion.isCompleted)
    await gate.open()
    await stopTask.value
    #expect(await completion.isCompleted)
}

private actor DriverOperationCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}
