import CryptoKit
import Foundation
import Security
import zlib

/// How much of the signature the host could check (package-store.md §4.5).
enum SignatureLevel: String, Codable, Sendable, Equatable {
    /// v2, v3, or v3.1 content digests and signer signatures verified.
    case verified
    /// v3.2 hybrid: classic signature verified; the ML-DSA part is left to Android.
    case verifiedHybrid
    /// v1-only or an algorithm Security.framework lacks: the signer certificate is read but
    /// Android remains the verifier. Shown as the certificate-only warning.
    case certificateOnly
}

/// The signing scheme that verified the APK.
enum SignatureScheme: String, Codable, Sendable, Equatable {
    case v2
    case v3
    case v31
    case v32
    case jarOnly
}

/// The signer set, lineage, scheme, and verification level of one APK.
struct APKSignatureInfo: Sendable, Equatable {
    /// SHA-256 digests of each signer's DER certificate, in signer order.
    var signerDigests: [SHA256Digest]
    /// The picked scheme.
    var scheme: SignatureScheme
    /// The verification level.
    var level: SignatureLevel
    /// The signing lineage oldest → newest when a rotation attribute is present.
    var lineage: [SHA256Digest]
    /// The lineage nodes with capability flags, oldest → newest. Empty when
    /// the APK carries no proof-of-rotation attribute.
    var lineageNodes: [SignerLineageNode]

    init(
        signerDigests: [SHA256Digest],
        scheme: SignatureScheme,
        level: SignatureLevel,
        lineage: [SHA256Digest] = [],
        lineageNodes: [SignerLineageNode] = []
    ) {
        self.signerDigests = signerDigests
        self.scheme = scheme
        self.level = level
        self.lineage = lineage
        self.lineageNodes = lineageNodes
    }
}

/// Native-Swift APK Signature Scheme verifier (package-store.md §4.5).
struct APKSignatureVerifier: Sendable {
    private static let sigBlockMagic = Data("APK Sig Block 42".utf8)
    private static let v2BlockID: UInt32 = 0x7109_871A
    private static let v3BlockID: UInt32 = 0xF053_68C0
    private static let v31BlockID: UInt32 = 0x1B93_AD61
    private static let verityBlockID: UInt32 = 0x2146_444E
    private static let stampBlockID: UInt32 = 0x6DFF_800D
    private static let stampBlockID2: UInt32 = 0x6DFF_800E
    private static let proofOfRotationAttrID: UInt32 = 0x3BA0_6F8C
    private static let rotationMinSdkReleaseAttrID: UInt32 = 0x559F_8B02

    private enum SignatureAlgorithm: UInt32 {
        // APK Signature Scheme algorithm IDs.
        case rsaPKCS1SHA256 = 0x0103
        case rsaPKCS1SHA512 = 0x0104
        case rsaPSSSHA256 = 0x0101
        case rsaPSSSHA512 = 0x0102
        case ecdsaSHA256 = 0x0201
        case ecdsaSHA512 = 0x0202
        case dsaSHA256 = 0x0301
        case veritySHA256 = 0x0421

        var digest: SHAVariant {
            switch self {
            case .rsaPKCS1SHA256, .rsaPSSSHA256, .ecdsaSHA256, .dsaSHA256, .veritySHA256:
                .sha256
            case .rsaPKCS1SHA512, .rsaPSSSHA512, .ecdsaSHA512:
                .sha512
            }
        }

        /// Security.framework signature algorithm, when it can be checked.
        var secAlgorithm: SecKeyAlgorithm? {
            switch self {
            case .rsaPKCS1SHA256: .rsaSignatureMessagePKCS1v15SHA256
            case .rsaPKCS1SHA512: .rsaSignatureMessagePKCS1v15SHA512
            case .rsaPSSSHA256: .rsaSignatureMessagePSSSHA256
            case .rsaPSSSHA512: .rsaSignatureMessagePSSSHA512
            case .ecdsaSHA256: .ecdsaSignatureMessageX962SHA256
            case .ecdsaSHA512: .ecdsaSignatureMessageX962SHA512
            case .dsaSHA256, .veritySHA256: nil
            }
        }
    }

