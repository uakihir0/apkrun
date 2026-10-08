import DiagnosticsCore
import Foundation
import VirtioDeviceCore
import Virtualization

package protocol FrameworkConfigurationValidator: Sendable {
    func validate(_ definition: VMDefinition) -> FrameworkConfigurationFailure?
}

package enum FrameworkConfigurationFailure: Sendable {
    case customDeviceInvalid(name: String, reason: String)
    case rejected(UnderlyingError)
}

struct VZFrameworkConfigurationValidator: FrameworkConfigurationValidator {
    func validate(_ definition: VMDefinition) -> FrameworkConfigurationFailure? {
        // VZ configuration objects are created and validated only on a VM queue,
        // as Virtualization.framework requires. No controller exists yet here.
        VMQueue().performSynchronously {
            validateOnVMQueue(definition)
        }
    }

    private func validateOnVMQueue(_ definition: VMDefinition) -> FrameworkConfigurationFailure? {
        do {
            let attachments = try VZConfigurationBuilder.nullDeviceConsoleAttachments(
                count: definition.consolePorts.count
            )
            let buildResult = try VZConfigurationBuilder.build(
                definition,
                consolePortAttachments: attachments
            )
            try buildResult.configuration.validate()
            return nil
        } catch let failure as VZCustomVirtioDeviceAdapterFailure {
            guard case .invalidDescriptor(let name, let reason) = failure else {
                return .rejected(
                    UnderlyingError(
                        domain: (failure as NSError).domain,
                        code: (failure as NSError).code
                    )
                )
            }
            return .customDeviceInvalid(name: name, reason: reason)
        } catch {
            let error = error as NSError
            return .rejected(UnderlyingError(domain: error.domain, code: error.code))
        }
    }
}
