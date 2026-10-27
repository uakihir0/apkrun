import RuntimeAPI

enum LauncherCompatibility: Equatable, Sendable {
    case compatible
    case runtimeTooOld
    case launcherTooOld
    case runtimeAPITooOld

    static func evaluate(
        runtimeVersion: String,
        serverAPI: APIVersion,
        minimumRuntimeVersion: WrapperMinimumRuntimeVersion,
        launcherAPI: APIVersion = .current
    ) -> Self {
        guard let minimum = SemanticVersion(minimumRuntimeVersion.rawValue),
            let runtime = SemanticVersion(runtimeVersion)
        else {
            return .runtimeAPITooOld
        }
        guard runtime >= minimum else {
            return .runtimeTooOld
        }

        if launcherAPI.major == serverAPI.major {
            return launcherAPI.minor <= serverAPI.minor ? .compatible : .runtimeAPITooOld
        }
        if launcherAPI.major < serverAPI.major {
            return serverAPI.major - launcherAPI.major == 1 ? .compatible : .launcherTooOld
        }
        return .runtimeAPITooOld
    }
}

private struct SemanticVersion: Comparable {
    private let components: [UInt64]

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let components = parts.compactMap { UInt64($0) }
        guard parts.count == 3,
            parts.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0") }),
            components.count == 3
        else {
            return nil
        }
        self.components = components
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
