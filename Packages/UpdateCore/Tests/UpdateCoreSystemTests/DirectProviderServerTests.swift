import APKStoreCore
import Foundation
import RuntimeAPI
import Testing

@testable import UpdateCore

// T1 of #51: DirectProvider over real loopback HTTP against
// scripts/dev/update-server.py (direct-provider-manifest.md §5.1, §5.3).

/// One `update-server.py` serving a per-test fixture root on a random
/// loopback port.
final class UpdateServer: @unchecked Sendable {
    let baseURL: URL
    let root: URL
    private let process: Process

    private init(baseURL: URL, root: URL, process: Process) {
        self.baseURL = baseURL
        self.root = root
        self.process = process
    }

    static func start() throws -> UpdateServer {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-update-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("local"), withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repoRoot.appendingPathComponent("scripts/dev/update-server.py")
        #expect(FileManager.default.fileExists(atPath: script.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", script.path, "--root", root.path, "--port", "0",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        nonisolated(unsafe) var buffer = Data()
        let semaphore = DispatchSemaphore(value: 0)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
            if buffer.contains(0x0A) { semaphore.signal() }
        }
        try process.run()
        guard semaphore.wait(timeout: .now() + 10) == .success,
            let line = String(data: buffer, encoding: .utf8)?
                .split(separator: "\n").first,
            let base = line.split(separator: " ").dropFirst().first,
            let baseURL = URL(string: String(base))
        else {
            process.terminate()
            Issue.record("update-server.py did not print its base URL")
            throw UpdateFailure.providerUnreachable(reason: "no base URL line")
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        return UpdateServer(baseURL: baseURL, root: root, process: process)
    }

    deinit {
        process.terminate()
    }

    /// Writes `data` as `local/<package>/<version>/<file>` — the manifest is
    /// synthesized by the server with the real hash and size.
    func addArtifact(package: String, version: Int, file: String, data: Data) throws {
        let directory = root.appendingPathComponent("local/\(package)/\(version)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(file))
    }

    func manifestURL(package: String, version: Int) -> String {
        "\(baseURL.absoluteString)/local/\(package)/\(version)/manifest.json"
    }
}

private func makePackage(
    _ id: String = "com.example.app",
    versionCode: VersionCode = 1,
    cursor: ProviderCursor? = nil
) throws -> InstalledPackage {
    InstalledPackage(
        id: try #require(PackageID(rawValue: id)),
        versionCode: versionCode,
        signerDigests: [],
        lineage: [],
        guest: GuestFacts(sdk: 37),
        lastCursor: cursor)
}

private struct DirectMemoryCache: ProviderCache {
    let root: URL
    func directory(forKey key: String) throws -> URL {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct DirectNoCredentials: ProviderCredentials {
    func token(for _: String) -> String? { nil }
    func setToken(_: String?, for _: String) throws {}
}

private func context(root: URL, userInitiated: Bool = false) -> ProviderContext {
    ProviderContext(
        http: URLSessionUpdateHTTPClient(),
        cache: DirectMemoryCache(root: root),
        credentials: DirectNoCredentials(),
        userInitiated: userInitiated)
}

private func makeProvider(_ url: String) throws -> DirectProvider {
    try DirectProvider(
        ref: UpdateProviderRef(type: .direct, configuration: .direct(url: url)))
}

@Test func directCheckReturnsCandidateOverLoopback() async throws {
    let server = try UpdateServer.start()
    try server.addArtifact(
        package: "com.example.app",
        version: 2,
        file: "base.apk",
        data: Data("fake apk bytes".utf8))
    let checked = try await makeProvider(
        server.manifestURL(package: "com.example.app", version: 2)
    )
    .check(try makePackage(), context: context(root: server.root))
    let candidate = try #require(checked)
    #expect(candidate.declaredVersionCode == 2)
    #expect(candidate.artifacts.count == 1)
    #expect(candidate.cursor.type == ProviderType.direct)
}

@Test func directCheckSendsIfNoneMatchAndHonors304() async throws {
    let server = try UpdateServer.start()
    try server.addArtifact(
        package: "com.example.app", version: 2, file: "base.apk", data: Data([1, 2, 3]))
    let url = server.manifestURL(package: "com.example.app", version: 2)
    let provider = try makeProvider(url)
    let context = context(root: server.root)
    let cursor =
        try #require(
            try await provider.check(try makePackage(), context: context)
        ).cursor
    let again = try await provider.check(
        try makePackage(cursor: cursor), context: context)
    #expect(again == nil)
}

@Test func directCheckMaps429ToRateLimited() async throws {
    let server = try UpdateServer.start()
    let provider = try makeProvider("\(server.baseURL.absoluteString)/status/429")
    do {
        _ = try await provider.check(
            try makePackage(), context: context(root: server.root))
        Issue.record("expected providerRateLimited")
    } catch let error as UpdateFailure {
        guard case .providerRateLimited = error else {
            Issue.record("expected providerRateLimited, got \(error)")
            return
        }
    }
}

@Test func directDownloadReportsHashMismatchAfterRetry() async throws {
    let server = try UpdateServer.start()
    let bytes = Data("payload".utf8)
    try server.addArtifact(
        package: "com.example.app", version: 2, file: "base.apk", data: bytes)
    // A manifest with a deliberately wrong sha256 under direct/.
    let manifest = """
        {"schemaVersion":1,"packageId":"com.example.app","versionCode":2,\
        "versionName":"2.0","artifacts":[{"type":"apk","url":\
        "\(server.baseURL.absoluteString)/local/com.example.app/2/base.apk",\
        "size":\(bytes.count),\
        "sha256":"0000000000000000000000000000000000000000000000000000000000000000"}]}
        """
    let directory = server.root.appendingPathComponent("direct")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try manifest.write(
        to: directory.appendingPathComponent("bad.json"),
        atomically: true, encoding: .utf8)
    let provider = try makeProvider("\(server.baseURL.absoluteString)/direct/bad.json")
    let candidate = try #require(
        try await provider.check(
            try makePackage(), context: context(root: server.root)))
    let destination = DownloadDestination(
        ticket: UUID(), directory: server.root.appendingPathComponent("download"))
    do {
        _ = try await provider.download(
            candidate, to: destination,
            context: context(root: server.root), progress: { _ in })
        Issue.record("expected hashMismatch")
    } catch let error as UpdateFailure {
        guard case .hashMismatch = error else {
            Issue.record("expected hashMismatch, got \(error)")
            return
        }
    }
}

/// The downloaded file lands under its URL's last path component — the
/// same name the coordinator's hash check looks up — and the transport
/// reports the file's real sha256.
@Test func directDownloadStoresFileUnderURLName() async throws {
    let server = try UpdateServer.start()
    let bytes = Data("real apk payload".utf8)
    let sha = SHA256Digest(data: bytes).hexValue
    let directory = server.root.appendingPathComponent("direct")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try bytes.write(to: directory.appendingPathComponent("release-2.apk"))
    let manifest = """
        {"schemaVersion":1,"packageId":"com.example.app","versionCode":2,\
        "versionName":"2.0","artifacts":[{"type":"apk","url":\
        "\(server.baseURL.absoluteString)/direct/release-2.apk",\
        "size":\(bytes.count),\
        "sha256":"\(sha)"}]}
        """
    try manifest.write(
        to: directory.appendingPathComponent("good.json"),
        atomically: true, encoding: .utf8)
    let url = "\(server.baseURL.absoluteString)/direct/good.json"
    let provider = try makeProvider(url)
    let candidate = try #require(
        try await provider.check(
            try makePackage(), context: context(root: server.root)))
    let destination = DownloadDestination(
        ticket: UUID(), directory: server.root.appendingPathComponent("download2"))
    let artifact = try await provider.download(
        candidate, to: destination, context: context(root: server.root), progress: { _ in })
    guard case .apk(let file) = artifact else {
        Issue.record("expected .apk, got \(artifact)")
        return
    }
    #expect(file.lastPathComponent == "release-2.apk")
    #expect(try Data(contentsOf: file) == bytes)
}

