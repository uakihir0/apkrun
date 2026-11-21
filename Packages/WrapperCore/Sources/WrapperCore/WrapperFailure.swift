import DiagnosticsCore
import Foundation
import RuntimeAPI

/// Why a user-provided icon file cannot be used (wrapper.md §13).
public enum IconInputProblem: String, Sendable, Codable {
    /// The file could not be read or decoded.
    case unreadable
    /// The image is not square.
    case notSquare
    /// The image is smaller than 512 px.
    case tooSmall
}

/// `BundleProblem` is defined in RuntimeAPI so the wire and domain layers share
/// one type (runtime-api.md §10.4).

/// Wrapper generation and lifecycle errors (wrapper.md §13). Cases for
/// approval, bootstrap, launcher screens, and distribution arrive with their
/// tasks (#47, #48, #89, #90).
public enum WrapperFailure: APKRunError, Equatable {
    /// The package has no record on this Mac.
    case packageNotInstalled(RuntimePackageID)

    /// The display name produced no usable file name.
    case invalidName(String)

    /// A user-provided icon file is unusable.
    case customIconInvalid(IconInputProblem)

    /// Icon conversion failed.
    case iconConversionFailed(String)

    /// The launcher template is missing, not arm64, or has no valid signature.
    case launcherTemplateInvalid(String)

    /// The destination directory cannot be written to.
    case destinationNotWritable(URL)

    /// macOS privacy controls deny apkrund access to the destination; the
    /// staged bundle waits for `placeStagedWrapper`.
    case destinationNotAccessible(URL, stagingToken: String)

    /// The destination path holds something that is never replaced.
    case nameConflict(URL, existing: ExistingItemKind)

    /// The registered wrapper of this package already exists.
    case wrapperExists(RuntimePackageID, URL)

    /// The package has no registered wrapper.
    case wrapperNotFound(RuntimePackageID)

    /// `codesign` exited non-zero. Status and message are logged.
    case signingFailed(status: Int32, message: String)

    /// Validation of a generated bundle failed.
    case verificationFailed(String)

    /// `LSRegisterURL` failed; reported as a warning.
    case registrationFailed(Int32)

    /// `registry.json` is unreadable (kept as `registry.json.corrupt-<time>`).
    case registryUnavailable

    /// A `placeStagedWrapper` token is unknown or expired.
    case stagingExpired

    /// A bundle fails the static checks of §7.3 step 1.
    case bundleInvalid(URL, reason: BundleProblem)

    /// The user pressed **Don't Allow** (wrapper.md §7.3 step 5).
    case approvalDenied

    /// Nobody answered the approval prompt within 10 minutes.
    case approvalTimedOut

    /// `decideApproval` named an unknown, answered, or expired prompt.
    case approvalNotFound

    /// More than 5 approval requests arrived within one minute
    /// (wrapper.md §7.3 step 3); reported as `runtime.busy`.
    case approvalBusy

    /// The stable error catalog namespace for wrappers.
    public static let domain: ErrorDomain = .wrapper

    /// The catalog code for this error.
    public var code: String {
        switch self {
        case .packageNotInstalled: "packageNotInstalled"
        case .invalidName: "invalidName"
        case .customIconInvalid: "customIconInvalid"
        case .iconConversionFailed: "iconConversionFailed"
        case .launcherTemplateInvalid: "launcherTemplateInvalid"
        case .destinationNotWritable: "destinationNotWritable"
        case .destinationNotAccessible: "destinationNotAccessible"
        case .nameConflict: "nameConflict"
        case .wrapperExists: "wrapperExists"
        case .wrapperNotFound: "wrapperNotFound"
        case .signingFailed: "signingFailed"
        case .verificationFailed: "verificationFailed"
        case .registrationFailed: "registrationFailed"
        case .registryUnavailable: "registryUnavailable"
        case .stagingExpired: "stagingExpired"
        case .bundleInvalid: "bundleInvalid"
        case .approvalDenied: "approvalDenied"
        case .approvalTimedOut: "approvalTimedOut"
        case .approvalNotFound: "approvalNotFound"
        case .approvalBusy: "busy"
        }
    }

    /// Safe values used by the catalog's messages.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .packageNotInstalled(let packageID):
            ["app": .text(packageID.rawValue)]
        case .invalidName(let name):
            ["name": .text(name)]
        case .customIconInvalid(let problem):
            ["reason": .text(problem.rawValue)]
        case .iconConversionFailed(let message):
            ["reason": .text(message)]
        case .launcherTemplateInvalid(let reason):
            ["reason": .text(reason)]
        case .destinationNotWritable(let url):
            ["file": .fileName(url.lastPathComponent)]
        case .destinationNotAccessible(let url, let stagingToken):
            [
                "file": .fileName(url.lastPathComponent),
                "stagingToken": .text(stagingToken),
            ]
        case .nameConflict(let url, _):
            ["file": .fileName(url.lastPathComponent)]
        case .wrapperExists(let packageID, let url):
            [
                "app": .text(packageID.rawValue),
                "file": .fileName(url.lastPathComponent),
                "package": .text(packageID.rawValue),
            ]
        case .wrapperNotFound(let packageID):
            ["app": .text(packageID.rawValue)]
        case .signingFailed(let status, let message):
            [
                "status": .count(Int(status)),
                "reason": .text(message),
            ]
        case .verificationFailed(let reason):
            ["reason": .text(reason)]
        case .registrationFailed(let status):
            ["status": .count(Int(status))]
        case .registryUnavailable, .stagingExpired, .approvalDenied, .approvalTimedOut,
            .approvalNotFound, .approvalBusy:
            [:]
        case .bundleInvalid(_, let reason):
            ["reason": .text(reason.rawValue)]
        }
    }
}
