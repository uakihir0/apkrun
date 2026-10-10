import Testing

/// Waits until `condition` holds, polling the render thread's work for up to five seconds.
func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    for _ in 0..<5_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("The condition did not hold within five seconds.", sourceLocation: sourceLocation)
}