/// §5.1: artifact URLs resolve against the final manifest URL after
/// redirects, not the configured URL.
@Test func directCheckFollowsRedirectAndResolvesRelative() async throws {
    let server = try UpdateServer.start()
    try server.addArtifact(
        package: "com.example.app", version: 2, file: "base.apk", data: Data([9]))
    let manifest = """
        {"schemaVersion":1,"packageId":"com.example.app","versionCode":2,\
        "versionName":"2.0","artifacts":[{"type":"apk","url":\
        "../local/com.example.app/2/base.apk","size":1,\
        "sha256":"4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865"}]}
        """
    let directory = server.root.appendingPathComponent("direct")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try manifest.write(
        to: directory.appendingPathComponent("rel.json"),
        atomically: true, encoding: .utf8)
    let provider = try makeProvider(
        "\(server.baseURL.absoluteString)/redirect/302/direct/rel.json")
    let candidate = try #require(
        try await provider.check(
            try makePackage(), context: context(root: server.root)))
    #expect(
        candidate.artifacts.first?.url.absoluteString
            == "\(server.baseURL.absoluteString)/local/com.example.app/2/base.apk")
}

/// D1: a manifest body over 1 MiB is refused as metadata, not decoded.
@Test func directCheckRefusesOversizedBody() async throws {
    let server = try UpdateServer.start()
    let padding = String(repeating: "x", count: 1_100_000)
    let manifest = """
        {"schemaVersion":1,"packageId":"com.example.app","versionCode":2,\
        "versionName":"2.0","releaseNotes":"\(padding)","artifacts":[]}
        """
    let directory = server.root.appendingPathComponent("direct")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try manifest.write(
        to: directory.appendingPathComponent("big.json"),
        atomically: true, encoding: .utf8)
    let provider = try makeProvider("\(server.baseURL.absoluteString)/direct/big.json")
    do {
        _ = try await provider.check(
            try makePackage(), context: context(root: server.root))
        Issue.record("expected providerMetadataInvalid")
    } catch let error as UpdateFailure {
        guard case .providerMetadataInvalid = error else {
            Issue.record("expected providerMetadataInvalid, got \(error)")
            return
        }
    }
}
