import Foundation
import RuntimeAPI
import XCTest

final class LauncherIdentityTests: XCTestCase {
    func testWrapperManifestWithoutPackageIDIsDamaged() throws {
        let (bundle, bundleURL) = try makeWrapperBundle(info: ["APKRunWrapperFormat": 1])
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        XCTAssertThrowsError(try LauncherIdentity.load(bundle: bundle, arguments: [])) { error in
            XCTAssertEqual(error as? LauncherIdentity.Failure, .malformedWrapper)
        }
    }

    func testWrapperWithNonStringPackageIDIsDamaged() throws {
        let (bundle, bundleURL) = try makeWrapperBundle(
            info: [
                "APKRunPackageID": 42,
                "APKRunWrapperFormat": 1,
            ])
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        XCTAssertThrowsError(try LauncherIdentity.load(bundle: bundle, arguments: [])) { error in
            XCTAssertEqual(error as? LauncherIdentity.Failure, .malformedWrapper)
        }
    }

    func testUnsupportedWrapperFormatIsDamaged() throws {
        let (bundle, bundleURL) = try makeWrapperBundle(
            info: [
                "APKRunPackageID": "com.example.chat",
                "APKRunWrapperFormat": 1,
            ],
            manifest: """
                {"formatVersion":2,"kind":"local","application":{"packageId":"com.example.chat","displayName":"Chat"},"runtime":{"minimumVersion":"1.0.0","launcherAPI":"1.0"}}
                """
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        XCTAssertThrowsError(try LauncherIdentity.load(bundle: bundle, arguments: [])) { error in
            XCTAssertEqual(error as? LauncherIdentity.Failure, .malformedWrapper)
        }
    }

    func testBooleanAndNonIntegerWrapperFormatsAreDamaged() throws {
        for format in [true as Any, 1.0 as Any, 1.5 as Any] {
            let (bundle, bundleURL) = try makeWrapperBundle(
                info: [
                    "APKRunPackageID": "com.example.chat",
                    "APKRunWrapperFormat": format,
                ])
            defer { try? FileManager.default.removeItem(at: bundleURL) }

            XCTAssertThrowsError(try LauncherIdentity.load(bundle: bundle, arguments: [])) { error in
                XCTAssertEqual(error as? LauncherIdentity.Failure, .malformedWrapper)
            }
        }
    }

    func testManifestPackageIDMustMatchInfoPlist() throws {
        let (bundle, bundleURL) = try makeWrapperBundle(
            info: [
                "APKRunPackageID": "com.example.wrapper",
                "APKRunWrapperFormat": 1,
            ],
            manifest: """
                {"formatVersion":1,"kind":"local","application":{"packageId":"com.example.manifest","displayName":"Chat"},"runtime":{"minimumVersion":"1.0.0","launcherAPI":"1.0"}}
                """
        )
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        XCTAssertThrowsError(try LauncherIdentity.load(bundle: bundle, arguments: [])) { error in
            XCTAssertEqual(error as? LauncherIdentity.Failure, .packageMismatch)
        }
    }

    private func makeWrapperBundle(info: [String: Any], manifest: String = "{}") throws -> (Bundle, URL) {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LauncherIdentityTests-\(UUID().uuidString).app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        let resourcesURL = contentsURL.appendingPathComponent("Resources")
        let executableURL = contentsURL.appendingPathComponent("MacOS/TestWrapper")
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var info = info
        info["CFBundleIdentifier"] = "io.apkrun.android.test"
        info["CFBundleName"] = "Test Wrapper"
        info["CFBundlePackageType"] = "APPL"
        info["CFBundleVersion"] = "1"
        info["CFBundleExecutable"] = "TestWrapper"
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try Data().write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        try Data(manifest.utf8).write(to: resourcesURL.appendingPathComponent("wrapper.json"))

        guard let bundle = Bundle(url: bundleURL) else {
            try? FileManager.default.removeItem(at: bundleURL)
            throw CocoaError(.fileReadCorruptFile)
        }
        return (bundle, bundleURL)
    }
}
