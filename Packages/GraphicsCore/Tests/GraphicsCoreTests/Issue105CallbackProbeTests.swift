import DiagnosticsCore
import DiagnosticsCoreTestSupport
import Dispatch
import Foundation
import GraphicsBridge
import Testing

@testable import GraphicsCore

@Test func issue105ProbeRequiresUnambiguousMatchingFailedSubmit() throws {
    let sink = RecordingLogSink()
    let logger = APKLogger(category: GraphicsLogCategory.renderer, sink: sink)
    let probe = Issue105CallbackProbe(enabled: true, budget: Issue105ProbeBudget())
    let diagnostic = VirGLCommandDiagnostic(ordinal: 42, command: 519, contextID: 17, resourceID: nil)
    let error = "check_copy_transfer3d_handles: context error reported 17 \"sensitive name\" Illegal resource 128\n"
    let dispatch = "context 17 failed to dispatch COPY_TRANSFER3D: 22\n"

    probe.begin(context: 17, diagnostic: diagnostic)
    error.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
    dispatch.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
    probe.finish(status: Int32(GB_E_SUBMIT_OPERATION), result: 22, logger: logger)
    #expect(try #require(sink.entries.last).publicMessage == "issue105_probe context_id=17 control_ordinal=42 resource_id=128")

    probe.begin(context: 17, diagnostic: diagnostic)
    error.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)); probe.record($0, level: Int32(GB_LOG_ERROR)) }
    dispatch.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
    probe.finish(status: Int32(GB_E_SUBMIT_OPERATION), result: 22, logger: logger)
    #expect(try #require(sink.entries.last).publicMessage.hasSuffix("resource_id=unattributed"))

    probe.begin(context: 17, diagnostic: diagnostic)
    error.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
    dispatch.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
    probe.finish(status: Int32(GB_E_SUBMIT_OPERATION), result: 0, logger: logger)
    #expect(try #require(sink.entries.last).publicMessage.hasSuffix("resource_id=unattributed"))
    #expect(sink.entries.allSatisfy { !$0.publicMessage.contains("sensitive name") })
}

@Test func issue105ProbeRejectsSpoofsAndBoundsEvents() throws {
    let sink = RecordingLogSink()
    let logger = APKLogger(category: GraphicsLogCategory.renderer, sink: sink)
    let probe = Issue105CallbackProbe(enabled: true, budget: Issue105ProbeBudget())
    let diagnostic = VirGLCommandDiagnostic(ordinal: 7, command: 519, contextID: 17, resourceID: nil)
    let messages = [
        "check_copy_transfer3d_handles: context error reported 17 \"name\" Illegal resource 513\n",
        "check_copy_transfer3d_handles: context error reported 18 \"name\" Illegal resource 1\n",
        "check_copy_transfer3d_handles: context error reported 17 \"name\" Illegal resource 1\nextra",
        "check_copy_transfer3d_handles: context error reported 17 \"name\" Illegal resource 1\" Illegal resource 2\n",
    ]
    for index in 0..<20 {
        probe.begin(context: 17, diagnostic: diagnostic)
        messages[index % messages.count].withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
        "context 17 failed to dispatch COPY_TRANSFER3D: 22\n".withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
        probe.finish(status: Int32(GB_E_SUBMIT_OPERATION), result: 22, logger: logger)
    }
    #expect(sink.entries.count == 16)
    #expect(sink.entries.allSatisfy { $0.publicMessage.hasSuffix("resource_id=unattributed") })
}

@Test func issue105ProbeRejectsOffThreadAndUnscopedCallbacks() throws {
    let sink = RecordingLogSink()
    let logger = APKLogger(category: GraphicsLogCategory.renderer, sink: sink)
    let probe = Issue105CallbackProbe(enabled: true, budget: Issue105ProbeBudget())
    let diagnostic = VirGLCommandDiagnostic(ordinal: 8, command: 519, contextID: 17, resourceID: nil)
    let error = "check_copy_transfer3d_handles: context error reported 17 \"name\" Illegal resource 1\n"
    let dispatch = "context 17 failed to dispatch COPY_TRANSFER3D: 22\n"
    error.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
    probe.begin(context: 17, diagnostic: diagnostic)
    error.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
    dispatch.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        dispatch.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
        done.signal()
    }
    done.wait()
    probe.finish(status: Int32(GB_E_SUBMIT_OPERATION), result: 22, logger: logger)
    #expect(try #require(sink.entries.last).publicMessage.hasSuffix("resource_id=unattributed"))

    probe.begin(context: 17, diagnostic: diagnostic)
    error.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
    dispatch.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
    probe.finish(status: Int32(GB_OK), result: 0, logger: logger)
    #expect(sink.entries.count == 1)
    let disabled = Issue105CallbackProbe(enabled: false, budget: Issue105ProbeBudget())
    disabled.begin(context: 17, diagnostic: diagnostic)
    error.withCString { disabled.record($0, level: Int32(GB_LOG_ERROR)) }
    dispatch.withCString { disabled.record($0, level: Int32(GB_LOG_ERROR)) }
    disabled.finish(status: Int32(GB_E_SUBMIT_OPERATION), result: 22, logger: logger)
    #expect(sink.entries.count == 1)
}

@Test func issue105ProbeSharesBudgetAndRequiresErrorLevel() throws {
    let sink = RecordingLogSink()
    let logger = APKLogger(category: GraphicsLogCategory.renderer, sink: sink)
    let budget = Issue105ProbeBudget()
    let first = Issue105CallbackProbe(enabled: true, budget: budget)
    let second = Issue105CallbackProbe(enabled: true, budget: budget)
    let diagnostic = VirGLCommandDiagnostic(ordinal: 9, command: 519, contextID: 17, resourceID: nil)
    let error = "check_copy_transfer3d_handles: context error reported 17 \"name\" Illegal resource 512\n"
    let dispatch = "context 17 failed to dispatch COPY_TRANSFER3D: 22\n"
    first.begin(context: 17, diagnostic: diagnostic)
    error.withCString { first.record($0, level: Int32(GB_LOG_INFO)) }
    dispatch.withCString { first.record($0, level: Int32(GB_LOG_ERROR)) }
    first.finish(status: Int32(GB_E_SUBMIT_OPERATION), result: 22, logger: logger)
    #expect(try #require(sink.entries.last).publicMessage.hasSuffix("resource_id=unattributed"))
    for index in 0..<20 {
        let probe = index.isMultiple(of: 2) ? first : second
        probe.begin(context: 17, diagnostic: diagnostic)
        error.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
        dispatch.withCString { probe.record($0, level: Int32(GB_LOG_ERROR)) }
        probe.finish(status: Int32(GB_E_SUBMIT_OPERATION), result: 22, logger: logger)
    }
    #expect(sink.entries.count == 16)
    #expect(sink.entries.dropFirst().allSatisfy { $0.publicMessage.hasSuffix("resource_id=512") })
}
