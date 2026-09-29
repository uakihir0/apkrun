typealias SecretHandler = (Sensitive<String>) -> Void
let log = APKLogger(category: .command)
let callback: SecretHandler = { secret in
    log.info("token \(secret.value, .public)")
}
