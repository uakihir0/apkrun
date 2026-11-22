import DiagnosticsCore
import Foundation
import GuestProtocol
import ImageCore
import RuntimeAPI

// The feed side of image updates (runtime-maintenance.md §4.1–§4.6):
// `ImageFeedClient` for the signed feed, `ImageCandidateSelection` for C1–C7,
// `ImageDownloader` for the archive, and the A1–A7 apply gate.
extension RuntimeHost {

    /// The image feed base URL `…/apkrun/images` (§9): the `APKRunImageFeedURL`
    /// Info.plist key, or `maintenance.imageFeedURL` for development. Empty
    /// means feeds are off — OQ-01 decides the production host.
    var imageFeedBaseURL: URL? {
        if let override = GlobalSettings.load(from: paths.settingsFile)
            .extraValue("maintenance.imageFeedURL"),
            let url = URL(string: override)
        {
            return url
        }
        guard let bundle = Self.apkRunAppBundleURL(),
            let raw = Bundle(url: bundle)?.object(forInfoDictionaryKey: "APKRunImageFeedURL") as? String,
            let url = URL(string: raw)
        else {
            return nil
        }
        return url
    }

    /// The feed channel (`maintenance.channel`, default `stable`).
    private var imageFeedChannel: String {
        GlobalSettings.load(from: paths.settingsFile)
            .extraValue("maintenance.channel") ?? "stable"
    }

    /// The signed-feed client, built once per channel.
    func imageFeedClient() -> ImageFeedClient? {
        guard let base = imageFeedBaseURL else {
            return nil
        }
        let trust = ImageTrustStore.standard()
        let channel = imageFeedChannel
        return ImageFeedClient(
            baseURL: base.appendingPathComponent(channel, isDirectory: true),
            channel: channel,
            trust: trust,
            cacheFile: paths.imagesDirectory.appendingPathComponent("feed-\(channel).json")
        )
    }

    /// One §4.2 check: fetch, C1–C7, and when a candidate is found and
    /// automatic downloads are on, the download starts right away.
    @discardableResult
    func checkImageUpdates(userInitiated: Bool) async -> ImageFeedClient.Outcome? {
        if !userInitiated,
            GlobalSettings.load(from: paths.settingsFile)
                .extraValue("maintenance.checkAutomatically") == "false"
        {
            return nil
        }
        guard let client = imageFeedClient() else { return nil }
        await imageUpdateCoordinator.beginCheck()
        do {
            let outcome = try await client.fetch()
            if case .notModified = outcome {
                await imageUpdateCoordinator.noteCheckResult(
                    candidate: nil, requiresNewerAPKRun: nil)
                return outcome
            }
            guard case .feed(let feed) = outcome else { return outcome }
            let context = try await candidateContext(userInitiated: userInitiated)
            let pick = ImageCandidateSelection.pick(feed: feed, context: context)
            await imageUpdateCoordinator.noteCheckResult(
                candidate: pick.candidate, requiresNewerAPKRun: pick.requiresNewerAPKRun)
            if pick.candidate != nil {
                await maybeDownloadCandidate(userInitiated: userInitiated)
            }
            return outcome
        } catch let failure as ImageFailure {
            await imageUpdateCoordinator.noteCheckFailed(reason: "image.\(failure.code)")
            return nil
        } catch {
            await imageUpdateCoordinator.noteCheckFailed(reason: "\(error)")
            return nil
        }
    }

    /// The C1–C7 inputs from the live instance.
    private func candidateContext(userInitiated: Bool) async throws(ImageFailure)
        -> ImageCandidateSelection.Context
    {
        guard let images = imageStore, let current = image else {
            throw .noCurrentImage
        }
        let rejected = Set((await imageUpdateCoordinator.stateSnapshot()).rejected.keys)
        var rejectedVersions: Set<ImageCore.ImageVersion> = []
        for name in rejected {
            if let version = ImageCore.ImageVersion(name) { rejectedVersions.insert(version) }
        }
        _ = images
        return ImageCandidateSelection.Context(
            current: current.version,
            currentKind: current.manifest.kind.rawValue,
            userdataSchema: await instanceStore?.userdataSchemaVersion() ?? 0,
            hostVersion: buildIdentity.marketingVersion,
            hostProtocol: Int(
                ProtocolVersion.supportedMajors.lowerBound)...Int(
                    ProtocolVersion.supportedMajors.upperBound),
            rejected: rejectedVersions,
            instanceID: await instanceStore?.instanceID() ?? UUID(),
            userInitiated: userInitiated
        )
    }

