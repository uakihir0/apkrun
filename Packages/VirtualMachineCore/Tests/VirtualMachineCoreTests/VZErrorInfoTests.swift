import DiagnosticsCore
import Foundation
import Testing

@testable import VirtualMachineCore

@Test func vzErrorInfoCopiesValuesAndExposesOnlySafeUnderlyingFields() throws {
    let original = NSError(
        domain: "VZErrorDomain",
        code: 42,
        userInfo: [NSLocalizedDescriptionKey: "Could not open /Users/alice/private/Image"]
    )
    let info = VZErrorInfo(original)

    #expect(info.domain == "VZErrorDomain")
    #expect(info.code == 42)
    #expect(info.description == "Could not open /Users/alice/private/Image")
    #expect(info.underlying == UnderlyingError(domain: "VZErrorDomain", code: 42))

    let failure = VMFailure.startFailed(underlying: info)
    #expect(failure.underlying == UnderlyingError(domain: "VZErrorDomain", code: 42))
    #expect(failure.parameters.isEmpty)
    #expect(!failure.parameters.values.contains(.text(info.description)))

    let presenter = ErrorPresenter(locale: Locale(identifier: "en"))
    let cliText = presenter.cli(failure)
    let jsonText = presenter.json(failure)
    let copyDetails = presenter.copyDetails(failure)
    let guiDetails = presenter.gui(failure).copyDetails
    for rendered in [cliText, jsonText, copyDetails, guiDetails] {
        #expect(!rendered.contains(info.description))
        #expect(!rendered.contains("/Users/alice"))
    }
    #expect(copyDetails.contains("underlying VZErrorDomain 42"))

    let json = try #require(
        JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any]
    )
    let error = try #require(json["error"] as? [String: Any])
    let underlying = try #require(error["underlying"] as? [String: Any])
    #expect(underlying["domain"] as? String == "VZErrorDomain")
    #expect(underlying["code"] as? Int == 42)
    #expect(underlying["description"] == nil)
}
