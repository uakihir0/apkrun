import Foundation
import Testing

@testable import RuntimeAPI

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

@Test func packageIDEnforcesAndroidGrammarAndUsesStringWireShape() throws {
    let validValues = [
        "com.example.app",
        "io.apkrun.fixture.hellotext",
        "A.b_2",
    ]
    for value in validValues {
        let packageID = try #require(RuntimePackageID(rawValue: value))
        #expect(packageID.rawValue == value)
        #expect(try roundTrip(packageID) == packageID)
        #expect(try JSONEncoder().encode(packageID) == Data("\"\(value)\"".utf8))
    }

    let invalidValues = [
        "",
        "example",
        ".com.example",
        "com..example",
        "com.example.",
        "com.2example",
        "com.example-name",
        "cöm.example",
    ]
    for value in invalidValues {
        #expect(RuntimePackageID(rawValue: value) == nil)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(RuntimePackageID.self, from: Data("\"com.example-name\"".utf8))
    }
}

@Test func importAndPackageDTOsRoundTrip() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellosplit"))
    let ticket = try #require(RuntimeImportTicket(rawValue: UUID().uuidString.lowercased()))
    let baseDigest = try #require(RuntimeSHA256Digest(rawValue: "sha256:\(String(repeating: "a", count: 64))"))
    let splitDigest = try #require(RuntimeSHA256Digest(rawValue: "sha256:\(String(repeating: "b", count: 64))"))
    let preview = RuntimeImportPreview(
        ticket: ticket,
        packageID: packageID,
        displayName: "Hello Split",
        versionCode: 4_294_967_299,
        versionName: "1.2",
        signerDigests: [
            try #require(RuntimeSHA256Digest(rawValue: "sha256:\(String(repeating: "c", count: 64))"))
        ],
        files: [
            RuntimeArtifactFile(name: "base.apk", size: 120, sha256: baseDigest),
            RuntimeArtifactFile(
                name: "split_config.arm64_v8a.apk",
                splitName: "config.arm64_v8a",
                size: 40,
                sha256: splitDigest
            ),
        ],
        excludedSplits: ["config.x86_64"],
        relation: .newPackage,
        warnings: [.debuggable, .lowTargetSDK(target: 27), .signingNotChecked]
    )
    #expect(try roundTrip(preview) == preview)
    var legacyPreviewObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)) as? [String: Any]
    )
    legacyPreviewObject["signerDigests"] = nil
    let legacyPreviewData = try JSONSerialization.data(withJSONObject: legacyPreviewObject)
    let decodedLegacyPreview = try JSONDecoder().decode(
        RuntimeImportPreview.self,
        from: legacyPreviewData
    )
    #expect(decodedLegacyPreview.signerDigests.isEmpty)
    #expect(decodedLegacyPreview.files == preview.files)

    let installed = RuntimePackageSummary(
        packageID: packageID,
        displayName: "Hello Split",
        versionCode: preview.versionCode,
        versionName: preview.versionName
    )
    let details = RuntimePackageDetails(
        summary: installed,
        files: preview.files,
        artifactBytes: 160,
        androidDataBytes: 2_048
    )
    #expect(try roundTrip(details) == details)
    #expect(
        try roundTrip(RuntimeInstallImportedRequest(ticket: ticket)) == RuntimeInstallImportedRequest(ticket: ticket))
    let downgrade = RuntimeInstallOptions(allowDowngrade: true)
    #expect(try roundTrip(downgrade) == downgrade)
    #expect(
        try JSONDecoder().decode(
            RuntimeInstallOptions.self,
            from: Data(#"{"authority":"manual","createWrapper":false}"#.utf8)
        ).allowDowngrade == false
    )
    #expect(
        try roundTrip(
            RuntimeUninstallPackageRequest(
                packageID: packageID,
                options: RuntimeUninstallOptions(keepData: true, trashWrappers: false)
            ))
            == RuntimeUninstallPackageRequest(
                packageID: packageID,
                options: RuntimeUninstallOptions(keepData: true, trashWrappers: false)
            )
    )
}

