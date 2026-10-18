import Foundation
import Testing

@testable import RuntimeHost

@Test func developmentAPKBadgingParserReadsPackageIdentifier() throws {
    let output = """
        package: name='io.apkrun.fixture.hellotext' versionCode='1' versionName='1.0'
        sdkVersion:'23'
        """

    #expect(
        try DevelopmentAPKResolver.parsePackageIdentifier(from: output)
            == "io.apkrun.fixture.hellotext"
    )
}

@Test func developmentAPKBadgingParserRejectsMissingInvalidAndConflictingIdentifiers() {
    let cases: [(output: String, expectedFailure: DevelopmentAPKFailure)] = [
        ("sdkVersion:'23'\n", .packageIdentifierMissing),
        ("package: versionCode='1'\n", .packageIdentifierMissing),
        ("package: name='bad-name' versionCode='1'\n", .invalidPackageIdentifier),
        (
            """
            package: name='io.example.first' versionCode='1'
            package: name='io.example.second' versionCode='2'
            """,
            .packageIdentifierMissing
        ),
    ]
    for (output, expectedFailure) in cases {
        do {
            _ = try DevelopmentAPKResolver.parsePackageIdentifier(from: output)
            Issue.record("Unexpectedly accepted badging output: \(output)")
        } catch {
            #expect(error == expectedFailure)
        }
    }
}

@Test func developmentAPKPackageNameValidationMatchesBadgingParser() {
    #expect(DevelopmentAPKResolver.isValidPackageIdentifier("io.apkrun.fixture.hellotext"))
    #expect(DevelopmentAPKResolver.isValidPackageIdentifier("com.example.internal_2"))
    #expect(!DevelopmentAPKResolver.isValidPackageIdentifier("example"))
    #expect(!DevelopmentAPKResolver.isValidPackageIdentifier("com.example._internal2"))
    #expect(!DevelopmentAPKResolver.isValidPackageIdentifier("io.example.bad-name"))
    #expect(!DevelopmentAPKResolver.isValidPackageIdentifier("io..example"))
    #expect(!DevelopmentAPKResolver.isValidPackageIdentifier("\(String(repeating: "a", count: 254)).b"))
}

@Test func developmentAPKStagingRejectsFilesAboveItsConfiguredLimit() throws {
    let fixture = try APKResolverFixture()
    let apk = fixture.root.appendingPathComponent("too-large.apk")
    try Data([0x50, 0x4b, 0x03]).write(to: apk)

    do {
        _ = try DevelopmentAPKStaging.create(from: apk, maximumSize: 2)
        Issue.record("The APK exceeded the staging limit but was accepted.")
    } catch {
        #expect(error == .apkTooLarge(limit: 2))
    }
}

@Test(.timeLimit(.minutes(1)))
func developmentAPKResolverPrefersBundledAapt2AndFallsBackToSDKBuildTools() async throws {
    let fixture = try APKResolverFixture()
    let apk = try fixture.makeAPK()
    let resources = fixture.root.appendingPathComponent("resources", isDirectory: true)
    let bundledTool = resources.appendingPathComponent("tools/aapt2")
    let sdkTool = fixture.root.appendingPathComponent("sdk/build-tools/36.0.0/aapt2")
    try fixture.makeTool(
        at: bundledTool,
        script: "printf \"package: name='io.example.bundled' versionCode='1'\\\\n\""
    )
    try fixture.makeTool(
        at: sdkTool,
        script: "printf \"package: name='io.example.sdk' versionCode='1'\\\\n\""
    )

    let bundledResult = try await DevelopmentAPKResolver.resolve(
        in: apk,
        environment: ["ANDROID_HOME": fixture.root.appendingPathComponent("sdk").path],
        resourcesDirectory: resources,
        sandboxExecutable: nil
    )
    #expect(bundledResult.packageIdentifier == "io.example.bundled")
    #expect(!bundledResult.wasSandboxed)

    try FileManager.default.removeItem(at: bundledTool)
    let sdkResult = try await DevelopmentAPKResolver.resolve(
        in: apk,
        environment: ["ANDROID_HOME": fixture.root.appendingPathComponent("sdk").path],
        resourcesDirectory: resources,
        sandboxExecutable: nil
    )
    #expect(sdkResult.packageIdentifier == "io.example.sdk")
    #expect(!sdkResult.wasSandboxed)
}

