import Foundation
import ZIPFoundation

/// One APK after inspection: badging facts, signature result, and file facts from the ZIP.
struct InspectedAPK: Sendable {
    var file: ArtifactFile
    var facts: APKFacts
    var signature: APKSignatureInfo
    /// Native libraries found in the central directory (`lib/<abi>/*.so` → ABI names).
    var libraryABIs: [String]
    /// `resources.arsc` compression (true = stored uncompressed) and 4-byte alignment.
    var resourcesArscOK: Bool
    /// Permissions from `aapt2 dump badging` (`uses-permission` lines).
    var permissions: [String]
    /// `uses-feature android:required="true"` hardware the guest lacks.
    var requiredFeatures: [String]
    /// `android:debuggable="true"`.
    var debuggable: Bool
    /// Selection attributes from the manifest.
    var attributes: SplitAttributes

    init(
        file: ArtifactFile,
        facts: APKFacts,
        signature: APKSignatureInfo,
        libraryABIs: [String] = [],
        resourcesArscOK: Bool = true,
        permissions: [String] = [],
        requiredFeatures: [String] = [],
        debuggable: Bool = false,
        attributes: SplitAttributes = SplitAttributes()
    ) {
        self.file = file
        self.facts = facts
        self.signature = signature
        self.libraryABIs = libraryABIs
        self.resourcesArscOK = resourcesArscOK
        self.permissions = permissions
        self.requiredFeatures = requiredFeatures
        self.debuggable = debuggable
        self.attributes = attributes
    }
}

/// The result of a verified set: the ordered artifact files, signer set, lineage, warnings.
struct VerifiedArtifactSet: Sendable {
    var files: [InspectedAPK]
    var signerDigests: [SHA256Digest]
    var lineage: [SHA256Digest]
    var warnings: [ImportWarning]

}

/// Non-blocking observations of package-store.md §4.6 (warnings reach the preview and inspect).
public enum ImportWarning: Codable, Sendable, Equatable {
    case missingHardwareFeature(feature: String)
    case certificateOnlyVerification
    case debuggable
    case lowTargetSDK(target: Int)
}

/// Runs the intrinsic checks I1–I12 and the warnings of package-store.md §4.6.
struct ArtifactVerifier: Sendable {
    /// Packages that APKRun or the image reserves (I10).
    static let reservedPackages: Set<String> = [
        "io.apkrun.guest",
        "io.apkrun.store",
    ]

