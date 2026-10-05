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
