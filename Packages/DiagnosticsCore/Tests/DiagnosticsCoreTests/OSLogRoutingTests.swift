import Foundation
import Testing

@testable import DiagnosticsCore

@Test func unifiedLogSinkCacheKeepsEachSubsystemAndCategorySeparate() {
    let cache = OSLogSinkCache()

    let lifecycle = cache.sink(subsystem: .vm, category: "lifecycle")
    #expect(lifecycle.subsystem == .vm)
    #expect(lifecycle.category == "lifecycle")

    let config = cache.sink(subsystem: .vm, category: "config")
    #expect(config.subsystem == .vm)
    #expect(config.category == "config")

    let other = cache.sink(subsystem: .diagnostics, category: "health")
    #expect(other.subsystem == .diagnostics)
    #expect(other.category == "health")
}

@Test func liveDiagnosticsContextRoutesEntriesByTheirOwnDestination() {
    let context = DiagnosticsContext.live(
        paths: APKRunPaths(allowingHomeOverride: true, environment: [:])
    )

    #expect(context.logSink is RoutingOSLogSink)
}
