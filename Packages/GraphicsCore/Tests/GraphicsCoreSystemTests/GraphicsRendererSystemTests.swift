import Darwin
import Dispatch
import Foundation
import GraphicsBridge
import GraphicsCore
import Metal
import Testing

@Test
func appBundleRuntimeLookupAllowsExpectedIdentitiesAndRejectsSymlinkEscapes() throws {
    let fileManager = FileManager.default
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent("apkrun-runtime-locator-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    func makeBundle(
        named name: String,
        identifier: String,
        buildIdentity: String = "release"
    ) throws -> URL {
        let bundle = temporaryRoot.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let executable =
            contents
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("APKRun")
        let runtime =
            contents
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("VirGLRuntime", isDirectory: true)
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data().write(to: executable)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": identifier,
                "APKRunBuildIdentity": buildIdentity,
            ],
            format: .xml,
            options: 0
        )
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        for library in [
            "libepoxy.0.dylib",
            "libEGL.dylib",
            "libGLESv2.dylib",
            "libvirglrenderer.1.dylib",
        ] {
            try Data().write(to: runtime.appendingPathComponent(library))
        }
        return executable
    }

    func isAccepted(_ executable: URL) -> Bool {
        executable.path.withCString(gb_debug_app_bundle_runtime_is_valid)
    }

    let releaseExecutable = try makeBundle(
        named: "Release",
        identifier: "io.apkrun.APKRun"
    )
    #expect(isAccepted(releaseExecutable))

    let updateTestExecutable = try makeBundle(
        named: "ReleaseUpdateTest",
        identifier: "io.apkrun.APKRun.updatetest",
        buildIdentity: "updatetest"
    )
    #expect(isAccepted(updateTestExecutable))

    let developmentExecutable = try makeBundle(
        named: "Development",
        identifier: "io.apkrun.APKRun.dev",
        buildIdentity: "dev"
    )
    #expect(isAccepted(developmentExecutable))

    let mismatchedIdentityExecutable = try makeBundle(
        named: "MismatchedIdentity",
        identifier: "io.apkrun.APKRun.updatetest"
    )
    #expect(!isAccepted(mismatchedIdentityExecutable))

    let mismatchedBundleExecutable = try makeBundle(
        named: "MismatchedBundle",
        identifier: "io.apkrun.APKRun",
        buildIdentity: "updatetest"
    )
    #expect(!isAccepted(mismatchedBundleExecutable))

    let unrecognizedExecutable = try makeBundle(
        named: "Unrecognized",
        identifier: "io.apkrun.unrecognized"
    )
    #expect(!isAccepted(unrecognizedExecutable))

    let externalRuntime = temporaryRoot.appendingPathComponent(
        "external-runtime",
        isDirectory: true
    )
    try fileManager.createDirectory(at: externalRuntime, withIntermediateDirectories: true)
    for library in [
        "libepoxy.0.dylib",
        "libEGL.dylib",
        "libGLESv2.dylib",
        "libvirglrenderer.1.dylib",
    ] {
        try Data().write(to: externalRuntime.appendingPathComponent(library))
    }

    let runtimeEscapeExecutable = try makeBundle(
        named: "RuntimeEscape",
        identifier: "io.apkrun.APKRun"
    )
    let runtimeDirectory =
        runtimeEscapeExecutable
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Frameworks/VirGLRuntime", isDirectory: true)
    try fileManager.removeItem(at: runtimeDirectory)
    try fileManager.createSymbolicLink(at: runtimeDirectory, withDestinationURL: externalRuntime)
    #expect(!isAccepted(runtimeEscapeExecutable))

    let libraryEscapeExecutable = try makeBundle(
        named: "LibraryEscape",
        identifier: "io.apkrun.APKRun"
    )
    let libraryRuntime =
        libraryEscapeExecutable
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Frameworks/VirGLRuntime", isDirectory: true)
    let escapedLibrary = libraryRuntime.appendingPathComponent("libEGL.dylib")
    try fileManager.removeItem(at: escapedLibrary)
    try fileManager.createSymbolicLink(
        at: escapedLibrary,
        withDestinationURL: externalRuntime.appendingPathComponent("libEGL.dylib")
    )
    #expect(!isAccepted(libraryEscapeExecutable))
}

