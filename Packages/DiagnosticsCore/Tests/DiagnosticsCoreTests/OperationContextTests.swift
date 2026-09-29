import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Foundation
import Testing

@Test func operationIDUsesCanonicalLowercaseUUIDV4AndWireHelpers() throws {
    let id = OperationID()

    #expect(id.rawValue == id.rawValue.lowercased())
    #expect(id.rawValue.count == 36)
    #expect(id.short.count == 8)
    #expect(id.rawValue.split(separator: "-")[2].first == "4")
    #expect(OperationID(wire: id.wireValue) == id)
    #expect(OperationID(wire: id.rawValue.uppercased()) == nil)
    #expect(OperationID(wire: "00000000-0000-1000-8000-000000000000") == nil)
    #expect(OperationID(wire: "00000000-0000-4000-7000-000000000000") == nil)
    #expect(OperationID(wire: "not-an-operation-id") == nil)

    let encoded = try JSONEncoder().encode(id)
    #expect(try JSONDecoder().decode(OperationID.self, from: encoded) == id)
}

@Test func operationContextPropagatesToChildTasks() async throws {
    try await OperationContext.withNew {
        let parent = try #require(OperationContext.current)
        let inherited = await Task {
            OperationContext.current
        }.value

        #expect(inherited == parent)
        #expect(OperationContext.currentWireID == parent.operationID.wireValue)
    }

    #expect(OperationContext.current == nil)
}

@Test func childOperationGetsANewIDAndRecordsItsParent() async throws {
    try await OperationContext.withNew {
        let parent = try #require(OperationContext.current?.operationID)
        try await OperationContext.withChild {
            let child = try #require(OperationContext.current)
            await Task.yield()
            #expect(child.operationID != parent)
            #expect(child.parent == parent)
        }
    }

    #expect(OperationContext.current == nil)
}

@Test func synchronousOperationScopesRestoreTheirPreviousContext() throws {
    try OperationContext.withNew {
        let parent = try #require(OperationContext.current?.operationID)

        try OperationContext.withChild {
            let child = try #require(OperationContext.current)
            #expect(child.parent == parent)
            #expect(child.operationID != parent)
        }

        #expect(OperationContext.current?.operationID == parent)
    }

    #expect(OperationContext.current == nil)
}

@Test func loggerAutomaticallyAddsTheCurrentTaskOperationID() async throws {
    let sink = RecordingLogSink()
    let logger = APKLogger(category: CLILogCategory.command, sink: sink)

    try await OperationContext.withNew {
        let operationID = try #require(OperationContext.current?.operationID)
        await Task.yield()
        logger.notice("command started")

        let entry = try #require(sink.entries.first)
        #expect(entry.operationID == operationID.wireValue)
        #expect(entry.formattedPublicMessage.contains("op=\(operationID.short)"))
    }
}
