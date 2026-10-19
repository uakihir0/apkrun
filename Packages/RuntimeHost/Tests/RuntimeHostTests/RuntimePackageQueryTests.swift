import APKStoreCore
import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func daemonPackageQueryUsesCachedInventoryWithoutStartingAndroid() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-daemon-package-query-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(PackageID(rawValue: "com.example.cached"))
    let store = PackageStore(packagesDirectory: paths.packagesDirectory)
    try await store.open()
    _ = try await store.saveLastKnownAndroidInventory([
        StorePackageSummary(
            packageID: packageID,
            displayName: "Cached app",
            versionCode: 7,
            launchable: true,
            userInstalled: true
        )
    ])

    let host = RuntimeHost(paths: paths, environment: [:])
    let result = try await host.listPackages(RuntimeListPackagesRequest(filter: .all))

    #expect(result.source == .cachedAndroid)
    #expect(result.packages.count == 1)
    #expect(result.packages[0].packageID.rawValue == packageID.rawValue)
    #expect(result.packages[0].displayName == "Cached app")
    #expect(result.packages[0].versionCode == 7)
    #expect(!result.packages[0].managed)
    #expect((await host.status()).runtimeState == "stopped")
}

@Test(.timeLimit(.minutes(1)))
func daemonPackageInfoReturnsTypedNotFoundWithoutStartingAndroid() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-daemon-package-info-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let host = RuntimeHost(paths: paths, environment: [:])
    do {
        _ = try await host.packageInfo(
            RuntimePackageRequest(packageID: try #require(RuntimePackageID(rawValue: "com.example.unknown")))
        )
        Issue.record("An unknown package must return the store's typed not-found error.")
    } catch {
        let wireError = try #require(error as? RuntimeWireError)
        #expect(wireError.code == "store.packageNotFound")
    }
    #expect((await host.status()).runtimeState == "stopped")
}

@Test(.timeLimit(.minutes(1)))
func daemonPackageInfoReturnsCachedUnmanagedPackageWithoutStartingAndroid() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-daemon-package-info-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let paths = APKRunPaths(allowingHomeOverride: true, environment: ["APKRUN_HOME": root.path])
    let packageID = try #require(RuntimePackageID(rawValue: "com.example.external"))
    let store = PackageStore(packagesDirectory: paths.packagesDirectory)
    try await store.open()
    _ = try await store.saveLastKnownAndroidInventory([
        StorePackageSummary(
            packageID: try #require(PackageID(rawValue: packageID.rawValue)),
            displayName: "External app",
            versionCode: 8,
            launchable: true,
            userInstalled: true
        )
    ])

    let host = RuntimeHost(paths: paths, environment: [:])
    let details = try await host.packageInfo(RuntimePackageRequest(packageID: packageID))

    #expect(details.summary.packageID == packageID)
    #expect(details.summary.displayName == "External app")
    #expect(details.summary.versionCode == 8)
    #expect(!details.summary.managed)
    #expect(details.summary.updateAuthority == .external)
    #expect(details.files.isEmpty)
    #expect(details.artifactBytes == 0)
    #expect((await host.status()).runtimeState == "stopped")
}
