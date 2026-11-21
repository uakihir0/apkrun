import APKStoreCore
import Foundation

/// The `entry.json` of a signed F-Droid v2 repository (update-system.md §4.5,
/// `Entry` in the F-Droid index format).
public struct FDroidEntry: Codable, Sendable, Equatable {
    /// Milliseconds since the epoch; also the `diffs` key of the matching base.
    public var timestamp: Int64
    /// The index format version; 20001+ is v2.
    public var version: Int64?
    /// The full index file.
    public var index: File
    /// Available diffs, keyed by the timestamp of the index they patch.
    public var diffs: [String: File]

    /// An `EntryFileV2`: a named file with integrity data.
    public struct File: Codable, Sendable, Equatable {
        /// The file name relative to the repository URL.
        public var name: String
        /// 64 lowercase hex digits.
        public var sha256: String
        /// The byte size.
        public var size: Int64
        /// The number of packages inside; informational.
        public var numPackages: Int?

        /// Creates an entry file reference.
        public init(name: String, sha256: String, size: Int64, numPackages: Int? = nil) {
            self.name = name
            self.sha256 = sha256
            self.size = size
            self.numPackages = numPackages
        }
    }

    /// Creates an entry document.
    public init(timestamp: Int64, version: Int64? = nil, index: File, diffs: [String: File] = [:]) {
        self.timestamp = timestamp
        self.version = version
        self.index = index
        self.diffs = diffs
    }
}

/// The parts of `PackageVersionV2` the update check needs (update-system.md
/// §4.5). `versions` is keyed by the APK file's SHA-256.
public struct FDroidPackage: Codable, Sendable {
    /// The package's versions, keyed by the artifact's SHA-256.
    public var versions: [String: Version]

    /// One `PackageVersionV2`.
    public struct Version: Codable, Sendable {
        /// The APK file, with a required SHA-256 (`FileV1`).
        public var file: File
        /// The Android manifest fields.
        public var manifest: Manifest

        /// `FileV1`: `sha256` is always present for real packages.
        public struct File: Codable, Sendable {
            /// The file name relative to the repository URL.
            public var name: String
            /// 64 hex digits; nil only on malformed input.
            public var sha256: String?
            /// The byte size.
            public var size: Int64?
        }

        /// `ManifestV2`: the manifest fields the index carries.
        public struct Manifest: Codable, Sendable {
            /// The display version name.
            public var versionName: String?
            /// Android `longVersionCode`.
            public var versionCode: Int64
            /// The declared SDK window; absent means unconstrained.
            public var usesSdk: UsesSdk?
            /// A hard maximum SDK level.
            public var maxSdkVersion: Int?
            /// The APK's signing certificates as SHA-256 hex.
            public var signer: Signer?
            /// The ABIs the APK ships; empty means universal.
            public var nativecode: [String]

            /// `UsesSdkV2`.
            public struct UsesSdk: Codable, Sendable {
                /// The declared minimum; nil means no constraint.
                public var minSdkVersion: Int?
                /// The target; not needed for filtering.
                public var targetSdkVersion: Int?
            }

            /// `SignerV2`.
            public struct Signer: Codable, Sendable {
                /// One SHA-256 hex digest per signing certificate.
                public var sha256: [String]
            }
        }
    }
}

/// Byte-level JSON object scanning for the streaming reader (update-system.md
/// §4.5 "streaming JSON reader"). Reads top-level object members without
/// materializing their values.
enum JSONMemberScanner {
    /// The `(key, valueByteRange)` pairs of a top-level object's member named
    /// `member`, which must itself be an object. Returns nil when the shape
    /// differs.
    static func members(of member: String, in data: Data) -> [(String, Range<Int>)]? {
        guard let memberRange = objectValue(of: member, in: data, range: data.indices) else {
            return nil
        }
        return members(in: data, range: memberRange)
    }

    /// The byte range of the value of `key` inside the object spanning
    /// `range`, or nil.
    static func objectValue(of key: String, in data: Data, range: Range<Int>) -> Range<Int>? {
        members(in: data, range: range)?.first(where: { $0.0 == key })?.1
    }

