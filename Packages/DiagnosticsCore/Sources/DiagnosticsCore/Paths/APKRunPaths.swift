import Foundation

/// Resolves APKRun's writable paths from the single per-user root.
public struct APKRunPaths: Sendable {
    /// The root for APKRun-owned persistent data.
    public let dataRoot: URL

    /// The root for APKRun log files.
    public let logsRoot: URL

    /// The root for disposable APKRun cache data.
    public let cachesRoot: URL

    /// Creates paths, optionally honoring `APKRUN_HOME` for development or tests.
    ///
    /// - Parameters:
    ///   - allowingHomeOverride: Whether the `APKRUN_HOME` environment variable may replace the default root.
    ///   - environment: The environment to inspect. Tests can provide a fixed value.
    ///   - homeDirectory: The home directory used to build default paths.
    public init(
        allowingHomeOverride: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        if allowingHomeOverride,
            let override = environment["APKRUN_HOME"],
            !override.isEmpty
        {
            let root: URL
            if override == "~" {
                root = homeDirectory
            } else if override.hasPrefix("~/") {
                root = homeDirectory.appending(path: String(override.dropFirst(2)), directoryHint: .isDirectory)
            } else {
                root = URL(fileURLWithPath: override, isDirectory: true)
            }
            let normalizedRoot = root.standardizedFileURL
            dataRoot = normalizedRoot
            logsRoot = normalizedRoot.appendingPathComponent("Logs", isDirectory: true)
            cachesRoot = normalizedRoot.appendingPathComponent("Caches", isDirectory: true)
            return
        }

        #if DEBUG
            let applicationName = "APKRun-Dev"
            let cacheName = "io.apkrun.APKRun-Dev"
        #else
            let applicationName = "APKRun"
            let cacheName = "io.apkrun.APKRun"
        #endif

        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        dataRoot =
            library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationName, isDirectory: true)
        logsRoot =
            library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(applicationName, isDirectory: true)
        cachesRoot =
            library
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent(cacheName, isDirectory: true)
    }

    /// The global state file.
    public var stateFile: URL { dataRoot.appendingPathComponent("state.json") }

    /// The global settings file.
    public var settingsFile: URL { dataRoot.appendingPathComponent("settings.json") }

    /// The installed Android runtime images directory.
    public var imagesDirectory: URL { dataRoot.appendingPathComponent("Images", isDirectory: true) }

    /// Returns the directory for an installed Android runtime image version.
    ///
    /// Artifact file paths inside this directory are resolved by `AndroidImageManifest`.
    public func imageDirectory(version: String) -> URL {
        imagesDirectory.appendingPathComponent(version, isDirectory: true)
    }

    /// Returns the manifest path for an installed Android runtime image version.
    public func imageManifestFile(version: String) -> URL {
        imageDirectory(version: version).appendingPathComponent("manifest.json")
    }

    /// Returns the signature path for an installed Android runtime image version.
    public func imageManifestSignatureFile(version: String) -> URL {
        imageDirectory(version: version).appendingPathComponent("manifest.sig")
    }

    /// Returns the boot files directory for an installed Android runtime image version.
    public func imageBootDirectory(version: String) -> URL {
        imageDirectory(version: version).appendingPathComponent("boot", isDirectory: true)
    }

    /// Returns the disk images directory for an installed Android runtime image version.
    public func imageDisksDirectory(version: String) -> URL {
        imageDirectory(version: version).appendingPathComponent("disks", isDirectory: true)
    }

    /// Returns the image templates directory for an installed Android runtime image version.
    public func imageTemplatesDirectory(version: String) -> URL {
        imageDirectory(version: version).appendingPathComponent("templates", isDirectory: true)
    }

    /// Returns the checksum list for an installed Android runtime image version.
    public func imageChecksumsFile(version: String) -> URL {
        imageDirectory(version: version).appendingPathComponent("SHA256SUMS")
    }

    /// Returns the staging directory for an image installation.
    public func imageInstallStagingDirectory(name: String) -> URL {
        imagesDirectory.appendingPathComponent(".installing-\(name)", isDirectory: true)
    }

    /// The current Android runtime image pointer.
    public var currentImage: URL { imagesDirectory.appendingPathComponent("current") }

    /// The previous Android runtime image pointer.
    public var previousImage: URL { imagesDirectory.appendingPathComponent("previous") }

    /// The Android image update state file.
    public var imageUpdateStateFile: URL { imagesDirectory.appendingPathComponent("update-state.json") }

    /// The runtime state directory.
    public var runtimeDirectory: URL { dataRoot.appendingPathComponent("Runtime", isDirectory: true) }

    /// The runtime instance lock file.
    public var instanceLockFile: URL { runtimeDirectory.appendingPathComponent("instance.lock") }

    /// The daemon run record.
    public var daemonStateFile: URL { runtimeDirectory.appendingPathComponent("daemon.json") }

    /// The APKRun update maintenance marker.
    public var maintenanceStateFile: URL { runtimeDirectory.appendingPathComponent("maintenance.json") }

    /// The one Android VM instance directory.
    public var instanceDirectory: URL { runtimeDirectory.appendingPathComponent("instance", isDirectory: true) }

    /// The current instance's generated boot files directory.
    public var bootDirectory: URL { instanceDirectory.appendingPathComponent("boot", isDirectory: true) }

    /// The current instance's generated initrd.
    public var instanceInitrdFile: URL { bootDirectory.appendingPathComponent("initrd.img") }

    /// The current instance's writable persistent disk.
    public var persistentDiskFile: URL { instanceDirectory.appendingPathComponent("persistent.img") }

    /// The current instance's writable user data disk.
    public var userDataDiskFile: URL { instanceDirectory.appendingPathComponent("userdata.img") }

    /// The current instance's metadata file.
    public var instanceInfoFile: URL { instanceDirectory.appendingPathComponent("instance.json") }

    /// The current instance's recovery point directory.
    public var recoveryPointsDirectory: URL {
        instanceDirectory.appendingPathComponent("recovery-points", isDirectory: true)
    }

    /// Returns a named recovery point directory.
    public func recoveryPointDirectory(timestamp: String, imageVersion: String) -> URL {
        recoveryPointsDirectory.appendingPathComponent("\(timestamp)-\(imageVersion)", isDirectory: true)
    }

    /// Returns the persistent disk snapshot in a recovery point.
    public func recoveryPointPersistentDiskFile(timestamp: String, imageVersion: String) -> URL {
        recoveryPointDirectory(timestamp: timestamp, imageVersion: imageVersion)
            .appendingPathComponent("persistent.img")
    }

    /// Returns the user data disk snapshot in a recovery point.
    public func recoveryPointUserDataDiskFile(timestamp: String, imageVersion: String) -> URL {
        recoveryPointDirectory(timestamp: timestamp, imageVersion: imageVersion)
            .appendingPathComponent("userdata.img")
    }

    /// Returns the instance metadata snapshot in a recovery point.
    public func recoveryPointInstanceInfoFile(timestamp: String, imageVersion: String) -> URL {
        recoveryPointDirectory(timestamp: timestamp, imageVersion: imageVersion)
            .appendingPathComponent("instance.json")
    }

    /// The installed Android package data directory.
    public var packagesDirectory: URL { dataRoot.appendingPathComponent("Packages", isDirectory: true) }

    /// The package transaction journal.
    public var packageJournalFile: URL { packagesDirectory.appendingPathComponent("journal.jsonl") }

    /// The package transaction trash directory.
    public var packageTrashDirectory: URL { packagesDirectory.appendingPathComponent(".trash", isDirectory: true) }

    /// Returns the data directory for a package identifier.
    public func packageDirectory(packageID: String) -> URL {
        packagesDirectory.appendingPathComponent(packageID, isDirectory: true)
    }

    /// Returns the metadata file for an installed package.
    public func packageMetadataFile(packageID: String) -> URL {
        packageDirectory(packageID: packageID).appendingPathComponent("metadata.json")
    }

    /// Returns the settings file for an installed package.
    public func packageSettingsFile(packageID: String) -> URL {
        packageDirectory(packageID: packageID).appendingPathComponent("settings.json")
    }

    /// Returns an installed package's current artifact directory.
    public func packageCurrentDirectory(packageID: String) -> URL {
        packageDirectory(packageID: packageID).appendingPathComponent("current", isDirectory: true)
    }

    /// Returns an installed package's previous artifact directory.
    public func packagePreviousDirectory(packageID: String) -> URL {
        packageDirectory(packageID: packageID).appendingPathComponent("previous", isDirectory: true)
    }

    /// Returns an installed package's staged artifact directory.
    public func packageStagedDirectory(packageID: String) -> URL {
        packageDirectory(packageID: packageID).appendingPathComponent("staged", isDirectory: true)
    }

    /// Returns a package's incoming transaction directory.
    public func packageIncomingDirectory(packageID: String, ticket: String) -> URL {
        packageDirectory(packageID: packageID)
            .appendingPathComponent("incoming", isDirectory: true)
            .appendingPathComponent(ticket, isDirectory: true)
    }

    /// Returns a package's retained failed artifact directory.
    public func packageFailedDirectory(packageID: String, versionCode: String) -> URL {
        packageDirectory(packageID: packageID)
            .appendingPathComponent("failed", isDirectory: true)
            .appendingPathComponent(versionCode, isDirectory: true)
    }

    /// Returns the rendered icon directory for an installed package.
    public func packageIconDirectory(packageID: String) -> URL {
        packageDirectory(packageID: packageID).appendingPathComponent("icon", isDirectory: true)
    }

    /// The generated Mac app wrapper data directory.
    public var wrappersDirectory: URL { dataRoot.appendingPathComponent("Wrappers", isDirectory: true) }

    /// The wrapper registry file.
    public var wrapperRegistryFile: URL { wrappersDirectory.appendingPathComponent("registry.json") }

    /// The user-selected wrapper icons directory.
    public var wrapperIconsDirectory: URL { wrappersDirectory.appendingPathComponent("icons", isDirectory: true) }

    /// Returns the custom icon file for a wrapper bundle identifier.
    public func wrapperIconFile(bundleID: String) -> URL {
        wrapperIconsDirectory.appendingPathComponent("\(bundleID).png")
    }

    /// The wrapper staging directory.
    public var wrapperStagingDirectory: URL { wrappersDirectory.appendingPathComponent("staging", isDirectory: true) }

    /// Returns the staging directory for one wrapper generation operation.
    public func wrapperStagingDirectory(identifier: String) -> URL {
        wrapperStagingDirectory.appendingPathComponent(identifier, isDirectory: true)
    }

    /// The app update state directory.
    public var updatesDirectory: URL { dataRoot.appendingPathComponent("Updates", isDirectory: true) }

    /// The app update state file.
    public var updatesStateFile: URL { updatesDirectory.appendingPathComponent("state.json") }

    /// The app update history file.
    public var updatesHistoryFile: URL { updatesDirectory.appendingPathComponent("history.jsonl") }

    /// The provider cache directory.
    public var providersDirectory: URL { dataRoot.appendingPathComponent("Providers", isDirectory: true) }

    /// The provider index cache.
    public var providerCacheDirectory: URL { providersDirectory.appendingPathComponent("cache", isDirectory: true) }

    /// Returns the cached data directory for a provider key.
    public func providerCacheDirectory(type: String, key: String) -> URL {
        providerCacheDirectory
            .appendingPathComponent(type, isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    /// The only host folder shared with Android by default.
    public var sharedDirectory: URL { dataRoot.appendingPathComponent("Shared", isDirectory: true) }

    /// The disposable cache stored under the persistent data root.
    public var dataCacheDirectory: URL { dataRoot.appendingPathComponent("Cache", isDirectory: true) }

    /// The Android image download cache.
    public var imageDownloadsDirectory: URL {
        dataCacheDirectory.appendingPathComponent("images", isDirectory: true)
    }

    /// The VM logs directory.
    public var vmLogsDirectory: URL { logsRoot.appendingPathComponent("vm", isDirectory: true) }

    /// The current serial console log.
    public var consoleLogFile: URL { vmLogsDirectory.appendingPathComponent("console.log") }

    /// Returns a rotated serial console log path.
    public func consoleLogRotationFile(index: Int) -> URL {
        vmLogsDirectory.appendingPathComponent("console.\(index).log")
    }

    /// The guest logs directory.
    public var guestLogsDirectory: URL { logsRoot.appendingPathComponent("guest", isDirectory: true) }

    /// The runtime crash snapshot directory.
    public var crashLogsDirectory: URL { logsRoot.appendingPathComponent("crash", isDirectory: true) }

    /// Returns a timestamped runtime crash snapshot directory.
    public func crashSnapshotDirectory(timestamp: String) -> URL {
        crashLogsDirectory.appendingPathComponent("\(timestamp)-runtime", isDirectory: true)
    }

    /// The daemon log mirror.
    public var daemonLogFile: URL { logsRoot.appendingPathComponent("apkrund.log") }

    /// Returns a rotated daemon log mirror path.
    public func daemonLogRotationFile(index: Int) -> URL {
        logsRoot.appendingPathComponent("apkrund.\(index).log")
    }

    /// The performance logs directory.
    public var performanceLogsDirectory: URL { logsRoot.appendingPathComponent("perf", isDirectory: true) }

    /// The app launch performance records.
    public var launchPerformanceFile: URL {
        performanceLogsDirectory.appendingPathComponent("launches.jsonl")
    }

    /// The Android boot performance records.
    public var bootPerformanceFile: URL { performanceLogsDirectory.appendingPathComponent("boots.jsonl") }

    /// Returns a timestamped guest logcat capture path.
    public func guestLogcatFile(timestamp: String) -> URL {
        guestLogsDirectory.appendingPathComponent("logcat-\(timestamp).log")
    }

    /// Returns a timestamped boot log path.
    public func bootLogFile(timestamp: String) -> URL {
        vmLogsDirectory.appendingPathComponent("boot-\(timestamp).log")
    }
}
