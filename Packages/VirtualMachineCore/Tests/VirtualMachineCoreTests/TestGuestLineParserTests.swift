import Foundation
import Testing

@testable import VirtualMachineCore

@Test
func testGuestLineParserHandlesSplitUTF8CRLFAndInterleavedKernelLines() {
    var parser = TestGuestLineParser()
    let text = """
        Booting Linux on physical CPU 0x0000000000 [0x410fd0c1]
        APKRUN-TEST: boot ok
        APKRUN-TEST: network ok route and café
        APKRUN-TEST: net ok ip=192.168.64.2 gw=192.168.64.1 dns=192.168.64.1 http=204
        APKRUN-TEST: net fail http expected HTTP 204
        APKRUN-TEST: storage fail read-only
        APKRUN-TEST: done
        """
    let bytes = Array(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    var records: [TestGuestRecord] = []

    for byte in bytes {
        records += parser.consume(Data([byte]))
    }
    records += parser.finish()

    #expect(
        records == [
            .bootOK,
            .check(name: "network", result: .ok, detail: "route and café"),
            .check(
                name: "net",
                result: .ok,
                detail: "ip=192.168.64.2 gw=192.168.64.1 dns=192.168.64.1 http=204"
            ),
            .check(name: "net", result: .fail, detail: "http expected HTTP 204"),
            .check(name: "storage", result: .fail, detail: "read-only"),
            .done,
        ]
    )
}

@Test
func testGuestLineParserFindsMarkerAfterUnterminatedKernelMessage() {
    var parser = TestGuestLineParser()

    #expect(
        parser.consume(Data("Run /init as init process".utf8)).isEmpty
    )
    #expect(
        parser.consume(
            Data("APKRUN-TEST: boot ok\r\nAPKRUN-TEST: done\n".utf8)
        ) == [.bootOK, .done]
    )
}

@Test
func testGuestLineParserParsesFinalRecordWithoutNewlineAndIgnoresMalformedMarkers() {
    var parser = TestGuestLineParser()

    #expect(parser.consume(Data("APKRUN-TEST:boot ok\n".utf8)).isEmpty)
    #expect(parser.consume(Data("APKRUN-TEST: network maybe detail\n".utf8)).isEmpty)
    #expect(parser.consume(Data("APKRUN-TEST: boot ok fail detail\n".utf8)).isEmpty)
    #expect(parser.consume(Data("APKRUN-TEST: boot ok".utf8)).isEmpty)
    #expect(parser.finish() == [.bootOK])
}

@Test
func testGuestLineParserDiscardsOverlongLinesAndRecoversAtNextLine() {
    var parser = TestGuestLineParser()
    let overlong = Data(
        "APKRUN-TEST: \(String(repeating: "x", count: 64 * 1_024))\n".utf8
    )
    let recovered = Data("APKRUN-TEST: done\n".utf8)

    #expect(parser.consume(overlong) == [])
    #expect(parser.discardedOverlongLineCount == 1)
    #expect(parser.consume(recovered) == [.done])
}

@Test
func testGuestLineParserAppliesTheSameBodyLimitToLFAndCRLF() {
    let prefix = "APKRUN-TEST: network ok "
    let detailAtLimit = String(
        repeating: "x",
        count: 64 * 1_024 - prefix.utf8.count
    )
    let validLine = prefix + detailAtLimit
    let overlongLine = validLine + "x"

    for ending in ["\n", "\r\n"] {
        var validParser = TestGuestLineParser()
        #expect(
            validParser.consume(Data((validLine + ending).utf8)).count == 1
        )
        #expect(validParser.discardedOverlongLineCount == 0)

        var overlongParser = TestGuestLineParser()
        #expect(
            overlongParser.consume(Data((overlongLine + ending).utf8)).isEmpty
        )
        #expect(overlongParser.discardedOverlongLineCount == 1)
    }
}