    /// Every `(key, valueRange)` of the JSON object spanning `range`.
    static func members(in data: Data, range: Range<Int>) -> [(String, Range<Int>)]? {
        var cursor = skipSpace(in: data, from: range.lowerBound, limit: range.upperBound)
        guard cursor < range.upperBound, data[cursor] == UInt8(ascii: "{") else { return nil }
        cursor += 1
        var result: [(String, Range<Int>)] = []
        while cursor < range.upperBound {
            cursor = skipSpace(in: data, from: cursor, limit: range.upperBound)
            if data[cursor] == UInt8(ascii: "}") { return result }
            guard let (key, keyEnd) = string(in: data, from: cursor, limit: range.upperBound) else {
                return nil
            }
            cursor = skipSpace(in: data, from: keyEnd, limit: range.upperBound)
            guard cursor < range.upperBound, data[cursor] == UInt8(ascii: ":") else { return nil }
            cursor = skipSpace(in: data, from: cursor + 1, limit: range.upperBound)
            guard let valueEnd = valueEnd(in: data, from: cursor, limit: range.upperBound) else {
                return nil
            }
            result.append((key, cursor..<valueEnd))
            cursor = skipSpace(in: data, from: valueEnd, limit: range.upperBound)
            guard cursor < range.upperBound else { return nil }
            if data[cursor] == UInt8(ascii: "}") { return result }
            guard data[cursor] == UInt8(ascii: ",") else { return nil }
            cursor += 1
        }
        return nil
    }

    /// The index one past a scalar/object/array/string starting at `start`.
    private static func valueEnd(in data: Data, from start: Int, limit: Int) -> Int? {
        guard start < limit else { return nil }
        switch data[start] {
        case UInt8(ascii: "{"):
            return containerEnd(in: data, from: start, limit: limit, open: UInt8(ascii: "{"), close: UInt8(ascii: "}"))
        case UInt8(ascii: "["):
            return containerEnd(in: data, from: start, limit: limit, open: UInt8(ascii: "["), close: UInt8(ascii: "]"))
        case UInt8(ascii: "\""):
            return string(in: data, from: start, limit: limit)?.1
        default:
            var cursor = start
            while cursor < limit,
                ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D]
                    .contains(data[cursor])
            {
                cursor += 1
            }
            return cursor > start ? cursor : nil
        }
    }

    /// The index one past the matching close of the container at `start`
    /// (`data[start]` must be `open`).
    private static func containerEnd(
        in data: Data, from start: Int, limit: Int, open: UInt8, close: UInt8
    ) -> Int? {
        var depth = 0
        var cursor = start
        while cursor < limit {
            let byte = data[cursor]
            if byte == UInt8(ascii: "\"") {
                guard let end = stringEnd(in: data, from: cursor, limit: limit) else { return nil }
                cursor = end
                continue
            }
            if byte == open { depth += 1 }
            if byte == close {
                depth -= 1
                if depth == 0 { return cursor + 1 }
            }
            cursor += 1
        }
        return nil
    }

    /// The decoded string and the index one past it; nil on bad JSON.
    private static func string(in data: Data, from start: Int, limit: Int) -> (String, Int)? {
        guard let end = stringEnd(in: data, from: start, limit: limit) else { return nil }
        guard
            let decoded = try? JSONDecoder().decode(
                String.self, from: data[start..<end])
        else { return nil }
        return (decoded, end)
    }

    /// The index one past the JSON string starting at `start`, handling
    /// escapes. Keys are short; `\uXXXX` needs no byte-level care because a
    /// backslash always escapes the next byte.
    private static func stringEnd(in data: Data, from start: Int, limit: Int) -> Int? {
        guard start < limit, data[start] == UInt8(ascii: "\"") else { return nil }
        var cursor = start + 1
        while cursor < limit {
            switch data[cursor] {
            case UInt8(ascii: "\\"):
                cursor += 2
            case UInt8(ascii: "\""):
                return cursor + 1
            default:
                cursor += 1
            }
        }
        return nil
    }

    private static func skipSpace(in data: Data, from start: Int, limit: Int) -> Int {
        var cursor = start
        while cursor < limit, [0x20, 0x09, 0x0A, 0x0D].contains(data[cursor]) { cursor += 1 }
        return cursor
    }
}

