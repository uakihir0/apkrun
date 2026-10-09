import Darwin
import Foundation

/// The Ed25519 keys that may sign image manifests (runtime-image-manifest.md §6.1).
public struct ImageTrustStore: Equatable, Sendable {
    /// One trusted key: its ID and its raw 32-byte public key.
    public struct Key: Equatable, Sendable {
        /// The key ID, from ``ImageSignature/keyID(of:)``.
        public let keyID: String
        /// The raw 32-byte Ed25519 public key.
        public let publicKey: Data

        /// Creates a trusted key; the key ID follows from the public key.
        public init(publicKey: Data) {
            self.publicKey = publicKey
            keyID = ImageSignature.keyID(of: publicKey)
        }
    }

    /// The trusted keys.
    public let keys: [Key]

    /// Creates a trust list. Tests use it to trust the test key.
    public init(keys: [Key]) {
        self.keys = keys
    }

    /// The trusted key with this ID, if any.
    public func key(for keyID: String) -> Key? {
        keys.first { $0.keyID == keyID }
    }

    /// The release image keys compiled into the app. None exist until the release key
    /// ceremony (#093), so a Release build trusts no bundle and refuses every one with
    /// `untrustedKey`. That is the fail-closed default for M1.
    public static let release = ImageTrustStore(keys: [])

    /// The trust list of this build: the release keys, and in Debug builds the developer key.
    public static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ImageTrustStore {
        #if DEBUG
            developmentStore(home: home)
        #else
            release
        #endif
    }

    #if DEBUG
        /// The release keys plus `~/.config/apkrun/dev-image-key.pub`, the base64 of the raw
        /// public key that `python3 -m apkrun_image keygen` writes (runtime-image-manifest.md
        /// §6.1). A file that does not hold exactly one 32-byte key adds nothing, so a bad file
        /// never trusts a key by mistake.
        static func developmentStore(home: URL) -> ImageTrustStore {
            let url = home.appendingPathComponent(".config/apkrun/dev-image-key.pub")
            guard isPrivateToTheUser(url) else {
                return release
            }
            guard
                let text = try? String(contentsOf: url, encoding: .utf8),
                let data = Data(
                    base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                data.count == 32
            else {
                return release
            }
            return ImageTrustStore(keys: release.keys + [Key(publicKey: data)])
        }

        /// True when `url` is a regular file owned by the current user, which no group or other
        /// user can write. Anyone who could replace the file could add a signer to the trust list,
        /// so a file like that is not a key. A symbolic link is not a regular file, so it is refused.
        static func isPrivateToTheUser(_ url: URL) -> Bool {
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                return false
            }
            return status.st_uid == getuid() && status.st_mode & (S_IWGRP | S_IWOTH) == 0
        }
    #endif
}