    /// Verifies one inspected set against the guest facts (package-store.md §4.6).
    ///
    /// `guestSDK` is 37 on the baseline image; `installFloor` is 24 on API 35+; `guestABIs`
    /// defaults to `arm64-v8a`. I1 (container limits) ran in `ContainerReader`.
    func verify(
        set files: [InspectedAPK],
        guest: SplitSelector.GuestFacts = SplitSelector.GuestFacts()
    ) throws(StoreFailure) -> VerifiedArtifactSet {
        guard !files.isEmpty else { throw .missingBase }

        // I3: exactly one base, unique split names.
        let bases = files.filter { $0.facts.splitName == nil }
        guard !bases.isEmpty else { throw .missingBase }
        guard bases.count == 1 else { throw .multipleBases }
        var seenSplits = Set<String>()
        for file in files {
            if let split = file.facts.splitName, !seenSplits.insert(split).inserted {
                throw .duplicateSplit(split)
            }
        }
        let base = bases[0]

        // I4: same package and VersionCode in every APK.
        for file in files {
            if file.facts.packageID != base.facts.packageID {
                throw .inconsistentSplits(.package, file: file.file.name)
            }
            if file.facts.versionCode != base.facts.versionCode {
                throw .inconsistentSplits(.versionCode, file: file.file.name)
            }
        }

        // I5: same signer set in every APK (signature validity ran in APKSignatureVerifier).
        for file in files where file.signature.signerDigests != base.signature.signerDigests {
            throw .inconsistentSplits(.signer, file: file.file.name)
        }

        // I7: native code must cover a guest ABI when present.
        let allABIs = Set(
            files.flatMap { file in
                file.libraryABIs.isEmpty ? file.facts.nativeABIs : file.libraryABIs
            })
        if !allABIs.isEmpty {
            let covered = files.contains { file in
                let abis = file.libraryABIs.isEmpty ? file.facts.nativeABIs : file.libraryABIs
                return !abis.isEmpty && abis.contains(where: { guest.abis.contains($0) })
            }
            guard covered else {
                throw .unsupportedABI(found: allABIs.sorted(), supported: guest.abis)
            }
        }

        // I8/I9: SDK bounds.
        for file in files where file.facts.minSDK > guest.sdk {
            throw .minSdkTooHigh(required: file.facts.minSDK, guest: guest.sdk)
        }
        for file in files where file.facts.targetSDK < guest.installFloor {
            throw .targetSdkTooLow(target: file.facts.targetSDK, floor: guest.installFloor)
        }

        // I10: reserved packages.
        if Self.reservedPackages.contains(base.facts.packageID.rawValue) {
            throw .reservedPackage(base.facts.packageID)
        }

        // I11: sizes (re-checked on the real files).
        var total: Int64 = 0
        for file in files {
            total += file.file.size
            guard file.file.size <= ContainerReader.maxFileBytes,
                total <= ContainerReader.maxTotalBytes
            else {
                throw .tooLarge(
                    bytes: file.file.size <= ContainerReader.maxFileBytes ? total : file.file.size,
                    limit: file.file.size <= ContainerReader.maxFileBytes
                        ? ContainerReader.maxTotalBytes : ContainerReader.maxFileBytes)
            }
        }

        // I12: resources.arsc stored and 4-byte aligned at targetSdk >= 30.
        for file in files where file.facts.targetSDK >= 30 && !file.resourcesArscOK {
            throw .resourcesArscNotAligned(file: file.file.name)
        }

        // Warnings.
        var warnings: [ImportWarning] = []
        if files.contains(where: { $0.signature.level == .certificateOnly }) {
            warnings.append(.certificateOnlyVerification)
        }
        for file in files {
            for feature in file.requiredFeatures {
                warnings.append(.missingHardwareFeature(feature: feature))
            }
            if file.debuggable { warnings.append(.debuggable) }
        }
        if base.facts.targetSDK < 28 {
            warnings.append(.lowTargetSDK(target: base.facts.targetSDK))
        }

        return VerifiedArtifactSet(
            files: files,
            signerDigests: base.signature.signerDigests,
            lineage: base.signature.lineage,
            warnings: warnings
        )
    }

    /// Reads file facts from an APK's central directory: library ABIs and resources.arsc
    /// storage/alignment (I7's cross-check and I12).
    static func zipFacts(of url: URL) -> (libraryABIs: [String], resourcesArscOK: Bool) {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return ([], true)
        }
        // Scan local headers: cheaper than finding the EOCD and covers what I7/I12 need.
        var abis = Set<String>()
        var arscOK = true
        var index = 0
        while index + 30 <= data.count {
            guard data[index] == 0x50, data[index + 1] == 0x4B,
                data[index + 2] == 0x03, data[index + 3] == 0x04
            else {
                index += 1
                continue
            }
            let nameLength = Int(data[index + 26]) | Int(data[index + 27]) << 8
            let extraLength = Int(data[index + 28]) | Int(data[index + 29]) << 8
            let compressedSize = Int(data[index + 18]) | Int(data[index + 19]) << 8
                | Int(data[index + 20]) << 16 | Int(data[index + 21]) << 24
            let nameEnd = index + 30 + nameLength
            guard nameEnd <= data.count else { break }
            let name = String(decoding: data[(index + 30)..<nameEnd], as: UTF8.self)
            let compression = Int(data[index + 8]) | Int(data[index + 9]) << 8
            if name.hasPrefix("lib/"), name.hasSuffix(".so") {
                let parts = name.split(separator: "/")
                if parts.count == 3 { abis.insert(String(parts[1])) }
            }
            if name == "resources.arsc" {
                let dataStart = nameEnd + extraLength
                arscOK = compression == 0 && dataStart % 4 == 0
            }
            // Skip the entry's compressed data; entries written with a data descriptor
            // carry size 0 here, and the signature scan finds the next header instead.
            let next = nameEnd + extraLength + compressedSize
            index = next > index ? next : index + 4
        }
        return (abis.sorted(), arscOK)
    }
}
