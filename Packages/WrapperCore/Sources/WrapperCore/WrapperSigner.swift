import Foundation

/// Ad-hoc signs a generated wrapper bundle (wrapper.md §7.1). Developer ID
/// signing for distribution wrappers is #89.
public enum WrapperSigner {
    /// Signs the bundle as the last write of generation:
    /// `codesign --force --sign - --identifier <bundleID> --options runtime
    /// --timestamp=none <app>`. Never `--deep` (TN2206): the bundle has no
    /// nested code, so one call seals the executable and `Contents/`.
    /// Verifies the result strictly and returns the 40-hex cdhash.
    public static func sign(bundleURL: URL, bundleID: String) throws(WrapperFailure) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--force",
            "--sign", "-",
            "--identifier", bundleID,
            "--options", "runtime",
            "--timestamp=none",
            bundleURL.path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw .signingFailed(status: -1, message: "codesign could not start")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(
                decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw .signingFailed(status: process.terminationStatus, message: output)
        }
        guard WrapperCodeSign.signatureIsValid(bundleURL: bundleURL, identifier: bundleID)
        else {
            throw .verificationFailed("strict check failed after signing")
        }
        guard let cdhash = WrapperCodeSign.cdhash(of: bundleURL) else {
            throw .verificationFailed("no cdhash after signing")
        }
        return cdhash
    }
}
