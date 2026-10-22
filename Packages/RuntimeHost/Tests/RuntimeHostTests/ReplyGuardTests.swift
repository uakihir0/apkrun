import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test func replyGuardAnswersAnUnrepliedRequestWithRuntimeInternal() throws {
    let probe = ReplyGuardProbe()
    var replyGuard: ReplyGuard? = ReplyGuard { data in
        probe.recordReply(data)
    }

    #expect(replyGuard != nil)
    #expect(probe.replies.isEmpty)
    replyGuard = nil

    let replies = probe.replies
    #expect(replies.count == 1)
    let data = try #require(replies.first)
    let typedReply = try JSONDecoder().decode(RuntimeInfoControlReply.self, from: data)
    let controlReply = try JSONDecoder().decode(RuntimeControlReply.self, from: data)
    #expect(typedReply.error?.domain == "runtime")
    #expect(typedReply.error?.code == "runtime.internal")
    #expect(controlReply.error?.code == "runtime.internal")
}

@Test func replyGuardOnlySendsOneReplyAndFlagsDuplicatesInDebug() {
    let probe = ReplyGuardProbe()
    let replyGuard = ReplyGuard(
        { data in probe.recordReply(data) },
        onDuplicateReply: { probe.recordDuplicate() }
    )

    replyGuard.send(Data([1]))
    replyGuard.send(Data([2]))

    #expect(probe.replies == [Data([1])])
    #if DEBUG
        #expect(probe.duplicateCount == 1)
    #else
        #expect(probe.duplicateCount == 0)
    #endif
}

private final class ReplyGuardProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedReplies: [Data] = []
    private var recordedDuplicates = 0

    var replies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return recordedReplies
    }

    var duplicateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedDuplicates
    }

    func recordReply(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        recordedReplies.append(data)
    }

    func recordDuplicate() {
        lock.lock()
        defer { lock.unlock() }
        recordedDuplicates += 1
    }
}
