import SwiftUI
import UniformTypeIdentifiers

/// Adds file-only drag and drop to the app-owned window content.
@MainActor
struct DropTarget<Content: View>: View {
    private let isEnabled: Bool
    private let onReject: (FileDropValidation.Failure) -> Void
    private let onImportFailure: (any Error) -> Void
    private let onImport: ([FileDropValidation.Item]) async throws -> Void
    private let content: (Bool) -> Content

    @State private var isTargeted = false

    /// Creates a drop target whose content can reflect its current drag state.
    init(
        isEnabled: Bool = true,
        onReject: @escaping (FileDropValidation.Failure) -> Void,
        onImportFailure: @escaping (any Error) -> Void,
        onImport: @escaping ([FileDropValidation.Item]) async throws -> Void,
        @ViewBuilder content: @escaping (_ isTargeted: Bool) -> Content
    ) {
        self.isEnabled = isEnabled
        self.onReject = onReject
        self.onImportFailure = onImportFailure
        self.onImport = onImport
        self.content = content
    }

    var body: some View {
        content(isTargeted && isEnabled)
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted, perform: accept)
    }

    private func accept(_ providers: [NSItemProvider]) -> Bool {
        guard isEnabled else {
            return false
        }
        guard !providers.isEmpty else {
            return false
        }
        guard providers.count <= FileDropValidation.maximumFileCount else {
            onReject(.tooManyFiles)
            return true
        }
        guard providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            onReject(.nonFileURL)
            return true
        }

        Task { @MainActor in
            do {
                let urls = try await Self.fileURLs(from: providers)
                let access = urls.map { $0.startAccessingSecurityScopedResource() }
                defer {
                    for (url, didStartAccessing) in zip(urls, access) where didStartAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let files = try FileDropValidation.inspect(urls)
                try await onImport(files)
            } catch let failure as FileDropValidation.Failure {
                onReject(failure)
            } catch {
                onImportFailure(error)
            }
        }
        return true
    }

    private static func fileURLs(from providers: [NSItemProvider]) async throws -> [URL] {
        var urls: [URL] = []
        urls.reserveCapacity(providers.count)
        for provider in providers {
            urls.append(try await fileURL(from: provider))
        }
        return urls
    }

    private static func fileURL(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let fileURL = item as? NSURL else {
                    continuation.resume(throwing: FileDropValidation.Failure.nonFileURL)
                    return
                }
                let url = fileURL as URL
                guard url.isFileURL else {
                    continuation.resume(throwing: FileDropValidation.Failure.nonFileURL)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}
