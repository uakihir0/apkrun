import Foundation

/// Detects that `APKRun.app` was replaced while apkrund is running
/// (runtime-maintenance.md §3.6). Sparkle installs by renaming the bundle, so
/// the watched `Contents/Info.plist` is re-read by path: cached `Bundle`
/// values would keep reporting the old build.
///
/// Triggers: a broker `hello` (`check()`), a periodic poll, and vnode events
/// (rename, delete) on the bundle directory. A build different from the
/// process's own build reports `restartPending(build)`; a missing plist
/// reports `restartPending(nil)`.
final class BundleWatcher: @unchecked Sendable {
    /// The bundle directory to watch, or `nil` when the watcher only polls.
    let bundleURL: URL?
    private let infoPlistURL: URL
    private let ownBuild: Int
    private let onChange: @Sendable (Int?) -> Void

    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "io.apkrun.bundle-watcher")
    private let pollInterval: TimeInterval

    /// - Parameters:
    ///   - bundleURL: the app bundle (`APKRun.app`) containing apkrund. Pass
    ///     `nil` for tests that only exercise `check()`.
    ///   - ownBuild: `CFBundleVersion` of the running process.
    ///   - pollInterval: seconds between re-reads; §3.6 says 60.
    ///   - onChange: called with the on-disk build when it differs from
    ///     `ownBuild`, or `nil` when the plist is gone.
    init(
        bundleURL: URL?,
        ownBuild: Int,
        pollInterval: TimeInterval = 60,
        onChange: @escaping @Sendable (Int?) -> Void
    ) {
        self.bundleURL = bundleURL
        infoPlistURL =
            (bundleURL ?? URL(fileURLWithPath: "/nonexistent"))
            .appendingPathComponent("Contents/Info.plist")
        self.ownBuild = ownBuild
        self.onChange = onChange
        self.pollInterval = pollInterval
    }

    /// Reads `Contents/Info.plist` fresh and reports a change. Called on every
    /// broker `hello` (§3.6). Synchronous and cheap; the plist is small.
    func check() {
        guard let onDiskBuild = onDiskBuild(), onDiskBuild != ownBuild else {
            if onDiskBuild() == nil { onChange(nil) }
            return
        }
        onChange(onDiskBuild)
    }

    /// On-disk `CFBundleVersion`, or `nil` when the plist cannot be read.
    func onDiskBuild() -> Int? {
        guard
            let dict = NSDictionary(contentsOf: infoPlistURL),
            let value = dict["CFBundleVersion"],
            let build = Int("\(value)")
        else { return nil }
        return build
    }

    /// Starts the 60 s poll and the vnode watch on the bundle directory.
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer

        guard let bundleURL else { return }
        let fd = open(bundleURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.rename, .delete],
            queue: queue)
        source.setEventHandler { [weak self] in self?.check() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
        source?.cancel()
        source = nil
    }
}
