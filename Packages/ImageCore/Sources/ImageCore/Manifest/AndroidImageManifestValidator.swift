import Foundation

/// Runs the Android image manifest checks that do not read image files.
public struct AndroidImageManifestValidator: Sendable {
    /// Creates a stateless manifest validator.
    public init() {}

    /// Validates the manifest-only M1–M3, M5, M7–M9, M14, and M15 rules.
    public func validate(_ manifest: AndroidImageManifest) throws(ImageFailure) {
        guard manifest.schemaVersion == 1 else {
            let reason =
                manifest.schemaVersion > 1
                ? "android-image.json: schemaVersion \(manifest.schemaVersion) is newer than this tool supports (1). Update Images/tools."
                : "android-image.json: schemaVersion \(manifest.schemaVersion) is invalid; supported version is 1."
            throw .manifestInvalid(path: "android-image.json", reason: reason)
        }

        let artifacts = manifest.artifacts
        var seenIDs: Set<String> = []
        let knownIDs = artifacts.map(\.id).filter { seenIDs.insert($0).inserted }
            .joined(separator: ", ")
        let roleReferences: [(String, String)] =
            [
                ("roles.kernel", manifest.roles.kernel),
                ("roles.genericRamdisk", manifest.roles.genericRamdisk),
                ("roles.vendorBoot", manifest.roles.vendorBoot),
            ]
            + manifest.roles.vbmeta.enumerated().map {
                ("roles.vbmeta[\($0.offset)]", $0.element)
            } + [
                ("roles.super", manifest.roles.`super`)
            ]
            + (manifest.roles.userdataTemplate.map {
                [("roles.userdataTemplate", $0)]
            } ?? [])

        for (role, identifier) in roleReferences where !artifacts.contains(where: { $0.id == identifier }) {
            let known = knownIDs.isEmpty ? "none" : knownIDs
            throw .manifestInvalid(
                path: "android-image.json",
                reason:
                    "\(role) = \"\(manifestDiagnosticValue(identifier))\": "
                    + "no artifact with that id. Known ids: "
                    + "\(manifestDiagnosticValue(known))."
            )
        }

        let roleKinds: [(String, String, [String], String)] =
            [
                ("kernel", manifest.roles.kernel, ["bootImage"], "boot"),
                ("genericRamdisk", manifest.roles.genericRamdisk, ["bootImage"], "init_boot"),
                ("vendorBoot", manifest.roles.vendorBoot, ["vendorBootImage"], "vendor_boot"),
                ("super", manifest.roles.`super`, ["dynamicPartitions", "sparse"], "super"),
            ]
            + (manifest.roles.userdataTemplate.map {
                [("userdataTemplate", $0, ["filesystem", "sparse"], "userdata")]
            } ?? [])

        for (role, identifier, allowedKinds, expectedPartition) in roleKinds {
            guard let index = artifacts.firstIndex(where: { $0.id == identifier }) else {
                continue
            }
            let artifact = artifacts[index]
            guard allowedKinds.contains(artifact.kind), artifact.partition == expectedPartition else {
                let expected = "\(allowedKinds.joined(separator: " or ")) on partition \(expectedPartition)"
                throw .manifestInvalid(
                    path: "android-image.json",
                    reason:
                        "artifacts[\(index)] (role \(role)): expected kind \(expected), "
                        + "found \(manifestDiagnosticValue(artifact.kind)) on partition "
                        + "\(manifestDiagnosticValue(artifact.partition)). Is the file swapped?"
                )
            }
        }

        for (position, identifier) in manifest.roles.vbmeta.enumerated() {
            guard let index = artifacts.firstIndex(where: { $0.id == identifier }) else {
                continue
            }
            let artifact = artifacts[index]
            let expectedPartition = position == 0 ? " on partition vbmeta" : ""
            guard artifact.kind == "vbmeta",
                position != 0 || artifact.partition == "vbmeta"
            else {
                throw .manifestInvalid(
                    path: "android-image.json",
                    reason:
                        "artifacts[\(index)] (role roles.vbmeta[\(position)]): expected "
                        + "kind vbmeta\(expectedPartition), found "
                        + "\(manifestDiagnosticValue(artifact.kind)) on partition "
                        + "\(manifestDiagnosticValue(artifact.partition)). Is the file swapped?"
                )
            }
        }

        let listedVBMetaIDs = Set(manifest.roles.vbmeta)
        for (index, artifact) in artifacts.enumerated()
        where artifact.kind == "vbmeta" && !listedVBMetaIDs.contains(artifact.id) {
            throw .manifestInvalid(
                path: "android-image.json",
                reason:
                    "artifacts[\(index)] (vbmeta): id "
                    + "\"\(manifestDiagnosticValue(artifact.id))\" is missing from "
                    + "roles.vbmeta. Add it to the chain order."
            )
        }

        guard manifest.architecture == "arm64" else {
            throw .manifestInvalid(
                path: "android-image.json",
                reason:
                    "architecture \(manifestDiagnosticValue(manifest.architecture)) "
                    + "is not supported. Use an arm64 target."
            )
        }

        var partitionLocations: [String: String] = [:]
        for (index, artifact) in artifacts.enumerated() {
            let location = "artifacts[\(index)]"
            if let previous = partitionLocations[artifact.partition] {
                throw .manifestInvalid(
                    path: "android-image.json",
                    reason:
                        "partition \"\(manifestDiagnosticValue(artifact.partition))\" "
                        + "appears in \(previous) and \(location)."
                )
            }
            partitionLocations[artifact.partition] = location
        }
        for (index, partition) in manifest.blankPartitions.enumerated() {
            let location = "blankPartitions[\(index)]"
            if let previous = partitionLocations[partition.partition] {
                throw .manifestInvalid(
                    path: "android-image.json",
                    reason:
                        "partition \"\(manifestDiagnosticValue(partition.partition))\" "
                        + "appears in \(previous) and \(location)."
                )
            }
            partitionLocations[partition.partition] = location
        }

        var artifactIDLocations: [String: Int] = [:]
        for (index, artifact) in artifacts.enumerated() {
            if let previous = artifactIDLocations[artifact.id] {
                throw .manifestInvalid(
                    path: "android-image.json",
                    reason:
                        "artifact id \"\(manifestDiagnosticValue(artifact.id))\" appears in "
                        + "artifacts[\(previous)] and artifacts[\(index)]."
                )
            }
            artifactIDLocations[artifact.id] = index
        }

        let targetVariant = manifest.source.target.split(separator: "-").last.map(String.init)
        guard targetVariant == manifest.android.variant else {
            throw .manifestInvalid(
                path: "android-image.json",
                reason:
                    "android.variant \"\(manifestDiagnosticValue(manifest.android.variant))\" "
                    + "does not match target "
                    + "\(manifestDiagnosticValue(manifest.source.target))."
            )
        }

        let buildIDBytes = Array(manifest.source.buildId.utf8)
        let isNumericBuildID =
            !buildIDBytes.isEmpty && buildIDBytes.allSatisfy { (48...57).contains($0) }
        let builderBuildIDSuffix = buildIDBytes.dropFirst(2)
        let isBuilderBuildID =
            buildIDBytes.starts(with: [97, 114])
            && builderBuildIDSuffix.count == 6
            && builderBuildIDSuffix.allSatisfy { (48...57).contains($0) }
        let buildIDMatchesOrigin =
            (manifest.source.origin == "ci.android.com" && isNumericBuildID)
            || (manifest.source.origin == "apkrun-builder" && isBuilderBuildID)
        if !buildIDMatchesOrigin {
            let expectedFormat =
                manifest.source.origin == "ci.android.com"
                ? "a numeric build ID"
                : "an ar-prefixed six-digit build ID"
            throw .manifestInvalid(
                path: "android-image.json",
                reason:
                    "source.buildId \"\(manifestDiagnosticValue(manifest.source.buildId))\" "
                    + "does not match origin "
                    + "\(manifestDiagnosticValue(manifest.source.origin)). Use \(expectedFormat)."
            )
        }

        var logicalPartitionLocations: [String: Int] = [:]
        for (index, partition) in manifest.logicalPartitions.enumerated() {
            if let previous = logicalPartitionLocations[partition.name] {
                throw .manifestInvalid(
                    path: "android-image.json",
                    reason:
                        "logicalPartitions[\(index)].name "
                        + "\"\(manifestDiagnosticValue(partition.name))\" duplicates "
                        + "logicalPartitions[\(previous)].name. "
                        + "Use a unique logical partition name."
                )
            }
            logicalPartitionLocations[partition.name] = index
        }
    }
}