    private enum SHAVariant {
        case sha256
        case sha512

        var digestLength: Int {
            switch self {
            case .sha256: 32
            case .sha512: 64
            }
        }

        func hash(_ data: Data) -> Data {
            switch self {
            case .sha256: Data(SHA256.hash(data: data))
            case .sha512: Data(SHA512.hash(data: data))
            }
        }

        /// One-step `Insecure` digest for the content-digest tree (chunked per apksig §3.1.3).
        func hashChunk(_ chunk: Data) -> Data {
            var prefixed = Data([0xA5])
            prefixed.appendUInt32LE(UInt32(chunk.count))
            prefixed.append(chunk)
            return hash(prefixed)
        }

        func contentDigest(chunks: [Data]) -> Data {
            var input = Data([0x5A])
            input.appendUInt32LE(UInt32(chunks.count))
            for chunk in chunks {
                input.append(chunk)
            }
            return hash(input)
        }
    }

    /// Verifies the signature of one APK file. `targetSDK` decides the v1-only rule (§4.5).
    func verify(apk url: URL, targetSDK: Int) throws(StoreFailure) -> APKSignatureInfo {
        let file = url.lastPathComponent
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count > 22 else {
            throw .io
        }
        guard let layout = Self.zipLayout(of: data) else {
            throw .notAnAPK(file: file)
        }
        guard let sigBlock = Self.signingBlock(in: data, layout: layout),
            let sigBlockOffset = layout.sigBlockOffset
        else {
            return try v1Fallback(data: data, file: file, targetSDK: targetSDK)
        }
        // Pick the scheme for the guest SDK (37 baseline): v3.1 when a signer's range covers it.
        let guestSDK = 37
        if let v31 = sigBlock[Self.v31BlockID], schemeCoversSDK(v31, sdk: guestSDK) {
            return try verifyScheme(
                v31, data: data, layout: layout, sigBlockOffset: sigBlockOffset, scheme: .v31, file: file)
        }
        if let v3 = sigBlock[Self.v3BlockID] {
            return try verifyScheme(
                v3, data: data, layout: layout, sigBlockOffset: sigBlockOffset, scheme: .v3, file: file)
        }
        if let v2 = sigBlock[Self.v2BlockID] {
            return try verifyScheme(
                v2, data: data, layout: layout, sigBlockOffset: sigBlockOffset, scheme: .v2, file: file)
        }
        // Signature block present but no usable v2/v3 scheme (for example v3.1 outside the SDK
        // range, which Android would pick as v3 if it existed): fall back like Android — refuse.
        throw .invalidSignature(file: file, reason: "no supported signature scheme in the block")
    }

    /// Reads the ZIP layout: EOCD, central directory, and the signing-block offset.
    private struct ZIPLayout {
        var eocdOffset: Int
        var cdOffset: Int
        var cdSize: Int
        var sigBlockOffset: Int?
    }

    private static func zipLayout(of data: Data) -> ZIPLayout? {
        let searchStart = max(0, data.count - 65_557)
        var eocd: Int?
        var index = data.count - 22
        while index >= searchStart {
            if data[index] == 0x50, data[index + 1] == 0x4B, data[index + 2] == 0x05, data[index + 3] == 0x06 {
                eocd = index
                break
            }
            index -= 1
        }
        guard let eocdOffset = eocd else { return nil }
        let cdOffset = Int(data.readUInt32LE(at: eocdOffset + 16))
        let cdSize = Int(data.readUInt32LE(at: eocdOffset + 12))
        var sigBlockOffset: Int?
        if cdOffset >= 32, cdOffset <= data.count {
            let magicStart = cdOffset - 16
            if data.count >= magicStart + 16,
                data[magicStart..<(magicStart + 16)] == sigBlockMagic,
                let blockSize = Int(exactly: data.readUInt64LE(at: cdOffset - 24))
            {
                sigBlockOffset = cdOffset - blockSize - 8
            }
        }
        return ZIPLayout(eocdOffset: eocdOffset, cdOffset: cdOffset, cdSize: cdSize, sigBlockOffset: sigBlockOffset)
    }

