import Foundation
import Testing

@Test
func linuxGuestConsoleCaptureBoundsOutputAndCountsOmittedBytes() {
    let capture = LinuxGuestConsoleCapture(maximumBytes: 8)
    capture.append(Data("abc".utf8))
    capture.append(Data("defghi".utf8))

    let snapshot = capture.snapshot()
    #expect(String(decoding: snapshot.bytes, as: UTF8.self) == "bcdefghi")
    #expect(snapshot.omittedByteCount == 1)
}
