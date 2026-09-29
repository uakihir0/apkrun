func send(secret: Sensitive<String>, log: APKLogger) {
    let alias = secret
    let aliasAgain = alias
    log.info("token \(aliasAgain.value, .public)")
}