    /// Starts the candidate download when the rules allow it (§4.4): automatic
    /// downloads need `maintenance.downloadImagesAutomatically`; a user request
    /// downloads immediately.
    func maybeDownloadCandidate(userInitiated: Bool) async {
        let state = await imageUpdateCoordinator.stateSnapshot()
        guard case .available(let candidate) = state.phase else { return }
        if !userInitiated,
            GlobalSettings.load(from: paths.settingsFile)
                .extraValue("maintenance.downloadImagesAutomatically") == "false"
        {
            return
        }
        let cacheDirectory = paths.cachesRoot.appendingPathComponent("images", isDirectory: true)
        await imageUpdateCoordinator.noteDownloadStarted(candidate)
        // Hold the daemon alive: a download can outlive the idle window, and
        // without an assertion the daemon would exit mid-download.
        let activity = await updateIdleController.assertActivity(.imageDownload)
        defer { activity.release() }
        let downloader = ImageDownloader()
        do {
            let archive = try await downloader.download(
                candidate, into: cacheDirectory, expensiveAllowed: userInitiated
            ) { progress in
                let fraction =
                    progress.total > 0
                    ? Double(progress.received) / Double(progress.total)
                    : 0
                Task { [weak self] in
                    await self?.imageUpdateCoordinator.noteDownloadProgress(
                        candidate, fraction: fraction)
                }
            }
            try await installDownloadedImage(candidate: candidate, archiveURL: archive)
        } catch let failure as ImageFailure {
            if failure.code == "imageArchiveHashMismatch" || failure.code == "imageArchiveSizeMismatch"
                || failure.code.hasPrefix("imageArchive") || failure.code == "imageFeedInvalid"
            {
                await imageUpdateCoordinator.noteInstallFailed(
                    candidate, reason: "image.\(failure.code)")
            } else {
                await imageUpdateCoordinator.noteDownloadFailed(
                    candidate, reason: "image.\(failure.code)")
            }
        } catch {
            await imageUpdateCoordinator.noteDownloadFailed(candidate, reason: "\(error)")
        }
    }

    /// §4.5 + §4.1 rule 6: install the archive, compare the manifest against
    /// the feed entry, delete the archive, and mark the image `ready`.
    private func installDownloadedImage(candidate: ImageCandidate, archiveURL: URL) async throws(ImageFailure) {
        guard let images = imageStore else {
            throw .noCurrentImage
        }
        let installed = try await images.install(from: .archive(archiveURL), activate: false)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        // §4.1 rule 6: the manifest must agree with the feed entry.
        guard installed.manifest.imageVersion == candidate.version else {
            throw .imageFeedInvalid(detail: "manifest does not match the feed entry")
        }
        await imageUpdateCoordinator.noteReady(installed.version)
        await maybeApplyReadyImage(userInitiated: false)
    }

    /// The §4.6 gate for automatic apply: every A-rule holds. A user-initiated
    /// apply skips A4, A5, and A7.
    func imageApplyGateOpen(userInitiated: Bool) async -> Bool {
        let state = await imageUpdateCoordinator.stateSnapshot()
        guard case .ready(let version) = state.phase else { return false }  // A1
        guard state.rejected[version.description] == nil else { return false }
        guard image != nil else { return false }
        if !userInitiated {
            // A2: no sessions, activities, package transactions.
            guard await maintenanceSessionPackageIDs().isEmpty,
                await maintenanceBackgroundTaskPackageIDs().isEmpty,
                activePackageMutations == 0,
                await updateIdleController.activeActivities.isEmpty
            else { return false }
            // A4: idle user; A5: AC power, no Low Power Mode, cool machine.
            guard Self.hostIdleSeconds() >= 600 else { return false }
            guard Self.hostOnACPower(),
                !ProcessInfo.processInfo.isLowPowerModeEnabled,
                ProcessInfo.processInfo.thermalState != .serious,
                ProcessInfo.processInfo.thermalState != .critical
            else { return false }
            // A7: no automatic attempt in the last 24 hours.
            guard await imageUpdateCoordinator.automaticApplyWindowOpen() else { return false }
        }
        // A3: host state normal.
        guard maintenanceHostState == .normal else { return false }
        // A6: 10 GiB free.
        guard
            let free = ImageDownloader.diskFreeSpace(paths.imagesDirectory),
            free >= 10 * 1_073_741_824
        else { return false }
        return true
    }

