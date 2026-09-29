typealias LocalLogger = APKLogger

func send(secret: Sensitive<String>, log: LocalLogger) {
    log.info("token \(secret.value, .public)")
}