    /// Parses the signing block's ID-value pairs.
    private static func signingBlock(in data: Data, layout: ZIPLayout) -> [UInt32: Data]? {
        guard let sigBlockOffset = layout.sigBlockOffset, sigBlockOffset >= 0,
            let declaredSize = Int(exactly: data.readUInt64LE(at: sigBlockOffset))
        else { return nil }
        guard declaredSize >= 24, sigBlockOffset + 8 + declaredSize <= data.count else { return nil }
        var pairs: [UInt32: Data] = [:]
        var offset = sigBlockOffset + 8
        let end = sigBlockOffset + 8 + declaredSize - 24
        while offset + 8 <= end {
            guard let pairSize = Int(exactly: data.readUInt64LE(at: offset)) else { break }
            guard pairSize >= 4, offset + 8 + pairSize <= data.count else { break }
            let id = data.readUInt32LE(at: offset + 8)
            let value = data[(offset + 12)..<(offset + 8 + pairSize)]
            pairs[id] = Data(value)
            offset += 8 + pairSize
        }
        return pairs
    }

    /// v3.1 block: every signer carries minSdk/maxSdkVersion. It applies when some signer covers
    /// the guest SDK.
    private func schemeCoversSDK(_ block: Data, sdk: Int) -> Bool {
        // Same `signers` nesting as verifyScheme: a length-prefixed sequence of
        // length-prefixed signer records. A v3.1 signer record is
        // [signed-data][minSdk u32][maxSdk u32][signatures][public key].
        for signer in Self.lengthPrefixed(block).flatMap(Self.lengthPrefixed) {
            var cursor = 0
            guard Self.takeLengthPrefixed(signer, at: &cursor) != nil,
                cursor + 8 <= signer.count
            else { continue }
            let minSDK = Int(signer.readUInt32LE(at: cursor))
            let maxSDK = Int(signer.readUInt32LE(at: cursor + 4))
            if sdk >= minSDK, sdk <= maxSDK { return true }
        }
        return false
    }

