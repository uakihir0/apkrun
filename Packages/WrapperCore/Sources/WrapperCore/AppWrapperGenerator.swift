import CoreGraphics
import DiagnosticsCore
import Foundation
import ImageIO
import RuntimeAPI

/// A generated placeholder `AppIcon.icns`. The full icon pipeline is #56; this
/// deterministic writer keeps generated bundles structurally complete until
/// then.
public enum PlaceholderIcon {
    /// Deterministic `.icns` bytes: a 1024 px PNG under the `ic10` type and a
    /// 128 px PNG under `ic07`, drawn by ImageIO without metadata.
    public static func icnsData() throws -> Data {
        let large = try png(size: 1024)
        let small = try png(size: 128)
        var data = Data()
        data.append(Data("icns".utf8))
        var total = UInt32(8 + 8 + large.count + 8 + small.count).bigEndian
        data.append(Data(bytes: &total, count: 4))
        data.append(Data("ic10".utf8))
        var part = UInt32(8 + large.count).bigEndian
        data.append(Data(bytes: &part, count: 4))
        data.append(large)
        data.append(Data("ic07".utf8))
        part = UInt32(8 + small.count).bigEndian
        data.append(Data(bytes: &part, count: 4))
        data.append(small)
        return data
    }

    /// A solid-color PNG without metadata chunks (wrapper.md §6.5).
    private static func png(size: Int) throws -> Data {
        guard
            let context = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else {
            throw WrapperFailure.iconConversionFailed("cannot create CGContext")
        }
        // APKRun placeholder: a flat blue-gray rounded square.
        context.setFillColor(red: 0.21, green: 0.35, blue: 0.55, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        guard let image = context.makeImage() else {
            throw WrapperFailure.iconConversionFailed("cannot rasterize the placeholder")
        }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil)
        else {
            throw WrapperFailure.iconConversionFailed("cannot create an image destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw WrapperFailure.iconConversionFailed("cannot encode PNG")
        }
        return data as Data
    }
}

/// Generates `<name>.app` for a package (wrapper.md §6). `generate` runs steps
/// 1–7 and 10–13 of §6.2: validate, stage, write the bundle, journal
/// `pending`, place, journal `active`, register with LaunchServices. Signing
/// (step 9) is #47; portable/distribution contents (step 8) are #89/#90.
public actor AppWrapperGenerator {
    /// Dependencies the generator reads but never owns.
    public struct Environment: Sendable {
        /// Build constants and the executable URL of the launcher template.
        public var launcher: LauncherBuild
        /// The registry that journals pending/active state.
        public var registry: WrapperRegistry
        /// The installer that places the bundle.
        public var installer: WrapperInstaller
        /// The staging root (`Wrappers/staging/`).
        public var stagingRoot: URL

        /// Creates the generator environment.
        public init(
            launcher: LauncherBuild,
            registry: WrapperRegistry,
            installer: WrapperInstaller,
            stagingRoot: URL
        ) {
            self.launcher = launcher
            self.registry = registry
            self.installer = installer
            self.stagingRoot = stagingRoot
        }
    }

    private let environment: Environment
    private let fileManager: FileManager
    private let logger: APKLogger

    /// Creates a generator.
    public init(
        environment: Environment,
        fileManager: FileManager = .default,
        sink: (any LogSink)? = nil
    ) {
        self.environment = environment
        self.fileManager = fileManager
        logger = APKLogger(category: WrapperLogCategory.generate, sink: sink)
    }

    /// The staging directory used for the next generation, when a
    /// `destinationNotAccessible` reply must point at it.
    private func newStagingToken() -> String {
        UUID().uuidString
    }

    /// Runs the generation sequence (wrapper.md §6.2).
    public func generate(
        _ request: WrapperGenerationRequest
    ) async throws(WrapperFailure) -> GeneratedWrapper {
        let started = ContinuousClock.now
        Perf.mark(.wrapperGenerateStart, ["packageID": .string(request.configuration.packageID.rawValue)])
        do {
            let result = try await perform(request)
            Perf.mark(
                .wrapperGenerateEnd,
                [
                    "durationMs": .integer(
                        Int64(started.duration(to: .now).components.seconds * 1000)),
                    "kind": .string(request.configuration.kind.rawValue),
                ]
            )
            return result
        } catch {
            Perf.mark(
                .wrapperGenerateEnd,
                ["kind": .string(request.configuration.kind.rawValue), "failed": .boolean(true)]
            )
            throw error
        }
    }

    private func perform(
        _ request: WrapperGenerationRequest
    ) async throws(WrapperFailure) -> GeneratedWrapper {
        let configuration = request.configuration
        guard configuration.kind == .local else {
            throw .verificationFailed("\(configuration.kind.rawValue) wrappers are #89/#90")
        }

        // 1. validate the package ID syntax, the name, the icon, the template.
        let fileName =
            request.fileName.map {
                WrapperFileName.sanitize(displayName: $0, packageID: configuration.packageID.rawValue)
            }
            ?? WrapperFileName.sanitize(
                displayName: configuration.displayName,
                packageID: configuration.packageID.rawValue
            )
        guard !fileName.isEmpty else {
            throw .invalidName(configuration.displayName)
        }
        let template = environment.launcher.executableURL
        guard fileManager.fileExists(atPath: template.path) else {
            throw .launcherTemplateInvalid("missing at \(template.path)")
        }
        guard WrapperCodeSign.isARM64(template) else {
            throw .launcherTemplateInvalid("not an arm64 executable")
        }
        guard WrapperCodeSign.signatureIsValid(bundleURL: template),
            WrapperCodeSign.cdhash(of: template) != nil
        else {
            throw .launcherTemplateInvalid("unsigned or invalid signature")
        }

        // 2. bundleID; a registered active wrapper of this package blocks.
        let bundleID = BundleIDMapper.map(configuration.packageID)

        // 3. resolve the destination and check conflicts (wrapper.md §6.4).
        //    A TCC-protected destination defers placement (§6.3): the bundle
        //    is still built and signed in staging, the client moves it, and
        //    `placeStagedWrapper` finishes registration.
        let stagingID = newStagingToken()
        var deferredDestination: URL?
        let destination: URL
        do {
            destination = try environment.installer.resolveDestination(
                request.destination, stagingToken: stagingID)
        } catch WrapperFailure.destinationNotAccessible(let directory, _) {
            deferredDestination = directory
            destination = directory
        }
        let finalURL = destination.appendingPathComponent("\(fileName).app", isDirectory: true)
        let existing = await environment.registry.entry(bundleID: bundleID)
        // The security bookmark tracks the bundle across a move in Finder,
        // so a resolvable location — the recorded path or the bookmark —
        // still counts as this package's wrapper. A row whose bundle is
        // gone or holds a foreign app is stale and regenerates.
        var existingURL = existing.map { URL(fileURLWithPath: $0.path) }
        if let existing, let url = existingURL,
            !fileManager.fileExists(atPath: url.path),
            let bookmark = existing.bookmark,
            let bookmarkData = Data(base64Encoded: bookmark)
        {
            var bookmarkIsStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale)
            {
                existingURL = resolved
            }
        }
        // A bundle in the Trash counts as missing (wrapper.md §9.1).
        let existingIsLive =
            existingURL.map {
                fileManager.fileExists(atPath: $0.path)
                    && !$0.path.contains("/.Trash/")
                    && environment.installer.isWrapperOf(configuration.packageID, at: $0)
            } ?? false
        if existingIsLive, let existingURL {
            guard request.replace == .sameWrapper else {
                throw .wrapperExists(configuration.packageID, existingURL)
            }
        }
        // A protected folder cannot be listed; the client's move handles
        // whatever already sits at the name it picks.
        if deferredDestination == nil, fileManager.fileExists(atPath: finalURL.path) {
            if environment.installer.isWrapperOf(configuration.packageID, at: finalURL) {
                guard request.replace == .sameWrapper else {
                    throw .wrapperExists(configuration.packageID, finalURL)
                }
            } else if let conflict = environment.installer.classifyConflict(
                at: finalURL, packageID: configuration.packageID)
            {
                throw .nameConflict(finalURL, existing: conflict)
            }
        }

        // 4. staging = Wrappers/staging/<uuid>/<name>.app
        let staging = environment.stagingRoot
            .appendingPathComponent(stagingID, isDirectory: true)
        let stagedBundle = staging.appendingPathComponent("\(fileName).app", isDirectory: true)
        do {
            try writeBundle(
                at: stagedBundle,
                fileName: fileName,
                bundleID: bundleID,
                configuration: configuration
            )
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        // 9. sign ad-hoc, verify strictly, read the cdhash (wrapper.md §7.1).
        let cdhash: String
        do {
            cdhash = try WrapperSigner.sign(bundleURL: stagedBundle, bundleID: bundleID)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }

        // 10. registry pending entry before placement.
        var entry = WrapperRegistryEntry(
            bundleId: bundleID,
            packageId: configuration.packageID.rawValue,
            kind: configuration.kind,
            state: .pending,
            path: finalURL.path,
            cdhash: cdhash,
            launcherVersion: environment.launcher.launcherVersion,
            launcherAPI: environment.launcher.launcherAPI,
            fileName: fileName,
            displayName: configuration.displayName,
            createdAt: existing?.createdAt ?? Date()
        )
        entry.stagingPath = stagedBundle.path
        entry.approval = .generated
        do {
            try await environment.registry.markPending(entry)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw .registryUnavailable
        }

        // 11. place. A deferred destination leaves the bundle staged: the
        // pending entry's stagingPath carries the token `placeStagedWrapper`
        // matches, and staging cleanup expires it (wrapper.md §6.3).
        if let deferredDestination {
            throw .destinationNotAccessible(
                deferredDestination, stagingToken: stagingID)
        }
        _ = try environment.installer.place(staged: stagedBundle, to: finalURL)

        // 12. bookmark + active.
        let bookmark = (try? finalURL.bookmarkData()) ?? Data()
        do {
            try await environment.registry.activate(
                bundleID: bundleID, path: finalURL, bookmark: bookmark)
        } catch {
            throw .registryUnavailable
        }

        // On a `sameWrapper` replace under a new file name, remove the
        // replaced bundle — at its recorded path or wherever the bookmark
        // resolved — so only one wrapper of the package remains.
        if existingIsLive, let existingURL, existingURL.path != finalURL.path {
            try? fileManager.removeItem(at: existingURL)
        }

        return GeneratedWrapper(
            bundleURL: finalURL,
            bundleID: bundleID,
            cdhash: cdhash,
            launcherVersion: environment.launcher.launcherVersion
        )
    }

    /// Builds and signs the refreshed bundle inside `stagingDirectory`
    /// (wrapper.md §9.3 step 3). The caller swaps `Contents` into the live
    /// bundle and finishes the registry update; nothing is placed or
    /// registered here. Returns the staged bundle URL and its cdhash.
    public func stageForRefresh(
        _ request: WrapperGenerationRequest,
        stagingDirectory: URL,
        fileName: String
    ) throws(WrapperFailure) -> (bundle: URL, cdhash: String) {
        let configuration = request.configuration
        guard configuration.kind == .local else {
            throw .verificationFailed("\(configuration.kind.rawValue) wrappers are #89/#90")
        }
        let template = environment.launcher.executableURL
        guard fileManager.fileExists(atPath: template.path),
            WrapperCodeSign.isARM64(template),
            WrapperCodeSign.signatureIsValid(bundleURL: template),
            WrapperCodeSign.cdhash(of: template) != nil
        else {
            throw .launcherTemplateInvalid("missing, unsigned, or not arm64")
        }
        let bundleID = BundleIDMapper.map(configuration.packageID)
        let stagedBundle = stagingDirectory.appendingPathComponent(
            "\(fileName).app", isDirectory: true)
        try writeBundle(
            at: stagedBundle,
            fileName: fileName,
            bundleID: bundleID,
            configuration: configuration
        )
        let cdhash = try WrapperSigner.sign(bundleURL: stagedBundle, bundleID: bundleID)
        return (stagedBundle, cdhash)
    }

    /// Writes the file tree of wrapper.md §2 for a non-portable wrapper.
    private func writeBundle(
        at bundle: URL,
        fileName: String,
        bundleID: String,
        configuration: WrapperConfiguration
    ) throws(WrapperFailure) {
        let contents = bundle.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        do {
            try fileManager.createDirectory(at: macos, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

            // Info.plist
            let plist = try InfoPlistWriter.plistData(
                bundleID: bundleID,
                fileName: fileName,
                displayName: WrapperFileName.sanitizedDisplayName(configuration.displayName),
                packageID: configuration.packageID.rawValue,
                category: configuration.category,
                kind: configuration.kind,
                build: environment.launcher
            )
            try plist.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)

            // PkgInfo
            try Data("APPL????".utf8).write(
                to: contents.appendingPathComponent("PkgInfo"), options: .atomic)

            // wrapper.json — no version, APK path, or digest (FR-WRP-03).
            let document = WrapperDocument.generated(
                configuration: configuration,
                displayName: WrapperFileName.sanitizedDisplayName(configuration.displayName),
                build: environment.launcher
            )
            try WrapperDocumentCodec.encode(document).write(
                to: resources.appendingPathComponent("wrapper.json"), options: .atomic)

            // AppIcon.icns (host preview or placeholder until #56).
            let icon: Data
            switch configuration.icon {
            case .rendered(let data):
                icon = data
            case .preview(let png):
                icon = Self.wrapPNGIntoICNS(png)
            case .custom(let url):
                icon = try Self.loadCustomIcon(at: url)
            case .placeholder:
                icon = try PlaceholderIcon.icnsData()
            }
            try icon.write(
                to: resources.appendingPathComponent("AppIcon.icns"), options: .atomic)

            // The launcher executable by clonefile(2), keeping its signature.
            let executable = macos.appendingPathComponent("APKRunLauncher")
            if clonefile(environment.launcher.executableURL.path, executable.path, 0) != 0 {
                // FAT filesystems lack clonefile; fall back to a byte copy.
                try fileManager.copyItem(at: environment.launcher.executableURL, to: executable)
            }
        } catch let error as WrapperFailure {
            throw error
        } catch {
            throw .verificationFailed("bundle write failed: \(error.localizedDescription)")
        }

        // File modes: 0644 for data, 0755 for the executable.
        setMode(0o644, at: contents.appendingPathComponent("Info.plist"))
        setMode(0o644, at: contents.appendingPathComponent("PkgInfo"))
        setMode(0o644, at: resources.appendingPathComponent("wrapper.json"))
        setMode(0o644, at: resources.appendingPathComponent("AppIcon.icns"))
        setMode(0o755, at: macos.appendingPathComponent("APKRunLauncher"))
    }

    /// Wraps an already-finished PNG in an `icns` container.
    private static func wrapPNGIntoICNS(_ png: Data) -> Data {
        var data = Data()
        data.append(Data("icns".utf8))
        var total = UInt32(8 + 8 + png.count).bigEndian
        data.append(Data(bytes: &total, count: 4))
        data.append(Data("ic10".utf8))
        var part = UInt32(8 + png.count).bigEndian
        data.append(Data(bytes: &part, count: 4))
        data.append(png)
        return data
    }

    /// Reads a user-provided icon file (minimal checks; full pipeline is #56).
    private static func loadCustomIcon(at url: URL) throws(WrapperFailure) -> Data {
        guard let data = try? Data(contentsOf: url) else {
            throw .customIconInvalid(.unreadable)
        }
        guard data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw .customIconInvalid(.unreadable)
        }
        return wrapPNGIntoICNS(data)
    }

    private func setMode(_ mode: mode_t, at url: URL) {
        chmod(url.path, mode)
    }
}
