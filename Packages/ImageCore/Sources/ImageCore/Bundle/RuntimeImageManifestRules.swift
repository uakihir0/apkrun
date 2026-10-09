import Foundation

/// The value rules of the manifest schema and the semantic rules S1–S14
/// (runtime-image-manifest.md §5, §7.2).
///
/// A violation names its rule as `apkrun_image.runtime_manifest` does: `schema` for a value
/// rule, `S1`…`S14` for a semantic rule. The shared fixtures in
/// `Images/tools/tests/fixtures/runtime-manifests/` hold both readers to the same answer.
/// Checks stop at the first violation, so the order below is part of the contract.
enum RuntimeImageManifestRules {
    /// One failed rule: its name, the JSON pointer, and a reason.
    struct Violation: Equatable, Sendable {
        let rule: String
        let path: String
        let reason: String
    }

    private struct Failure: Error {
        let violation: Violation
    }

    /// The first violation of the value rules, then of S1–S14; empty when the manifest passes.
    static func violations(of manifest: RuntimeImageManifest) -> [Violation] {
        do {
            try checkValues(manifest)
            try checkSemantics(manifest)
            return []
        } catch let failure as Failure {
            return [failure.violation]
        } catch {
            return []
        }
    }

    // MARK: Helpers

    private static func schema(_ condition: Bool, _ path: String, _ reason: String) throws {
        try expect(condition, rule: "schema", path: path, reason: reason)
    }

    private static func expect(_ condition: Bool, rule: String, path: String, reason: String) throws {
        if !condition {
            throw Failure(violation: Violation(rule: rule, path: path, reason: reason))
        }
    }

