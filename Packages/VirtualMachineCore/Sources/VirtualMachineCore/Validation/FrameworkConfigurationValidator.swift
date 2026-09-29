import DiagnosticsCore
import Foundation
import Virtualization

package protocol FrameworkConfigurationValidator: Sendable {
    func validate(_ definition: VMDefinition) -> UnderlyingError?
}

struct VZFrameworkConfigurationValidator: FrameworkConfigurationValidator {
    func validate(_ definition: VMDefinition) -> UnderlyingError? {
        do {
            let attachments = try VZConfigurationBuilder.nullDeviceConsoleAttachments(
                count: definition.consolePorts.count
            )
            let configuration = try VZConfigurationBuilder.build(
                definition,
                consolePortAttachments: attachments
            )
            try configuration.validate()
            return nil
        } catch {
            let error = error as NSError
            return UnderlyingError(domain: error.domain, code: error.code)
        }
    }
}