@Test(
    .enabled(
        if: MTLCreateSystemDefaultDevice() != nil,
        "This host does not provide a Metal device."
    )
)
func rendererInitializesVirgl2CapsetAndCanBeRecreated() throws {
    guard let runtimeDirectory = developmentRuntimeDirectory() else {
        Issue.record("The built VirGL runtime cache is unavailable.")
        return
    }
    #expect(setenv("APKRUN_VIRGL_RUNTIME_PATH", runtimeDirectory, 1) == 0)

    for generation in 0..<2 {
        let renderer = try VirGLRenderer()
        defer { try? renderer.destroy() }

        do {
            _ = try VirGLRenderer()
            Issue.record("A second process-wide virglrenderer instance was accepted.")
        } catch let failure {
            #expect(failure.code == "rendererInitFailed")
            #expect(failure.parameters["stage"] == .text("virgl"))
            #expect(
                failure.parameters["detail"]
                    == .text("a virglrenderer instance is already active in this process")
            )
        }

        let angleDevice = try renderer.metalDevice()
        #expect(!angleDevice.name.isEmpty)

        let capsetInfo = try renderer.capsetInfo(id: GraphicsCapset.virgl2)
        #expect(capsetInfo.maxVersion > 0)
        #expect(capsetInfo.maxSizeBytes > 0)

        #expect(capsetInfo.maxSizeBytes > 1)
        var undersizedBuffer = [UInt8](
            repeating: 0,
            count: Int(capsetInfo.maxSizeBytes - 1)
        )
        #expect(
            throws: GraphicsFailure.rendererOperationFailed(
                operation: "capsetFill",
                detail: "capset output buffer is too small"
            )
        ) {
            try renderer.fillCapset(
                id: GraphicsCapset.virgl2,
                version: capsetInfo.maxVersion,
                into: &undersizedBuffer
            )
        }

        var capset = [UInt8](repeating: 0, count: Int(capsetInfo.maxSizeBytes))
        try renderer.fillCapset(
            id: GraphicsCapset.virgl2,
            version: capsetInfo.maxVersion,
            into: &capset
        )
        #expect(capset.contains(where: { $0 != 0 }))

        try renderer.createContext(id: 1, name: "apkrun-t1-\(generation)")
        try renderer.destroyContext(id: 1)
        try renderer.createContext(id: 1, name: "apkrun-t1-recreated-\(generation)")
        try renderer.reset()

        let rendererBox = RendererBox(renderer: renderer)
        let wrongThreadDetail = "graphics renderer called from a thread other than its owner"
        let metalDeviceOperation: RendererOperation = {
            _ = try rendererBox.renderer.metalDevice()
        }
        let capsetInfoOperation: RendererOperation = {
            _ = try rendererBox.renderer.capsetInfo(id: GraphicsCapset.virgl2)
        }
        let capsetFillOperation: RendererOperation = {
            var buffer = [UInt8](repeating: 0, count: Int(capsetInfo.maxSizeBytes))
            try rendererBox.renderer.fillCapset(
                id: GraphicsCapset.virgl2,
                version: capsetInfo.maxVersion,
                into: &buffer
            )
        }
        let contextCreateOperation: RendererOperation = {
            try rendererBox.renderer.createContext(id: 2, name: "wrong-thread")
        }
        let contextDestroyOperation: RendererOperation = {
            try rendererBox.renderer.destroyContext(id: 1)
        }
        let resetOperation: RendererOperation = {
            try rendererBox.renderer.reset()
        }
        let destroyOperation: RendererOperation = {
            try rendererBox.renderer.destroy()
        }
        let operations = [
            metalDeviceOperation,
            capsetInfoOperation,
            capsetFillOperation,
            contextCreateOperation,
            contextDestroyOperation,
            resetOperation,
            destroyOperation,
        ]
        let threadResults = ThreadFailureBox()
        let threadFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            threadResults.store(operations.map(captureFailure))
            threadFinished.signal()
        }
        // Quiesce every rejected off-thread call before owner-thread teardown.
        threadFinished.wait()
        let expectedFailure: (String) -> GraphicsFailure? = { operation in
            .rendererOperationFailed(operation: operation, detail: wrongThreadDetail)
        }
        #expect(
            threadResults.value
                == [
                    expectedFailure("metalDevice"),
                    expectedFailure("capsetInfo"),
                    expectedFailure("capsetFill"),
                    expectedFailure("contextCreate"),
                    expectedFailure("contextDestroy"),
                    expectedFailure("reset"),
                    expectedFailure("destroy"),
                ]
        )

        try renderer.destroyContext(id: 1)
        try renderer.reset()
        try renderer.destroy()
    }
}

private typealias RendererOperation = @Sendable () throws(GraphicsFailure) -> Void

private final class RendererBox: @unchecked Sendable {
    let renderer: VirGLRenderer

    init(renderer: VirGLRenderer) {
        self.renderer = renderer
    }
}

private final class ThreadFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [GraphicsFailure?]?

    var value: [GraphicsFailure?]? {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    func store(_ failures: [GraphicsFailure?]) {
        lock.lock()
        self.failures = failures
        lock.unlock()
    }
}

private func captureFailure(
    _ operation: () throws(GraphicsFailure) -> Void
) -> GraphicsFailure? {
    do {
        try operation()
        return nil
    } catch {
        return error
    }
}

private func developmentRuntimeDirectory() -> String? {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let fileManager = FileManager.default

    for _ in 0..<16 {
        let candidate =
            directory
            .appendingPathComponent("ThirdParty/out/virgl-runtime/current")
        if fileManager.fileExists(atPath: candidate.path) {
            return candidate.resolvingSymlinksInPath().path
        }

        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path else { return nil }
        directory = parent
    }
    return nil
}