@Test func sessionDTOsAndWireErrorsRoundTrip() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "com.example.app"))
    let launch = RuntimeLaunchResult(sessionID: UUID(), packageID: packageID, state: .running)
    let terminate = RuntimeTerminateResult(packageID: packageID, hadSession: true)
    #expect(try roundTrip(launch) == launch)
    #expect(try roundTrip(terminate) == terminate)

    let header = APIRequestHeader(
        operationID: UUID(),
        clientKind: .cli
    )
    let launchRequest = RuntimeLaunchControlRequest(header: header, packageID: packageID)
    let terminateRequest = RuntimeTerminateControlRequest(header: header, packageID: packageID)
    let listRequest = RuntimeListPackagesControlRequest(header: header, filter: .all)
    let packageInfoRequest = RuntimePackageInfoControlRequest(header: header, packageID: packageID)
    #expect(try roundTrip(launchRequest) == launchRequest)
    #expect(try roundTrip(terminateRequest) == terminateRequest)
    #expect(try roundTrip(listRequest) == listRequest)
    #expect(try roundTrip(packageInfoRequest) == packageInfoRequest)
    #expect(RuntimeListPackagesControlRequest(header: header).filter == .managed)

    let launchReply = RuntimeLaunchControlReply(result: launch)
    let terminateReply = RuntimeTerminateControlReply(result: terminate)
    let packageSummary = RuntimePackageSummary(packageID: packageID, displayName: "Example", versionCode: 7)
    let packageList = RuntimePackageListResult(packages: [packageSummary], source: .managedRecords)
    let packageDetails = RuntimePackageDetails(summary: packageSummary, files: [], artifactBytes: 0)
    let listReply = RuntimeListPackagesControlReply(result: packageList)
    let packageInfoReply = RuntimePackageInfoControlReply(result: packageDetails)
    #expect(try roundTrip(launchReply) == launchReply)
    #expect(try roundTrip(terminateReply) == terminateReply)
    #expect(try roundTrip(listReply) == listReply)
    #expect(try roundTrip(packageInfoReply) == packageInfoReply)

    let failure = RuntimeWireError.store(
        "packageNotFound",
        message: "Package is not installed.",
        remediation: "Install the package first."
    )
    #expect(failure.code == "store.packageNotFound")
    #expect(try roundTrip(failure) == failure)
    #expect(try roundTrip(RuntimeLaunchControlReply(error: failure)).error == failure)
    #expect(try roundTrip(RuntimeTerminateControlReply(error: failure)).error == failure)
    #expect(try roundTrip(RuntimeListPackagesControlReply(error: failure)).error == failure)
    #expect(try roundTrip(RuntimePackageInfoControlReply(error: failure)).error == failure)
}

@Test func daemonPackageImportAndInstallControlDTOsRoundTrip() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellosplit"))
    let ticket = try #require(RuntimeImportTicket(rawValue: UUID().uuidString.lowercased()))
    let digest = try #require(RuntimeSHA256Digest(rawValue: "sha256:" + String(repeating: "a", count: 64)))
    let header = APIRequestHeader(clientKind: .cli)
    let importBody = RuntimeImportPackageRequest(
        files: [
            RuntimeImportSourceFile(fileIndex: 0, name: "base.apk"),
            RuntimeImportSourceFile(fileIndex: 1, name: "split_config.arm64_v8a.apk"),
        ],
        origin: .cli
    )
    let importRequest = RuntimeImportPackageControlRequest(header: header, request: importBody)
    let preview = RuntimeImportPreview(
        ticket: ticket,
        packageID: packageID,
        displayName: "Hello Split",
        versionCode: 2,
        files: [
            RuntimeArtifactFile(name: "base.apk", size: 12, sha256: digest)
        ],
        relation: .newPackage
    )
    let importReply = RuntimeImportPackageControlReply(result: preview)
    let installBody = RuntimeInstallImportedRequest(ticket: ticket)
    let installRequest = RuntimeInstallImportedControlRequest(header: header, request: installBody)
    let summary = RuntimePackageSummary(packageID: packageID, displayName: "Hello Split", versionCode: 2)
    let installReply = RuntimeInstallImportedControlReply(result: summary)
    let failure = RuntimeWireError.store(
        "invalidAPK",
        message: "The APK set could not be inspected.",
        remediation: "Choose a valid APK file."
    )

    #expect(try roundTrip(importRequest) == importRequest)
    #expect(try roundTrip(importReply) == importReply)
    #expect(try roundTrip(installRequest) == installRequest)
    #expect(try roundTrip(installReply) == installReply)
    #expect(try roundTrip(RuntimeImportPackageControlReply(error: failure)).error == failure)
    #expect(try roundTrip(RuntimeInstallImportedControlReply(error: failure)).error == failure)
    #expect(importRequest.header.apiVersion == APIVersion(major: 1, minor: 18))
}