    /// Verifies one scheme block: content digests, signer signatures, keys, lineage.
    private func verifyScheme(
        _ block: Data,
        data: Data,
        layout: ZIPLayout,
        sigBlockOffset: Int,
        scheme: SignatureScheme,
        file: String
    ) throws(StoreFailure) -> APKSignatureInfo {
        var digests: [SHA256Digest] = []
        var lineage: [SHA256Digest] = []
        var lineageNodes: [SignerLineageNode] = []
        let level: SignatureLevel = .verified
        var sawSigner = false

        // The block value is `signers`: a length-prefixed sequence of length-prefixed
        // signer records, so flatten the two nesting levels before iterating signers.
        for signer in Self.lengthPrefixed(block).flatMap(Self.lengthPrefixed) {
            sawSigner = true
            // v2 signer records are all length-prefixed fields; v3/v3.1 insert
            // raw minSdk/maxSdkVersion uint32s after the signed data and after
            // the certificate list inside it.
            let signedData: Data
            let signaturesBlob: Data
            let publicKeyBlob: Data
            let digestsBlob: Data
            let certificatesBlob: Data
            let attributesBlob: Data
            if scheme == .v3 || scheme == .v31 {
                var cursor = 0
                guard let sd = Self.takeLengthPrefixed(signer, at: &cursor),
                    cursor + 8 <= signer.count
                else {
                    throw .invalidSignature(file: file, reason: "malformed signer block")
                }
                cursor += 8  // minSdkVersion, maxSdkVersion
                guard let sigs = Self.takeLengthPrefixed(signer, at: &cursor),
                    let key = Self.takeLengthPrefixed(signer, at: &cursor)
                else {
                    throw .invalidSignature(file: file, reason: "malformed signer block")
                }
                signedData = sd
                signaturesBlob = sigs
                publicKeyBlob = key
                var sdCursor = 0
                guard let digs = Self.takeLengthPrefixed(signedData, at: &sdCursor),
                    let certs = Self.takeLengthPrefixed(signedData, at: &sdCursor),
                    sdCursor + 8 <= signedData.count
                else {
                    throw .invalidSignature(file: file, reason: "malformed signed data")
                }
                sdCursor += 8  // minSdkVersion, maxSdkVersion
                digestsBlob = digs
                certificatesBlob = certs
                attributesBlob = signedData.subdata(in: sdCursor..<signedData.count)
            } else {
                let parts = Self.lengthPrefixed(signer)
                guard parts.count >= 3 else {
                    throw .invalidSignature(file: file, reason: "malformed signer block")
                }
                signedData = parts[0]
                signaturesBlob = parts[1]
                publicKeyBlob = parts[2]
                let sdParts = Self.lengthPrefixed(signedData)
                guard sdParts.count >= 2 else {
                    throw .invalidSignature(file: file, reason: "malformed signed data")
                }
                digestsBlob = sdParts[0]
                certificatesBlob = sdParts[1]
                attributesBlob = sdParts.count > 2 ? sdParts[2] : Data()
            }

            // The signer certificate is the first X.509 cert in the list.
            guard let certificateDER = Self.lengthPrefixed(certificatesBlob).first else {
                throw .invalidSignature(file: file, reason: "no signer certificate")
            }

            // Content digests: pick a supported algorithm the signer offers (skip verity).
            var digestOK = false
            var sawAnyDigest = false
            for record in Self.lengthPrefixed(digestsBlob) where record.count >= 4 {
                let algorithmID = record.readUInt32LE(at: 0)
                // The digest value is itself length-prefixed within the record.
                guard let digestValue = Self.lengthPrefixed(record.subdata(in: 4..<record.count)).first
                else { continue }
                guard let algorithm = SignatureAlgorithm(rawValue: algorithmID) else { continue }
                if algorithm == .veritySHA256 { continue }
                sawAnyDigest = true
                let computed = Self.computeContentDigest(
                    algorithm.digest, data: data, layout: layout, sigBlockOffset: sigBlockOffset)
                if computed == digestValue { digestOK = true }
            }
            if sawAnyDigest, !digestOK {
                throw .invalidSignature(file: file, reason: "content digest mismatch")
            }

            // Signatures over the signed data.
            var signatureOK = false
            var sawSignature = false
            guard let key = Self.secKey(for: certificateDER) else {
                throw .invalidSignature(file: file, reason: "unsupported signer key")
            }
            for record in Self.lengthPrefixed(signaturesBlob) where record.count >= 4 {
                let algorithmID = record.readUInt32LE(at: 0)
                guard let algorithm = SignatureAlgorithm(rawValue: algorithmID),
                    let secAlgorithm = algorithm.secAlgorithm
                else { continue }
                sawSignature = true
                // The signature bytes are length-prefixed within the record.
                guard let signature = Self.lengthPrefixed(record.subdata(in: 4..<record.count)).first
                else { continue }
                var error: Unmanaged<CFError>?
                if SecKeyVerifySignature(key, secAlgorithm, signedData as CFData, signature as CFData, &error) {
                    signatureOK = true
                }
            }
            guard signatureOK else {
                throw .invalidSignature(
                    file: file,
                    reason: sawSignature ? "signer signature does not verify" : "no supported signer signature")
            }
            // The signer's key must equal the certificate's key: the raw key bytes are the
            // tail of the X.509 SubjectPublicKeyInfo stored in the signer block.
            if let external = Self.externalKey(from: certificateDER),
                !publicKeyBlob.suffix(external.count).elementsEqual(external)
            {
                throw .invalidSignature(file: file, reason: "signer key differs from its certificate")
            }

            digests.append(SHA256Digest(data: certificateDER))

            // Rotation attribute → lineage, oldest → newest. The v3 tail of the
            // signed data is one more length-prefixed level than v2's field.
            let parsed = Self.lengthPrefixed(attributesBlob)
            let attributes =
                parsed.count == 1 ? Self.lengthPrefixed(parsed[0]) : parsed
            for attribute in attributes where attribute.count >= 8 {
                if attribute.readUInt32LE(at: 0) == Self.proofOfRotationAttrID {
                    // Attribute = id (uint32) + value; the item itself carries the length.
                    lineageNodes = try Self.parseLineage(
                        attribute.subdata(in: 4..<attribute.count), file: file)
                    lineage = lineageNodes.map(\.certificateDigest)
                    // The newest lineage entry must be the signer itself;
                    // otherwise a carrier APK could present a lineage that
                    // grants its predecessor's capabilities to a different
                    // key (apksig §6.3: the lineage ends at the signer).
                    guard lineageNodes.last?.certificateDigest == SHA256Digest(data: certificateDER)
                    else {
                        throw .invalidSignature(
                            file: file,
                            reason: "signing lineage does not end at the signer")
                    }
                }
            }
        }
        guard sawSigner else {
            throw .invalidSignature(file: file, reason: "empty signer set")
        }
        return APKSignatureInfo(
            signerDigests: digests, scheme: scheme, level: level,
            lineage: lineage, lineageNodes: lineageNodes)
    }

