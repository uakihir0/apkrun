/// Serializes package launches and store mutations for each package.
struct PackageActivityReservations {
    enum Failure: Error, Equatable {
        case uninstallAlreadyInProgress
        case uninstallInProgress
        case installAlreadyInProgress
        case installInProgress
        case forgetAlreadyInProgress
        case forgetInProgress
    }

    private var uninstallingPackages = Set<String>()
    private var installingPackages = Set<String>()
    private var forgettingPackages = Set<String>()
    private var activeLaunches: [String: Int] = [:]

    mutating func beginLaunch(packageID: String) throws(Failure) {
        guard !uninstallingPackages.contains(packageID) else {
            throw .uninstallInProgress
        }
        guard !installingPackages.contains(packageID) else {
            throw .installInProgress
        }
        activeLaunches[packageID, default: 0] += 1
    }

    mutating func finishLaunch(packageID: String) {
        let count = activeLaunches[packageID, default: 0]
        guard count > 0 else { return }
        activeLaunches[packageID] = count > 1 ? count - 1 : nil
    }

    mutating func beginUninstall(packageID: String) throws(Failure) {
        guard !uninstallingPackages.contains(packageID) else {
            throw .uninstallAlreadyInProgress
        }
        guard !installingPackages.contains(packageID) else {
            throw .installInProgress
        }
        guard !forgettingPackages.contains(packageID) else {
            throw .forgetInProgress
        }
        uninstallingPackages.insert(packageID)
    }

    mutating func finishUninstall(packageID: String) {
        uninstallingPackages.remove(packageID)
    }

    func isUninstalling(packageID: String) -> Bool {
        uninstallingPackages.contains(packageID)
    }

    func isInstalling(packageID: String) -> Bool {
        installingPackages.contains(packageID)
    }

    mutating func beginInstall(packageID: String) throws(Failure) {
        guard !uninstallingPackages.contains(packageID) else {
            throw .uninstallInProgress
        }
        guard !forgettingPackages.contains(packageID) else {
            throw .forgetInProgress
        }
        guard installingPackages.insert(packageID).inserted else {
            throw .installAlreadyInProgress
        }
    }

    mutating func finishInstall(packageID: String) {
        installingPackages.remove(packageID)
    }

    mutating func beginForget(packageID: String) throws(Failure) {
        guard !uninstallingPackages.contains(packageID) else {
            throw .uninstallInProgress
        }
        guard !installingPackages.contains(packageID) else {
            throw .installInProgress
        }
        guard forgettingPackages.insert(packageID).inserted else {
            throw .forgetAlreadyInProgress
        }
    }

    mutating func finishForget(packageID: String) {
        forgettingPackages.remove(packageID)
    }

    func hasActiveLaunches(packageID: String) -> Bool {
        activeLaunches[packageID, default: 0] > 0
    }
}