    /// Evaluates the gate and applies the ready image when it opens. Called on
    /// gate events (session ended, activity released) and the periodic tick.
    func maybeApplyReadyImage(userInitiated: Bool) async {
        // `maintenance.installImages = ask` turns off automatic apply; the
        // user starts it from Settings or `apkrun image install --latest`.
        if !userInitiated,
            GlobalSettings.load(from: paths.settingsFile)
                .extraValue("maintenance.installImages") == "ask"
        {
            return
        }
        let state = await imageUpdateCoordinator.stateSnapshot()
        guard case .ready(let version) = state.phase,
            let current = image?.version,
            await imageApplyGateOpen(userInitiated: userInitiated)
        else { return }
        if !userInitiated {
            await imageUpdateCoordinator.noteAutomaticApplyAttempt()
        }
        do {
            try await imageUpdateCoordinator.apply(version, from: current)
        } catch {
            // The coordinator recorded the failure (rejection or failed phase).
        }
    }

    /// `apkrun image check` / Settings **Check Now** (§4.2 user-initiated).
    func imageCheckNow() async -> String {
        await checkImageUpdates(userInitiated: true)
        let state = await imageUpdateCoordinator.stateSnapshot()
        return "Image update state: \(state.phase.phaseDescription)"
    }

    /// `apkrun image install --latest`: check, download, install, then apply
    /// with the user-initiated gate (§4.6).
    func imageInstallLatest() async throws -> String {
        await checkImageUpdates(userInitiated: true)
        var state = await imageUpdateCoordinator.stateSnapshot()
        if case .available = state.phase {
            await maybeDownloadCandidate(userInitiated: true)
            state = await imageUpdateCoordinator.stateSnapshot()
        }
        guard case .ready(let version) = state.phase else {
            if case .failed(_, let reason, _) = state.phase {
                throw ImageFailure.imageDownloadFailed(detail: reason)
            }
            throw ImageFailure.noCompatibleImage
        }
        guard let current = image?.version else {
            throw ImageFailure.noCurrentImage
        }
        guard await maintenanceSessionPackageIDs().isEmpty,
            await maintenanceBackgroundTaskPackageIDs().isEmpty
        else {
            // A CLI apply cannot ask for consent to close apps; the GUI
            // dialog of §4.6 does. Leave the image ready instead.
            return "Image \(version) is installed; close running Android apps, then run this again."
        }
        guard await imageApplyGateOpen(userInitiated: true) else {
            return "Image \(version) is installed; it will be applied when the runtime is idle."
        }
        try await imageUpdateCoordinator.apply(version, from: current)
        return "Updated Android to \(version)."
    }

    /// The §4.2/§4.6 loop: every five minutes it runs a due check and
    /// re-evaluates the apply gate. Inert when no feed URL is configured.
    func startImageUpdateLoop() {
        guard imageFeedBaseURL != nil, imageUpdateLoopTask == nil else { return }
        imageUpdateLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.imageUpdateTick()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// The hourly/idle tick: run a due check and re-evaluate the gate (§4.2,
    /// §4.6). Wired from the existing maintenance wake.
    func imageUpdateTick() async {
        let state = await imageUpdateCoordinator.stateSnapshot()
        if state.nextCheckAt.map({ $0 <= Date() }) ?? true {
            await checkImageUpdates(userInitiated: false)
        }
        await maybeApplyReadyImage(userInitiated: false)
    }
}
