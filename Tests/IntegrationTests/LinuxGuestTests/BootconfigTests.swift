import Foundation
import XCTest

@testable import ImageCore

/// Android bootconfig on the Linux test guest (android-image.md §6.3; #012 step 5).
///
/// The kernel reads one bootconfig block from the end of the initrd and shows it in
/// `/proc/bootconfig`. The test merges a golden input with `BootconfigWriter`, appends the
/// trailer to the test initrd, boots the guest, and compares the kernel's view with the
/// merged block. The check is semantic: it compares key/value pairs, not the byte layout
/// of the kernel's listing.
final class LinuxGuestBootconfigTests: XCTestCase {
    /// Layer 1 (vendor) and layer 2 (image) of the golden input.
    private static let vendorText = """
        androidboot.hardware=cutf_cvm
        kernel.vmw_vsock_virtio_transport_common.virtio_transport_max_vsock_pkt_buf_size=16384
        """
    private static let imageText = """
        androidboot.slot_suffix=_a
        androidboot.force_normal_boot=1
        androidboot.vendor.apex.com.android.hardware.keymint=com.android.hardware.keymint.rust_nonsecure
        """

    func testBootconfigTrailer() async throws {
        let layers = [
            BootconfigLayer(name: "vendor", values: try BootconfigWriter.parse(Self.vendorText, layer: "vendor")),
            BootconfigLayer(name: "image", values: try BootconfigWriter.parse(Self.imageText, layer: "image")),
        ]
        let entries = try BootconfigWriter.merge(layers)
        let golden = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        let block = BootconfigWriter.serialize(entries)
        let commandLine = "console=hvc0 bootconfig apkrun.test=bootconfig"
        let trailer = try BootconfigWriter.trailer(for: block, commandLine: commandLine)

        let artifacts = try LinuxGuestHarness.artifactURLs()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-bootconfig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initrd = directory.appendingPathComponent("initramfs-bootconfig.cpio.gz")
        try (try Data(contentsOf: artifacts.initrd) + trailer).write(to: initrd)

        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["bootconfig"],
            initrd: initrd,
            extraCommandLine: ["bootconfig"]
        )

        let console = String(decoding: result.consoleOutput, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        if console.contains("APKRUN-BOOTCONFIG-ABSENT") {
            let kernelLines = console.split(separator: "\n")
                .filter { $0.hasPrefix("APKRUN-BOOTCONFIG-DMESG ") }
                .map { $0.dropFirst("APKRUN-BOOTCONFIG-DMESG ".count) }
            throw XCTSkip(
                "The pinned test kernel has no /proc/bootconfig (CONFIG_BOOT_CONFIG is not set: "
                    + "\(kernelLines.joined(separator: "; "))). #013 checks /proc/bootconfig on Android."
            )
        }
        let printed = try Self.listing(in: console)
        let kernelView = Self.keyValues(in: printed)
        XCTAssertEqual(kernelView, golden, "/proc/bootconfig equals the merged block")
        XCTAssertEqual(result.records.last, .done)
        XCTAssertTrue(
            result.records.contains { record in
                if case .check(let name, let outcome, _) = record {
                    return name == "bootconfig" && outcome == .ok
                }
                return false
            },
            "the guest reports the bootconfig check as ok"
        )
    }

    /// The listing parser needs no VM, so it runs on every kernel, including one without bootconfig.
    func testListingParserFlattensFlatAndNestedForms() {
        let flat = """
            androidboot.hardware = "cutf_cvm";
            androidboot.slot_suffix = "_a";

            """
        XCTAssertEqual(
            Self.keyValues(in: flat),
            ["androidboot.hardware": "cutf_cvm", "androidboot.slot_suffix": "_a"]
        )
        let nested = """
            androidboot {
            \thardware = "cutf_cvm";
            \tslot_suffix = "_a";
            }
            kernel {
            \tvmw {
            \t\tpkt = "16384";
            \t}
            }

            """
        XCTAssertEqual(
            Self.keyValues(in: nested),
            [
                "androidboot.hardware": "cutf_cvm",
                "androidboot.slot_suffix": "_a",
                "kernel.vmw.pkt": "16384",
            ]
        )
    }

    /// The lines the guest printed between the bootconfig markers.
    static func listing(in console: String) throws -> String {
        guard
            let begin = console.range(of: "APKRUN-BOOTCONFIG-BEGIN\n"),
            let end = console.range(of: "APKRUN-BOOTCONFIG-END", range: begin.upperBound..<console.endIndex)
        else {
            throw XCTSkip("The guest did not print /proc/bootconfig before the console ended.")
        }
        return String(console[begin.upperBound..<end.lowerBound])
    }

    /// Flattens the kernel's listing into dotted keys. It accepts `key = "value";` lines and
    /// `name {` ... `}` blocks, so it does not depend on whether the kernel nests the keys.
    static func keyValues(in listing: String) -> [String: String] {
        var values: [String: String] = [:]
        var prefix: [String] = []
        for rawLine in listing.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("}") {
                _ = prefix.popLast()
                continue
            }
            if line.hasSuffix("{") {
                prefix.append(line.dropLast().trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                continue
            }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") {
                value.removeLast()
            }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            let key = (prefix + [name]).joined(separator: ".")
            values[key] = value
        }
        return values
    }
}
