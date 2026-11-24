import Foundation
import Testing

@testable import RuntimeHost

/// runtime-maintenance.md §3.6: BundleWatcher re-reads `Contents/Info.plist`
/// by path and reports `restartPending` when the on-disk build differs.
private final class ReportedBuild: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int??
    var value: Int?? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
    func set(_ newValue: Int?) {
        lock.lock()
        _value = .some(newValue)
        lock.unlock()
    }
}

@Suite struct BundleWatcherTests {
    private func makeBundle(build: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundlewatcher-\(UUID().uuidString)")
        let contents = root.appendingPathComponent("APKRun.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": "\(build)"],
            format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        return root.appendingPathComponent("APKRun.app")
    }

    private func rewriteBundle(_ bundle: URL, build: Int) throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": "\(build)"],
            format: .xml, options: 0)
        try plist.write(
            to: bundle.appendingPathComponent("Contents/Info.plist"),
            options: .atomic)
    }

    @Test func checkReportsChangedBuild() throws {
        let bundle = try makeBundle(build: 9000)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let reported = ReportedBuild()
        let watcher = BundleWatcher(bundleURL: bundle, ownBuild: 9000) { reported.set($0) }
        watcher.check()
        #expect(reported.value == nil)
        try rewriteBundle(bundle, build: 9001)
        watcher.check()
        #expect(reported.value != nil)
        #expect(reported.value! == 9001)
    }

    @Test func missingPlistReportsNil() throws {
        let bundle = try makeBundle(build: 9000)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let reported = ReportedBuild()
        let watcher = BundleWatcher(bundleURL: bundle, ownBuild: 9000) { reported.set($0) }
        try FileManager.default.removeItem(
            at: bundle.appendingPathComponent("Contents/Info.plist"))
        watcher.check()
        #expect(reported.value != nil)
        #expect(reported.value! == nil)
    }

    @Test func replacedBundleIsReadByPath() throws {
        // Sparkle swaps the bundle by rename: a new directory appears at the
        // same path. The watcher must follow the path, not the old directory.
        let bundle = try makeBundle(build: 9000)
        let parent = bundle.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let reported = ReportedBuild()
        let watcher = BundleWatcher(bundleURL: bundle, ownBuild: 9000) { reported.set($0) }

        let replacement = try makeBundle(build: 9001)
        defer { try? FileManager.default.removeItem(at: replacement.deletingLastPathComponent()) }
        try FileManager.default.moveItem(
            at: bundle, to: parent.appendingPathComponent("APKRun.old.app"))
        try FileManager.default.moveItem(at: replacement, to: bundle)

        watcher.check()
        #expect(reported.value != nil)
        #expect(reported.value! == 9001)
    }
}
