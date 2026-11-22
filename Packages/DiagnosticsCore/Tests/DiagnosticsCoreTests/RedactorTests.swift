import Foundation
import XCTest

@testable import DiagnosticsCore

/// Layer 3 and 4 redaction rules on fixture text (diagnostics.md §6).
final class RedactorTests: XCTestCase {
    private func identity(secrets: [String] = []) -> RedactionIdentity {
        RedactionIdentity(
            homeDirectory: "/Users/kim",
            userName: "kim",
            fullUserName: "Kim Example",
            computerName: "KimsMac",
            localHostName: "KimsMac.local",
            preservedPaths: [
                "/Users/kim/Library/Application Support/APKRun",
                "/Users/kim/Library/Logs/APKRun",
            ],
            preservedURLHosts: ["updates.apkrun.example"],
            knownSecrets: secrets
        )
    }

    func testNamesAndHomeDirectory() {
        let redactor = Redactor(identity: identity())
        let out = redactor.redact(
            "user kim on KimsMac opened /Users/kim/secret/key.pem and "
                + "/Users/kim/Library/Application Support/APKRun/settings.json")
        XCTAssertFalse(out.contains("kim"))
        XCTAssertTrue(out.contains("~/…/key.pem"))
        XCTAssertTrue(out.contains("~/Library/Application Support/APKRun/settings.json"))
        XCTAssertTrue(out.contains("<user>"))
        XCTAssertTrue(out.contains("<computer>"))
    }

    func testURLsEmailsIPsMACsAndContentURIs() {
        let redactor = Redactor(identity: identity())
        let out = redactor.redact(
            "GET https://example.com/path?q=1#f mail a@b.co ip 10.0.0.9 nat 192.168.64.3 "
                + "loop 127.0.0.1 v6 2001:db8::1 mac aa:bb:cc:dd:ee:ff "
                + "content://com.app.provider/files/x.png")
        XCTAssertTrue(out.contains("https://example.com/…"))
        XCTAssertTrue(out.contains("<email>"))
        XCTAssertTrue(out.contains("<ip>"))
        XCTAssertTrue(out.contains("192.168.64.3"))
        XCTAssertTrue(out.contains("127.0.0.1"))
        XCTAssertTrue(out.contains("<mac>"))
        XCTAssertTrue(out.contains("content://com.app.provider/…"))
        XCTAssertFalse(out.contains("2001:db8::1"))
    }

    func testPreservedEndpointKeepsPath() {
        let redactor = Redactor(identity: identity())
        let out = redactor.redact("feed https://updates.apkrun.example/feed.json?v=1")
        XCTAssertTrue(out.contains("https://updates.apkrun.example/feed.json?v=1"))
    }

    func testSecretKeyValueAndProviderTokens() {
        let redactor = Redactor(identity: identity())
        let out = redactor.redact(
            "authorization: Bearer abc.def\npassword=hunter2\nghp_" + String(repeating: "a", count: 40))
        XCTAssertFalse(out.contains("hunter2"))
        XCTAssertFalse(out.contains("ghp_"))
        XCTAssertTrue(out.contains("<redacted:secret>"))
        XCTAssertTrue(out.contains("<redacted:token>"))
    }

    func testJWTPEMAndBase64() {
        let redactor = Redactor(identity: identity())
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc123def456"
        let pem = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"
        let b64 = String(repeating: "QUJD", count: 20)
        let sha = String(repeating: "ab12", count: 16)  // pure hex: not a base64 hit
        let out = redactor.redact("\(jwt)\n\(pem)\n\(b64)\nsha256 \(sha)")
        XCTAssertFalse(out.contains("eyJ"))
        XCTAssertFalse(out.contains("PRIVATE KEY"))
        XCTAssertFalse(out.contains("QUJD"))
        XCTAssertTrue(out.contains(sha))
    }

    func testKnownSecretsInAllForms() {
        let secret = "APKRUN-FIXTURE-SECRET-1 value?"
        let redactor = Redactor(identity: identity(secrets: [secret]))
        let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let b64 = secret.data(using: .utf8)!.base64EncodedString()
        let out = redactor.redact("a \(secret) b \(encoded) c \(b64)")
        XCTAssertFalse(out.contains(secret))
        XCTAssertFalse(out.contains(encoded))
        XCTAssertFalse(out.contains(b64))
        XCTAssertEqual(redactor.redactionCounts["knownSecret"], 3)
    }

    func testContainsKnownSecretUTF16() {
        let secret = "APKRUN-FIXTURE-SECRET-9"
        let redactor = Redactor(identity: identity(secrets: [secret]))
        var data = "prefix ".data(using: .utf8)!
        data.append(secret.data(using: .utf16LittleEndian)!)
        XCTAssertTrue(redactor.containsKnownSecret(in: data))
        XCTAssertFalse(redactor.containsKnownSecret(in: "clean".data(using: .utf8)!))
    }

    func testStablePlaceholders() {
        let redactor = Redactor(identity: identity())
        XCTAssertEqual(redactor.placeholder(for: "S1", kind: "serial"), "<serial-1>")
        XCTAssertEqual(redactor.placeholder(for: "S1", kind: "serial"), "<serial-1>")
        XCTAssertEqual(redactor.placeholder(for: "U1", kind: "uuid"), "<uuid-1>")
    }

    func testGetpropAllowlist() {
        XCTAssertTrue(DiagnosticsAllowlists.allowsGetprop("ro.build.fingerprint"))
        XCTAssertTrue(DiagnosticsAllowlists.allowsGetprop("ro.build.version.sdk"))
        XCTAssertTrue(DiagnosticsAllowlists.allowsGetprop("init.svc.adbd"))
        XCTAssertTrue(DiagnosticsAllowlists.allowsGetprop("ro.apkrun.image.version"))
        XCTAssertFalse(DiagnosticsAllowlists.allowsGetprop("ro.serialno"))
        XCTAssertFalse(DiagnosticsAllowlists.allowsGetprop("ro.boot.serialno"))
        XCTAssertFalse(DiagnosticsAllowlists.allowsGetprop("net.hostname"))
    }

    func testPackageRecordFilter() {
        let record: [String: Any] = [
            "packageID": "com.example.app",
            "signerDigest": "aabbccddeeff001122334455",
            "providerToken": "must-not-leak",
        ]
        let filtered = DiagnosticsAllowlists.filterPackageRecord(record)
        XCTAssertEqual(filtered["packageID"] as? String, "com.example.app")
        XCTAssertEqual(filtered["signerDigest"] as? String, "aabbccddeeff")
        XCTAssertNil(filtered["providerToken"])
    }

    func testUnitSeparatorCut() {
        XCTAssertEqual(
            DiagnosticsAllowlists.cutAtUnitSeparator("public\u{001F}private"),
            "public")
        XCTAssertEqual(DiagnosticsAllowlists.cutAtUnitSeparator("plain"), "plain")
    }

    func testBootconfigPlaceholders() {
        let redactor = Redactor(identity: identity())
        let out = DiagnosticsAllowlists.redactBootconfig(
            "androidboot.serialno=REALSERIAL androidboot.apkrun.instance_uuid=REALUUID",
            redactor: redactor)
        XCTAssertTrue(out.contains("androidboot.serialno=<serial-1>"))
        XCTAssertTrue(out.contains("androidboot.apkrun.instance_uuid=<uuid-1>"))
    }
}
