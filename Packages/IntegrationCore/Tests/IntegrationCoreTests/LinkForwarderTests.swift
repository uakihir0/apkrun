import Foundation
import GuestProtocol
import RuntimeAPI
import Testing

@testable import IntegrationCore

/// The link validation, policy, rate limit, and prompt flow of
/// desktop-integration.md §7.2 (issue #82).
@Suite("LinkForwarder (desktop-integration.md §7.2)")
struct LinkForwarderTests {

    private final class FakeChannel: LinkChannel, @unchecked Sendable {
        var supports = true
        var resolves: [(UInt64, GPUrlAction)] = []
        var redirects: [(Bool, [String])] = []
        var failResolve = false

        func supportsLinks() async -> Bool { supports }

        func resolveUrl(requestID: UInt64, action: GPUrlAction) async throws(IntegrationFailure) {
            if failResolve { throw .guestUnavailable }
            resolves.append((requestID, action))
        }

        func setUrlRedirect(enabled: Bool, excludedPackages: [String]) async throws(IntegrationFailure) {
            redirects.append((enabled, excludedPackages))
        }
    }

    private final class FakeOpener: LinkOpener, @unchecked Sendable {
        var opened: [URL] = []
        func open(_ url: URL) async { opened.append(url) }
    }

    private struct Rig: Sendable {
        let channel = FakeChannel()
        let opener = FakeOpener()
        var packageValues: [String: String] = [:]
        var state = LinkWindowState(sessionID: UUID(), usable: true)
        var presented: [(UUID, RuntimePackageID, LinkPrompt)] = []
        var writes: [(RuntimePackageID, String)] = []
        var drops: [(RuntimePackageID, LinkRejection)] = []
        var excluded: [String] = []

        mutating func forwarder() -> LinkForwarder {
            let values = packageValues
            let state = state
            let presentedBox = Box<[(UUID, RuntimePackageID, LinkPrompt)]>([])
            let writesBox = Box<[(RuntimePackageID, String)]>([])
            let dropsBox = Box<[(RuntimePackageID, LinkRejection)]>([])
            let excluded = excluded
            let forwarder = LinkForwarder(
                policy: IntegrationPolicy(
                    source: IntegrationSettingsSource(
                        packageValue: { _, package in values[package.rawValue] },
                        globalEnabled: { _ in true },
                        supported: { _ in true }
                    )),
                channel: channel,
                opener: opener,
                linksValue: { package in values[package.rawValue] },
                windowState: { _ in state },
                presentPrompt: { session, package, prompt in
                    presentedBox.value.append((session, package, prompt))
                },
                setLinksValue: { package, value in writesBox.value.append((package, value)) },
                excludedPackages: { excluded },
                logDrop: { package, rejection, _ in dropsBox.value.append((package, rejection)) }
            )
            presentedHook = { presentedBox.value }
            writesHook = { writesBox.value }
            dropsHook = { dropsBox.value }
            return forwarder
        }

        var presentedHook: @Sendable () -> [(UUID, RuntimePackageID, LinkPrompt)] = { [] }
        var writesHook: @Sendable () -> [(RuntimePackageID, String)] = { [] }
        var dropsHook: @Sendable () -> [(RuntimePackageID, LinkRejection)] = { [] }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func event(
        url: String,
        package: String = "io.app",
        requestID: UInt64 = 1
    ) -> GPOpenUrlOnHost {
        var event = GPOpenUrlOnHost()
        event.requestID = requestID
        event.url = url
        event.sourcePackage = package
        event.displayID = 1
        return event
    }

    // MARK: Validation (§7.2, T0)

    @Test("http, https, and mailto validate")
    func validSchemes() {
        #expect(LinkForwarder.validatedURL("https://example.com/") != nil)
        #expect(LinkForwarder.validatedURL("http://example.com") != nil)
        #expect(LinkForwarder.validatedURL("mailto:test@example.com") != nil)
        #expect(LinkForwarder.validatedURL("https://例え.jp/パス") != nil)
    }

