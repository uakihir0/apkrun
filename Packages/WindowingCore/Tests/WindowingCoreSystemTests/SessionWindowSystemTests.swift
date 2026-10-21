import AppKit
import CoreGraphics
import Foundation
@preconcurrency import IOSurface
import ImageIO
import XCTest

@testable import WindowingCore

@MainActor
final class SessionWindowSystemTests: XCTestCase {
    func testIOSurfaceFrameReplacesThePlaceholderInANativeWindowScreenshot() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip(
                "Screen Recording access is required to capture the test window; grant it to the test runner.")
        }

        let source = try SyntheticFrameSource()
        let previousPolicy = NSApplication.shared.activationPolicy()
        XCTAssertTrue(NSApplication.shared.setActivationPolicy(.regular))
        defer {
            XCTAssertTrue(NSApplication.shared.setActivationPolicy(previousPolicy))
        }

        let title = "APKRun T1 \(UUID().uuidString)"
        let windowController = SessionWindowController(
            source: source,
            title: title,
            backingScale: 1,
            allowsResize: false,
            holdsPlaceholderUntilAppRunning: true
        )
        defer { windowController.close() }

        NSApplication.shared.activate(ignoringOtherApps: true)
        windowController.show()

        let window = try XCTUnwrap(NSApplication.shared.windows.first { $0.title == title })
        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNil(window.toolbar)
        XCTAssertTrue(
            Self.containsAccessibilityLabel("\(title), Starting Android", in: try XCTUnwrap(window.contentView)),
            "the placeholder should expose its app name and launch status"
        )

        let screenshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-windowing-t1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: screenshotDirectory) }

        let placeholderScreenshot = screenshotDirectory.appendingPathComponent("placeholder.png")
        try await Self.waitForPlaceholderContent(window: window, screenshot: placeholderScreenshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: placeholderScreenshot.path))
        XCTAssertTrue(
            Self.hasPlaceholderContent(in: placeholderScreenshot, window: window),
            "the content area should show the placeholder's icon or text"
        )
        XCTAssertFalse(
            Self.hasRedFrame(in: placeholderScreenshot), "the placeholder should remain before a frame arrives")
        Self.attach(placeholderScreenshot, named: "placeholder.png", to: self)

        let frameDisplayed = expectation(description: "Core Animation committed the synthetic IOSurface")
        source.onFrameDisplayed = { generation, sequence in
            XCTAssertEqual(generation, 1)
            XCTAssertEqual(sequence, 1)
            frameDisplayed.fulfill()
        }
        source.send(.frameReady(generation: 1, bufferIndex: 0, sequence: 1))
        await fulfillment(of: [frameDisplayed], timeout: 10)

        let startupFrameScreenshot = screenshotDirectory.appendingPathComponent("startup-frame.png")
        try Self.capture(window: window, to: startupFrameScreenshot)
        XCTAssertFalse(
            Self.hasRedFrame(in: startupFrameScreenshot),
            "an Android frame must remain covered until the app session reaches running"
        )
        XCTAssertTrue(
            Self.hasPlaceholderContent(in: startupFrameScreenshot, window: window),
            "the placeholder should remain visible while the app is launching"
        )
        Self.attach(startupFrameScreenshot, named: "startup-frame.png", to: self)

        windowController.appDidPresentFirstFrame()

        let frameScreenshot = screenshotDirectory.appendingPathComponent("iosurface-frame.png")
        try Self.capture(window: window, to: frameScreenshot)
        XCTAssertTrue(Self.hasRedFrame(in: frameScreenshot))
        Self.attach(frameScreenshot, named: "iosurface-frame.png", to: self)
    }

    private static func capture(window: NSWindow, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), destination.path]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let error = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "screencapture failed for window \(window.windowNumber): \(error)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), error)
    }

    private static func hasRedFrame(in url: URL) -> Bool {
        guard let bitmap = bitmap(in: url)
        else {
            return false
        }
        let point = NSPoint(x: CGFloat(bitmap.pixelsWide / 2), y: CGFloat(bitmap.pixelsHigh * 3 / 5))
        guard let color = bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.deviceRGB) else {
            return false
        }
        return color.redComponent > 0.65 && color.greenComponent < 0.4 && color.blueComponent < 0.4
    }

    private static func waitForPlaceholderContent(window: NSWindow, screenshot: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            try? FileManager.default.removeItem(at: screenshot)
            try capture(window: window, to: screenshot)
            if hasPlaceholderContent(in: screenshot, window: window) {
                return
            }
            await Task.yield()
        }
        XCTFail("the placeholder did not appear in the native window content area before the deadline")
    }

    private static func hasPlaceholderContent(in url: URL, window: NSWindow) -> Bool {
        guard let bitmap = bitmap(in: url), let contentView = window.contentView else { return false }
        let scaleX = CGFloat(bitmap.pixelsWide) / window.frame.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / window.frame.height
        let contentTop = (window.frame.height - contentView.bounds.height) * scaleY
        let contentHeight = contentView.bounds.height * scaleY
        var brightPixels = 0
        let minX = Int(CGFloat(bitmap.pixelsWide) * 0.2)
        let maxX = Int(CGFloat(bitmap.pixelsWide) * 0.8)
        let minY = Int(contentTop + contentHeight * 0.1)
        let maxY = Int(contentTop + contentHeight * 0.9)
        let strideInPixels = max(1, Int(4 * min(scaleX, scaleY)))
        for y in stride(from: minY, to: min(maxY, bitmap.pixelsHigh), by: strideInPixels) {
            for x in stride(from: minX, to: maxX, by: strideInPixels) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent > 0.65 && color.greenComponent > 0.65 && color.blueComponent > 0.65 {
                    brightPixels += 1
                }
            }
        }
        return brightPixels >= 20
    }

    private static func containsAccessibilityLabel(_ label: String, in view: NSView) -> Bool {
        if view.accessibilityLabel() == label {
            return true
        }
        return view.subviews.contains { containsAccessibilityLabel(label, in: $0) }
    }

    private static func bitmap(in url: URL) -> NSBitmapImageRep? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func attach(_ url: URL, named name: String, to testCase: XCTestCase) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}

