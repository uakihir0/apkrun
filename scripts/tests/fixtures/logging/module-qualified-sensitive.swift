let secret: DiagnosticsCore . Sensitive<String> = DiagnosticsCore . Sensitive<String>("token")
let log = DiagnosticsCore . APKLogger(category: .command)
log.info("token \(secret.value, .public)")
