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

// MARK: - Removing a home

/// A fresh root under `/tmp` for one removal test. The test removes it again.
private func removalTestRoot() -> URL {
    URL(fileURLWithPath: "/tmp/apkrun-removehome-\(UUID().uuidString.lowercased())", isDirectory: true)
}

private func posixMode(_ path: String) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
}

private func setPosixMode(_ mode: Int, _ path: String) throws {
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
}

/// A home shaped like an installed run: an image of read-only directories and files, a symbolic link to a sibling
/// inside it, and a symbolic link to a directory outside it. The outside directory holds a read-only file.
private func makeReadOnlyHome(root: URL) throws -> (home: URL, outside: URL) {
    let manager = FileManager.default
    let home = root.appendingPathComponent("home", isDirectory: true)
    let images = home.appendingPathComponent("Images", isDirectory: true)
    let image = images.appendingPathComponent("2026.10.0/boot", isDirectory: true)
    let runtime = home.appendingPathComponent("Runtime", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try manager.createDirectory(at: image, withIntermediateDirectories: true)
    try manager.createDirectory(at: runtime, withIntermediateDirectories: true)
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("kernel".utf8).write(to: image.appendingPathComponent("kernel"))
    try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
    try manager.createSymbolicLink(atPath: images.appendingPathComponent("current").path, withDestinationPath: "2026.10.0")
    try manager.createSymbolicLink(atPath: runtime.appendingPathComponent("escape").path, withDestinationPath: outside.path)
    // Files are read-only and directories are r-x, as in an installed image. Symbolic links are not changed.
    try setPosixMode(0o444, image.appendingPathComponent("kernel").path)
    try setPosixMode(0o444, outside.appendingPathComponent("keep.txt").path)
    for directory in [outside, image, image.deletingLastPathComponent(), images, runtime, home] {
        try setPosixMode(0o555, directory.path)
    }
    return (home, outside)
}

@Test func removesAReadOnlyHomeAndLeavesSymbolicLinkTargetsAlone() throws {
    let root = removalTestRoot()
    defer { try? VMRunResources.removeHome(root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let (home, outside) = try makeReadOnlyHome(root: root)
    let kernel = home.appendingPathComponent("Images/2026.10.0/boot/kernel").path
    // Precondition: the tree is read-only, so a plain removeItem would fail on it.
    #expect(!FileManager.default.isWritableFile(atPath: kernel))

    try VMRunResources.removeHome(home)

    #expect(!FileManager.default.fileExists(atPath: home.path))
    // The symbolic link Runtime/escape pointed outside the home. Nothing outside may change.
    let keep = outside.appendingPathComponent("keep.txt").path
    #expect(try posixMode(keep) == 0o444)
    #expect(try posixMode(outside.path) == 0o555)
    #expect(FileManager.default.fileExists(atPath: keep))
}

@Test func aHomeThatCannotBeRemovedThrowsItsPathAndTheError() throws {
    let root = removalTestRoot()
    let parent = root.appendingPathComponent("parent", isDirectory: true)
    let home = parent.appendingPathComponent("home", isDirectory: true)
    defer {
        try? setPosixMode(0o755, parent.path)
        try? VMRunResources.removeHome(root)
    }
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Images", isDirectory: true), withIntermediateDirectories: true)
    // Removing the home needs write access to its parent, which this makes impossible.
    try setPosixMode(0o555, parent.path)

    do {
        try VMRunResources.removeHome(home)
        Issue.record("the home was removed although its parent is read-only")
    } catch {
        guard case .homeNotRemoved(let path, let text) = error else {
            Issue.record("unexpected error: \(error)")
            return
        }
        #expect(path == home.path)
        #expect(!text.isEmpty)
    }
    #expect(FileManager.default.fileExists(atPath: home.path))
}

@Test func removingAHomeThatIsGoneIsNotAnError() throws {
    let missing = removalTestRoot().appendingPathComponent("home", isDirectory: true)
    try VMRunResources.removeHome(missing)
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}
