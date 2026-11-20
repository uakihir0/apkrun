import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// apkrund's only AppKit touch point (runtime-daemon.md §3): opening a wrapper,
/// the generic launcher, or APKRun.app through `NSWorkspace`.
enum WorkspaceOpener {
    /// Opens an application with `NSWorkspace.openApplication(at:configuration:)`.
    /// Returns whether the workspace accepted the request.
    @discardableResult
    static func openApplication(at url: URL, arguments: [String] = [], activates: Bool = true)
        async -> Bool
    {
        #if canImport(AppKit)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            configuration.activates = activates
            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: url, configuration: configuration)
                return true
            } catch {
                return false
            }
        #else
            return false
        #endif
    }

    /// The LaunchServices candidates for a bundle identifier (wrapper.md §9.1
    /// step 1), used to find a wrapper the user moved or renamed.
    static func applicationURLs(bundleIdentifier: String) -> [URL] {
        #if canImport(AppKit)
            return NSWorkspace.shared.urlsForApplications(
                withBundleIdentifier: bundleIdentifier)
        #else
            return []
        #endif
    }
}
