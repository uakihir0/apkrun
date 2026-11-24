import RuntimeAPI
import Testing

@Test
func menuBarShowsOpenAPKRunWhenRuntimeIsUnreachable() {
    let presentation = MenuBarSnapshot(runtimeStatus: nil)
        .presentation(isConnected: false)

    #expect(presentation.runtimeLine == .unreachable)
    #expect(presentation.primaryAction == .openAPKRun)
    #expect(!presentation.androidIsActive)
    #expect(!presentation.showsAttentionDot)
}

@Test
func menuBarShowsStartWhenAndroidIsStopped() {
    let presentation = MenuBarSnapshot(runtimeStatus: runtimeStatus("stopped"))
        .presentation(isConnected: true)

    #expect(presentation.runtimeLine == .stopped)
    #expect(presentation.primaryAction == .startAndroid)
    #expect(!presentation.androidIsActive)
    #expect(!presentation.showsAttentionDot)
}

@Test
func menuBarShowsActiveBootAndDeveloperMode() {
    let presentation = MenuBarSnapshot(
        runtimeStatus: runtimeStatus("booting(systemServices)"),
        developerModeEnabled: true
    )
    .presentation(isConnected: true)

    #expect(presentation.runtimeLine == .starting)
    #expect(presentation.androidIsActive)
    #expect(presentation.primaryAction == .none)
    #expect(presentation.developerModeEnabled)
}

@Test
func menuBarShowsUpdateAndHealthAttentionDots() {
    let updateAvailable = MenuBarSnapshot(
        runtimeStatus: runtimeStatus("ready"),
        availableUpdates: [
            MenuBarUpdate(packageID: "io.example.app", displayName: "Example", versionName: "2.0")
        ]
    )
    .presentation(isConnected: true)
    let healthNeedsAttention = MenuBarSnapshot(
        runtimeStatus: runtimeStatus("ready"),
        liveHealthNeedsAttention: true
    )
    .presentation(isConnected: true)

    #expect(updateAvailable.showsAttentionDot)
    #expect(!updateAvailable.needsAttention)
    #expect(healthNeedsAttention.showsAttentionDot)
    #expect(healthNeedsAttention.needsAttention)
}

@Test
func menuBarShowsFailedRuntimeAttentionAndStartAction() {
    let presentation = MenuBarSnapshot(runtimeStatus: runtimeStatus("failed"))
        .presentation(isConnected: true)

    #expect(presentation.runtimeLine == .failed)
    #expect(presentation.primaryAction == .startAndroid)
    #expect(!presentation.androidIsActive)
    #expect(presentation.needsAttention)
    #expect(presentation.showsAttentionDot)
}

private func runtimeStatus(
    _ runtimeState: String,
    hostState: String = "running",
    startupFailureCode: String? = nil
) -> RuntimeHostStatus {
    RuntimeHostStatus(
        hostState: hostState,
        runtimeState: runtimeState,
        bootProgress: nil,
        startupFailureStep: nil,
        startupFailureCode: startupFailureCode,
        crashLoopActive: false,
        daemonPID: 1,
        imageVersion: nil
    )
}
