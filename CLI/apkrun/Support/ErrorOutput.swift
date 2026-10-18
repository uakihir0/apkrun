import DiagnosticsCore
import Foundation
import RuntimeAPI

enum ErrorOutput {
    static func render(_ error: any Error, json: Bool) -> String {
        if let wireError = error as? RuntimeWireError {
            return render(wireError, json: json)
        }
        let typedError = error as? any APKRunError ?? InternalCommandFailure()
        let presenter = ErrorPresenter()
        return json ? presenter.json(typedError) : presenter.cli(typedError)
    }

    static func write(_ error: any Error, json: Bool) {
        let text = render(error, json: json) + "\n"
        let data = Data(text.utf8)
        if json {
            FileHandle.standardOutput.write(data)
        } else {
            FileHandle.standardError.write(data)
        }
    }

    private static func render(_ error: RuntimeWireError, json: Bool) -> String {
        if json {
            let envelope = RuntimeWireErrorEnvelope(error: error)
            guard let data = try? JSONEncoder.sorted.encode(envelope),
                let text = String(data: data, encoding: .utf8)
            else {
                return
                    #"{"schemaVersion":1,"error":{"code":"runtime.internal","message":"APKRun couldn't complete the operation."}}"#
            }
            return text
        }

        var lines = ["error: \(error.message)"]
        if let remediation = error.remediation, !remediation.isEmpty {
            lines.append("hint: \(remediation)")
        }
        lines.append("code: \(error.code)")
        return lines.joined(separator: "\n")
    }
}

private struct InternalCommandFailure: APKRunError {
    static var domain: ErrorDomain { .runtime }
    var code: String { "internal" }
}

private struct RuntimeWireErrorEnvelope: Encodable {
    let schemaVersion = 1
    let error: Body

    init(error: RuntimeWireError) {
        self.error = Body(
            code: error.code,
            message: error.message,
            remediation: error.remediation
        )
    }

    struct Body: Encodable {
        let code: String
        let message: String
        let remediation: String?

        private enum CodingKeys: String, CodingKey {
            case code
            case message
            case remediation
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(remediation, forKey: .remediation)
        }
    }
}

extension JSONEncoder {
    fileprivate static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
