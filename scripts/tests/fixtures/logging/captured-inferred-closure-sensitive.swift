let log = APKLogger(category: .command)
let callback: (Sensitive<String>) -> Void = { [log] secret in
    log.info("token \(secret.value, .public)")
}
