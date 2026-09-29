let log = APKLogger(category: .command)
let callback: (Sensitive<String>) -> Void = { (secret: Sensitive<String>) in
    log.info("token \(secret.value, .public)")
}
