import Foundation
import Testing

@testable import RuntimeAPI

private func approvalRoundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Value.self, from: data)
}

/// T0 of #48: DTO round trips of the approval operations (runtime-api.md §3.4,
/// §10.6, §10.9).
@Test func approvalPromptAndEventsRoundTrip() throws {
    let prompt = ApprovalPrompt(
        approvalID: ApprovalID(rawValue: "approval-1"),
        kind: .wrapper,
        bundleURL: URL(fileURLWithPath: "/Users/x/Downloads/Discord.app"),
        bundleID: "io.apkrun.android.com.discord",
        packageID: RuntimePackageID(rawValue: "com.discord")!,
        displayName: "Discord",
        signer: .developerID(teamID: "TEAM", teamName: "Example Inc.", notarized: true),
        packageInstalled: false,
        bundledVersion: "245.0",
        replacesURL: URL(fileURLWithPath: "/Applications/Discord.app"),
        integrations: [
            .clipboard: .on,
            .links: .ask,
            .sharedFolders: .readOnly,
        ],
        icon: Data([0x89, 0x50]),
        requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
        expiresAt: Date(timeIntervalSince1970: 1_700_000_600)
    )
    #expect(try approvalRoundTrip(prompt) == prompt)

    let changes: [WrapperChange] = [
        .approvalRequested(prompt),
        .approvalResolved(prompt.approvalID),
    ]
    #expect(try changes.map(approvalRoundTrip) == changes)

    #expect(
        try approvalRoundTrip(
            ApprovalRequest(
                bundleURL: prompt.bundleURL,
                bundleID: prompt.bundleID,
                packageID: prompt.packageID
            ))
            == ApprovalRequest(
                bundleURL: prompt.bundleURL,
                bundleID: prompt.bundleID,
                packageID: prompt.packageID
            )
    )
}

@Test func approvalReplyCasesRoundTrip() throws {
    let until = Date(timeIntervalSince1970: 1_700_086_400)
    let replies: [ApprovalReply] = [
        .approved,
        .denied(until: until),
        .timedOut,
    ]
    #expect(try replies.map(approvalRoundTrip) == replies)
}

@Test func approvalOperationDTOsRoundTrip() throws {
    let header = APIRequestHeader(clientKind: .app)
    let prompt = ApprovalPrompt(
        approvalID: ApprovalID(rawValue: "approval-3"),
        kind: .wrapper,
        bundleURL: URL(fileURLWithPath: "/tmp/X.app"),
        bundleID: "io.apkrun.android.com.x",
        packageID: RuntimePackageID(rawValue: "com.x")!,
        displayName: "X",
        signer: .unknown,
        packageInstalled: true,
        installedVersion: "1.0",
        requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
        expiresAt: Date(timeIntervalSince1970: 1_700_000_600)
    )
    let denied = DeniedWrapper(
        bundleID: prompt.bundleID,
        packageID: prompt.packageID,
        cdhash: "abcd",
        until: Date(timeIntervalSince1970: 1_700_086_400)
    )

    let pendingRequest = RuntimePendingApprovalsControlRequest(header: header)
    let pendingReply = RuntimePendingApprovalsControlReply(result: [prompt])
    let decideRequest = RuntimeDecideApprovalControlRequest(
        header: header, approvalID: prompt.approvalID, allow: true)
    let decideReply = RuntimeDecideApprovalControlReply()
    let deniedRequest = RuntimeDeniedWrappersControlRequest(header: header)
    let deniedReply = RuntimeDeniedWrappersControlReply(result: [denied])
    let clearRequest = RuntimeClearWrapperDenialControlRequest(
        header: header, bundleID: denied.bundleID, cdhash: denied.cdhash)
    let clearReply = RuntimeClearWrapperDenialControlReply()
    let brokerReply = RuntimeApprovalBrokerReply(result: .approved)
    let brokerError = RuntimeApprovalBrokerReply(
        error: RuntimeWireError(domain: "runtime", code: "runtime.busy", message: "busy"))

    #expect(try approvalRoundTrip(pendingRequest) == pendingRequest)
    #expect(try approvalRoundTrip(pendingReply) == pendingReply)
    #expect(try approvalRoundTrip(decideRequest) == decideRequest)
    #expect(try approvalRoundTrip(decideReply) == decideReply)
    #expect(try approvalRoundTrip(deniedRequest) == deniedRequest)
    #expect(try approvalRoundTrip(deniedReply) == deniedReply)
    #expect(try approvalRoundTrip(clearRequest) == clearRequest)
    #expect(try approvalRoundTrip(clearReply) == clearReply)
    #expect(try approvalRoundTrip(brokerReply) == brokerReply)
    #expect(try approvalRoundTrip(brokerError) == brokerError)
    #expect(try approvalRoundTrip(denied) == denied)

    let decisions: [WireIntegrationDecision] = [
        .off, .on, .readOnly, .readWrite, .android, .ask, .mac,
    ]
    #expect(try decisions.map(approvalRoundTrip) == decisions)
    let kinds: [IntegrationKind] = [
        .clipboard, .notifications, .links, .files, .sharedFolders, .microphone,
    ]
    #expect(try kinds.map(approvalRoundTrip) == kinds)
}
