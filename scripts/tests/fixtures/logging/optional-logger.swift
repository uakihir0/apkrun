func send(secret: Sensitive<String>, log: APKLogger?) {
    log?.info("token \(secret.value, .public)")
}