    @Test("javascript, intent, file, and custom schemes are dropped")
    func badSchemes() {
        #expect(LinkForwarder.validatedURL("javascript:alert(1)") == nil)
        #expect(LinkForwarder.validatedURL("intent://x/#Intent;end") == nil)
        #expect(LinkForwarder.validatedURL("file:///etc/passwd") == nil)
        #expect(LinkForwarder.validatedURL("myapp://callback") == nil)
        #expect(LinkForwarder.validatedURL("FTP://example.com") == nil)
    }

    @Test("an http(s) link needs a host")
    func hostRequired() {
        #expect(LinkForwarder.validatedURL("https:///nohost") == nil)
        #expect(LinkForwarder.validatedURL("https://") == nil)
    }

    @Test("a link over 8 KiB is dropped")
    func tooLong() {
        let long = "https://example.com/" + String(repeating: "a", count: 8 * 1024)
        #expect(LinkForwarder.validatedURL(long) == nil)
        let justUnder = "https://e.co/" + String(repeating: "a", count: 8 * 1024 - 14)
        #expect(LinkForwarder.validatedURL(justUnder) != nil)
    }

    @Test("registrable domains")
    func registrableDomain() {
        #expect(LinkForwarder.registrableDomain(of: "www.example.com") == "example.com")
        #expect(LinkForwarder.registrableDomain(of: "example.com") == "example.com")
        #expect(LinkForwarder.registrableDomain(of: "a.b.example.co.jp") == "example.co.jp")
        #expect(LinkForwarder.registrableDomain(of: "evil.github.io") == "evil.github.io")
        #expect(LinkForwarder.registrableDomain(of: "a.b.c.github.io") == "c.github.io")
        #expect(LinkForwarder.registrableDomain(of: "sub.appspot.com") == "sub.appspot.com")
        #expect(LinkForwarder.registrableDomain(of: "localhost") == "localhost")
        #expect(LinkForwarder.registrableDomain(of: "例え.jp") == "例え.jp")
    }

    // MARK: Forwarding decisions (§7.2)

    @Test("an invalid link answers DROP and is counted")
    func invalidLinkDropped() async {
        var rig = Rig()
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(event(url: "javascript:alert(1)"))
        #expect(outcome == .dropped(.scheme))
        #expect(rig.channel.resolves.map(\.1) == [.drop])
        #expect(rig.dropsHook().map(\.1) == [.scheme])
    }

    @Test("links = mac opens the validated URL on the host")
    func macOpens() async {
        var rig = Rig()
        rig.packageValues = ["io.app": "mac"]
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(event(url: "https://example.com/a?q=1"))
        #expect(outcome == .openedOnHost)
        #expect(rig.opener.opened == [URL(string: "https://example.com/a?q=1")!])
        #expect(rig.channel.resolves.map(\.1) == [.openedOnHost])
    }

    @Test("links = android answers OPEN_IN_GUEST")
    func androidStays() async {
        var rig = Rig()
        rig.packageValues = ["io.app": "android"]
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(event(url: "https://example.com/"))
        #expect(outcome == .openInGuest)
        #expect(rig.channel.resolves.map(\.1) == [.openInGuest])
        #expect(rig.opener.opened.isEmpty)
    }

    @Test("links = off is denied and dropped")
    func offDenied() async {
        var rig = Rig()
        rig.packageValues = ["io.app": "off"]
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(event(url: "https://example.com/"))
        #expect(outcome == .denied(.packageOff))
        #expect(rig.channel.resolves.map(\.1) == [.drop])
    }

    @Test("a link without a key window is dropped as notFocused")
    func noSessionDrops() async {
        var rig = Rig()
        rig.state = LinkWindowState(sessionID: nil, usable: false)
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(event(url: "https://example.com/"))
        #expect(outcome == .dropped(.notFocused))
        #expect(rig.channel.resolves.map(\.1) == [.drop])
    }

