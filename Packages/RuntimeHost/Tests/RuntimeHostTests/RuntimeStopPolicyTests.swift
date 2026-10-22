import Testing

@testable import RuntimeHost

@Test
func runtimeStopRequiresForceForOpenAppSessions() {
    #expect(RuntimeStopPolicy.sessionError(force: false, hasActiveSessions: true) == .busy)
    #expect(RuntimeStopPolicy.sessionError(force: true, hasActiveSessions: true) == nil)
    #expect(RuntimeStopPolicy.sessionError(force: false, hasActiveSessions: false) == nil)
}

@Test
func runtimeStopAlwaysWaitsForPackageMutationsEvenWhenForced() {
    #expect(
        RuntimeStopPolicy.transitionError(
            isStopping: false,
            isResetting: false,
            isRestarting: false,
            activeRuntimeStarts: 0,
            activePackageMutations: 1,
            hasActivePackageLaunches: false
        ) == .invalidTransition
    )
    #expect(
        RuntimeStopPolicy.transitionError(
            isStopping: false,
            isResetting: false,
            isRestarting: false,
            activeRuntimeStarts: 0,
            activePackageMutations: 0,
            hasActivePackageLaunches: true
        ) == .invalidTransition
    )
    #expect(
        RuntimeStopPolicy.transitionError(
            isStopping: false,
            isResetting: false,
            isRestarting: false,
            activeRuntimeStarts: 1,
            activePackageMutations: 0,
            hasActivePackageLaunches: false
        ) == .invalidTransition
    )
}

@Test
func runtimeStopRejectsConflictingLifecycleTransitions() {
    for (stopping, resetting, restarting) in [
        (true, false, false),
        (false, true, false),
        (false, false, true),
    ] {
        #expect(
            RuntimeStopPolicy.transitionError(
                isStopping: stopping,
                isResetting: resetting,
                isRestarting: restarting,
                activeRuntimeStarts: 0,
                activePackageMutations: 0,
                hasActivePackageLaunches: false
            ) == .invalidTransition
        )
    }
    #expect(
        RuntimeStopPolicy.transitionError(
            isStopping: false,
            isResetting: false,
            isRestarting: false,
            activeRuntimeStarts: 0,
            activePackageMutations: 0,
            hasActivePackageLaunches: false
        ) == nil
    )
}
