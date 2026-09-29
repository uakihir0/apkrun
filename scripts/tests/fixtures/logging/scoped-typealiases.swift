typealias ScopedValue = Sensitive<String>
func logSensitive(_ value: ScopedValue, log: APKLogger) {
    log.info("sensitive \(value.value, .public)")
}

struct PublicScope {
    typealias ScopedValue = String

    func logPublic(_ value: ScopedValue, log: APKLogger) {
        log.info("public \(value, .public)")
    }
}

typealias ScopedLogger = Logger
struct LoggerShadow {
    typealias ScopedLogger = String
}
