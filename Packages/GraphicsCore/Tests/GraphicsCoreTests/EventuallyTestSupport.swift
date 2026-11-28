import Testing

/// Waits until `condition` holds, polling the render thread's work for up to ten seconds.
/// The sleep is coarse on purpose: a tight 1 ms loop keeps waking on the cooperative
/// executor and starves the very render thread the condition waits for once the CI
/// runner is loaded.
func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0..<2_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("The condition did not hold within ten seconds.", sourceLocation: sourceLocation)
}
