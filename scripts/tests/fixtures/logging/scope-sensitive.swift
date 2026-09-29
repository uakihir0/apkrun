func privateValue(secret: Sensitive<String>, log: APKLogger) {
    log.info("secret \(secret, .private)")
}

func publicValue(secret: String, log: APKLogger) {
    log.info("public \(secret, .public)")
}
