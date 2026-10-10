import Foundation
import ImageCore
import RuntimeCore
import XCTest

/// The #021 refusal of a GPU profile that the device cannot offer (graphics.md §9; IR-380).
///
/// The refusal happens before the VM is created, so this check starts no VM and does not boot Android. It runs in the
/// `AndroidGraphics` configuration with the installed test bundle, because the bundle is what names the profile's
/// required features.
final class AndroidGraphicsRefusalTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-graphics" else {
            throw XCTSkip("The Android graphics checks run in the AndroidGraphics test-plan configuration.")
        }
    }

    /// `drmVirgl` needs `VIRTIO_GPU_F_VIRGL`, which the device does not offer before #022. The boot must end at once
    /// with `gpuProfileUnavailable`, and it must change no file under the home directory: the instance and the initrd
    /// are not read or written.
    func testDRMVirglIsRefusedBeforeTheInstanceIsTouched() async throws {
        let home = try AndroidBootFixture.makeHome()
        defer { removeTestHome(home) }
        let bundle = try AndroidBootFixture.bundleDirectory()
        let fixture = try await AndroidBootFixture(home: home, bundle: bundle)
        try await fixture.resetInstance()
        let supervisor = try fixture.supervisor(developerMode: false, gpuProfile: .drmVirgl)
        let before = try Self.snapshot(of: home)

        do {
            try await supervisor.ensureReady(.cli)
            XCTFail("drmVirgl must be refused while the device does not offer VIRGL")
        } catch {
            XCTAssertEqual(error, RuntimeBootFailure.gpuProfileUnavailable(profile: "drmVirgl"))
        }
        let state = await supervisor.state
        XCTAssertEqual(state, .failed(.gpuProfileUnavailable(profile: "drmVirgl")))
        XCTAssertEqual(try Self.snapshot(of: home), before, "the refusal changes no file under the home directory")
    }

    /// Every file and directory under `root`, with its size and modification time, sorted by path.
    private static func snapshot(of root: URL) throws -> [String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }
        var entries: [String] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = String(url.path.dropFirst(root.path.count))
            if values.isDirectory == true {
                entries.append("\(path)/")
            } else {
                let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                entries.append("\(path) \(values.fileSize ?? 0) \(modified)")
            }
        }
        return entries.sorted()
    }
}
