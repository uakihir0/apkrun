import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceImportsIndexedFileHandlesWithoutStartingAndroid() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let service = EmbeddedPackageService(
        paths: paths,
        inspector: { _ in
            APKFacts(
                packageID: package,
                versionCode: 12,
                versionName: "1.2",
                splitName: nil,
                displayName: "Hello Text",
                minSDK: 23,
                targetSDK: 35,
                nativeABIs: []
            )
        }
    )
    try await service.open()

    let source = root.appendingPathComponent("hello.apk")
    try Data("apk-test-bytes".utf8).write(to: source)
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }

    let preview = try await service.importPackage(
        RuntimeImportPackageRequest(
            files: [RuntimeImportSourceFile(fileIndex: 0, name: "hello.apk")],
            origin: .cli
        ),
        files: [handle]
    )

    #expect(preview.packageID.rawValue == package.rawValue)
    #expect(preview.versionCode == 12)
    #expect(preview.displayName == "Hello Text")
    #expect(preview.relation == .newPackage)
    #expect(preview.files.count == 1)
    #expect(try await service.listPackages(RuntimeListPackagesRequest()) == [])
    let stagingRoot = paths.packagesDirectory.appendingPathComponent(".client-imports", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil).isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceRejectsFileHandlePathTraversal() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let service = EmbeddedPackageService(
        paths: paths,
        inspector: { _ in
            throw APKInspectionFailure.inputNotReadable
        })
    let source = root.appendingPathComponent("source.apk")
    try Data("apk".utf8).write(to: source)
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }

    do {
        _ = try await service.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: "../escape.apk")],
                origin: .cli
            ),
            files: [handle]
        )
        Issue.record("An import filename containing a parent path must be rejected.")
    } catch {
        #expect(error.code == "store.invalidSourceFile")
    }
}

@Test(.timeLimit(.minutes(1)))
func embeddedPackageServiceFailsClosedWhenHostSpaceCannotBeRead() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-package-service-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let package = try #require(PackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let service = EmbeddedPackageService(
        paths: paths,
        inspector: { _ in
            APKFacts(
                packageID: package,
                versionCode: 12,
                versionName: "1.2",
                splitName: nil,
                displayName: "Hello Text",
                minSDK: 23,
                targetSDK: 35,
                nativeABIs: []
            )
        },
        hostFreeSpace: { _ in 0 }
    )
    try await service.open()

    let source = root.appendingPathComponent("hello.apk")
    try Data("apk-test-bytes".utf8).write(to: source)
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }

    do {
        _ = try await service.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: "hello.apk")],
                origin: .cli
            ),
            files: [handle]
        )
        Issue.record("Import staging must stop when available host space is unknown.")
    } catch {
        #expect(error.code == "store.insufficientHostSpace")
    }

    let stagingRoot = paths.packagesDirectory.appendingPathComponent(".client-imports", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil).isEmpty)
}