    /// True when the whole string matches the anchored pattern.
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return false
        }
        return range.lowerBound == text.startIndex && range.upperBound == text.endIndex
    }

    private static func isSHA256(_ text: String) -> Bool {
        matches(text, "^[0-9a-f]{64}$")
    }

    private static func isSemver(_ text: String) -> Bool {
        matches(text, "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")
    }

    private static func isShortImageVersion(_ text: String) -> Bool {
        matches(text, "^[0-9]{4}\\.(0[1-9]|1[0-2])\\.(0|[1-9][0-9]{0,2})$")
    }

    private static func isRepositoryPath(_ text: String) -> Bool {
        text.count <= 255
            && matches(text, "^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$")
            && !text.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == "." || $0 == ".." }
    }

    private static func isBundlePath(_ text: String) -> Bool {
        matches(text, "^(boot|disks|templates|legal)/[a-z0-9][a-z0-9._-]{0,63}$")
    }

    private static func isTreeRevision(_ text: String) -> Bool {
        matches(text, "^[0-9a-f]{40}(-dirty)?$")
    }

    private static func isBootconfigKey(_ text: String) -> Bool {
        text.count <= 256 && matches(text, "^[A-Za-z0-9_.-]+$")
    }

    /// The bootconfig value alphabet: printable ASCII without `"` and backslash, up to 1024.
    private static func isBootconfigValue(_ text: String) -> Bool {
        text.count <= 1024
            && text.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return (0x20...0x21).contains(value) || (0x23...0x5b).contains(value)
                    || (0x5d...0x7e).contains(value)
            }
    }

    private static func isUnique<T: Hashable>(_ values: [T]) -> Bool {
        Set(values).count == values.count
    }

    private static func checkFile(
        _ entry: RuntimeImageManifest.FileEntry, _ path: String, prefix: String? = nil
    ) throws {
        try schema(isBundlePath(entry.path), path + "/path", "not a bundle path")
        if let prefix {
            try schema(entry.path.hasPrefix(prefix), path + "/path", "must start with \(prefix)")
        }
        try schema((1...(UInt64(1) << 40)).contains(entry.size), path + "/size", "size out of range")
        try schema(isSHA256(entry.sha256), path + "/sha256", "not a SHA-256")
    }

    private static func checkDisk(_ disk: RuntimeImageManifest.Disk, _ path: String) throws {
        try schema(isBundlePath(disk.path), path + "/path", "not a bundle path")
        try schema(matches(disk.identifier, "^[a-z0-9][a-z0-9-]{0,19}$"), path + "/identifier", "identifier")
        let megabyte: UInt64 = 1 << 20
        try schema(
            disk.logicalSize >= 2 * megabyte && disk.logicalSize <= UInt64(1) << 40
                && disk.logicalSize % megabyte == 0,
            path + "/logicalSize", "must be a multiple of 1 MiB, at least 2 MiB, at most 1 TiB"
        )
        try schema((1...64).contains(disk.partitions.count), path + "/partitions", "1 to 64 partitions")
        for (index, partition) in disk.partitions.enumerated() {
            let base = "\(path)/partitions/\(index)"
            try schema(
                matches(partition.label, "^[a-z][a-z0-9_]{0,35}$"), base + "/label", "label"
            )
            try schema(
                partition.firstLBA >= 2048 && partition.firstLBA % 2048 == 0,
                base + "/firstLBA", "a multiple of 2048, at least 2048"
            )
            try schema(
                partition.size >= 512 && partition.size % 512 == 0,
                base + "/size", "a multiple of 512, at least 512"
            )
            try schema(isSHA256(partition.sha256), base + "/sha256", "not a SHA-256")
        }
    }

    // MARK: Schema value rules (§5)

    private static func checkValues(_ m: RuntimeImageManifest) throws {
        try schema(m.schemaVersion == 1, "/schemaVersion", "must be 1")

        let source = m.provenance.source
        try schema(
            ["ci.android.com", "apkrun-builder"].contains(source.origin),
            "/provenance/source/origin", "origin"
        )
        try schema(
            matches(source.branch, "^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$"),
            "/provenance/source/branch", "branch"
        )
        try schema(
            source.target.count <= 128
                && matches(source.target, "^[a-z0-9][a-z0-9_-]*-(user|userdebug|eng)$"),
            "/provenance/source/target", "target"
        )
        try schema(
            matches(source.buildId, "^([0-9]{1,20}|ar[0-9]{6})$"),
            "/provenance/source/buildId", "buildId"
        )
        try schema((1...8).contains(source.archives.count), "/provenance/source/archives", "1 to 8")
        for (index, archive) in source.archives.enumerated() {
            let base = "/provenance/source/archives/\(index)"
            try schema(
                matches(archive.name, "^[A-Za-z0-9._+-]{1,255}$"), base + "/name", "archive name"
            )
            try schema(archive.size >= 1, base + "/size", "must be at least 1")
            try schema(isSHA256(archive.sha256), base + "/sha256", "not a SHA-256")
        }
        let android = m.provenance.android
        try schema(
            matches(android.release, "^[1-9][0-9]*(\\.[0-9]+){0,2}$"),
            "/provenance/android/release", "release"
        )
        try schema((1...10000).contains(android.sdk), "/provenance/android/sdk", "SDK out of range")
        try schema(
            ["user", "userdebug", "eng"].contains(android.variant),
            "/provenance/android/variant", "variant"
        )
        try schema(
            matches(android.securityPatch, "^[0-9]{4}-(0[1-9]|1[0-2])$"),
            "/provenance/android/securityPatch", "securityPatch"
        )
        try schema(
            m.provenance.deviceFamily.count <= 64
                && matches(m.provenance.deviceFamily, "^[a-z0-9]+(-[a-z0-9]+)*$"),
            "/provenance/deviceFamily", "deviceFamily"
        )
        try schema(isRepositoryPath(m.provenance.layout.path), "/provenance/layout/path", "path")
        try schema(isSHA256(m.provenance.layout.sha256), "/provenance/layout/sha256", "not a SHA-256")
        if let reference = m.provenance.reference {
            try schema(isRepositoryPath(reference), "/provenance/reference", "reference path")
        }
        let tools = m.provenance.tools
        try schema(isSemver(tools.apkrunImage), "/provenance/tools/apkrunImage", "not a version")
        try schema(matches(tools.mkbootimg, "^[0-9a-f]{40}$"), "/provenance/tools/mkbootimg", "revision")
        try schema(matches(tools.avbtool, "^[0-9a-f]{40}$"), "/provenance/tools/avbtool", "revision")
        try schema(
            isTreeRevision(m.provenance.revisions.imagesTools),
            "/provenance/revisions/imagesTools", "revision"
        )
        if let guest = m.provenance.revisions.guest {
            try schema(isTreeRevision(guest), "/provenance/revisions/guest", "revision")
        }
        if let pinned = m.provenance.pinnedManifestSHA256 {
            try schema(isSHA256(pinned), "/provenance/pinnedManifestSHA256", "not a SHA-256")
        }
        if let digest = m.provenance.builderImageDigest {
            try schema(
                matches(digest, "^sha256:[0-9a-f]{64}$"),
                "/provenance/builderImageDigest", "digest"
            )
        }

        let guest = m.guest
        try schema((1...10000).contains(guest.sdk), "/guest/sdk", "SDK out of range")
        try schema(
            (1...8).contains(guest.abis.count) && isUnique(guest.abis)
                && guest.abis.allSatisfy({ matches($0, "^[a-z0-9_-]{1,32}$") })
                && guest.abis.contains("arm64-v8a"),
            "/guest/abis", "1 to 8 unique ABIs, including arm64-v8a"
        )
        try schema((1...10000).contains(guest.targetSdkFloor), "/guest/targetSdkFloor", "out of range")

        let boot = m.boot
        try checkFile(boot.kernel, "/boot/kernel", prefix: "boot/")
        try checkFile(boot.ramdisk, "/boot/ramdisk", prefix: "boot/")
        try checkFile(boot.bootconfig, "/boot/bootconfig", prefix: "boot/")
        try checkFile(boot.cmdline, "/boot/cmdline", prefix: "boot/")
        try schema([4096, 16384, 65536].contains(boot.kernelPageSize), "/boot/kernelPageSize", "page size")
        try schema(
            boot.bootconfigOverrides.count <= 64 && isUnique(boot.bootconfigOverrides)
                && boot.bootconfigOverrides.allSatisfy(isBootconfigKey),
            "/boot/bootconfigOverrides", "at most 64 unique bootconfig keys"
        )

        try schema(m.disks.count == 1, "/disks", "exactly one os disk")
        let os = m.disks[0]
        try schema(os.role == "os", "/disks/0/role", "must be os")
        try schema(os.path.hasPrefix("disks/"), "/disks/0/path", "must be under disks/")
        try schema(os.readOnly, "/disks/0/readOnly", "the os disk is read-only")
        try schema(os.userdataStrategy == nil, "/disks/0/userdataStrategy", "only for userdata")
        try checkDisk(os, "/disks/0")

        try schema(m.templates.count == 1, "/templates", "exactly one userdata template")
        let userdata = m.templates[0]
        try schema(userdata.role == "userdata", "/templates/0/role", "must be userdata")
        try schema(userdata.path.hasPrefix("templates/"), "/templates/0/path", "under templates/")
        try schema(!userdata.readOnly, "/templates/0/readOnly", "a template is writable")
        try schema(userdata.userdataStrategy != nil, "/templates/0/userdataStrategy", "required")
        try checkDisk(userdata, "/templates/0")

        try schema((1...32).contains(m.consolePorts.count), "/consolePorts", "1 to 32 ports")
        for (index, port) in m.consolePorts.enumerated() {
            try schema((0...31).contains(port.index), "/consolePorts/\(index)/index", "0 to 31")
            try schema(
                matches(port.name, "^[a-z][a-z0-9_]{0,31}$"),
                "/consolePorts/\(index)/name", "port name"
            )
        }

        let allowedProfiles: Set<String> = ["drmVirgl", "guestSwiftshader", "headless"]
        try schema(
            Set(m.gpuProfiles.keys).isSuperset(of: ["drmVirgl", "guestSwiftshader"])
                && Set(m.gpuProfiles.keys).isSubset(of: allowedProfiles),
            "/gpuProfiles", "drmVirgl and guestSwiftshader, and optionally headless"
        )
        for name in m.gpuProfiles.keys.sorted() {
            let profile = m.gpuProfiles[name]!
            let base = "/gpuProfiles/\(name)"
            try schema(profile.bootconfig.count <= 64, base + "/bootconfig", "at most 64 keys")
            for (key, value) in profile.bootconfig.sorted(by: { $0.key < $1.key }) {
                try schema(isBootconfigKey(key), base + "/bootconfig", "key \(key)")
                try schema(isBootconfigValue(value), base + "/bootconfig/\(key)", "value")
            }
            try schema(
                profile.overrides.count <= 64 && isUnique(profile.overrides)
                    && profile.overrides.allSatisfy(isBootconfigKey),
                base + "/overrides", "at most 64 unique keys"
            )
            try schema(
                isUnique(profile.requiredHostCapabilities)
                    && profile.requiredHostCapabilities.allSatisfy({ ["virgl", "edid"].contains($0) }),
                base + "/requiredHostCapabilities", "virgl or edid, unique"
            )
        }

        let requirements = m.requirements
        try schema(isSemver(requirements.minimumRuntimeVersion), "/requirements/minimumRuntimeVersion", "version")
        try schema(
            (1...65535).contains(requirements.guestProtocol.min)
                && (1...65535).contains(requirements.guestProtocol.max),
            "/requirements/guestProtocol", "majors 1 to 65535"
        )
        try schema((0...16).contains(requirements.agents.count), "/requirements/agents", "0 to 16")
        for (index, agent) in requirements.agents.enumerated() {
            let base = "/requirements/agents/\(index)"
            try schema(
                agent.package.count <= 255
                    && matches(agent.package, "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$"),
                base + "/package", "package name"
            )
            try schema(agent.versionCode >= 1, base + "/versionCode", "must be at least 1")
        }

        try schema(m.userdata.schemaVersion >= 1, "/userdata/schemaVersion", "at least 1")
        try schema(
            (1...64).contains(m.userdata.upgradableFrom.count)
                && isUnique(m.userdata.upgradableFrom)
                && m.userdata.upgradableFrom.allSatisfy({ $0 >= 1 }),
            "/userdata/upgradableFrom", "1 to 64 unique versions of at least 1"
        )
        try schema(
            isShortImageVersion(m.compatibility.upgradeFrom.minimumImageVersion),
            "/compatibility/upgradeFrom/minimumImageVersion", "short image version"
        )
        if let legal = m.legal {
            try checkFile(legal.notice, "/legal/notice", prefix: "legal/")
        }
        try schema((1...64).contains(m.files.count), "/files", "1 to 64 entries")
        for (index, entry) in m.files.enumerated() {
            try checkFile(entry, "/files/\(index)")
        }
    }

    // MARK: Semantic rules S1–S14 (§7.2)

    private static func checkSemantics(_ m: RuntimeImageManifest) throws {
        let source = m.provenance.source
        let base = m.imageVersion.description.split(separator: "-")[1]
        let expectedBase = source.origin == "ci.android.com" ? "cf" + source.buildId : source.buildId
        try expect(
            String(base) == expectedBase, rule: "S1", path: "/imageVersion",
            reason: "base \(base) must be \(expectedBase)"
        )
        try expect(
            (m.kind == .stock) == (source.origin == "ci.android.com"), rule: "S2", path: "/kind",
            reason: "kind is stock exactly when the origin is ci.android.com"
        )

        var files: [String: RuntimeImageManifest.FileEntry] = [:]
        for entry in m.files {
            files[entry.path] = entry
        }
        var named: [String: (size: UInt64, sha256: String?)] = [:]
        for entry in [m.boot.kernel, m.boot.ramdisk, m.boot.bootconfig, m.boot.cmdline] {
            named[entry.path] = (entry.size, Optional(entry.sha256))
        }
        for disk in m.disks + m.templates {
            named[disk.path] = (disk.logicalSize, nil as String?)
        }
        if let notice = m.legal?.notice {
            named[notice.path] = (notice.size, Optional(notice.sha256))
        }
        for path in named.keys.sorted() {
            let expected = named[path]!
            guard let entry = files[path] else {
                throw Failure(violation: Violation(rule: "S3", path: "/files", reason: "\(path) has no files entry"))
            }
            try expect(
                entry.size == expected.size && (expected.sha256 == nil || entry.sha256 == expected.sha256),
                rule: "S3", path: "/files", reason: "\(path) differs from its files entry"
            )
        }
        if let extra = files.keys.sorted().first(where: { named[$0] == nil }) {
            throw Failure(
                violation: Violation(rule: "S3", path: "/files", reason: "files lists \(extra), which no block names")
            )
        }

        let paths = m.files.map(\.path)
        try expect(
            paths == paths.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
                && isUnique(paths),
            rule: "S4", path: "/files", reason: "files must be sorted by path with no duplicates"
        )

        var labels: Set<String> = []
        var identifiers: Set<String> = []
        for (group, disks) in [("disks", m.disks), ("templates", m.templates)] {
            for (index, disk) in disks.enumerated() {
                try expect(
                    identifiers.insert(disk.identifier).inserted,
                    rule: "S6", path: "/\(group)/\(index)/identifier",
                    reason: "disk identifiers must be unique"
                )
                var lastEnd: UInt64 = 0
                let limit = disk.logicalSize / 512 - 34
                for (position, partition) in disk.partitions.enumerated() {
                    let pointer = "/\(group)/\(index)/partitions/\(position)"
                    let first = partition.firstLBA
                    let last = first + partition.size / 512 - 1
                    try expect(
                        first >= lastEnd, rule: "S5", path: pointer,
                        reason: "partitions must be ascending and not overlap"
                    )
                    try expect(
                        last <= limit, rule: "S5", path: pointer,
                        reason: "partition ends in the backup GPT area"
                    )
                    lastEnd = last + 1
                    try expect(
                        labels.insert(partition.label).inserted, rule: "S6",
                        path: pointer + "/label", reason: "partition labels must be unique"
                    )
                }
            }
        }

        for (index, port) in m.consolePorts.enumerated() {
            try expect(
                port.index == index, rule: "S7", path: "/consolePorts/\(index)/index",
                reason: "index must equal the array position"
            )
        }
        let systemCount = m.consolePorts.filter { $0.role == .systemConsole }.count
        try expect(
            systemCount == 1 && m.consolePorts.first?.role == .systemConsole, rule: "S7",
            path: "/consolePorts", reason: "exactly one systemConsole port, at index 0"
        )
        try expect(
            isUnique(m.consolePorts.map(\.name)), rule: "S7", path: "/consolePorts",
            reason: "port names must be unique"
        )

        for name in m.gpuProfiles.keys.sorted() {
            let profile = m.gpuProfiles[name]!
            let unknown = profile.overrides.filter { profile.bootconfig[$0] == nil }.sorted()
            try expect(
                unknown.isEmpty, rule: "S8", path: "/gpuProfiles/\(name)/overrides",
                reason: "\(unknown.first ?? "") is not a profile key"
            )
        }

        let protocolRange = m.requirements.guestProtocol
        try expect(
            protocolRange.min <= protocolRange.max, rule: "S9",
            path: "/requirements/guestProtocol", reason: "min must not exceed max"
        )

        let agents = m.requirements.agents.map(\.package)
        if m.kind == .stock {
            try expect(agents.isEmpty, rule: "S10", path: "/requirements/agents", reason: "a stock image has no agents")
        }
        if m.kind == .apkrun {
            try expect(
                Set(agents).isSuperset(of: ["io.apkrun.guest", "io.apkrun.store"]), rule: "S10",
                path: "/requirements/agents", reason: "an apkrun image lists the guest and store agents"
            )
        }
        try expect(isUnique(agents), rule: "S10", path: "/requirements/agents", reason: "agent packages must be unique")

        let versions = m.userdata.upgradableFrom
        try expect(
            versions == versions.sorted() && versions.contains(m.userdata.schemaVersion), rule: "S11",
            path: "/userdata/upgradableFrom", reason: "must ascend and contain the schemaVersion"
        )

        let minimum = m.compatibility.upgradeFrom.minimumImageVersion
        try expect(
            shortTriple(minimum) <= (m.imageVersion.year, m.imageVersion.month, m.imageVersion.sequence),
            rule: "S12",
            path: "/compatibility/upgradeFrom/minimumImageVersion", reason: "above this image"
        )

        let revisions = [
            m.provenance.revisions.guest,
            m.provenance.pinnedManifestSHA256,
            m.provenance.builderImageDigest,
        ]
        if m.kind == .apkrun {
            try expect(
                revisions.allSatisfy { $0 != nil }, rule: "S13", path: "/provenance",
                reason: "an apkrun image records the guest revision and pins"
            )
        }
        if m.kind == .stock {
            try expect(
                revisions.allSatisfy { $0 == nil }, rule: "S13", path: "/provenance",
                reason: "a stock image records no guest revision or pins"
            )
        }

        let sdk = m.provenance.android.sdk
        try expect(m.guest.sdk == sdk, rule: "S14", path: "/guest/sdk", reason: "must equal provenance.android.sdk")
        try expect(
            m.guest.targetSdkFloor == (sdk <= 34 ? 23 : 24), rule: "S14",
            path: "/guest/targetSdkFloor",
            reason: "must be 23 for SDK 34 and 24 for SDK 35 and later"
        )
    }

    /// `(year, month, sequence)` of a short image version, which the schema has checked.
    private static func shortTriple(_ text: String) -> (Int, Int, Int) {
        let parts = text.split(separator: ".").map { Int($0) ?? 0 }
        return (parts[0], parts[1], parts[2])
    }
}