    @Test("the fourth link in 10 s is rate limited")
    func rateLimited() async {
        var rig = Rig()
        rig.packageValues = ["io.app": "android"]
        let forwarder = rig.forwarder()
        for i in 0..<4 {
            _ = await forwarder.openUrlOnHost(
                event(url: "https://example.com/\(i)", requestID: UInt64(i + 1)))
        }
        #expect(rig.channel.resolves.map(\.1) == [.openInGuest, .openInGuest, .openInGuest, .drop])
    }

    @Test("ask publishes the prompt to the key window")
    func askPrompts() async throws {
        var rig = Rig()
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(
            event(url: "https://sub.example.com/oauth/cb"))
        guard case .prompted(let prompt) = outcome else {
            Issue.record("expected a prompt, got \(outcome)")
            return
        }
        #expect(prompt.scheme == "https")
        #expect(prompt.registrableDomain == "example.com")
        #expect(prompt.signInHint)
        #expect(prompt.keepInAndroidAvailable)
        #expect(rig.presentedHook().count == 1)
    }

    @Test("the prompt never carries the path or query")
    func promptHidesPath() async throws {
        var rig = Rig()
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(
            event(url: "https://www.example.co.jp/secret/path?token=abc"))
        guard case .prompted(let prompt) = outcome else {
            Issue.record("expected a prompt, got \(outcome)")
            return
        }
        #expect(prompt.host == "www.example.co.jp")
        #expect(prompt.registrableDomain == "example.co.jp")
        #expect(!prompt.signInHint)
        let encoded = String(describing: prompt)
        #expect(!encoded.contains("token"))
        #expect(!encoded.contains("secret"))
    }

    @Test("a mailto prompt shows the address without the query")
    func mailtoPromptStripsQuery() async throws {
        var rig = Rig()
        rig.packageValues["io.app"] = "ask"
        rig.state.sessionID = UUID()
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(
            event(url: "mailto:team@example.com?subject=hi&body=secret%20draft", package: "io.app"))
        guard case .prompted(let prompt) = outcome else {
            Issue.record("expected a prompt, got \(outcome)")
            return
        }
        #expect(prompt.host == "team@example.com")
        let encoded = String(describing: prompt)
        #expect(!encoded.contains("secret"))
        #expect(!encoded.contains("subject"))
    }

    @Test("a wrapper cannot answer another package's prompt (NFR-SEC-07)")
    func resolvePromptWrongPackage() async throws {
        var rig = Rig()
        rig.packageValues["io.victim"] = "ask"
        rig.state.sessionID = UUID()
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(
            event(url: "https://example.com/", package: "io.victim"))
        guard case .prompted(let prompt) = outcome else {
            Issue.record("expected a prompt")
            return
        }
        await #expect(throws: IntegrationFailure.self) {
            try await forwarder.resolvePrompt(
                sessionID: rig.state.sessionID!,
                promptID: prompt.promptID,
                choice: .openOnMac,
                remember: true,
                callerPackageID: RuntimePackageID(rawValue: "io.impostor"))
        }
        // A rejected resolve consumes the entry, like a real timeout does.
        #expect(rig.opener.opened.isEmpty)
        #expect(rig.writesHook().isEmpty)
    }

    @Test("resolvePrompt openOnMac opens and remembers")
    func resolveOpenOnMac() async throws {
        var rig = Rig()
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(event(url: "https://example.com/"))
        guard case .prompted(let prompt) = outcome else {
            Issue.record("expected a prompt")
            return
        }
        let sessionID = rig.state.sessionID!
        try await forwarder.resolvePrompt(
            sessionID: sessionID, promptID: prompt.promptID, choice: .openOnMac, remember: true)
        #expect(rig.opener.opened == [URL(string: "https://example.com/")!])
        #expect(rig.channel.resolves.map(\.1) == [.openedOnHost])
        #expect(rig.writesHook().map(\.1) == ["mac"])
    }

