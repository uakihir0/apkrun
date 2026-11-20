import Foundation

/// Manifest attributes that drive split selection (package-store.md §4.3, §4.4).
struct SplitAttributes: Sendable, Equatable {
    var isFeatureSplit: Bool
    var configForSplit: String?
    var isSplitRequired: Bool
    var requiredSplitTypes: [String]
    var splitTypes: [String]

    init(
        isFeatureSplit: Bool = false,
        configForSplit: String? = nil,
        isSplitRequired: Bool = false,
        requiredSplitTypes: [String] = [],
        splitTypes: [String] = []
    ) {
        self.isFeatureSplit = isFeatureSplit
        self.configForSplit = configForSplit
        self.isSplitRequired = isSplitRequired
        self.requiredSplitTypes = requiredSplitTypes
        self.splitTypes = splitTypes
    }
}

/// One APK's identity plus selection attributes.
struct SplitCandidate: Sendable, Equatable {
    var name: String
    var splitName: String?
    var attributes: SplitAttributes

    init(name: String, splitName: String?, attributes: SplitAttributes = SplitAttributes()) {
        self.name = name
        self.splitName = splitName
        self.attributes = attributes
    }
}

/// The outcome of one selection run.
struct SplitSelection: Sendable, Equatable {
    /// Names of the selected candidates, in input order.
    var included: [String]
    /// Split names excluded by ABI and density rules.
    var excludedSplits: [String]
}

/// Picks the splits of a container for the guest (package-store.md §4.4).
struct SplitSelector: Sendable {
    /// The guest ABIs (default `arm64-v8a`) and baseline density (320 dpi).
    struct GuestFacts: Sendable, Equatable {
        var abis: [String]
        var densityDPI: Int
        /// The guest SDK (37 on the baseline image) and the install floor.
        var sdk: Int
        var installFloor: Int

        init(abis: [String] = ["arm64-v8a"], densityDPI: Int = 320, sdk: Int = 37, installFloor: Int = 24) {
            self.abis = abis
            self.densityDPI = densityDPI
            self.sdk = sdk
            self.installFloor = installFloor
        }
    }

    private let guest: GuestFacts

    init(guest: GuestFacts = GuestFacts()) {
        self.guest = guest
    }

    private static let abiQualifiers: [String: String] = [
        "arm64_v8a": "arm64-v8a",
        "armeabi_v7a": "armeabi-v7a",
        "armeabi": "armeabi",
        "x86_64": "x86_64",
        "x86": "x86",
    ]

    private static let densityBuckets: [String: Int] = [
        "ldpi": 120, "mdpi": 160, "tvdpi": 213, "hdpi": 240,
        "xhdpi": 320, "xxhdpi": 480, "xxxhdpi": 640,
    ]

    /// Selects from the container candidates. Individual dropped `.apk` files are not selected —
    /// callers pass the full set for dropped files.
    func select(_ candidates: [SplitCandidate]) throws(StoreFailure) -> SplitSelection {
        var included: [SplitCandidate] = []
        var excluded: [String] = []

        // Density: nearest bucket to the guest density; if none is at least it, the highest.
        let densitySplits = candidates.compactMap {
            candidate -> (candidate: SplitCandidate, qualifier: String, dpi: Int)? in
            guard let qualifier = Self.configQualifier(of: candidate),
                let dpi = Self.densityBuckets[qualifier]
            else { return nil }
            return (candidate, qualifier, dpi)
        }
        var keptDensities = Set<String>()
        if !densitySplits.isEmpty {
            let atLeast = densitySplits.filter { $0.dpi >= guest.densityDPI }
            let pick =
                atLeast.isEmpty
                ? densitySplits.max { $0.dpi < $1.dpi }
                : atLeast.min { $0.dpi < $1.dpi }
            if let pick {
                keptDensities.insert(pick.qualifier)
            }
        }

        for candidate in candidates {
            if candidate.splitName == nil || candidate.attributes.isFeatureSplit {
                // Base and feature splits are always kept.
                included.append(candidate)
                continue
            }
            guard let qualifier = Self.configQualifier(of: candidate) else {
                // Not a config split by name: deferred to the configForSplit pass below.
                continue
            }
            if let abi = Self.abiQualifiers[qualifier] {
                if guest.abis.contains(abi) {
                    included.append(candidate)
                } else {
                    excluded.append(candidate.splitName ?? candidate.name)
                }
                continue
            }
            if Self.densityBuckets[qualifier] != nil {
                if keptDensities.contains(qualifier) {
                    included.append(candidate)
                } else {
                    excluded.append(candidate.splitName ?? candidate.name)
                }
                continue
            }
            // Language and unknown config qualifiers are kept.
            included.append(candidate)
        }

        // Other or unknown config splits: keep when they are `configForSplit` of an included split.
        var changed = true
        while changed {
            changed = false
            for candidate in candidates
            where !included.contains(where: { $0.name == candidate.name })
                && !excluded.contains(candidate.splitName ?? candidate.name)
            {
                if let target = candidate.attributes.configForSplit,
                    included.contains(where: { ($0.splitName ?? "") == target || $0.name == target })
                {
                    included.append(candidate)
                    changed = true
                }
            }
        }
        // Candidates still unclassified (no qualifier, no included parent) are excluded.
        for candidate in candidates
        where !included.contains(where: { $0.name == candidate.name })
            && !excluded.contains(candidate.splitName ?? candidate.name)
        {
            excluded.append(candidate.splitName ?? candidate.name)
        }

        // requiredSplitTypes of the base must be satisfied by the included splitTypes.
        if let base = candidates.first(where: { $0.splitName == nil }) {
            let includedTypes = Set(included.flatMap { $0.attributes.splitTypes })
            let missing = base.attributes.requiredSplitTypes.filter { !includedTypes.contains($0) }
            if !missing.isEmpty {
                throw .incompleteSplitSet(missing: missing)
            }
        }
        // isSplitRequired: a required split that was excluded breaks the set.
        let includedNames = Set(included.map { $0.splitName ?? $0.name })
        let missingRequired = candidates.filter {
            $0.attributes.isSplitRequired && !includedNames.contains($0.splitName ?? $0.name)
        }
        if !missingRequired.isEmpty {
            throw .incompleteSplitSet(missing: missingRequired.map { $0.splitName ?? $0.name })
        }

        return SplitSelection(included: included.map { $0.name }, excludedSplits: excluded)
    }

    /// The config qualifier of a `config.<qualifier>` or `<split>.config.<qualifier>` split name.
    private static func configQualifier(of candidate: SplitCandidate) -> String? {
        guard let split = candidate.splitName else { return nil }
        if split.hasPrefix("config.") {
            return String(split.dropFirst("config.".count))
        }
        if let marker = split.range(of: ".config.") {
            return String(split[marker.upperBound...])
        }
        return nil
    }
}
