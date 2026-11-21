#!/usr/bin/env swift  // Signs a file with the Sparkle EdDSA private key, the way `sign_update`  // does (runtime-maintenance.md §3.3): the signature is the base64 of the  // Ed25519 signature over the raw file bytes.
//
// Usage:
//   sign-update.swift <file>                 signs with $APKRUN_SPARKLE_ED_PRIVATE_KEY
//   sign-update.swift --generate             prints a fresh key pair (tests only)
//   sign-update.swift --public-key           prints the public half of the env key
//
// The private key is the base64 of Sparkle's 64-byte key (32-byte seed +
// 32-byte public key); a bare 32-byte seed is also accepted.
import CryptoKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments == ["--generate"] {
    let key = Curve25519.Signing.PrivateKey()
    let stored = key.rawRepresentation + key.publicKey.rawRepresentation
    print("private:", stored.base64EncodedString())
    print("public:", key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

if arguments == ["--public-key"] {
    guard let encoded = ProcessInfo.processInfo.environment["APKRUN_SPARKLE_ED_PRIVATE_KEY"],
        let keyBytes = Data(base64Encoded: encoded),
        keyBytes.count == 32 || keyBytes.count == 64
    else {
        FileHandle.standardError.write(
            Data("sign-update: APKRUN_SPARKLE_ED_PRIVATE_KEY must be a base64 EdDSA key\n".utf8))
        exit(65)
    }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyBytes.prefix(32))
    print(key.publicKey.rawRepresentation.base64EncodedString())
    exit(0)
}

guard arguments.count == 1 else {
    FileHandle.standardError.write(Data("usage: sign-update.swift <file> | --generate\n".utf8))
    exit(64)
}

guard let encoded = ProcessInfo.processInfo.environment["APKRUN_SPARKLE_ED_PRIVATE_KEY"],
    let keyBytes = Data(base64Encoded: encoded),
    keyBytes.count == 32 || keyBytes.count == 64
else {
    FileHandle.standardError.write(
        Data("sign-update: APKRUN_SPARKLE_ED_PRIVATE_KEY must be a base64 EdDSA key\n".utf8))
    exit(65)
}

let fileURL = URL(fileURLWithPath: arguments[0])
let body: Data
do {
    body = try Data(contentsOf: fileURL)
} catch {
    FileHandle.standardError.write(Data("sign-update: cannot read \(arguments[0])\n".utf8))
    exit(66)
}

let seed = keyBytes.prefix(32)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let signature = try key.signature(for: body)
print(signature.base64EncodedString())
