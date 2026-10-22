import Darwin
import Foundation
import RuntimeCore
import XCTest

/// T2 checks for the custom image's developer-mode ADB switch (#36, android-image.md §11.3).
final class DeveloperModeAdbTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try AndroidCustomImageSession.requireAndroidCustomSuite()
    }

    /// With developer mode enabled, ADB reaches adbd through the loopback-only 6520 forwarder and
    /// Android grants the expected shell uid.
    func testDeveloperModeOnServesAdbOnLoopbackAndAcceptsShellUid() async throws {
        try await AndroidCustomImageSession.withBoot(developerMode: true) { session in
            let port = await session.supervisor.developmentADBHostPort
            XCTAssertEqual(port, UInt16(6520))
            XCTAssertEqual(try Self.listeningAddresses(port: 6520), ["127.0.0.1:6520"])

            let adb = try await AndroidCustomImageSession.connectedADB(session)
            let developerMode = try await adb.getprop("ro.boot.apkrun.devmode")
            XCTAssertEqual(developerMode, "1")
            let uid = try await adb.shell("id -u")
            XCTAssertEqual(uid.status, 0)
            XCTAssertEqual(uid.output.trimmingCharacters(in: .whitespacesAndNewlines), "2000")
        }
    }

    /// With developer mode disabled, there is no host forwarder and adbd does not listen on
    /// guest vsock port 5555.
    func testDeveloperModeOffHasNoAdbForwarderOrGuestListener() async throws {
        try await AndroidCustomImageSession.withBoot(developerMode: false) { session in
            let state = await session.supervisor.state
            XCTAssertEqual(state, .ready)
            let hostPort = await session.supervisor.developmentADBHostPort
            XCTAssertNil(hostPort)
            XCTAssertTrue(try Self.listeningAddresses(port: 6520).isEmpty)

            do {
                _ = try await session.supervisor.connect(vsockPort: 5555, timeout: .seconds(3))
                XCTFail("adbd accepted a guest vsock connection while developer mode was off")
            } catch let error as RuntimeBootFailure {
                guard case .vm(.vsockPortNotListening(port: 5555)) = error else {
                    XCTFail("unexpected failure while checking the disabled adbd port: \(error)")
                    return
                }
            } catch {
                XCTFail("unexpected error while checking the disabled adbd port: \(error)")
            }
        }
    }

    private static func listeningAddresses(port: UInt16) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { $0.hasPrefix("n") ? String($0.dropFirst()) : nil }
    }
}
