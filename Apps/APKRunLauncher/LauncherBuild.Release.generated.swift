#if APKRUN_LAUNCHER_RELEASE
    import Foundation
    import RuntimeAPI
    import RuntimeClient

    enum LauncherBuild {
        static let version = "0.1.0"
        static let launcherAPI = APIVersion(major: 1, minor: 18)
        static let minimumRuntimeVersion: WrapperMinimumRuntimeVersion = {
            guard let version = WrapperMinimumRuntimeVersion(rawValue: "0.1.0") else {
                fatalError("Generated minimum runtime version is invalid.")
            }
            return version
        }()
        static let downloadURL: URL = {
            guard let url = URL(string: "https://apkrun.io/apkrun/download/") else {
                fatalError("Generated download URL is invalid.")
            }
            return url
        }()
        static let hostAppBundleIdentifier = "io.apkrun.APKRun.dev"
        static let daemonIdentity: RuntimeWrapperDaemonBuildIdentity = .development
    }
#endif