    /// The apksig chunked content digest: ZIP entries, central directory, EOCD with the CD
    /// offset replaced by the signing-block offset (apksig §3.1.3).
    private static func computeContentDigest(
        _ variant: SHAVariant,
        data: Data,
        layout: ZIPLayout,
        sigBlockOffset: Int
    ) -> Data {
        var chunks: [Data] = []
        var pending = Data()
        pending.reserveCapacity(1 << 20)
        func feed(_ slice: Data) {
            var slice = slice
            while !slice.isEmpty {
                let take = Swift.min((1 << 20) - pending.count, slice.count)
                pending.append(slice.prefix(take))
                slice = slice.dropFirst(take)
                if pending.count == (1 << 20) {
                    chunks.append(variant.hashChunk(pending))
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        func flushSection() {
            if !pending.isEmpty {
                chunks.append(variant.hashChunk(pending))
                pending.removeAll(keepingCapacity: true)
            }
        }
        // apksig chunks each of the three ZIP sections separately: a chunk never
        // spans a section boundary.
        feed(data[0..<sigBlockOffset])
        flushSection()
        feed(data[layout.cdOffset..<layout.cdOffset + layout.cdSize])
        flushSection()
        // subdata re-bases indices at 0; a Data slice keeps the file's offsets.
        var eocd = data.subdata(in: layout.eocdOffset..<data.count)
        var le = UInt32(sigBlockOffset).littleEndian
        Swift.withUnsafeBytes(of: &le) { bytes in
            eocd.replaceSubrange(16..<20, with: bytes)
        }
        feed(eocd)
        flushSection()
        return variant.contentDigest(chunks: chunks)
    }

    /// v1-only path: read the certificate from META-INF/*.RSA, *.EC, or *.DSA.
    private func v1Fallback(data: Data, file: String, targetSDK: Int) throws(StoreFailure) -> APKSignatureInfo {
        var hasJarSignature = false
        var certificateDER: Data?
        var index = 0
        while index + 30 <= data.count {
            if data[index] == 0x50, data[index + 1] == 0x4B, data[index + 2] == 0x03, data[index + 3] == 0x04 {
                let nameLength = Int(data.readUInt16LE(at: index + 26))
                let name = String(
                    decoding: data[(index + 30)..<Swift.min(index + 30 + nameLength, data.count)], as: UTF8.self)
                if name.hasPrefix("META-INF/"),
                    name.hasSuffix(".RSA") || name.hasSuffix(".EC") || name.hasSuffix(".DSA")
                {
                    hasJarSignature = true
                    let method = Int(data.readUInt16LE(at: index + 8))
                    let compressedSize = Int(data.readUInt32LE(at: index + 18))
                    let uncompressedSize = Int(data.readUInt32LE(at: index + 22))
                    let dataStart = index + 30 + nameLength + Int(data.readUInt16LE(at: index + 28))
                    if dataStart + compressedSize <= data.count {
                        let payload = Data(data[dataStart..<dataStart + compressedSize])
                        switch method {
                        case 0:
                            certificateDER = Self.findCertificateDER(in: payload)
                        case 8:
                            if let inflated = Self.inflate(payload, expectedSize: uncompressedSize) {
                                certificateDER = Self.findCertificateDER(in: inflated)
                            }
                        default:
                            break
                        }
                    }
                }
            }
            index += 1
        }
        if !hasJarSignature {
            throw .unsignedAPK(file: file)
        }
        if targetSDK >= 30 {
            throw .legacySignatureNotAllowed(targetSdk: targetSDK)
        }
        guard let certificateDER else {
            throw .invalidSignature(file: file, reason: "no certificate in the signature file")
        }
        return APKSignatureInfo(
            signerDigests: [SHA256Digest(data: certificateDER)],
            scheme: .jarOnly,
            level: .certificateOnly
        )
    }

    /// Inflates a raw DEFLATE stream (ZIP method 8) to its declared uncompressed size.
    private static func inflate(_ compressed: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0, expectedSize <= (1 << 28) else { return nil }
        var output = Data(count: expectedSize)
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { return nil }
        defer { inflateEnd(&stream) }
        var result: Int32 = Z_OK
        let outputCapacity = output.count
        compressed.withUnsafeBytes { src in
            output.withUnsafeMutableBytes { dst in
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: src.baseAddress?.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(compressed.count)
                stream.next_out = dst.baseAddress?.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(outputCapacity)
                result = zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, Int(stream.total_out) == expectedSize else { return nil }
        return output
    }

    /// Scans a PKCS#7 blob for the first DER certificate (0x30, plausible length, X.509 v3 version).
    private static func findCertificateDER(in blob: Data) -> Data? {
        let blob = Data(blob)  // materialize: slices keep the parent's indices
        var index = 0
        while index + 8 < blob.count {
            if blob[index] == 0x30, blob[index + 1] == 0x82 {
                let length = Int(blob[index + 2]) << 8 | Int(blob[index + 3])
                let end = index + 4 + length
                if end <= blob.count,
                    blob[index + 4] == 0x30,
                    blob[index + 5] == 0x82 || blob[index + 5] == 0x81
                {
                    // A certificate's tbsCertificate starts with [0] EXPLICIT version 2.
                    let inner = blob[(index + 4)..<Swift.min(index + 40, end)]
                    if let marker = inner.range(of: Data([0xA0, 0x03, 0x02, 0x01, 0x02])) {
                        _ = marker
                        return Data(blob[index..<end])
                    }
                }
            }
            index += 1
        }
        return nil
    }

    /// Parses a SigningCertificateLineage into certificate digests, oldest → newest.
    /// Parses and verifies a proof-of-rotation attribute value
    /// (apksig `V3SigningCertificateLineage`): uint32 version (1), then
    /// length-prefixed nodes, each `{lenPrefixed signedData, uint32 flags,
    /// uint32 sigAlgorithmId, lenPrefixed signature}` where signedData is
    /// `{lenPrefixed certificate, uint32 nextSigAlgorithmId}`. A node's
    /// signature covers its signedData and verifies with the previous node's
    /// certificate key, so the flag set can be trusted.
    private static func parseLineage(
        _ blob: Data, file: String
    ) throws(StoreFailure) -> [SignerLineageNode] {
        guard blob.count >= 4, blob.readUInt32LE(at: 0) == 1 else {
            throw .invalidSignature(
                file: file, reason: "unsupported signing-lineage version")
        }
        var nodes: [SignerLineageNode] = []
        var parentCertificate: Data?
        var parentNextSigAlgorithm: UInt32 = 0
        var index = 0
        for node in Self.lengthPrefixed(blob.subdata(in: 4..<blob.count)) {
            index += 1
            var cursor = 0
            func takeLengthPrefixed() throws(StoreFailure) -> Data {
                guard cursor + 4 <= node.count else {
                    throw StoreFailure.invalidSignature(
                        file: file, reason: "truncated signing-lineage node")
                }
                let length = Int(node.readUInt32LE(at: cursor))
                guard length >= 0, cursor + 4 + length <= node.count else {
                    throw StoreFailure.invalidSignature(
                        file: file, reason: "truncated signing-lineage node")
                }
                let part = node.subdata(in: cursor + 4..<cursor + 4 + length)
                cursor += 4 + length
                return part
            }
            let signedData = try takeLengthPrefixed()
            guard cursor + 8 <= node.count else {
                throw .invalidSignature(
                    file: file, reason: "truncated signing-lineage node")
            }
            let flags = node.readUInt32LE(at: cursor)
            let sigAlgorithmID = node.readUInt32LE(at: cursor + 4)
            cursor += 8
            let signature = try takeLengthPrefixed()

            var innerCursor = 0
            guard innerCursor + 4 <= signedData.count else {
                throw .invalidSignature(
                    file: file, reason: "truncated signing-lineage node")
            }
            let certLength = Int(signedData.readUInt32LE(at: innerCursor))
            guard certLength >= 0, innerCursor + 4 + certLength + 4 <= signedData.count
            else {
                throw .invalidSignature(
                    file: file, reason: "truncated signing-lineage node")
            }
            let certificate = signedData.subdata(
                in: innerCursor + 4..<innerCursor + 4 + certLength)
            innerCursor += 4 + certLength
            let signedSigAlgorithm = signedData.readUInt32LE(at: innerCursor)

            if let parent = parentCertificate {
                // The node is signed over its signedData by the previous
                // node's key, using the algorithm that node declared.
                guard
                    let algorithm = SignatureAlgorithm(rawValue: parentNextSigAlgorithm),
                    let secAlgorithm = algorithm.secAlgorithm,
                    let key = Self.secKey(for: parent)
                else {
                    throw .invalidSignature(
                        file: file,
                        reason: "unsupported signing-lineage signature algorithm")
                }
                var error: Unmanaged<CFError>?
                guard
                    SecKeyVerifySignature(
                        key, secAlgorithm, signedData as CFData, signature as CFData, &error)
                else {
                    throw .invalidSignature(
                        file: file,
                        reason: "signing-lineage node \(index) signature does not verify")
                }
                guard signedSigAlgorithm == parentNextSigAlgorithm else {
                    throw .invalidSignature(
                        file: file,
                        reason: "signing-lineage signature algorithm mismatch at node \(index)")
                }
            }
            let digest = SHA256Digest(data: certificate)
            guard !nodes.contains(where: { $0.certificateDigest == digest }) else {
                throw .invalidSignature(
                    file: file, reason: "duplicate certificate in signing lineage")
            }
            nodes.append(
                SignerLineageNode(
                    certificateDigest: digest,
                    capabilities: SignerCapabilities(rawValue: flags)))
            parentCertificate = certificate
            parentNextSigAlgorithm = sigAlgorithmID
        }
        return nodes
    }

    private static func secKey(for certificateDER: Data) -> SecKey? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
            let key = SecCertificateCopyKey(certificate)
        else { return nil }
        return key
    }

    /// The raw key of a certificate (its SPKI's subjectPublicKey payload).
    private static func externalKey(from certificateDER: Data) -> Data? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateDER as CFData),
            let key = SecCertificateCopyKey(certificate)
        else { return nil }
        return SecKeyCopyExternalRepresentation(key, nil) as? Data
    }

    /// Splits a length-prefixed (UInt32 LE) sequence field.
    static func lengthPrefixed(_ blob: Data) -> [Data] {
        var parts: [Data] = []
        var offset = 0
        while offset + 4 <= blob.count {
            let length = Int(blob.readUInt32LE(at: offset))
            guard length >= 0, offset + 4 + length <= blob.count else { break }
            parts.append(blob.subdata(in: offset + 4..<offset + 4 + length))
            offset += 4 + length
        }
        return parts
    }

    /// Reads one length-prefixed (UInt32 LE) field at `offset` and advances it.
    static func takeLengthPrefixed(_ blob: Data, at offset: inout Int) -> Data? {
        guard offset + 4 <= blob.count else { return nil }
        let length = Int(blob.readUInt32LE(at: offset))
        guard length >= 0, offset + 4 + length <= blob.count else { return nil }
        let part = blob.subdata(in: offset + 4..<offset + 4 + length)
        offset += 4 + length
        return part
    }
}

extension Data {
    fileprivate func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    fileprivate func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    fileprivate func readUInt64LE(at offset: Int) -> UInt64 {
        UInt64(readUInt32LE(at: offset)) | UInt64(readUInt32LE(at: offset + 4)) << 32
    }

    fileprivate mutating func appendUInt32LE(_ value: UInt32) {
        var le = value.littleEndian
        append(contentsOf: Swift.withUnsafeBytes(of: &le) { Array($0) })
    }
}
