import Darwin
import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeHost

@Test
func instanceLockRejectsASecondOpenDescriptionAndReleasesOnClose() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-instance-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    let first = try InstanceLock.acquire(
        paths: paths,
        owner: .apkrunDev,
        processID: 123,
        executablePath: "/test/apkrun"
    )

    #expect(throws: RuntimeFailure.instanceLocked(owner: .apkrunDev)) {
        try InstanceLock.acquire(
            paths: paths,
            owner: .apkrunDev,
            processID: 456,
            executablePath: "/test/apkrun-second"
        )
    }

    first.close()
    #expect(chmod(paths.instanceLockFile.path, mode_t(S_IRUSR | S_IWUSR | S_IRGRP)) == 0)
    let afterRelease = try InstanceLock.acquire(
        paths: paths,
        owner: .apkrunDev,
        processID: 789,
        executablePath: "/test/apkrun-third"
    )
    var metadata = stat()
    #expect(paths.instanceLockFile.path.withCString { stat($0, &metadata) } == 0)
    #expect((metadata.st_mode & mode_t(0o777)) == mode_t(0o600))
    afterRelease.close()
}
