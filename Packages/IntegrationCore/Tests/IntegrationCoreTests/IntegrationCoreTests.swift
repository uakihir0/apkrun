import DiagnosticsCore
import Foundation
import Testing

@testable import IntegrationCore

@Test func fileNameSanitizerAppliesWrapperFileNameRules() {
    let name = "...\u{0001}e\u{0301} /: \u{202E}👩‍💻"

    #expect(FileNameSanitizer.sanitize(name, packageID: "com.example.saved") == "é -- 👩‍💻")
    #expect(FileNameSanitizer.sanitize("a\u{200B}\u{0301}", packageID: "com.example.saved") == "á")
}

@Test func fileNameSanitizerTruncatesAtGraphemeBoundaries() {
    let name = String(repeating: "a", count: 199) + "😀"

    #expect(FileNameSanitizer.sanitize(name, packageID: "com.example.saved") == String(repeating: "a", count: 199))
    #expect(
        FileNameSanitizer.sanitize(String(repeating: "a", count: 200), packageID: "com.example.saved").utf8.count == 200
    )
}

@Test func fileNameSanitizerFallsBackToPackageSegmentWhenNameIsEmpty() {
    #expect(FileNameSanitizer.sanitize("...\u{0000}\u{202E}", packageID: "com.example.saved") == "saved")
    #expect(FileNameSanitizer.sanitize("...", packageID: "invalid") == "invalid")
    #expect(FileNameSanitizer.sanitize("...", packageID: "com.example/../../bad") == "-bad")
    #expect(FileNameSanitizer.sanitize("...", packageID: "....") == "file")
}

@Test func fileTransferLimitsAcceptExactCountAndByteBoundaries() throws {
    let files = [
        FileTransferItem(name: "large-a.bin", sizeBytes: FileTransferLimits.maximumFileBytes),
        FileTransferItem(name: "large-b.bin", sizeBytes: FileTransferLimits.maximumFileBytes),
    ]
    let totalBytes = try FileTransferLimits.validate(files)

    #expect(totalBytes == FileTransferLimits.maximumTotalBytes)
    #expect(
        try FileTransferLimits.validate(
            (0..<FileTransferLimits.maximumFileCount).map {
                FileTransferItem(name: "file-\($0)", sizeBytes: 0)
            }
        ) == 0
    )
}

@Test func fileTransferLimitsRejectEmptyBatches() {
    do {
        _ = try FileTransferLimits.validate([])
        Issue.record("Expected an empty-batch failure.")
    } catch {
        #expect(error == .emptyFileSet)
    }
}

@Test func fileTransferLimitsRejectTooManyFiles() {
    let files = (0...FileTransferLimits.maximumFileCount).map {
        FileTransferItem(name: "file-\($0)", sizeBytes: 0)
    }

    do {
        _ = try FileTransferLimits.validate(files)
        Issue.record("Expected a file-count failure.")
    } catch {
        #expect(error == .tooManyFiles(count: 21, limit: 20))
    }
}

@Test func fileTransferLimitsRejectOversizedFilesAndCombinedDrops() {
    do {
        _ = try FileTransferLimits.validate([
            FileTransferItem(name: "large.bin", sizeBytes: FileTransferLimits.maximumFileBytes + 1)
        ])
        Issue.record("Expected an individual file-size failure.")
    } catch {
        #expect(error == .fileTooLarge(name: "large.bin", bytes: FileTransferLimits.maximumFileBytes + 1))
    }

    do {
        _ = try FileTransferLimits.validate([
            FileTransferItem(name: "one.bin", sizeBytes: 1_610_612_736),
            FileTransferItem(name: "two.bin", sizeBytes: 1_610_612_736),
            FileTransferItem(name: "three.bin", sizeBytes: 1_610_612_736),
        ])
        Issue.record("Expected a combined file-size failure.")
    } catch {
        #expect(error == .fileTooLarge(name: "Files", bytes: 4_831_838_208))
    }
}

@Test func integrationFailuresExposeOnlySafeFileNames() {
    let failure = IntegrationFailure.fileTooLarge(
        name: "/private/test secret.txt",
        bytes: FileTransferLimits.maximumFileBytes + 1
    )

    #expect(failure.qualifiedCode == "integration.fileTooLarge")
    #expect(failure.parameters["file"] == .fileName("test secret.txt"))
    #expect(ErrorCatalog.entry(for: failure.qualifiedCode)?.parameters == ["file", "bytes"])
    #expect(ErrorCatalog.cliExit(for: failure) == 1)
}

@Test func unreadableFileIntegrationSettingsHaveACatalogEntry() {
    let failure = IntegrationFailure.settingsUnreadable

    #expect(failure.qualifiedCode == "integration.settingsUnreadable")
    #expect(ErrorCatalog.entry(for: failure.qualifiedCode)?.remediation?["en"] != nil)
    #expect(ErrorCatalog.cliExit(for: failure) == 1)
}

@Test func stoppedSharedFolderServiceCannotReopenRootsDuringReconfiguration() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-shared-folder-stop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let definition = SharedFolderRoot(
        id: "root",
        title: "Root",
        directoryURL: root,
        maximumAccess: .readWrite
    )
    let service = try SharedFolderService(roots: [definition])
    await service.runtimeDidStop()

    do {
        try await service.replaceConfiguration(roots: [definition], packageAccess: [:])
        Issue.record("A stopped service must not reopen configured roots.")
    } catch {
        #expect(error == .transferFailed)
    }

    do {
        _ = try await service.listRoots(packageID: "com.example.app")
        Issue.record("A stopped service must not expose roots.")
    } catch {
        #expect(error == .transferFailed)
    }
}