private final class SyntheticFrameSource: FrameSource, @unchecked Sendable {
    private let surfaceSet: FrameSurfaceSet
    private let stream: AsyncStream<FrameSourceEvent>
    private let continuation: AsyncStream<FrameSourceEvent>.Continuation
    private let lock = NSLock()
    private var frameDisplayedHandler: (@Sendable (UInt64, UInt64) -> Void)?

    init() throws {
        let width = 256
        let height = 256
        let rowBytes = width * 4
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .bytesPerRow: rowBytes,
            .pixelFormat: UInt32(0x4247_5241),  // BGRA
        ]
        guard let surface = IOSurface(properties: properties) else {
            throw XCTSkip("The host could not allocate a synthetic IOSurface.")
        }
        let lockOptions = IOSurfaceLockOptions(rawValue: 0)
        guard IOSurfaceLock(surface, lockOptions, nil) == kIOReturnSuccess else {
            throw XCTSkip("The host could not lock a synthetic IOSurface.")
        }
        defer { IOSurfaceUnlock(surface, lockOptions, nil) }

        let address = IOSurfaceGetBaseAddress(surface)
        let pixels = address.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                pixels[offset] = 0x20
                pixels[offset + 1] = 0x20
                pixels[offset + 2] = 0xF0
                pixels[offset + 3] = 0xFF
            }
        }

        surfaceSet = FrameSurfaceSet(
            generation: 1,
            surfaces: [surface],
            pixelWidth: width,
            pixelHeight: height,
            contentSize: CGSize(width: width, height: height),
            contentsScale: 1,
            zoom: 1
        )
        let pair = AsyncStream.makeStream(of: FrameSourceEvent.self, bufferingPolicy: .bufferingNewest(8))
        stream = pair.stream
        continuation = pair.continuation
    }

    var onFrameDisplayed: (@Sendable (UInt64, UInt64) -> Void)? {
        get { lock.withLock { frameDisplayedHandler } }
        set { lock.withLock { frameDisplayedHandler = newValue } }
    }

    var currentSurfaceSet: FrameSurfaceSet { surfaceSet }
    var surfaces: [IOSurface] { surfaceSet.surfaces }
    var generation: UInt64 { surfaceSet.generation }
    var pixelWidth: Int { surfaceSet.pixelWidth }
    var pixelHeight: Int { surfaceSet.pixelHeight }
    var frames: AsyncStream<FrameSourceEvent> { stream }

    func surfaceSet(generation: UInt64) -> FrameSurfaceSet? {
        generation == surfaceSet.generation ? surfaceSet : nil
    }

    func frameDisplayed(generation: UInt64, sequence: UInt64) {
        onFrameDisplayed?(generation, sequence)
    }

    func send(_ event: FrameSourceEvent) {
        continuation.yield(event)
    }
}
