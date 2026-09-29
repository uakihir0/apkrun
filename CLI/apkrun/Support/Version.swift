import Foundation

struct VersionInformation: Codable, Equatable, Sendable {
    let marketingVersion: String
    let buildNumber: String
    let buildIdentity: String

    static let current = VersionInformation(infoDictionary: Bundle.main.infoDictionary ?? [:])

    init(marketingVersion: String, buildNumber: String, buildIdentity: String) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.buildIdentity = buildIdentity
    }

    private init(infoDictionary: [String: Any]) {
        marketingVersion = infoDictionary["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
        buildNumber = infoDictionary["CFBundleVersion"] as? String ?? "0"
        buildIdentity = infoDictionary["APKRunBuildIdentity"] as? String ?? "dev"
    }
}
