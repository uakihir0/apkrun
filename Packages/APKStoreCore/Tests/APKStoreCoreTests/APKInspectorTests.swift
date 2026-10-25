import Foundation
import Testing

@testable import APKStoreCore

@Test func apkInspectorParsesLongVersionCodeAndPackageFacts() throws {
    let facts = try APKInspector.parseBadging(
        """
        package: name='org.example.app' versionCode='42' versionCodeMajor='3' versionName='3.42' split=''
        application-label:'Example App'
        minSdkVersion:'23'
        targetSdkVersion:'35'
        native-code: 'arm64-v8a' 'armeabi-v7a'
        """
    )

    #expect(facts.packageID.rawValue == "org.example.app")
    #expect(facts.versionCode == 12_884_901_930)
    #expect(facts.versionName == "3.42")
    #expect(facts.splitName == nil)
    #expect(facts.displayName == "Example App")
    #expect(facts.minSDK == 23)
    #expect(facts.targetSDK == 35)
    #expect(facts.nativeABIs == ["arm64-v8a", "armeabi-v7a"])
}

@Test func apkInspectorParsesSplitAndUsesPackageNameWhenLabelIsMissing() throws {
    let facts = try APKInspector.parseBadging(
        """
        package: name='org.example.app' versionCode='7' versionName='' split='config.xhdpi'
        sdkVersion:'26'
        targetSdkVersion:'34'
        """
    )

    #expect(facts.splitName == "config.xhdpi")
    #expect(facts.displayName == "org.example.app")
    #expect(facts.nativeABIs.isEmpty)
}

@Test func apkInspectorRejectsBadPackageVersionAndSDKValues() {
    #expect(throws: APKInspectionFailure.invalidPackageID) {
        try APKInspector.parseBadging(
            """
            package: name='not-a-package' versionCode='1'
            sdkVersion:'23'
            targetSdkVersion:'35'
            """
        )
    }
    #expect(throws: APKInspectionFailure.invalidVersionCode) {
        try APKInspector.parseBadging(
            """
            package: name='org.example.app' versionCode='not-a-number'
            sdkVersion:'23'
            targetSdkVersion:'35'
            """
        )
    }
    #expect(throws: APKInspectionFailure.invalidSDKValue) {
        try APKInspector.parseBadging(
            """
            package: name='org.example.app' versionCode='1'
            sdkVersion:'unknown'
            targetSdkVersion:'35'
            """
        )
    }
}

@Test func apkInspectorStopsAtTheCombinedOutputLimit() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("APKInspectorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let executable = directory.appendingPathComponent("noisy-aapt2")
    try """
    #!/bin/sh
    i=0
    while [ "$i" -lt 17 ]; do
      printf "%1048576s" x
      i=$((i + 1))
    done
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let apk = directory.appendingPathComponent("base.apk")
    try Data([0]).write(to: apk)
    let inspector = APKInspector(executable: executable, resourcesDirectory: nil, sandboxExecutable: nil)

    await #expect(throws: APKInspectionFailure.aapt2OutputTooLarge) {
        try await inspector.inspect(apk)
    }
}

@Test func apkInspectorClosesTheOutputPipeAfterTheReaderFinishes() async throws {
    let pipe = Pipe()
    let expected = Data(repeating: 0x41, count: 128)
    try pipe.fileHandleForWriting.write(contentsOf: expected)
    try pipe.fileHandleForWriting.close()
    let reader = Task.detached {
        try await Task.sleep(for: .milliseconds(25))
        return try pipe.fileHandleForReading.readToEnd() ?? Data()
    }

    let output = try await APKInspector.finishCapturingOutput(
        reader,
        readingFrom: pipe.fileHandleForReading
    )

    #expect(output == expected)
}
