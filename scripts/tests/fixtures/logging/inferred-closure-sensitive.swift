let log = APKLogger(category: .command)
let callback: (Sensitive<String>) -> Void = { secret in
    log.info("token \(secret.value, .public)")
}
