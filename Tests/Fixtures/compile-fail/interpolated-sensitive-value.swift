import DiagnosticsCore

let token = Sensitive("fixture-secret")
let message: LogMessage = "token \(token, .public)"
