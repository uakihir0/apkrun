import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func devPowerActionsRoundTripThroughTheControlSocket() async throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("apkrun-dev-control-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let service = RecordingDeveloperService()
    let server = DevControlSocketServer(directory: directory, service: service)
    defer { server.stop() }
    try server.start()

    #expect(try permissions(at: directory.path) == 0o700)
    #expect(try permissions(at: directory.appendingPathComponent("control.sock").path) == 0o600)

    try DevControlSocketClient.injectPower(.sleep, directory: directory)
    try DevControlSocketClient.injectPower(.wake, directory: directory)
    #expect(await service.actions == [.sleep, .wake])

    server.stop()
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("control.sock").path))
}

@Test(.timeLimit(.minutes(1)))
func devPowerReturnsUnavailableWhenNoBootOwnsTheControlSocket() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("apkrun-dev-control-missing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    do {
        try DevControlSocketClient.injectPower(.sleep, directory: directory)
        Issue.record("A missing control socket must report that the development runtime is unavailable.")
    } catch let error as RuntimeWireError {
        #expect(error.code == "runtime.serviceUnavailable")
    }
}

@Test(.timeLimit(.minutes(1)))
func devControlSocketRejectsAnExistingNonSocketFile() throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("apkrun-dev-control-file-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("control.sock")
    try Data("preserve".utf8).write(to: path)

    let server = DevControlSocketServer(directory: directory, service: RecordingDeveloperService())
    #expect(throws: RuntimeFailure.devConsoleSocketUnavailable) {
        try server.start()
    }
    #expect(try Data(contentsOf: path) == Data("preserve".utf8))
}

private actor RecordingDeveloperService: DeveloperService {
    private(set) var actions: [DevPowerAction] = []

    func injectPower(_ action: DevPowerAction) async {
        actions.append(action)
    }
}

private func permissions(at path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
