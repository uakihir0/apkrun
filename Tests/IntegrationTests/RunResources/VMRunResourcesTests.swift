import DiagnosticsCore
import Foundation
import Testing

/// T0 checks of the per-run resources of the VM tests (test-strategy §3.10). They create only directories
/// under `/tmp`, and they start no VM.

@Test func adbPortIsKernelChosenWhenTheVariableIsUnsetOrEmpty() throws {
    #expect(try VMRunResources.adbHostPort(environment: [:]) == 0)
    #expect(try VMRunResources.adbHostPort(environment: ["APKRUN_TEST_ADB_PORT": ""]) == 0)
}

@Test func adbPortAcceptsEveryPortNumber() throws {
    #expect(try VMRunResources.adbHostPort(environment: ["APKRUN_TEST_ADB_PORT": "0"]) == 0)
    #expect(try VMRunResources.adbHostPort(environment: ["APKRUN_TEST_ADB_PORT": "6520"]) == 6520)
    #expect(try VMRunResources.adbHostPort(environment: ["APKRUN_TEST_ADB_PORT": "007"]) == 7)
    #expect(try VMRunResources.adbHostPort(environment: ["APKRUN_TEST_ADB_PORT": "65535"]) == 65535)
}

@Test func adbPortRejectsEveryValueThatIsNotAPortNumber() {
    let values = ["65536", "99999", "-1", "+5", " 6520", "6520 ", "6520\n", "abc", "6.5", "0x1934", "٦٥٢٠"]
    for value in values {
        #expect(throws: VMRunResourcesFailure.invalidADBPort(value)) {
            try VMRunResources.adbHostPort(environment: ["APKRUN_TEST_ADB_PORT": value])
        }
    }
}

@Test func newRunRefusesABadPort() {
    #expect(throws: VMRunResourcesFailure.invalidADBPort("nope")) {
        try VMRunResources.new(environment: ["APKRUN_TEST_ADB_PORT": "nope"])
    }
}

@Test func twoRunsGetDifferentHomesInstancesConsolesAndLogs() {
    let first = VMRunResources(runID: UUID(), adbHostPort: 0)
    let second = VMRunResources(runID: UUID(), adbHostPort: 0)
    #expect(first.home != second.home)
    #expect(first.paths.instanceDirectory != second.paths.instanceDirectory)
    #expect(first.paths.instanceLockFile != second.paths.instanceLockFile)
    #expect(first.paths.devConsoleDirectory != second.paths.devConsoleDirectory)
    #expect(first.paths.logsRoot != second.paths.logsRoot)
    #expect(first.consoleSocketPath("hvc0") != second.consoleSocketPath("hvc0"))
    #expect(first.consoleSocketPath("hvc1") != second.consoleSocketPath("hvc1"))
}

@Test func aRunsPathsLieInsideItsOwnHome() {
    let run = VMRunResources(runID: UUID(), adbHostPort: 0)
    let home = run.home.path + "/"
    #expect(run.paths.dataRoot.path == run.home.path)
    #expect(run.paths.instanceDirectory.path.hasPrefix(home))
    #expect(run.paths.devConsoleDirectory.path.hasPrefix(home))
    #expect(run.paths.logsRoot.path.hasPrefix(home))
    #expect(run.paths.cachesRoot.path.hasPrefix(home))
}

@Test func aRunsHomeIsAShortTemporaryDirectoryNamedByItsUUID() {
    let runID = UUID()
    let run = VMRunResources(runID: runID, adbHostPort: 0)
    #expect(run.home.path == "/tmp/apkrun-vm-\(runID.uuidString.lowercased())")
    // Never the shared artifact directory, and never the developer's own home of the Debug build.
    #expect(run.home.path != "/tmp/apkrun-test-linux")
    let developer = APKRunPaths()
    #expect(!run.paths.instanceDirectory.path.hasPrefix(developer.dataRoot.path))
}

@Test func theCaptureOfARunIsAUniqueSiblingOfItsHome() {
    let first = VMRunResources(runID: UUID(), adbHostPort: 0)
    let second = VMRunResources(runID: UUID(), adbHostPort: 0)
    // A sibling, so that removing the home (its teardown) keeps the capture, which is gate evidence.
    #expect(!first.captureDirectory.path.hasPrefix(first.home.path + "/"))
    #expect(first.captureDirectory.path.hasPrefix("/tmp/apkrun-vm-"))
    #expect(first.captureDirectory != second.captureDirectory)
    #expect(first.captureDirectory != first.home)
}

@Test func theSameRunIDGivesTheSameHome() {
    let runID = UUID()
    #expect(
        VMRunResources(runID: runID, adbHostPort: 0).home
            == VMRunResources(runID: runID, adbHostPort: 6520).home
    )
}

@Test func everyConsoleSocketPathFitsTheSocketAddressLimit() {
    #expect(VMRunResources.maximumSocketPathBytes == 103)
    for _ in 0..<20 {
        let run = VMRunResources(runID: UUID(), adbHostPort: 0)
        for name in ["hvc0", "hvc1"] {
            #expect(run.consoleSocketPath(name).utf8.count <= VMRunResources.maximumSocketPathBytes)
        }
    }
}

@Test func newRunsGetFreshPrivateHomesOnDisk() throws {
    let first = try VMRunResources.new(environment: [:])
    let second = try VMRunResources.new(environment: ["APKRUN_TEST_ADB_PORT": "49321"])
    defer {
        try? FileManager.default.removeItem(at: first.home)
        try? FileManager.default.removeItem(at: second.home)
    }
    #expect(first.home != second.home)
    #expect(first.adbHostPort == 0)
    #expect(second.adbHostPort == 49321)
    for run in [first, second] {
        var isDirectory = ObjCBool(false)
        #expect(FileManager.default.fileExists(atPath: run.home.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: run.home.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}
