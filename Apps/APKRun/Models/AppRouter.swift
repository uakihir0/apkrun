import Foundation
import RuntimeAPI

/// A navigation target inside the app (host-ui.md §3.1).
enum AppRoute: Equatable {
    /// The main window, Apps section.
    case home
    /// The Updates list.
    case updates
    /// The app's page/selects the package row in Apps. `section` is
    /// `general`, `window`, `input`, `integrations`, `updates`, `mac-app`, or
    /// `storage`; an unknown section lands on the package page itself.
    case package(RuntimePackageID, section: String?)
    /// Settings at a pane: `general`, `runtime`, `updates`, `privacy`,
    /// `files`, `language`, `storage`, `troubleshooting`, `advanced`.
    case settings(pane: String)
    /// Onboarding when setup is incomplete, otherwise home.
    case setup
    /// The diagnostics report sheet; `package` preselects a package
    /// (diagnostics.md §8.4).
    case report(package: RuntimePackageID?)
}

/// Delivers document opens (double-click, Open With, `open -a APKRun file.apk`)
/// from the app delegate to the add flow (host-ui.md §3.2).
enum OpenFileRouter {
    /// Set by the app once `HomeModel` exists.
    @MainActor static var handler: (([URL]) -> Void)?

    /// Forwards opened file URLs to the add flow.
    @MainActor static func open(_ urls: [URL]) {
        handler?(urls)
    }
}

/// Routes `apkrun://` URLs. URLs only navigate — they never perform an
/// action, because any process can open a URL (host-ui.md §3.1).
enum AppRouter {
    /// The sections a `package/<id>/<section>` route accepts.
    static let packageSections: Set<String> = [
        "general", "window", "input", "integrations", "updates", "mac-app", "storage",
    ]

    /// The panes a `settings/<pane>` route accepts.
    static let settingsPanes: Set<String> = [
        "general", "runtime", "updates", "privacy", "files", "language",
        "storage", "troubleshooting", "advanced",
    ]

    /// Parses an `apkrun://` URL into a navigation target.
    ///
    /// Unknown routes open home. Package IDs
    /// that fail the Android package-name grammar are rejected as `nil`
    /// (the caller shows "‹id› isn't installed in APKRun.").
    static func route(_ url: URL) -> AppRoute? {
        guard url.scheme?.lowercased() == "apkrun" else { return nil }
        let host = (url.host(percentEncoded: false) ?? "").lowercased()
        let segments = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "home", "":
            return .home
        case "package":
            guard let id = segments.first else { return nil }
            guard let packageID = RuntimePackageID(rawValue: id) else { return nil }
            let section = segments.dropFirst().first
            if let section, !packageSections.contains(section) {
                return .package(packageID, section: nil)
            }
            return .package(packageID, section: section)
        case "updates":
            return .updates
        case "settings":
            let pane = segments.first ?? "general"
            return .settings(pane: settingsPanes.contains(pane) ? pane : "general")
        case "setup":
            return .setup
        case "report":
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "package" })?.value
            if let id, !id.isEmpty {
                guard let packageID = RuntimePackageID(rawValue: id) else {
                    return nil
                }
                return .report(package: packageID)
            }
            return .report(package: nil)
        default:
            return .home
        }
    }
}