    @Test("resolvePrompt keepInAndroid answers OPEN_IN_GUEST and remembers")
    func resolveKeepInAndroid() async throws {
        var rig = Rig()
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(event(url: "https://example.com/"))
        guard case .prompted(let prompt) = outcome else {
            Issue.record("expected a prompt")
            return
        }
        try await forwarder.resolvePrompt(
            sessionID: rig.state.sessionID!,
            promptID: prompt.promptID,
            choice: .keepInAndroid,
            remember: true)
        #expect(rig.channel.resolves.map(\.1) == [.openInGuest])
        #expect(rig.writesHook().map(\.1) == ["android"])
    }

    @Test("resolvePrompt cancel drops and does not remember")
    func resolveCancel() async throws {
        var rig = Rig()
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(event(url: "https://example.com/"))
        guard case .prompted(let prompt) = outcome else {
            Issue.record("expected a prompt")
            return
        }
        try await forwarder.resolvePrompt(
            sessionID: rig.state.sessionID!,
            promptID: prompt.promptID,
            choice: .cancel,
            remember: true)
        #expect(rig.channel.resolves.map(\.1) == [.drop])
        #expect(rig.writesHook().isEmpty)
    }

    @Test("an unanswered prompt expires, drops, and refuses late answers")
    func promptExpiry() async throws {
        let rig = Rig()
        let forwarder = LinkForwarder(
            policy: IntegrationPolicy(
                source: IntegrationSettingsSource(
                    packageValue: { _, _ in nil },
                    globalEnabled: { _ in true },
                    supported: { _ in true }
                )),
            channel: rig.channel,
            opener: rig.opener,
            linksValue: { _ in nil },
            windowState: { _ in rig.state },
            presentPrompt: { _, _, _ in },
            setLinksValue: { _, _ in },
            promptLifetime: .milliseconds(50)
        )
        let outcome = await forwarder.openUrlOnHost(event(url: "https://example.com/"))
        guard case .prompted(let prompt) = outcome else {
            Issue.record("expected a prompt")
            return
        }
        // Wait for the 50 ms lifetime to expire instead of a fixed sleep: on a
        // loaded CI runner the expiry task can be scheduled late, so poll.
        for _ in 0..<40 {
            if rig.channel.resolves.map(\.1) == [.drop] { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(rig.channel.resolves.map(\.1) == [.drop])
        await #expect(throws: IntegrationFailure.promptTimedOut) {
            try await forwarder.resolvePrompt(
                sessionID: rig.state.sessionID!,
                promptID: prompt.promptID,
                choice: .openOnMac,
                remember: false)
        }
    }

    @Test("an unknown prompt throws promptTimedOut")
    func unknownPrompt() async {
        var rig = Rig()
        let forwarder = rig.forwarder()
        await #expect(throws: IntegrationFailure.promptTimedOut) {
            try await forwarder.resolvePrompt(
                sessionID: UUID(), promptID: UUID(), choice: .cancel, remember: false)
        }
    }

    @Test("pushUrlRedirect sends the enabled switch and the excluded list")
    func pushUrlRedirect() async {
        var rig = Rig()
        rig.excluded = ["io.a", "io.b"]
        let forwarder = rig.forwarder()
        await forwarder.pushUrlRedirect(enabled: true)
        #expect(rig.channel.redirects.count == 1)
        #expect(rig.channel.redirects[0].0 == true)
        #expect(rig.channel.redirects[0].1 == ["io.a", "io.b"])
    }

    @Test("ask without the url.v1 capability is notSupported")
    func askNeedsCapability() async {
        var rig = Rig()
        rig.channel.supports = false
        let forwarder = rig.forwarder()
        let outcome = await forwarder.openUrlOnHost(event(url: "https://example.com/"))
        #expect(outcome == .denied(.notSupported))
        #expect(rig.channel.resolves.map(\.1) == [.drop])
    }
}
