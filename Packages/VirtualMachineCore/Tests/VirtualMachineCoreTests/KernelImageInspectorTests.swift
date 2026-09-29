import Foundation
import Testing

@testable import VirtualMachineCore

@Test func kernelHeaderFixturesIdentifySupportedAndRejectedFormats() throws {
    #expect(try kernelHeader("image-arm64.bin") == .arm64Image)
    #expect(try kernelHeader("gzip.bin") == .gzip)
    #expect(try kernelHeader("lz4-legacy.bin") == .lz4)
    #expect(try kernelHeader("lz4-frame.bin") == .lz4)
    #expect(try kernelHeader("zboot-gzip.bin") == .zboot)
    #expect(try kernelHeader("x86-bzimage.bin") == .unknown)
    #expect(try kernelHeader("zeros.bin") == .unknown)
}

@Test func kernelImageHeaderDetectionRequiresCompleteMagicAtExpectedOffsets() {
    #expect(KernelImageInspector.inspect(Data([0x1F])) == .unknown)
    #expect(KernelImageInspector.inspect(Data(repeating: 0, count: 0x3B)) == .unknown)
    #expect(KernelImageInspector.inspect(Data([0x4D, 0x5A, 0, 0, 0x7A, 0x69, 0x6D])) == .unknown)
}

private func kernelHeader(_ name: String) throws -> KernelImageFormat {
    let fixtureDirectory = try #require(
        Bundle.module.url(forResource: "kernel-headers", withExtension: nil)
    )
    let data = try Data(contentsOf: fixtureDirectory.appending(path: name))
    #expect(data.count == 64)
    return KernelImageInspector.inspect(data)
}