/// RFC 7396 JSON Merge Patch for F-Droid index diffs (update-system.md §4.5).
/// Objects merge recursively; a null member deletes; anything else replaces.
enum JSONMergePatch {
    /// Applies `patch` to `target` and returns the merged value. Both are
    /// `JSONSerialization` objects ([String: Any], [Any], scalars, NSNull).
    static func apply(_ patch: Any, to target: Any) -> Any {
        guard let patchObject = patch as? [String: Any] else { return patch }
        var result = (target as? [String: Any]) ?? [:]
        for (key, value) in patchObject {
            if value is NSNull {
                result.removeValue(forKey: key)
            } else {
                result[key] = apply(value, to: result[key] as Any)
            }
        }
        return result
    }
}

/// The F-Droid index reader (update-system.md §4.5): a byte-level package
/// extractor that decodes only the kept packages, plus the diff merge over
/// the cached index bytes. The decode path stays inside a 64 MiB budget.
public struct FDroidIndexReader: Sendable {
    /// The total index bytes the reader accepts (update-system.md §4.5).
    public static let indexByteLimit = 67_108_864

    /// Creates a reader.
    public init() {}

    /// The kept packages of an index document: only `keep` package IDs are
    /// decoded; other members are scanned byte-wise and skipped.
    /// - Throws: `providerMetadataInvalid` when the document is malformed or
    ///   over the byte budget.
    public func packages(in data: Data, keep: Set<PackageID>) throws(UpdateFailure) -> [PackageID:
        FDroidPackage]
    {
        guard data.count <= Self.indexByteLimit else {
            throw .providerMetadataInvalid(detail: "index: over 64 MiB")
        }
        guard let members = JSONMemberScanner.members(of: "packages", in: data) else {
            throw .providerMetadataInvalid(detail: "index: no packages object")
        }
        let wanted = Set(keep.map(\.rawValue))
        var result: [PackageID: FDroidPackage] = [:]
        for (name, range) in members where wanted.contains(name) {
            let slice = data.subdata(in: range)
            guard let id = PackageID(rawValue: name),
                let package = try? JSONDecoder().decode(FDroidPackage.self, from: slice)
            else {
                throw .providerMetadataInvalid(detail: "index: malformed package \(name)")
            }
            result[id] = package
        }
        return result
    }

    /// The raw byte ranges of every top-level `packages` member — the merge
    /// path copies untouched members without decoding them.
    static func packageMembers(in data: Data) throws(UpdateFailure) -> [(String, Range<Int>)] {
        guard let members = JSONMemberScanner.members(of: "packages", in: data) else {
            throw .providerMetadataInvalid(detail: "index: no packages object")
        }
        return members
    }

    /// The byte range of the top-level `repo` member, for the diff merge.
    static func repoRange(in data: Data) -> Range<Int>? {
        JSONMemberScanner.objectValue(of: "repo", in: data, range: data.indices)
    }

