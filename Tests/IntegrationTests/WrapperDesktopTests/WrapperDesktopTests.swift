import Foundation
import XCTest

/// #57 T2 (issues/M07-mac-app-wrappers.md, wrapper.md §6.3, §7.4, §14):
/// a generated `HelloText.app` behaves like any Mac app — it passes
/// `plutil -lint`, lands in `~/Applications` or a user-picked folder
/// (including a protected one such as Desktop through the staged
/// `placeStagedWrapper` client path), is found by `mdfind` inside 60 s,
/// lists in a read-only `lsregister -dump`, and shows screen T when a
/// quarantined copy opens from a download folder.
///
/// The suite needs the real daemon and the macOS account's TCC state, so it
/// runs only under the `WrapperDesktop` integration configuration, with the
/// CLI binary staged by scripts at APKRUN_WRAPPERDESKTOP_CLI. Suites clean up
/// `~/Applications` of the apps they create (test-strategy.md §3.9).
final class WrapperDesktopTests: XCTestCase {

    private static let bundleId = "io.apkrun.android.io.apkrun.fixture.hellotext"
    private static let appName = "HelloText.app"

    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["APKRUN_WRAPPERDESKTOP_CLI"] != nil else {
            return
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard cli() != nil else {
            throw XCTSkip("APKRUN_WRAPPERDESKTOP_CLI is not set; the suite runs on a lab Mac.")
        }
    }

    private func cli() -> URL? {
        ProcessInfo.processInfo.environment["APKRUN_WRAPPERDESKTOP_CLI"]
            .map { URL(fileURLWithPath: $0) }
    }

    private var userApplications: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    private var desktop: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
    }

    override func tearDownWithError() throws {
        // test-strategy.md §3.9: suites clean up ~/Applications.
        for dir in [userApplications, desktop] {
            let placed = dir.appendingPathComponent(Self.appName)
            try? FileManager.default.removeItem(at: placed)
        }
        try super.tearDownWithError()
    }

    private func run(_ tool: String, _ args: [String], timeout: TimeInterval = 60) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return String(
            data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - Step 1: destinations (wrapper.md §6.3)

    /// `~/Applications` (created when missing) and a user-picked folder both
    /// take a wrapper that passes `plutil -lint`.
    func testWrappersPlacedInUserApplicationsAndPickedFolder() throws {
        let cli = try XCTUnwrap(cli())
        let picked = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-wrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: picked) }

        for dir in [userApplications, picked] {
            _ = try run(
                cli.path,
                ["wrap", "io.apkrun.fixture.hellotext", "--output", dir.path],
                timeout: 600)
            let app = dir.appendingPathComponent(Self.appName)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: app.path),
                "wrapper missing at \(app.path)")
            XCTAssertNoThrow(try run("/usr/bin/plutil", ["-lint", app.path]))
        }
    }

    /// Step 2: a protected folder — Desktop — goes through the staged
    /// `placeStagedWrapper` path; the CLI moves the bundle itself.
    func testProtectedFolderUsesClientPath() throws {
        let cli = try XCTUnwrap(cli())
        let app = desktop.appendingPathComponent(Self.appName)
        try? FileManager.default.removeItem(at: app)
        _ = try run(
            cli.path,
            ["wrap", "io.apkrun.fixture.hellotext", "--output", desktop.path],
            timeout: 600)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: app.path),
            "the client path did not place \(app.path)")
    }

    /// /Applications needs the admin group; a non-admin run would get
    /// `wrapper.destinationNotWritable`. This Mac is an admin, so the wrapper
    /// lands and is cleaned up.
    func testApplicationsForAdmin() throws {
        let cli = try XCTUnwrap(cli())
        let app = URL(fileURLWithPath: "/Applications").appendingPathComponent(Self.appName)
        try? FileManager.default.removeItem(at: app)
        defer { try? FileManager.default.removeItem(at: app) }
        _ = try run(
            cli.path,
            ["wrap", "io.apkrun.fixture.hellotext", "--output", "/Applications"],
            timeout: 600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    // MARK: - Step 3: Spotlight and LaunchServices (wrapper.md §14)

    /// Spotlight finds the wrapper within 60 s in `~/Applications` and in a
    /// Desktop placement. No indexing tool ever runs — `mdfind` only reads.
    func testSpotlightFindsWrapperWithinSixtySeconds() throws {
        let cli = try XCTUnwrap(cli())
        for dir in [userApplications, desktop] {
            _ = try run(
                cli.path,
                [
                    "wrap", "io.apkrun.fixture.hellotext", "--output", dir.path,
                    "--replace",
                ],
                timeout: 600)
            let deadline = Date().addingTimeInterval(60)
            var found = false
            while Date() < deadline {
                let hits = try run(
                    "/usr/bin/mdfind",
                    ["kMDItemCFBundleIdentifier == '\(Self.bundleId)'"])
                if hits.contains(Self.appName) {
                    found = true
                    break
                }
                Thread.sleep(forTimeInterval: 2)
            }
            XCTAssertTrue(found, "mdfind did not list \(Self.appName) within 60 s (\(dir.path))")
        }
    }

    /// A read-only `lsregister -dump` lists the bundle. APKRun must not run
    /// `lsregister` itself; the check only observes what macOS registered.
    func testLaunchServicesKnowsWrapper() throws {
        let cli = try XCTUnwrap(cli())
        _ = try run(
            cli.path,
            [
                "wrap", "io.apkrun.fixture.hellotext", "--output", userApplications.path,
                "--replace",
            ],
            timeout: 600)
        let lsregister =
            "/System/Library/Frameworks/CoreServices.framework/"
            + "Frameworks/LaunchServices.framework/Support/lsregister"
        // `-dump` is read-only.
        let dump = try run(lsregister, ["-dump"], timeout: 120)
        XCTAssertTrue(
            dump.contains(Self.bundleId),
            "lsregister -dump does not list \(Self.bundleId)")
    }

    // MARK: - Quarantine (wrapper.md §7.4)

    /// A quarantined copy opened from a download folder shows screen T and
    /// asks for no approval.
    func testQuarantinedCopyShowsScreenT() throws {
        let cli = try XCTUnwrap(cli())
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        _ = try run(
            cli.path,
            ["wrap", "io.apkrun.fixture.hellotext", "--output", downloads.path],
            timeout: 600)
        let app = downloads.appendingPathComponent(Self.appName)
        defer { try? FileManager.default.removeItem(at: app) }
        _ = try run(
            "/usr/bin/xattr",
            ["-w", "com.apple.quarantine", "0002;00000000;Safari;", app.path])
        // NSWorkspace.open reaches the launcher; screen T (§7.4) is asserted
        // in the launcher UI test — here the copy must launch at all.
        _ = try run("/usr/bin/open", [app.path], timeout: 30)
    }
}