private struct TestRuntimeService: RuntimeService {
    let packageID: RuntimePackageID

    func importPackage(
        _ request: RuntimeImportPackageRequest,
        files: [FileHandle]
    ) async throws(RuntimeWireError) -> RuntimeImportPreview {
        RuntimeImportPreview(
            ticket: RuntimeImportTicket(rawValue: UUID().uuidString.lowercased())!,
            packageID: packageID,
            displayName: "Test",
            versionCode: 1,
            files: [],
            relation: .newPackage
        )
    }

    func installImported(_ request: RuntimeInstallImportedRequest) async throws(RuntimeWireError)
        -> RuntimePackageSummary
    {
        RuntimePackageSummary(packageID: packageID, displayName: "Test", versionCode: 1)
    }

    func uninstallPackage(_ request: RuntimeUninstallPackageRequest) async throws(RuntimeWireError) {}

    func listPackages(
        _ request: RuntimeListPackagesRequest
    ) async throws(RuntimeWireError) -> RuntimePackageListResult {
        RuntimePackageListResult(
            packages: [RuntimePackageSummary(packageID: packageID, displayName: "Test", versionCode: 1)],
            source: .managedRecords
        )
    }

    func packageInfo(_ request: RuntimePackageRequest) async throws(RuntimeWireError) -> RuntimePackageDetails {
        RuntimePackageDetails(
            summary: RuntimePackageSummary(packageID: packageID, displayName: "Test", versionCode: 1),
            files: [],
            artifactBytes: 0
        )
    }

    func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        RuntimeLaunchResult(sessionID: UUID(), packageID: packageID, state: .running)
    }

    func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        RuntimeTerminateResult(packageID: packageID, hadSession: true)
    }
}

@Test func runtimeServiceProtocolExposesPackageAndSessionOperations() async throws {
    let packageID = try #require(RuntimePackageID(rawValue: "com.example.app"))
    let service: any RuntimeService = TestRuntimeService(packageID: packageID)
    let request = RuntimeImportPackageRequest(
        files: [RuntimeImportSourceFile(fileIndex: 0, name: "app.apk")],
        origin: .cli
    )

    let file = FileHandle.nullDevice
    let preview = try await service.importPackage(request, files: [file])
    #expect(preview.packageID == packageID)
    #expect(try await service.listPackages(RuntimeListPackagesRequest()).packages.count == 1)
    #expect(try await service.packageInfo(RuntimePackageRequest(packageID: packageID)).summary.packageID == packageID)
    #expect(try await service.launch(RuntimeLaunchRequest(packageID: packageID)).state == .running)
}

@Test func runtimeBoundaryRejectsInvalidTicketsAndDigestsAndHandlesUnknownEnums() throws {
    #expect(RuntimeImportTicket(rawValue: "test-ticket") == nil)
    #expect(RuntimeImportTicket(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA") == nil)
    #expect(RuntimeSHA256Digest(rawValue: "sha256:ABC") == nil)
    #expect(RuntimeSHA256Digest(rawValue: "sha256:\(String(repeating: "g", count: 64))") == nil)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(RuntimeSHA256Digest.self, from: Data("\"sha256:base\"".utf8))
    }

    #expect(
        try JSONDecoder().decode(
            RuntimeImportRelation.self,
            from: Data(#"{"futureRelation":{}}"#.utf8)
        ) == .unknown
    )
    #expect(
        try JSONDecoder().decode(
            RuntimePackageState.self,
            from: Data(#"{"futurePackageState":{}}"#.utf8)
        ) == .unknown
    )
    #expect(
        try JSONDecoder().decode(RuntimeSessionPhase.self, from: Data(#""futurePhase""#.utf8)) == .unknown
    )
}