    /// Merges an RFC 7396 diff into the cached index bytes, one top-level
    /// member at a time, and returns the merged index. Package members that
    /// the diff does not touch are copied without decoding.
    /// - Throws: `providerMetadataInvalid` on malformed input or an over-limit
    ///   result.
    public func merged(index data: Data, diff diffData: Data) throws(UpdateFailure) -> Data {
        guard data.count <= Self.indexByteLimit, diffData.count <= Self.indexByteLimit else {
            throw .providerMetadataInvalid(detail: "index or diff: over 64 MiB")
        }
        guard let patch = try? JSONSerialization.jsonObject(with: diffData),
            let patchObject = patch as? [String: Any]
        else {
            throw .providerMetadataInvalid(detail: "diff: not a JSON object")
        }

        // Top-level members other than `packages` merge wholesale (only
        // `repo` exists in IndexV2; unknown members merge or replace).
        var topLevel: [String: Any] = [:]
        var packageSlices: [(String, Data)] = []
        for (name, range) in try Self.topLevelMembers(in: data) {
            if name == "packages" {
                guard let members = JSONMemberScanner.members(in: data, range: range) else {
                    throw .providerMetadataInvalid(detail: "index: malformed packages object")
                }
                packageSlices = members.map { ($0.0, data.subdata(in: $0.1)) }
            } else {
                guard
                    let value = try? JSONSerialization.jsonObject(
                        with: data.subdata(in: range), options: [.fragmentsAllowed])
                else {
                    throw .providerMetadataInvalid(detail: "index: malformed member \(name)")
                }
                topLevel[name] = value
            }
        }

        for (key, value) in patchObject where key != "packages" {
            if value is NSNull {
                topLevel.removeValue(forKey: key)
            } else {
                topLevel[key] = JSONMergePatch.apply(value, to: topLevel[key] as Any)
            }
        }

        // Merge packages member-wise so untouched members keep their raw
        // bytes; decoding the whole map would defeat the byte budget.
        var packagePatch: [String: Any] = [:]
        if let value = patchObject["packages"] {
            guard let object = value as? [String: Any] else {
                throw .providerMetadataInvalid(detail: "diff: packages is not an object")
            }
            packagePatch = object
        }
        var patchedIDs = Set<String>()
        var mergedPackages: [(String, Data)] = []
        mergedPackages.reserveCapacity(packageSlices.count + packagePatch.count)
        for (name, raw) in packageSlices {
            guard let patchValue = packagePatch[name] else {
                mergedPackages.append((name, raw))
                continue
            }
            patchedIDs.insert(name)
            if patchValue is NSNull { continue }
            guard
                let target = try? JSONSerialization.jsonObject(
                    with: raw, options: [.fragmentsAllowed]),
                let merged = try? JSONSerialization.data(
                    withJSONObject: JSONMergePatch.apply(patchValue, to: target))
            else {
                throw .providerMetadataInvalid(detail: "diff: cannot merge package \(name)")
            }
            mergedPackages.append((name, merged))
        }
        for (name, patchValue) in packagePatch where !patchedIDs.contains(name) {
            if patchValue is NSNull { continue }
            let merged = JSONMergePatch.apply(patchValue, to: [String: Any]())
            guard let encoded = try? JSONSerialization.data(withJSONObject: merged)
            else {
                throw .providerMetadataInvalid(detail: "diff: cannot add package \(name)")
            }
            mergedPackages.append((name, encoded))
        }

        var output = Data()
        output.reserveCapacity(data.count)
        output.append(UInt8(ascii: "{"))
        var first = true
        func emit(_ name: String, _ raw: Data) {
            if !first { output.append(UInt8(ascii: ",")) }
            first = false
            let key =
                (try? JSONSerialization.data(
                    withJSONObject: name, options: [.fragmentsAllowed])) ?? Data()
            output.append(key)
            output.append(UInt8(ascii: ":"))
            output.append(raw)
        }
        for (key, value) in topLevel.sorted(by: { $0.key < $1.key }) {
            guard
                let raw = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            else {
                throw .providerMetadataInvalid(detail: "index: cannot re-encode \(key)")
            }
            emit(key, raw)
        }
        var packagesData = Data()
        packagesData.append(UInt8(ascii: "{"))
        for (index, pair) in mergedPackages.enumerated() {
            if index > 0 { packagesData.append(UInt8(ascii: ",")) }
            let key =
                (try? JSONSerialization.data(
                    withJSONObject: pair.0, options: [.fragmentsAllowed])) ?? Data()
            packagesData.append(key)
            packagesData.append(UInt8(ascii: ":"))
            packagesData.append(pair.1)
        }
        packagesData.append(UInt8(ascii: "}"))
        emit("packages", packagesData)
        output.append(UInt8(ascii: "}"))
        guard output.count <= Self.indexByteLimit else {
            throw .providerMetadataInvalid(detail: "merged index: over 64 MiB")
        }
        return output
    }

    /// Every top-level member of the index object.
    private static func topLevelMembers(in data: Data) throws(UpdateFailure) -> [(
        String, Range<Int>
    )] {
        guard let members = JSONMemberScanner.members(in: data, range: data.indices) else {
            throw .providerMetadataInvalid(detail: "index: not a JSON object")
        }
        return members
    }
}
