import Foundation
import RuntimeAPI

/// The update flags shared by `install` and `wrap --install` (cli.md §4.2,
/// update-system.md §11.3): `--provider <spec>`, `--updates
/// automatic|notify|manual` and its `--update` alias, and the
/// `--update-provider <type> --update-url <url>` pair that means
/// `--provider <type>:<url>`.
enum InstallUpdateOptions {
    /// Parses a provider spec into the wire type, creating a security-scoped
    /// bookmark for `local:` roots (runtime-api.md §9.2).
    static func providerSpec(_ spec: String) throws -> ProviderSpec {
        if spec.hasPrefix("local:") {
            let path = String(spec.dropFirst("local:".count))
            let url = URL(fileURLWithPath: path)
            guard url.isFileURL else {
                throw CLIFailure.invalidArgument(argument: "--provider", reason: "invalidValue")
            }
            let bookmark: Data
            do {
                bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil)
            } catch {
                throw CLIFailure.fileNotAccessible(file: path, .permissionDenied)
            }
            return ProviderSpec(spec: spec, bookmark: bookmark)
        }
        return ProviderSpec(spec: spec)
    }

    /// Maps the flag values to install options. `provider` implies authority
    /// `apkrun`; `--updates manual` yields authority `manual` with the
    /// provider stored unused (cli.md §4.2, update-system.md §2.4).
    static func options(
        provider: String?,
        updates: String?,
        update: String?,
        updateProvider: String?,
        updateURL: String?
    ) throws -> RuntimeInstallOptions {
        let modeRaw: String?
        switch (updates, update) {
        case (nil, nil): modeRaw = nil
        case (let value?, nil), (nil, let value?): modeRaw = value
        default:
            throw CLIFailure.invalidArgument(
                argument: "--updates/--update", reason: "incompatible")
        }
        let choice: UpdateChoice?
        switch modeRaw {
        case nil: choice = nil
        case "automatic", "auto": choice = .automatic
        case "notify": choice = .notifyOnly
        case "manual": choice = .manual
        default:
            throw CLIFailure.invalidArgument(argument: "--updates", reason: "invalidValue")
        }

        let specString: String?
        switch (provider, updateProvider, updateURL) {
        case (.some, .some, _), (.some, _, .some):
            throw CLIFailure.invalidArgument(
                argument: "--provider/--update-provider", reason: "incompatible")
        case (nil, .some(let type), .some(let url)):
            specString = "\(type):\(url)"
        case (nil, .some, nil), (nil, nil, .some):
            throw CLIFailure.invalidArgument(
                argument: "--update-provider/--update-url", reason: "incompatible")
        default:
            specString = provider
        }

        var options = RuntimeInstallOptions()
        if let specString {
            options.provider = try providerSpec(specString)
            options.authority = choice == .manual ? .manual : .apkrun
        }
        if choice == .manual {
            options.authority = .manual
        }
        options.updateMode = choice
        return options
    }
}
