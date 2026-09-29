import DiagnosticsCore
import Foundation

enum ErrorOutput {
    static func render(_ error: any Error, json: Bool) -> String {
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
}

private struct InternalCommandFailure: APKRunError {
    static var domain: ErrorDomain { .runtime }
    var code: String { "internal" }
}
