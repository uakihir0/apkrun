import APKStoreCore
import Foundation
import RuntimeAPI
import Testing

@testable import UpdateCore

private func policyRecord(
    authority: UpdateAuthority, provider: UpdateProviderRef? = nil
) throws -> PackageRecord {
    let date = Date(timeIntervalSince1970: 0)
    return PackageRecord(
        packageId: try #require(PackageID(rawValue: "com.example.app")),
        displayName: "Example",
        versionCode: 1,
        signingCertificates: [
            try #require(SHA256Digest(hex: String(repeating: "d", count: 64)))
        ],
        installer: .apkrun,
        updateAuthority: authority,
        updateProvider: provider,
        state: .installed,
        artifacts: ArtifactSlots(currentMatchesAndroid: true),
        android: AndroidPackageFacts(
            minSdk: 24,
            targetSdk: 35,
            nativeAbis: [],
            userdataGeneration: UUID(uuidString: "622ec21f-5ab6-4077-8b13-293c025adcfb")!,
            lastSyncedAt: date
        ),
        source: PackageSource(kind: .file, at: date),
        createdAt: date,
        updatedAt: date)
}

private let localSpec = ProviderSpec(
    spec: "local:/tmp/repo", bookmark: Data("bookmark".utf8))

@Test func manualChoiceMapsToManualAuthorityAndMode() throws {
    let resolution = try UpdatePolicyRules.resolve(
        UpdatePolicy(choice: .manual),
        for: policyRecord(authority: .apkrun, provider: localProvider()))
    #expect(resolution.authority == .manual)
    #expect(resolution.settingsMode == "manual")
    #expect(resolution.removeProvider == false)
    // The provider stays so switching back to apkrun restores it (§2.3).
    #expect(resolution.requireProvider == false)
}

@Test func automaticAndNotifyOnlyNeedAProvider() throws {
    let record = try policyRecord(authority: .manual)
    for choice in [UpdateChoice.automatic, .notifyOnly] {
        #expect(throws: UpdateFailure.providerNotConfigured) {
            try UpdatePolicyRules.resolve(UpdatePolicy(choice: choice), for: record)
        }
    }
}

@Test func providerAttachmentMakesAuthorityApkrun() throws {
    let resolution = try UpdatePolicyRules.resolve(
        UpdatePolicy(choice: .automatic, provider: .set(localSpec)),
        for: policyRecord(authority: .manual))
    #expect(resolution.authority == .apkrun)
    #expect(resolution.settingsMode == "automatic")
    #expect(resolution.requireProvider)
    #expect(resolution.provider?.type == .local)
}

@Test func providerRemovalMakesAuthorityManual() throws {
    let resolution = try UpdatePolicyRules.resolve(
        UpdatePolicy(choice: .automatic, provider: .remove),
        for: policyRecord(authority: .apkrun, provider: localProvider()))
    #expect(resolution.authority == .manual)
    #expect(resolution.removeProvider)
}

@Test func googlePlayAndExternalRefuseEveryChoice() throws {
    for authority in [UpdateAuthority.googlePlay, .external] {
        for choice in UpdateChoice.allCases {
            #expect(throws: UpdateFailure.authorityDoesNotAllowUpdates) {
                try UpdatePolicyRules.resolve(
                    UpdatePolicy(choice: choice),
                    for: policyRecord(authority: authority))
            }
        }
    }
}

@Test func choiceReportedForAuthorityAndMode() throws {
    #expect(
        UpdatePolicyRules.choice(authority: .apkrun, mode: "automatic") == .automatic)
    #expect(
        UpdatePolicyRules.choice(authority: .apkrun, mode: "notifyOnly") == .notifyOnly)
    #expect(UpdatePolicyRules.choice(authority: .manual, mode: nil) == .manual)
    #expect(UpdatePolicyRules.choice(authority: .googlePlay, mode: "automatic") == nil)
    #expect(UpdatePolicyRules.choice(authority: .external, mode: nil) == nil)
}

private func localProvider() -> UpdateProviderRef {
    UpdateProviderRef(type: .local, configuration: .local(path: "/tmp/repo", bookmark: ""))
}
