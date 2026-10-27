import CoreFoundation
import Foundation
import RuntimeAPI

/// The identity the shared launcher uses for one APKRun package.
struct LauncherIdentity: Equatable, Sendable {
    enum Failure: Error, Equatable {
        case genericPackageMissing
        case malformedWrapper
        case packageMismatch
    }

    let packageID: RuntimePackageID
    let displayName: String
    let document: WrapperDocument?

    /// Loads the immutable wrapper identity or the package passed to the generic launcher.
    static func load(
        bundle: Bundle = .main,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> Self {
        let info = bundle.infoDictionary ?? [:]
        let manifestURL = bundle.url(forResource: "wrapper", withExtension: "json")
        let hasWrapperMetadata =
            info.keys.contains("APKRunPackageID")
            || info.keys.contains("APKRunWrapperFormat")
            || manifestURL != nil
        if hasWrapperMetadata {
            guard let rawPackageID = info["APKRunPackageID"] as? String,
                let packageID = RuntimePackageID(rawValue: rawPackageID),
                Self.hasSupportedWrapperFormat(info["APKRunWrapperFormat"]),
                let manifestURL,
                let attributes = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
                let fileSize = attributes[.size] as? NSNumber,
                fileSize.intValue <= 64 * 1024,
                let data = try? Data(contentsOf: manifestURL),
                let document = try? JSONDecoder().decode(WrapperDocument.self, from: data)
            else {
                throw Failure.malformedWrapper
            }
            guard document.application.packageID == packageID else {
                throw Failure.packageMismatch
            }
            let displayName =
                (info["CFBundleDisplayName"] as? String)
                ?? document.application.displayName
            return Self(packageID: packageID, displayName: displayName, document: document)
        }

        guard let rawPackageID = Self.packageIDArgument(in: arguments),
            let packageID = RuntimePackageID(rawValue: rawPackageID)
        else {
            throw Failure.genericPackageMissing
        }
        let displayName =
            (info["CFBundleDisplayName"] as? String)
            ?? packageID.rawValue
        return Self(packageID: packageID, displayName: displayName, document: nil)
    }

    private static func packageIDArgument(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--package"),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func hasSupportedWrapperFormat(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(number as CFNumber)
        else {
            return false
        }
        return number.compare(NSNumber(value: WrapperDocument.currentFormatVersion)) == .orderedSame
    }
}
