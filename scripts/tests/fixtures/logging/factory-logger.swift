func makeLogger() -> APKLogger {
    APKLogger(category: .command)
}

func send(secret: Sensitive<String>) {
    let log = makeLogger()
    log.info("token \(secret.value, .public)")
}