@Test(.timeLimit(.minutes(1)))
func developmentAPKSandboxDeniesToolWrites() async throws {
    let fixture = try APKResolverFixture()
    let stage = fixture.root.appendingPathComponent("ticket", isDirectory: true)
    let tool = URL(fileURLWithPath: "/usr/bin/touch").resolvingSymlinksInPath()
    let stagedAPK = stage.appendingPathComponent("input.apk")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    try Data([0x50, 0x4b, 0x03, 0x04]).write(to: stagedAPK)
    let writeTarget = stage.appendingPathComponent("write-should-be-denied")
    let sandboxExecutable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    guard FileManager.default.isExecutableFile(atPath: sandboxExecutable.path) else {
        return
    }
    let profile = try DevelopmentAPKSandbox.profile(
        tool: tool,
        stagedAPK: stagedAPK.resolvingSymlinksInPath(),
        stagingDirectory: stage.resolvingSymlinksInPath()
    )

    let result = try await DevelopmentAPKProcess.run(
        executable: sandboxExecutable,
        arguments: ["-p", profile, tool.path, writeTarget.resolvingSymlinksInPath().path],
        environment: ["LANG": "C", "LC_ALL": "C"],
        timeout: .seconds(2),
        maximumOutputBytes: 1_024
    )

    #expect(result.status == 1)
    #expect(result.standardOutput.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: writeTarget.path))
}

@Test(.timeLimit(.minutes(1)))
func developmentAPKSandboxReadsOnlyTheStagedAPK() async throws {
    let fixture = try APKResolverFixture()
    let stage = fixture.root.appendingPathComponent("ticket", isDirectory: true)
    let stagedAPK = stage.appendingPathComponent("input.apk")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    try Data("staged-apk".utf8).write(to: stagedAPK)
    let tool = URL(fileURLWithPath: "/bin/cat").resolvingSymlinksInPath()
    let sandboxExecutable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    guard FileManager.default.isExecutableFile(atPath: sandboxExecutable.path) else {
        return
    }
    let profile = try DevelopmentAPKSandbox.profile(
        tool: tool,
        stagedAPK: stagedAPK.resolvingSymlinksInPath(),
        stagingDirectory: stage.resolvingSymlinksInPath()
    )

    let result = try await DevelopmentAPKProcess.run(
        executable: sandboxExecutable,
        arguments: ["-p", profile, tool.path, stagedAPK.resolvingSymlinksInPath().path],
        environment: ["LANG": "C", "LC_ALL": "C"],
        timeout: .seconds(2),
        maximumOutputBytes: 1_024
    )

    #expect(result.status == 0)
    #expect(String(decoding: result.standardOutput, as: UTF8.self) == "staged-apk")
}

@Test func developmentAPKSandboxDeniesProcessFork() throws {
    let stage = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-026-apk-resolver-\(UUID().uuidString)", isDirectory: true)
    let stagedAPK = stage.appendingPathComponent("input.apk")
    let tool = URL(fileURLWithPath: "/bin/cat").resolvingSymlinksInPath()
    let profile = try DevelopmentAPKSandbox.profile(
        tool: tool,
        stagedAPK: stagedAPK.resolvingSymlinksInPath(),
        stagingDirectory: stage.resolvingSymlinksInPath()
    )

    #expect(profile.contains("(deny process-fork)"))
    #expect(!profile.contains("(allow process-fork)"))
}

@Test(.timeLimit(.minutes(1)))
func developmentAPKProcessRunnerBoundsRuntimeAndOutput() async {
    let fixture = try? APKResolverFixture()
    guard let fixture else {
        Issue.record("Could not create the process fixture.")
        return
    }
    let timeoutTool = fixture.root.appendingPathComponent("sleep")
    let outputTool = fixture.root.appendingPathComponent("output")
    do {
        try fixture.makeTool(at: timeoutTool, script: "exec /bin/sleep 5")
        try fixture.makeTool(at: outputTool, script: "exec /usr/bin/yes package")
    } catch {
        Issue.record("Could not create fake aapt2 tools: \(error)")
        return
    }

    do {
        _ = try await DevelopmentAPKProcess.run(
            executable: timeoutTool,
            arguments: [],
            environment: [:],
            timeout: .milliseconds(100),
            maximumOutputBytes: 1_024
        )
        Issue.record("The fake aapt2 process exceeded its timeout but succeeded.")
    } catch {
        #expect(error == .aapt2TimedOut)
    }

    do {
        _ = try await DevelopmentAPKProcess.run(
            executable: outputTool,
            arguments: [],
            environment: [:],
            timeout: .seconds(2),
            maximumOutputBytes: 1_024
        )
        Issue.record("The fake aapt2 process exceeded its output cap but succeeded.")
    } catch {
        #expect(error == .aapt2OutputTooLarge)
    }
}

private final class APKResolverFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-026-apk-resolver-\(UUID().uuidString)", isDirectory: true)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeAPK() throws -> URL {
        let apk = root.appendingPathComponent("hello.apk")
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: apk)
        return apk
    }

    func makeTool(at url: URL, script: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
