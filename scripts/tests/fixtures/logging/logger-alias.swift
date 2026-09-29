func send(secret: Sensitive<String>, log: APKLogger) {
    let alias = log
    alias.info("token \(secret.value, .public)")
}
